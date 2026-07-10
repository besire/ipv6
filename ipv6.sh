#!/bin/sh

# Simple IPv6 runtime and persistent configuration manager for Linux.

VERSION="1.0.0"
SCRIPT_NAME=${0##*/}
case "$0" in
    /dev/fd/*|/proc/*/fd/*|/dev/stdin|-)
        SCRIPT_NAME="ipv6.sh"
        ;;
esac
case "$SCRIPT_NAME" in
    sh|dash|ash|bash|"") SCRIPT_NAME="ipv6.sh" ;;
esac

IPV6_CONF_DIR="/proc/sys/net/ipv6/conf"
IF_INET6_FILE="/proc/net/if_inet6"
MANAGED_SYSCTL_FILE="/etc/sysctl.d/99-ipv6-control.conf"
MANAGED_MARKER="# Managed by ipv6-control"
TMP_FILE=""

if [ -t 1 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-}" != "dumb" ]; then
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

info() { printf '%s\n' "${BLUE}提示:${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}成功:${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}警告:${RESET} $*"; }
err() { printf '%s\n' "${RED}错误:${RESET} $*" >&2; }

usage() {
    cat <<EOF
${BOLD}IPv6 Control ${VERSION}${RESET}

用法:
  ./${SCRIPT_NAME}                 交互菜单
  ./${SCRIPT_NAME} status          简洁状态
  ./${SCRIPT_NAME} status-full     详细状态
  ./${SCRIPT_NAME} disable-temp    临时关闭 IPv6
  ./${SCRIPT_NAME} disable-perm    永久关闭 IPv6 并立即应用
  ./${SCRIPT_NAME} enable-temp     临时开启 IPv6
  ./${SCRIPT_NAME} enable-perm     移除本工具配置并立即开启 IPv6
  ./${SCRIPT_NAME} version         显示版本
  ./${SCRIPT_NAME} help            显示帮助

退出码: 0=成功，1=操作失败，2=参数错误
EOF
}

is_root() {
    [ "$(id -u 2>/dev/null)" = "0" ]
}

require_root() {
    if is_root; then
        return 0
    fi
    err "该操作需要 root 权限，请使用 sudo。"
    return 1
}

ipv6_kernel_available() {
    [ -d "$IPV6_CONF_DIR" ]
}

require_ipv6_kernel() {
    if ipv6_kernel_available; then
        return 0
    fi
    err "当前内核或网络命名空间没有 IPv6 控制接口。"
    return 1
}

read_flag() {
    rf_path=$1
    if [ ! -r "$rf_path" ]; then
        printf '%s' "unknown"
        return 1
    fi
    rf_value=$(sed -n '1p' "$rf_path" 2>/dev/null) || rf_value=""
    case "$rf_value" in
        0|1) printf '%s' "$rf_value" ;;
        *) printf '%s' "unknown"; return 1 ;;
    esac
}

flag_label() {
    case "$1" in
        0) printf '%s' "已开启" ;;
        1) printf '%s' "已关闭" ;;
        *) printf '%s' "未知" ;;
    esac
}

set_flag() {
    sf_path=$1
    sf_value=$2

    if [ ! -e "$sf_path" ]; then
        warn "控制文件已消失：$sf_path"
        return 1
    fi
    if ! (printf '%s\n' "$sf_value" > "$sf_path") 2>/dev/null; then
        warn "写入失败：$sf_path"
        return 1
    fi
    sf_actual=$(read_flag "$sf_path") || sf_actual="unknown"
    if [ "$sf_actual" != "$sf_value" ]; then
        warn "写入校验失败：$sf_path"
        return 1
    fi
    return 0
}

apply_runtime_value() {
    ar_value=$1
    case "$ar_value" in
        0|1) ;;
        *) err "无效控制值：$ar_value"; return 1 ;;
    esac

    require_root || return 1
    require_ipv6_kernel || return 1

    ar_found=0
    ar_unwritable=0
    for ar_path in "$IPV6_CONF_DIR"/*/disable_ipv6; do
        [ -e "$ar_path" ] || continue
        ar_found=$((ar_found + 1))
        if [ ! -w "$ar_path" ]; then
            warn "控制文件不可写：$ar_path"
            ar_unwritable=1
        fi
    done

    if [ "$ar_found" -eq 0 ]; then
        err "没有找到 disable_ipv6 控制文件。"
        return 1
    fi
    if [ "$ar_unwritable" -ne 0 ]; then
        err "控制文件不可写，未开始修改。"
        return 1
    fi

    ar_failed=0
    for ar_name in default all; do
        ar_path="$IPV6_CONF_DIR/$ar_name/disable_ipv6"
        [ -e "$ar_path" ] || continue
        set_flag "$ar_path" "$ar_value" || ar_failed=1
    done
    for ar_path in "$IPV6_CONF_DIR"/*/disable_ipv6; do
        [ -e "$ar_path" ] || continue
        ar_name=${ar_path%/disable_ipv6}
        ar_name=${ar_name##*/}
        case "$ar_name" in all|default) continue ;; esac
        set_flag "$ar_path" "$ar_value" || ar_failed=1
    done

    if [ "$ar_failed" -ne 0 ]; then
        err "部分 IPv6 标志修改失败，当前状态可能不一致。"
        return 1
    fi
    return 0
}

warn_ipv6_ssh() {
    ssh_info=${SSH_CONNECTION:-${SSH_CLIENT:-}}
    case "$ssh_info" in
        *:*) warn "当前 SSH 会话使用 IPv6，关闭后连接可能立即中断。" ;;
    esac
}

disable_temp() {
    warn_ipv6_ssh
    info "正在临时关闭 IPv6..."
    if ! apply_runtime_value 1; then
        err "临时关闭未完成。"
        return 1
    fi
    ok "IPv6 已临时关闭。"
    warn "重启、网络服务重载或网卡重建后可能恢复。"
}

enable_temp() {
    info "正在临时开启 IPv6..."
    if ! apply_runtime_value 0; then
        err "临时开启未完成。"
        return 1
    fi
    ok "IPv6 内核开关已开启。"
    warn "地址和路由可能需要网络服务重新配置。"
    report_other_persistent_disables
}

emit_managed_config() {
    printf '%s\n' "$MANAGED_MARKER"
    printf '%s\n' '# Run "ipv6.sh enable-perm" to remove this file.'
    printf '%s\n' 'net.ipv6.conf.all.disable_ipv6 = 1'
    printf '%s\n' 'net.ipv6.conf.default.disable_ipv6 = 1'
    printf '%s\n' 'net.ipv6.conf.lo.disable_ipv6 = 1'
}

is_current_managed_file() {
    im_file=$1
    [ -f "$im_file" ] && [ ! -L "$im_file" ] || return 1
    emit_managed_config | cmp -s - "$im_file"
}

is_legacy_managed_file() {
    il_file=$1
    [ -f "$il_file" ] && [ ! -L "$il_file" ] || return 1
    awk '
        BEGIN { ok = 1 }
        NR == 1 && $0 !~ /^# (Managed by (ipv6\.sh|[0-9]+)|由 (ipv6\.sh|[0-9]+) 管理)$/ { ok = 0 }
        NR == 2 && $0 !~ /^# (Remove this file or run: (ipv6\.sh|[0-9]+) enable-perm|删除此文件，或执行：(ipv6\.sh|[0-9]+) enable-perm)$/ { ok = 0 }
        NR == 3 && $0 != "net.ipv6.conf.all.disable_ipv6 = 1" { ok = 0 }
        NR == 4 && $0 != "net.ipv6.conf.default.disable_ipv6 = 1" { ok = 0 }
        NR == 5 && $0 != "net.ipv6.conf.lo.disable_ipv6 = 1" { ok = 0 }
        NR > 5 { ok = 0 }
        END { exit (ok && NR == 5 ? 0 : 1) }
    ' "$il_file" 2>/dev/null
}

managed_file_kind() {
    mf_file=${1:-$MANAGED_SYSCTL_FILE}
    if [ -L "$mf_file" ]; then
        printf '%s' "conflict"
    elif [ ! -e "$mf_file" ]; then
        printf '%s' "absent"
    elif is_current_managed_file "$mf_file"; then
        printf '%s' "current"
    elif is_legacy_managed_file "$mf_file"; then
        printf '%s' "legacy"
    else
        printf '%s' "conflict"
    fi
}

cleanup_tmp() {
    if [ -n "${TMP_FILE:-}" ]; then
        rm -f "$TMP_FILE" 2>/dev/null || :
        TMP_FILE=""
    fi
}

write_persistent_config() {
    require_root || return 1

    wpc_kind=$(managed_file_kind "$MANAGED_SYSCTL_FILE")
    case "$wpc_kind" in
        current|legacy) return 0 ;;
        conflict)
            err "不会覆盖同名的非托管或已修改文件：$MANAGED_SYSCTL_FILE"
            return 1
            ;;
    esac

    wpc_dir=${MANAGED_SYSCTL_FILE%/*}
    if [ ! -d "$wpc_dir" ]; then
        (umask 022; mkdir -p "$wpc_dir") || {
            err "创建目录失败：$wpc_dir"
            return 1
        }
    fi

    TMP_FILE=$(mktemp "${MANAGED_SYSCTL_FILE}.tmp.XXXXXX") || {
        err "创建临时配置失败。"
        TMP_FILE=""
        return 1
    }
    if ! emit_managed_config > "$TMP_FILE" ||
       ! chmod 0644 "$TMP_FILE" ||
       ! mv "$TMP_FILE" "$MANAGED_SYSCTL_FILE"; then
        err "安装永久配置失败：$MANAGED_SYSCTL_FILE"
        cleanup_tmp
        return 1
    fi
    TMP_FILE=""
    return 0
}

remove_persistent_config() {
    require_root || return 1
    rpc_kind=$(managed_file_kind "$MANAGED_SYSCTL_FILE")
    case "$rpc_kind" in
        absent)
            info "未找到本工具管理的永久配置。"
            return 0
            ;;
        current|legacy)
            if rm -f "$MANAGED_SYSCTL_FILE"; then
                ok "已删除：$MANAGED_SYSCTL_FILE"
                return 0
            fi
            err "删除失败：$MANAGED_SYSCTL_FILE"
            return 1
            ;;
        *)
            err "同名文件不是本工具的完整配置，拒绝删除：$MANAGED_SYSCTL_FILE"
            return 1
            ;;
    esac
}

disable_perm() {
    require_root || return 1
    require_ipv6_kernel || return 1
    warn_ipv6_ssh
    info "正在安装永久关闭配置..."
    if ! write_persistent_config; then
        return 1
    fi
    ok "永久配置已安装：$MANAGED_SYSCTL_FILE"
    info "正在立即关闭 IPv6..."
    if ! apply_runtime_value 1; then
        err "永久配置已安装，但立即关闭失败或仅部分完成。"
        return 1
    fi
    ok "IPv6 已关闭。"
}

enable_perm() {
    info "正在移除本工具的永久关闭配置..."
    if ! remove_persistent_config; then
        return 1
    fi
    info "正在立即开启 IPv6..."
    if ! apply_runtime_value 0; then
        err "永久配置已移除，但立即开启失败或仅部分完成。"
        return 1
    fi
    ok "IPv6 内核开关已开启。"
    warn "地址和路由可能需要网络服务重新配置。"
    report_other_persistent_disables
}

runtime_state() {
    if ! ipv6_kernel_available; then
        printf '%s' "unavailable"
        return 1
    fi

    rs_enabled=0
    rs_disabled=0
    rs_unknown=0
    rs_seen=0
    for rs_path in "$IPV6_CONF_DIR"/*/disable_ipv6; do
        [ -e "$rs_path" ] || continue
        rs_name=${rs_path%/disable_ipv6}
        rs_name=${rs_name##*/}
        case "$rs_name" in all|default) continue ;; esac
        rs_seen=$((rs_seen + 1))
        rs_value=$(read_flag "$rs_path") || rs_value="unknown"
        case "$rs_value" in
            0) rs_enabled=$((rs_enabled + 1)) ;;
            1) rs_disabled=$((rs_disabled + 1)) ;;
            *) rs_unknown=$((rs_unknown + 1)) ;;
        esac
    done

    if [ "$rs_seen" -eq 0 ] || [ "$rs_unknown" -ne 0 ]; then
        printf '%s' "unknown"
    elif [ "$rs_enabled" -ne 0 ] && [ "$rs_disabled" -ne 0 ]; then
        printf '%s' "mixed"
    elif [ "$rs_enabled" -ne 0 ]; then
        printf '%s' "enabled"
    else
        printf '%s' "disabled"
    fi
}

print_runtime_state() {
    prs_state=$(runtime_state) || :
    case "$prs_state" in
        enabled) printf '当前接口状态：已开启\n' ;;
        disabled) printf '当前接口状态：已关闭\n' ;;
        mixed) printf '当前接口状态：部分关闭\n' ;;
        unavailable) printf '当前接口状态：不可用\n' ;;
        *) printf '当前接口状态：未知\n' ;;
    esac
}

print_managed_state() {
    pms_kind=$(managed_file_kind "$MANAGED_SYSCTL_FILE")
    case "$pms_kind" in
        current) printf '永久配置：已设置关闭\n' ;;
        legacy) printf '永久配置：已设置关闭（旧版）\n' ;;
        absent) printf '永久配置：未设置\n' ;;
        *) printf '永久配置：同名文件冲突\n' ;;
    esac
}

print_flags() {
    printf '运行时标志（0=开启，1=关闭）：\n'
    if ! ipv6_kernel_available; then
        printf '  不可用\n'
        return
    fi
    for pf_path in "$IPV6_CONF_DIR"/*/disable_ipv6; do
        [ -e "$pf_path" ] || continue
        pf_name=${pf_path%/disable_ipv6}
        pf_name=${pf_name##*/}
        pf_value=$(read_flag "$pf_path") || pf_value="unknown"
        printf '  %-16s %s\n' "$pf_name" "$pf_value"
    done
}

print_addresses() {
    printf 'IPv6 地址：\n'
    if command -v ip >/dev/null 2>&1; then
        if pa_output=$(ip -o -6 addr show 2>/dev/null); then
            if [ -n "$pa_output" ]; then
                printf '%s\n' "$pa_output" | sed 's/^/  /'
            else
                printf '  无\n'
            fi
            return
        fi
        printf '  ip 查询失败，回退到 %s\n' "$IF_INET6_FILE"
    fi
    if [ -s "$IF_INET6_FILE" ]; then
        awk '{ print "  " $6 "  " $1 }' "$IF_INET6_FILE" 2>/dev/null || printf '  无法读取\n'
    elif [ -r "$IF_INET6_FILE" ]; then
        printf '  无\n'
    else
        printf '  不可用\n'
    fi
}

print_routes() {
    printf 'IPv6 默认路由：\n'
    if ! command -v ip >/dev/null 2>&1; then
        printf '  ip 命令不可用\n'
        return
    fi
    if pr_output=$(ip -6 route show default 2>/dev/null); then
        if [ -n "$pr_output" ]; then
            printf '%s\n' "$pr_output" | sed 's/^/  /'
        else
            printf '  无\n'
        fi
    else
        printf '  查询失败\n'
    fi
}

report_other_persistent_disables() {
    ro_found=0
    for ro_file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
        [ -f "$ro_file" ] || continue
        [ "$ro_file" = "$MANAGED_SYSCTL_FILE" ] && continue
        if grep -Eq '^[[:space:]]*-?[[:space:]]*net\.ipv6\.conf\..*\.disable_ipv6([[:space:]]*=[[:space:]]*|[[:space:]]+)1([[:space:]]*(#.*)?)?$' "$ro_file" 2>/dev/null; then
            if [ "$ro_found" -eq 0 ]; then
                warn "发现其他 IPv6 永久关闭配置："
                ro_found=1
            fi
            printf '  %s\n' "$ro_file"
        fi
    done
}

status() {
    printf '%s\n' "${BOLD}IPv6 状态${RESET}"
    if ipv6_kernel_available; then
        printf '内核控制接口：可用\n'
        print_runtime_state
        st_default=$(read_flag "$IPV6_CONF_DIR/default/disable_ipv6") || st_default="unknown"
        printf '新建接口默认：%s\n' "$(flag_label "$st_default")"
    else
        printf '内核控制接口：不可用\n'
        printf '当前接口状态：不可用\n'
    fi
    print_managed_state
    report_other_persistent_disables
}

status_full() {
    printf '%s\n' "${BOLD}IPv6 详细状态${RESET}"
    print_managed_state
    print_runtime_state
    print_flags
    print_routes
    print_addresses
    report_other_persistent_disables
}

confirm_disable() {
    printf '该操作可能中断 IPv6 网络连接，确认继续？[y/N] '
    IFS= read -r answer || return 1
    case "$answer" in y|Y|yes|YES|Yes|是) return 0 ;; esac
    return 1
}

menu() {
    while :; do
        printf '\n%s\n' "${BOLD}IPv6 管理菜单${RESET}"
        printf '  1) 查看状态\n'
        printf '  2) 临时关闭\n'
        printf '  3) 永久关闭\n'
        printf '  4) 临时开启\n'
        printf '  5) 永久开启\n'
        printf '  6) 查看详细状态\n'
        printf '  0) 退出\n'
        printf '请选择：'
        IFS= read -r choice || return 0
        case "$choice" in
            1) status ;;
            2) if confirm_disable; then disable_temp || :; else info "已取消。"; fi ;;
            3) if confirm_disable; then disable_perm || :; else info "已取消。"; fi ;;
            4) enable_temp || : ;;
            5) enable_perm || : ;;
            6) status_full ;;
            0) return 0 ;;
            *) warn "无效选项：$choice" ;;
        esac
    done
}

main() {
    if [ "$#" -gt 1 ]; then
        err "参数过多。"
        usage
        return 2
    fi
    case "${1:-}" in
        "") menu ;;
        status) status ;;
        status-full|detail) status_full ;;
        disable-temp) disable_temp ;;
        disable-perm|disable) disable_perm ;;
        enable-temp) enable_temp ;;
        enable-perm|enable) enable_perm ;;
        version|-V|--version) printf 'IPv6 Control %s\n' "$VERSION" ;;
        help|-h|--help) usage ;;
        *) err "未知命令：$1"; usage; return 2 ;;
    esac
}

if [ "${IPV6_CONTROL_SOURCE_ONLY:-0}" != "1" ]; then
    trap 'cleanup_tmp' 0
    trap 'cleanup_tmp; exit 129' 1
    trap 'cleanup_tmp; exit 130' 2
    trap 'cleanup_tmp; exit 143' 15
    main "$@"
    exit $?
fi
