#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
case "$mode" in
    screen|window) ;;
    *) echo "Usage: inir screenshot <screen|window>" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

import_service_session_env() {
    [[ -n "${UMBRIEL_SOCKET:-}" || -n "${NIRI_SOCKET:-}" ]] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0

    local pid line key value
    pid="$(systemctl --user show inir.service -p MainPID --value 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -r "/proc/$pid/environ" ]] || return 0

    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            UMBRIEL_SOCKET|NIRI_SOCKET|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|XDG_CURRENT_DESKTOP|XDG_SESSION_DESKTOP|XDG_SESSION_TYPE)
                [[ -n "$value" ]] && export "$key=$value"
                ;;
        esac
    done < <(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)
}

import_service_session_env

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
config_file="$config_home/inir/config.json"
if [[ ! -r "$config_file" && -r "$config_home/illogical-impulse/config.json" ]]; then
    config_file="$config_home/illogical-impulse/config.json"
fi

save_dir=""
name_format="ss-%Y%m%d-%H%M%S"
if [[ -r "$config_file" ]]; then
    save_dir="$(jq -r '.regionSelector.savePath // empty' "$config_file" 2>/dev/null || true)"
    configured_format="$(jq -r '.regionSelector.screenshotNameFormat // empty' "$config_file" 2>/dev/null || true)"
    [[ -n "$configured_format" ]] && name_format="$configured_format"
fi
if [[ -z "$save_dir" ]]; then
    pictures_dir="$(xdg-user-dir PICTURES 2>/dev/null || true)"
    [[ -z "$pictures_dir" ]] && pictures_dir="$HOME/Pictures"
    save_dir="$pictures_dir/Screenshots"
fi

mkdir -p "$save_dir"
name="$(date "+$name_format")"
name="${name//\//-}"
path="$save_dir/$name.png"

if [[ -n "${UMBRIEL_SOCKET:-}" ]]; then
    command -v umbriel >/dev/null 2>&1 || { echo "umbriel not found" >&2; exit 1; }
    command -v grim >/dev/null 2>&1 || { echo "grim not found" >&2; exit 1; }
    case "$mode" in
        screen)
            output="$(umbriel workspaces --json | jq -r 'first(.[] | select(.focused == true)) | .output // empty')"
            [[ -n "$output" ]] || { echo "No focused Umbriel output" >&2; exit 1; }
            grim -o "$output" "$path"
            ;;
        window)
            window_id="$(umbriel windows --json | jq -r 'first(.[] | select(.focused == true)) | .id // empty')"
            [[ -n "$window_id" ]] || { echo "No focused Umbriel window" >&2; exit 1; }
            grim -T "$window_id" "$path"
            ;;
    esac
elif [[ -n "${NIRI_SOCKET:-}" ]]; then
    command -v niri >/dev/null 2>&1 || { echo "niri not found" >&2; exit 1; }
    case "$mode" in
        screen)
            command -v grim >/dev/null 2>&1 || { echo "grim not found" >&2; exit 1; }
            output="$(niri msg -j focused-output | jq -r '.name // empty')"
            [[ -n "$output" ]] || { echo "No focused Niri output" >&2; exit 1; }
            grim -o "$output" "$path"
            ;;
        window)
            window_id="$(niri msg -j focused-window | jq -r '.id // empty')"
            [[ -n "$window_id" ]] || { echo "No focused Niri window" >&2; exit 1; }
            niri msg action screenshot-window --id "$window_id" --path "$path" >/dev/null
            ;;
    esac
else
    echo "No supported compositor session detected" >&2
    exit 1
fi

command -v notify-send >/dev/null 2>&1 && notify-send "Screenshot saved" "$path" -a "iNiR" -i camera-photo -t 2500 || true
printf '%s\n' "$path"
