#!/usr/bin/env bash
# Close window — tries QS first (for confirm dialog), then the active compositor.
#
# Race condition protection:
# 1. We capture the focused window ID immediately (before spawn latency can shift focus).
# 2. If IPC fails/times out, we close the *captured* window by ID — not whatever is
#    focused at fallback time.
# 3. Because both paths target the same window by ID, an accidental double-close is a
#    harmless no-op instead of killing a random window.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
launcher_path="$script_dir/inir"

# Capture focused window JSON immediately — this is the window the user intended to close.
compositor=""
focused_window_json=""
if [ -n "${UMBRIEL_SOCKET:-}" ] && command -v umbriel >/dev/null 2>&1; then
    compositor="umbriel"
    focused_window_json=$(umbriel windows --json 2>/dev/null \
        | jq -c 'first(.[] | select(.focused == true)) // empty' 2>/dev/null)
elif [ -n "${NIRI_SOCKET:-}" ] && command -v niri >/dev/null 2>&1; then
    compositor="niri"
    focused_window_json=$(niri msg -j focused-window 2>/dev/null)
fi

focused_id=$(printf '%s' "$focused_window_json" | jq -r '.id // empty' 2>/dev/null)
focused_app_id=$(printf '%s' "$focused_window_json" | jq -r '.app_id // empty' 2>/dev/null)

close_focused() {
    if [ "$compositor" = "niri" ] && [ "${focused_app_id,,}" = "spotify" ]; then
        if [ -n "$focused_id" ]; then
            niri msg action move-window-to-workspace --window-id "$focused_id" --focus false 99 >/dev/null 2>&1
            return 0
        fi
    fi

    case "$compositor" in
        umbriel)
            if [ -n "$focused_id" ]; then
                umbriel msg "window-close:$focused_id"
            else
                umbriel msg window-close
            fi
            ;;
        niri)
            if [ -n "$focused_id" ]; then
                niri msg action close-window --id "$focused_id"
            else
                niri msg action close-window
            fi
            ;;
        *) return 1 ;;
    esac
}

# If QS is not running, close directly using the captured ID.
if ! pgrep -x qs >/dev/null 2>&1 && ! pgrep -x quickshell >/dev/null 2>&1; then
    close_focused
    exit 0
fi

# QS is running — pass the snapshot through IPC so confirmation and fast-close
# use the same window that was focused when the keybind fired.
if [ -n "$focused_id" ]; then
    ipc_args=(closeConfirm triggerWindow "$focused_id" "$focused_app_id")
else
    ipc_args=(closeConfirm trigger)
fi
if timeout 1 "$launcher_path" "${ipc_args[@]}" 2>/dev/null; then
    exit 0
fi

# Fallback — IPC failed or timed out. Close the originally captured window.
# If QS already processed the trigger (timeout just killed the client), both
# paths target the same window by ID, so the second close is a no-op.
close_focused
