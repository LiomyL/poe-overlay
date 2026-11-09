#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR=${POE_OVERLAY_STATE_DIR:-${XDG_STATE_HOME:-"$HOME/.local/state"}/poe-overlay}

command -v quickshell >/dev/null 2>&1 || {
    printf '%s\n' "quickshell is required but was not found in PATH." >&2
    exit 1
}
command -v "${POE_OVERLAY_PYTHON:-python3}" >/dev/null 2>&1 || {
    printf '%s\n' "Python 3 is required but was not found in PATH." >&2
    exit 1
}

mkdir -p "$STATE_DIR"
export POE_OVERLAY_STATE_DIR=$STATE_DIR
cd "$APP_DIR"
exec quickshell --path "$APP_DIR/shell.qml"