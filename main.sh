#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly ARGS=("$@")

# Script Information
get_scriptname() {
    local SOURCE
    local DIR
    SOURCE="${BASH_SOURCE[0]}"
    while [[ -h "${SOURCE}" ]]; do # resolve ${SOURCE} until the file is no longer a symlink
        DIR="$( cd -P "$( dirname "${SOURCE}" )" > /dev/null && pwd )"
        SOURCE="$(readlink "${SOURCE}")"
        [[ ${SOURCE} != /* ]] && SOURCE="${DIR}/${SOURCE}" # if ${SOURCE} was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    echo "${SOURCE}"
}

readonly SCRIPTNAME="$(get_scriptname)"
readonly SCRIPTPATH="$( cd -P "$( dirname "${SCRIPTNAME}" )" > /dev/null && pwd )"

# User/Group Information
readonly DETECTED_PUID=${SUDO_UID:-$UID}
readonly DETECTED_UNAME=$(id -un "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_PGID=$(id -g "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_UGROUP=$(id -gn "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_HOMEDIR=$(eval echo "~${DETECTED_UNAME}" 2> /dev/null || true)

# Colors
# https://misc.flogisoft.com/bash/tip_colors_and_formatting
readonly BLU='\e[34m'
readonly GRN='\e[32m'
readonly RED='\e[31m'
readonly YLW='\e[33m'
readonly ENDCOLOR='\e[0m'

# Log Functions
readonly LOG_FILE="/tmp/dockstarter.log"
sudo chown "${DETECTED_PUID:-$DETECTED_UNAME}":"${DETECTED_PGID:-$DETECTED_UGROUP}" "${LOG_FILE}" > /dev/null 2>&1 || true # This line should always use sudo
info()    { echo -e "$(date +"%F %T") ${BLU}[INFO]${ENDCOLOR}       $*" | tee -a "${LOG_FILE}" >&2 ; }
warning() { echo -e "$(date +"%F %T") ${YLW}[WARNING]${ENDCOLOR}    $*" | tee -a "${LOG_FILE}" >&2 ; }
error()   { echo -e "$(date +"%F %T") ${RED}[ERROR]${ENDCOLOR}      $*" | tee -a "${LOG_FILE}" >&2 ; }
fatal()   { echo -e "$(date +"%F %T") ${RED}[FATAL]${ENDCOLOR}      $*" | tee -a "${LOG_FILE}" >&2 ; exit 1 ; }

# Check Arch
readonly ARCH=$(uname -m)
if [[ ${ARCH} != "aarch64" ]] && [[ ${ARCH} != "armv7l" ]] && [[ ${ARCH} != "x86_64" ]]; then
    fatal "Unsupported architecture."
fi

# Github Token for Travis CI
if [[ ${CI:-} == true ]] && [[ ${TRAVIS:-} == true ]] && [[ ${TRAVIS_SECURE_ENV_VARS} == true ]]; then
    readonly GH_HEADER="Authorization: token ${GH_TOKEN}"
fi

# Check Systemd
if [[ -L "/sbin/init" ]]; then
    readonly ISSYSTEMD=true
else
    readonly ISSYSTEMD=false
fi

# Usage Information
#/ Usage: sudo ds [OPTION]
#/ NOTE: ds shortcut is only available after the first run of sudo bash ~/.docker/main.sh
#/
#/ This is the main DockSTARTer script.
#/ For regular usage you can run without providing any options.
#/
#/    -b --backup <min/med/max>     create a backup snapshot of your configs (see wiki more information)
#/    -c --compose                  run the docker-compose yml generator
#/    -e --env                      update your .env file with new variables
#/    -h --help                     show this usage information
#/    -i --install                  install docker and dependencies
#/    -p --prune                    remove all unused containers, networks, volumes, images and build cache
#/    -t --test <test_name>         run tests to check the program
#/    -u --update                   update DockSTARTer
##/    -v --verbose                  verbose
#/    -x --debug                    debug
#/
#/
#/ Examples:
#/    Run compose, env, help, install, prune, update:
#/    ds --compose
#/    or
#/    ds -c
#/
#/    Run backup:
#/    ds --backup min
#/    or
#/    ds -b min
#/
#/    Debug can be combined with any option but should be indicated before other options:
#/    ds --debug --update
#/    or
#/    ds -xu
#/
#/    Run Shellcheck test:
#/    ds --test validate_shellcheck
#/    or
#/    ds -t validate_shellcheck
#/
usage() {
    grep '^#/' "${SCRIPTNAME}" | cut -c4- || fatal "Failed to display usage information."
}

# Script Runner Function
run_script() {
    local SCRIPTSNAME="${1:-}"; shift
    if [[ -f ${SCRIPTPATH}/scripts/${SCRIPTSNAME}.sh ]]; then
        # shellcheck source=/dev/null
        source "${SCRIPTPATH}/scripts/${SCRIPTSNAME}.sh"
        ${SCRIPTSNAME} "$@";
    else
        fatal "${SCRIPTPATH}/scripts/${SCRIPTSNAME}.sh not found."
    fi
}

# Test Runner Function
run_test() {
    local TESTSNAME="${1:-}"; shift
    if [[ -f ${SCRIPTPATH}/tests/${TESTSNAME}.sh ]]; then
        # shellcheck source=/dev/null
        source "${SCRIPTPATH}/tests/${TESTSNAME}.sh"
        ${TESTSNAME} "$@";
    else
        fatal "${SCRIPTPATH}/tests/${TESTSNAME}.sh not found."
    fi
}

# Cleanup Function
cleanup() {
    if [[ ${SCRIPTPATH} == "${DETECTED_HOMEDIR}/.docker" ]]; then
        chmod +x "${SCRIPTNAME}" > /dev/null 2>&1 || fatal "ds must be executable."
    fi
    if [[ ${CI:-} == true ]] && [[ ${TRAVIS:-} == true ]] && [[ ${TRAVIS_SECURE_ENV_VARS} == false ]]; then
        warning "TRAVIS_SECURE_ENV_VARS is false for Pull Requests from remote branches. Please retry failed builds!"
    fi
}
trap 'cleanup' 0 1 2 3 6 14 15

# Main Function
main() {
    if [[ ${CI:-} != true ]] && [[ ${TRAVIS:-} != true ]] && [[ -z ${ARGS[*]:-} ]]; then
        if [[ ! -d ${DETECTED_HOMEDIR}/.docker/.git ]]; then
            warning "Attempting to clone DockSTARTer repo to ${DETECTED_HOMEDIR}/.docker location."
            git clone https://github.com/GhostWriters/DockSTARTer "${DETECTED_HOMEDIR}/.docker" || fatal "Failed to clone DockSTARTer repo to ${DETECTED_HOMEDIR}/.docker location."
            info "Performing first run install."
            (sudo bash "${DETECTED_HOMEDIR}/.docker/main.sh" "-i") || fatal "Failed first run install, please reboot and try again."
            exit
        elif [[ ${SCRIPTPATH} != "${DETECTED_HOMEDIR}/.docker" ]]; then
            (sudo bash "${DETECTED_HOMEDIR}/.docker/main.sh" "-u") || true
            warning "Attempting to run DockSTARTer from ${DETECTED_HOMEDIR}/.docker location."
            (sudo bash "${DETECTED_HOMEDIR}/.docker/main.sh") || true
            exit
        fi
    fi
    run_script 'root_check'
    run_script 'symlink_ds'
    # shellcheck source=scripts/cmdline.sh
    source "${SCRIPTPATH}/scripts/cmdline.sh"
    cmdline "${ARGS[@]:-}"
    readonly PROMPT="menu"
    run_script 'menu_main'
}
main
