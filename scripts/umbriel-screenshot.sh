#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
case "$mode" in
    screen|window) ;;
    *) echo "Usage: inir umbriel-screenshot <screen|window>" >&2; exit 2 ;;
esac

command -v umbriel >/dev/null 2>&1 || { echo "umbriel not found" >&2; exit 1; }
command -v grim >/dev/null 2>&1 || { echo "grim not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
config_file="$config_home/inir/config.json"
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

command -v notify-send >/dev/null 2>&1 && notify-send "Screenshot saved" "$path" -a "iNiR" -i camera-photo -t 2500 || true
printf '%s\n' "$path"
