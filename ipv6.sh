#!/bin/sh

# IPv6 one-click control script for common Linux distributions.
# Supports runtime status, temporary disable/enable, and persistent disable/enable.

SCRIPT_NAME=${0##*/}
MANAGED_SYSCTL_FILE="/etc/sysctl.d/99-ipv6-control.conf"

if [ -t 1 ]; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    BLUE=$(printf '\033[34m')
    BOLD=$(printf '\033[1m')
    RESET=$(printf '\033[0m')
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    RESET=""
fi

info() { printf '%s\n' "${BLUE}==>${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}OK:${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN:${RESET} $*"; }
err() { printf '%s\n' "${RED}ERROR:${RESET} $*" >&2; }

usage() {
    cat <<EOF
${BOLD}IPv6 control script${RESET}

Usage:
  ./${SCRIPT_NAME}                 Interactive menu
  ./${SCRIPT_NAME} status          Show IPv6 status
  ./${SCRIPT_NAME} disable-temp    Disable IPv6 until reboot or network reload
  ./${SCRIPT_NAME} disable-perm    Disable IPv6 persistently and apply now
  ./${SCRIPT_NAME} enable-temp     Enable IPv6 for current runtime
  ./${SCRIPT_NAME} enable-perm     Remove this script's persistent disable file and apply now
  ./${SCRIPT_NAME} help            Show this help

Examples:
  sudo ./${SCRIPT_NAME} disable-perm
  sudo ./${SCRIPT_NAME} enable-perm
  ./${SCRIPT_NAME} status
EOF
}

is_root() {
    [ "$(id -u 2>/dev/null)" = "0" ]
}

need_root() {
    if ! is_root; then
        err "This action requires root. Please run with sudo or as root."
        exit 1
    fi
}

ipv6_kernel_available() {
    [ -d /proc/sys/net/ipv6/conf ]
}

need_ipv6_kernel() {
    if ! ipv6_kernel_available; then
        err "IPv6 kernel controls are not available. IPv6 may be missing from this kernel/container."
        exit 1
    fi
}

set_disable_flag_path() {
    path=$1
    value=$2

    if [ -e "$path" ]; then
        if ( printf '%s\n' "$value" > "$path" ) 2>/dev/null; then
            return 0
        fi
        warn "Failed to write $path"
        return 1
    fi

    return 0
}

apply_runtime_value() {
    value=$1

    need_root
    need_ipv6_kernel

    failed=0
    for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [ -e "$path" ] || continue
        if ! set_disable_flag_path "$path" "$value"; then
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        err "Some IPv6 runtime flags could not be changed."
        return 1
    fi

    return 0
}

disable_temp() {
    info "Disabling IPv6 for the current runtime..."
    apply_runtime_value 1
    ok "IPv6 has been disabled temporarily."
    warn "This may be reset after reboot, network service reload, or interface recreation."
}

enable_temp() {
    info "Enabling IPv6 for the current runtime..."
    apply_runtime_value 0
    ok "IPv6 has been enabled for the current runtime."
    warn "If another sysctl file disables IPv6 at boot, it may be disabled again after reboot."
}

write_persistent_disable_file() {
    need_root

    if [ ! -d /etc/sysctl.d ]; then
        mkdir -p /etc/sysctl.d || {
            err "Failed to create /etc/sysctl.d"
            exit 1
        }
    fi

    tmp_file="${MANAGED_SYSCTL_FILE}.$$"
    umask 022
    {
        printf '%s\n' "# Managed by ${SCRIPT_NAME}"
        printf '%s\n' "# Remove this file or run: ${SCRIPT_NAME} enable-perm"
        printf '%s\n' "net.ipv6.conf.all.disable_ipv6 = 1"
        printf '%s\n' "net.ipv6.conf.default.disable_ipv6 = 1"
        printf '%s\n' "net.ipv6.conf.lo.disable_ipv6 = 1"
    } > "$tmp_file" || {
        err "Failed to write $tmp_file"
        exit 1
    }

    mv "$tmp_file" "$MANAGED_SYSCTL_FILE" || {
        rm -f "$tmp_file" 2>/dev/null
        err "Failed to install $MANAGED_SYSCTL_FILE"
        exit 1
    }
}

disable_perm() {
    info "Installing persistent IPv6 disable sysctl file..."
    write_persistent_disable_file
    ok "Persistent config written to $MANAGED_SYSCTL_FILE"

    info "Applying disable setting now..."
    apply_runtime_value 1
    ok "IPv6 is disabled now and will stay disabled after reboot on normal sysctl-based systems."
}

remove_persistent_disable_file() {
    need_root

    if [ -f "$MANAGED_SYSCTL_FILE" ]; then
        rm -f "$MANAGED_SYSCTL_FILE" || {
            err "Failed to remove $MANAGED_SYSCTL_FILE"
            exit 1
        }
        ok "Removed $MANAGED_SYSCTL_FILE"
    else
        info "No managed persistent config found at $MANAGED_SYSCTL_FILE"
    fi
}

enable_perm() {
    info "Removing this script's persistent IPv6 disable config..."
    remove_persistent_disable_file

    info "Applying enable setting now..."
    apply_runtime_value 0
    ok "IPv6 is enabled now."

    report_other_persistent_disables
}

read_flag() {
    path=$1
    if [ -r "$path" ]; then
        sed -n '1p' "$path" 2>/dev/null
    else
        printf '%s' "unknown"
    fi
}

print_runtime_flags() {
    if ! ipv6_kernel_available; then
        printf 'Kernel IPv6 controls: unavailable\n'
        return
    fi

    printf 'Runtime disable flags:\n'
    for name in all default lo; do
        path="/proc/sys/net/ipv6/conf/${name}/disable_ipv6"
        [ -e "$path" ] || continue
        printf '  %-10s %s\n' "$name" "$(read_flag "$path")"
    done

    printed_header=0
    for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [ -e "$path" ] || continue
        name=${path%/disable_ipv6}
        name=${name##*/}
        case "$name" in
            all|default|lo) continue ;;
        esac
        if [ "$printed_header" -eq 0 ]; then
            printf 'Interface disable flags:\n'
            printed_header=1
        fi
        printf '  %-10s %s\n' "$name" "$(read_flag "$path")"
    done
}

print_ipv6_addresses() {
    printf 'IPv6 addresses:\n'

    if command -v ip >/dev/null 2>&1; then
        addr_output=$(ip -6 addr show 2>/dev/null)
        if [ -n "$addr_output" ]; then
            printf '%s\n' "$addr_output" | sed 's/^/  /'
        else
            printf '  none\n'
        fi
        if [ $? -eq 0 ]; then
            return
        fi
    fi

    if [ -r /proc/net/if_inet6 ]; then
        if [ ! -s /proc/net/if_inet6 ]; then
            printf '  none\n'
            return
        fi
        awk '{ print "  " $6 "  " $1 }' /proc/net/if_inet6 2>/dev/null || printf '  unable to read\n'
        return
    fi

    printf '  unavailable\n'
}

print_ipv6_routes() {
    printf 'IPv6 default route:\n'

    if command -v ip >/dev/null 2>&1; then
        route_output=$(ip -6 route show default 2>/dev/null)
        if [ -n "$route_output" ]; then
            printf '%s\n' "$route_output" | sed 's/^/  /'
        else
            printf '  none\n'
        fi
        return
    fi

    printf '  ip command unavailable\n'
}

report_other_persistent_disables() {
    found=0

    for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
        [ -f "$file" ] || continue
        [ "$file" = "$MANAGED_SYSCTL_FILE" ] && continue

        if grep -Eq '^[[:space:]]*net\.ipv6\.conf\..*\.disable_ipv6[[:space:]]*=[[:space:]]*1([[:space:]]*#.*)?$' "$file" 2>/dev/null; then
            if [ "$found" -eq 0 ]; then
                warn "Other persistent IPv6 disable entries still exist:"
                found=1
            fi
            printf '  %s\n' "$file"
        fi
    done

    if [ "$found" -ne 0 ]; then
        warn "Review those files if IPv6 becomes disabled again after reboot."
    fi
}

status() {
    printf '%s\n' "${BOLD}IPv6 status${RESET}"
    printf 'Managed persistent config: '
    if [ -f "$MANAGED_SYSCTL_FILE" ]; then
        printf '%s\n' "present ($MANAGED_SYSCTL_FILE)"
    else
        printf '%s\n' "absent"
    fi

    if ipv6_kernel_available; then
        printf 'Kernel IPv6 controls: available\n'
    else
        printf 'Kernel IPv6 controls: unavailable\n'
    fi

    print_runtime_flags
    print_ipv6_routes
    print_ipv6_addresses
    report_other_persistent_disables
}

menu() {
    while :; do
        printf '\n%s\n' "${BOLD}IPv6 one-click menu${RESET}"
        printf '  1) IPv6 status\n'
        printf '  2) Disable IPv6 temporarily\n'
        printf '  3) Disable IPv6 permanently\n'
        printf '  4) Enable IPv6 temporarily\n'
        printf '  5) Enable IPv6 permanently\n'
        printf '  0) Exit\n'
        printf 'Choose an option: '
        read choice || exit 1

        case "$choice" in
            1) status ;;
            2) disable_temp ;;
            3) disable_perm ;;
            4) enable_temp ;;
            5) enable_perm ;;
            0) exit 0 ;;
            *) warn "Invalid option: $choice" ;;
        esac
    done
}

case "${1:-}" in
    "")
        menu
        ;;
    status)
        status
        ;;
    disable-temp|temporary-disable|temp-disable)
        disable_temp
        ;;
    disable-perm|permanent-disable|perm-disable|disable)
        disable_perm
        ;;
    enable-temp|temporary-enable|temp-enable)
        enable_temp
        ;;
    enable-perm|permanent-enable|perm-enable|enable)
        enable_perm
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        err "Unknown command: $1"
        usage
        exit 1
        ;;
esac
