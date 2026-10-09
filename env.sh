#!/usr/bin/env bash

# Supports both `source ./env.sh` (Bash/Zsh) and `./env.sh command ...`.
STORAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
export NIMBLE_DIR="${NIMBLE_DIR:-${STORAGE_ROOT}/nimbledeps}"
if [ "$#" -gt 0 ]; then
  exec nimble --nimbleDir:"${NIMBLE_DIR}" shell "$@"
else
  eval "$(nimble --nimbleDir:"${NIMBLE_DIR}" shellenv)"
fi
