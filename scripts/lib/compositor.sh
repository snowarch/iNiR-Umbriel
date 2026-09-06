#!/usr/bin/env bash

inir_detect_compositor_service() {
    command -v systemctl >/dev/null 2>&1 || return 1

    local manager_env=""
    manager_env="$(systemctl --user show-environment 2>/dev/null || true)"

    if [[ -n "${UMBRIEL_SOCKET:-}" ]] || grep -q '^UMBRIEL_SOCKET=' <<< "$manager_env"; then
        if systemctl --user cat umbriel-session.target >/dev/null 2>&1; then
            printf 'umbriel-session.target\n'
            return 0
        fi
    fi
    if [[ -n "${NIRI_SOCKET:-}" ]] || grep -q '^NIRI_SOCKET=' <<< "$manager_env"; then
        if systemctl --user cat niri.service >/dev/null 2>&1; then
            printf 'niri.service\n'
            return 0
        fi
    fi

    local umbriel_active=false niri_active=false
    systemctl --user is-active --quiet umbriel-session.target >/dev/null 2>&1 && umbriel_active=true
    systemctl --user is-active --quiet niri.service >/dev/null 2>&1 && niri_active=true
    if [[ "$umbriel_active" == true && "$niri_active" == false ]]; then
        printf 'umbriel-session.target\n'
        return 0
    fi
    if [[ "$niri_active" == true && "$umbriel_active" == false ]]; then
        printf 'niri.service\n'
        return 0
    fi

    local user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local existing=""
    local target
    for target in niri.service umbriel-session.target; do
        if [[ -e "$user_dir/${target}.wants/inir.service" || -L "$user_dir/${target}.wants/inir.service" ]]; then
            if [[ -n "$existing" ]]; then
                existing=""
                break
            fi
            existing="$target"
        fi
    done
    if [[ -n "$existing" ]]; then
        printf '%s\n' "$existing"
        return 0
    fi

    local niri_available=false umbriel_available=false
    systemctl --user cat niri.service >/dev/null 2>&1 && niri_available=true
    systemctl --user cat umbriel-session.target >/dev/null 2>&1 && umbriel_available=true
    if [[ "$niri_available" == true && "$umbriel_available" == false ]]; then
        printf 'niri.service\n'
        return 0
    fi
    if [[ "$umbriel_available" == true && "$niri_available" == false ]]; then
        printf 'umbriel-session.target\n'
        return 0
    fi
    return 1
}

inir_write_compositor_lifecycle_dropin() {
    local target="$1"
    local user_dir="${2:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
    case "$target" in
        niri.service|umbriel-session.target) ;;
        *) return 1 ;;
    esac

    local dropin_dir="$user_dir/inir.service.d"
    local dropin="$dropin_dir/compositor.conf"
    local tmp="$dropin.tmp.$$"
    mkdir -p "$dropin_dir"
    cat > "$tmp" <<EOF_DROPIN
[Unit]
PartOf=
Requisite=
After=
PartOf=$target
Requisite=$target
After=$target
EOF_DROPIN
    if [[ -f "$dropin" ]] && cmp -s "$tmp" "$dropin"; then
        rm -f "$tmp"
        return 0
    fi
    mv -f "$tmp" "$dropin"
}
