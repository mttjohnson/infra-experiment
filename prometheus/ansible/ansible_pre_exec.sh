#!/usr/bin/env bash

set -eu

# static code analysis:
##   shellcheck ansible_pre_exec.sh

# check whether user had supplied -h or --help . If yes display usage
if [[ ($* == "--help") || $* == "-h" ]]; then
    echo "Description: Used to rotate log files and install Ansible Galaxy dependencies"
    echo "Usage: source ${0##*/}"
    exit 0
fi

# Text Color Variables
# ---------------------------------------------------------------
# Reset
Color_Off='\033[0m'       # Text Reset
# Regular Colors
Yellow='\033[0;33m'       # Yellow
YellowBlink='\033[5;33m'  # Yellow (blinking)
Cyan='\033[0;36m'         # Cyan
# Bold
BRed='\033[1;31m'         # Red

# Check to make sure this script is being sourced, if not abort with error
sourced=0
if [ -n "${ZSH_EVAL_CONTEXT-}" ]; then 
  case $ZSH_EVAL_CONTEXT in *:file) sourced=1;; esac
elif [ -n "$BASH_VERSION" ]; then
  (return 0 2>/dev/null) && sourced=1 
fi

if [ "${sourced}" = "0" ]; then
    echo -e "${BRed}[ERROR] Script must be sourced${Color_Off}"
    echo -e "${YellowBlink}   source ${0##*/}${Color_Off}"
    exit 1
fi



# Change to the directory the script is in
if [ -n "${ZSH_EVAL_CONTEXT-}" ]; then
  echo "zsh   ${(%):-%N}"
  pushd "$(cd -P -- "$(dirname -- "${(%):-%N}")" && pwd -P)"
elif [ -n "$BASH_VERSION" ]; then
  echo "bash   ${BASH_SOURCE[0]}"
  pushd "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
else
  >&2 echo "ERROR: Unable to determine shell type (zsh, bash)"
  exit 5
fi

# Set Ansible environment variable configurations
echo "Setting Ansible environment variable configurations"
ANSIBLE_FORCE_COLOR=1
export ANSIBLE_FORCE_COLOR
PYTHONUNBUFFERED=1
export PYTHONUNBUFFERED

# Rotate log files
echo "Rotating log files"
mkdir -p logs
if [ -f "logs/ansible.log" ]; then
  find ./logs -maxdepth 1 -type f -name "*.log" | sort -rn | awk 'NR>10 {print $1}' | xargs rm -rf
  mv logs/ansible.log "logs/$(date +%Y-%m-%d_%H-%M-%S)_ansible.log"
fi

# Load pipenv shell
pipenv sync
source "$(pipenv --venv)/bin/activate"

# Install Ansible Galaxy dependencies
echo "Installing Ansible Galaxy dependencies"
FORCE_UPDATE_ANSIBLE_DEPENDENCIES="${FORCE_UPDATE_ANSIBLE_DEPENDENCIES:---force}"
ansible-galaxy role install -r ansible_requirements.yml "${FORCE_UPDATE_ANSIBLE_DEPENDENCIES}"
ansible-galaxy collection install -r ansible_requirements.yml

# Run ansible requirements script for misc requirements
./ansible_requirements.sh

# Change back to the directory originally called from
popd

set +eu
