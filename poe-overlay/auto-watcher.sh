#!/usr/bin/env bash
set -uo pipefail

POE1_CLASS=${POE1_CLASS:-steam_app_238960}
POLL_INTERVAL=${POE_OVERLAY_POLL_INTERVAL:-0.35}
GEOMETRY_FILE=${POE_OVERLAY_GEOMETRY_FILE:-/tmp/poe-overlay-hud-geometry}

resolve_overlay_config() {
    if [[ -n ${POE_OVERLAY_CONFIG:-} && -f $POE_OVERLAY_CONFIG ]]; then
        printf '%s\n' "$(realpath "$POE_OVERLAY_CONFIG")"
        return 0
    fi

    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    for candidate in \
        "$script_dir/shell.qml" \
        "$script_dir/../shell.qml" \
        "$HOME/poe-overlay/shell.qml" \
        "$HOME/poe-overlay-git/shell.qml" \
        "$HOME/.local/share/poe-overlay/shell.qml" \
        "$HOME/.config/poe-overlay/shell.qml"; do
        if [[ -f $candidate ]]; then
            printf '%s\n' "$(realpath "$candidate")"
            return 0
        fi
    done

    printf 'Overlay config not found. Set POE_OVERLAY_CONFIG to the absolute path of shell.qml.\n' >&2
    return 1
}

usage() {
    printf 'Usage: %s [toggle-overlay|open-build|open-build-viewer|route-cursor-backward|route-cursor-forward]\n' "$0" >&2
}

OVERLAY_CONFIG=$(resolve_overlay_config) || exit 1

if (($# > 0)); then
    case $1 in
        toggle-overlay) command_name=toggleHud ;;
        open-build) command_name=openBuild ;;
        open-build-viewer) command_name=toggleBuildViewer ;;
        route-cursor-forward) command_name=routeCursorForward ;;
        route-cursor-backward) command_name=routeCursorBackward ;;
        *) usage; exit 2 ;;
    esac
    exec quickshell ipc --path "$OVERLAY_CONFIG" call poe-overlay "$command_name"
fi

for dependency in quickshell hyprctl jq python3; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$dependency" >&2
        exit 1
    fi
done

get_poe1_workspace() {
    hyprctl clients -j 2>/dev/null \
        | jq -r --arg class "$POE1_CLASS" '[.[] | select(.class == $class) | .workspace.id][0] // empty'
}

get_active_workspace() {
    hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty'
}

is_overlay_running() {
    quickshell list --all --json 2>/dev/null \
        | jq -e --arg config "$OVERLAY_CONFIG" \
            'any(.[]; .config_path == $config)' >/dev/null
}

start_overlay() {
    is_overlay_running && return 0
    env -u DISPLAY -u GDK_BACKEND -u XDG_SESSION_TYPE QT_QPA_PLATFORM=wayland \
        quickshell --no-duplicate --path "$OVERLAY_CONFIG" >/dev/null 2>&1 &
}

stop_overlay() {
    local instance_id
    while IFS= read -r instance_id; do
        [[ -n $instance_id ]] || continue
        quickshell kill --id "$instance_id" >/dev/null 2>&1 || true
    done < <(
        quickshell list --all --json 2>/dev/null \
            | jq -r --arg config "$OVERLAY_CONFIG" \
                '.[] | select(.config_path == $config) | .id'
    )
}

cursor_over_hud() {
    local hud_x hud_y hud_width hud_height hud_visible hud_enabled
    local cursor cursor_x cursor_y
    [[ -r $GEOMETRY_FILE ]] || return 1
    read -r hud_x hud_y hud_width hud_height hud_visible hud_enabled < "$GEOMETRY_FILE" || return 1
    [[ $hud_x =~ ^-?[0-9]+$ && $hud_y =~ ^-?[0-9]+$ \
        && $hud_width =~ ^[0-9]+$ && $hud_height =~ ^[0-9]+$ ]] || return 1
    ((hud_width > 0 && hud_height > 0)) || return 1

    cursor=$(hyprctl cursorpos -j 2>/dev/null) || return 1
    cursor_x=$(printf '%s' "$cursor" | jq -r '.x // empty') || return 1
    cursor_y=$(printf '%s' "$cursor" | jq -r '.y // empty') || return 1
    [[ $cursor_x =~ ^-?[0-9]+$ && $cursor_y =~ ^-?[0-9]+$ ]] || return 1
    ((cursor_x >= hud_x && cursor_x < hud_x + hud_width \
        && cursor_y >= hud_y && cursor_y < hud_y + hud_height))
}

set_hud_visibility() {
    local desired=$1
    local hud_visible hud_enabled command_name
    local unused_x unused_y unused_width unused_height

    if [[ -r $GEOMETRY_FILE ]]; then
        read -r unused_x unused_y unused_width unused_height hud_visible hud_enabled < "$GEOMETRY_FILE" || true
    else
        hud_visible=1
        hud_enabled=1
    fi
    [[ ${hud_visible:-} =~ ^[01]$ && ${hud_enabled:-} =~ ^[01]$ ]] || {
        hud_visible=1
        hud_enabled=1
    }

    if [[ $desired == visible ]]; then
        [[ $hud_visible == 1 || $hud_enabled == 0 ]] && return 0
        command_name=showHud
    else
        [[ $hud_visible == 0 ]] && return 0
        command_name=hideHud
    fi

    quickshell ipc --path "$OVERLAY_CONFIG" call poe-overlay "$command_name" >/dev/null 2>&1 || true
}

cleanup() {
    stop_overlay
}
trap cleanup EXIT
trap 'exit 0' INT TERM

while true; do
    poe_workspace=$(get_poe1_workspace)

    if [[ -z $poe_workspace ]]; then
        if is_overlay_running; then
            stop_overlay
        fi
    else
        start_overlay
        active_workspace=$(get_active_workspace)
        if [[ $active_workspace == "$poe_workspace" ]] && ! cursor_over_hud; then
            set_hud_visibility visible
        else
            set_hud_visibility hidden
        fi
    fi

    sleep "$POLL_INTERVAL"
done
