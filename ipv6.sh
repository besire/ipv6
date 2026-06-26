#!/bin/sh

# 适用于常见 Linux 发行版的 IPv6 一键控制脚本。
# 支持状态查询、临时关闭/开启、永久关闭/开启。

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

info() { printf '%s\n' "${BLUE}提示:${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}成功:${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}警告:${RESET} $*"; }
err() { printf '%s\n' "${RED}错误:${RESET} $*" >&2; }

usage() {
    cat <<EOF
${BOLD}IPv6 控制脚本${RESET}

用法:
  ./${SCRIPT_NAME}                 交互菜单
  ./${SCRIPT_NAME} status          查看 IPv6 状态
  ./${SCRIPT_NAME} disable-temp    临时关闭 IPv6，重启或网络重载后可能恢复
  ./${SCRIPT_NAME} disable-perm    永久关闭 IPv6，并立即生效
  ./${SCRIPT_NAME} enable-temp     临时开启 IPv6
  ./${SCRIPT_NAME} enable-perm     删除本脚本创建的永久关闭配置，并立即生效
  ./${SCRIPT_NAME} help            显示帮助

示例:
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
        err "该操作需要 root 权限，请使用 sudo 或以 root 身份执行。"
        exit 1
    fi
}

ipv6_kernel_available() {
    [ -d /proc/sys/net/ipv6/conf ]
}

need_ipv6_kernel() {
    if ! ipv6_kernel_available; then
        err "当前内核未暴露 IPv6 控制接口。此系统或容器可能未启用 IPv6。"
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
        warn "写入失败：$path"
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
        err "部分 IPv6 运行时标志无法修改。"
        return 1
    fi

    return 0
}

disable_temp() {
    info "正在临时关闭 IPv6..."
    apply_runtime_value 1
    ok "IPv6 已临时关闭。"
    warn "重启、网络服务重载或网卡重建后，可能会恢复。"
}

enable_temp() {
    info "正在临时开启 IPv6..."
    apply_runtime_value 0
    ok "IPv6 已在当前运行时开启。"
    warn "如果其他 sysctl 配置在启动时关闭 IPv6，重启后仍可能再次被关闭。"
}

write_persistent_disable_file() {
    need_root

    if [ ! -d /etc/sysctl.d ]; then
        mkdir -p /etc/sysctl.d || {
            err "创建 /etc/sysctl.d 失败"
            exit 1
        }
    fi

    tmp_file="${MANAGED_SYSCTL_FILE}.$$"
    umask 022
    {
        printf '%s\n' "# 由 ${SCRIPT_NAME} 管理"
        printf '%s\n' "# 删除此文件，或执行：${SCRIPT_NAME} enable-perm"
        printf '%s\n' "net.ipv6.conf.all.disable_ipv6 = 1"
        printf '%s\n' "net.ipv6.conf.default.disable_ipv6 = 1"
        printf '%s\n' "net.ipv6.conf.lo.disable_ipv6 = 1"
    } > "$tmp_file" || {
        err "写入失败：$tmp_file"
        exit 1
    }

    mv "$tmp_file" "$MANAGED_SYSCTL_FILE" || {
        rm -f "$tmp_file" 2>/dev/null
        err "安装失败：$MANAGED_SYSCTL_FILE"
        exit 1
    }
}

disable_perm() {
    info "正在写入永久关闭 IPv6 的 sysctl 配置..."
    write_persistent_disable_file
    ok "已写入永久配置：$MANAGED_SYSCTL_FILE"

    info "正在立即应用关闭设置..."
    apply_runtime_value 1
    ok "IPv6 已关闭。对于常规 sysctl 系统，重启后也会保持关闭。"
}

remove_persistent_disable_file() {
    need_root

    if [ -f "$MANAGED_SYSCTL_FILE" ]; then
        rm -f "$MANAGED_SYSCTL_FILE" || {
            err "删除失败：$MANAGED_SYSCTL_FILE"
            exit 1
        }
        ok "已删除：$MANAGED_SYSCTL_FILE"
    else
        info "未找到本脚本管理的永久配置：$MANAGED_SYSCTL_FILE"
    fi
}

enable_perm() {
    info "正在删除本脚本创建的永久关闭配置..."
    remove_persistent_disable_file

    info "正在立即应用开启设置..."
    apply_runtime_value 0
    ok "IPv6 已开启。"

    report_other_persistent_disables
}

read_flag() {
    path=$1
    if [ -r "$path" ]; then
        sed -n '1p' "$path" 2>/dev/null
    else
        printf '%s' "未知"
    fi
}

print_runtime_flags() {
    if ! ipv6_kernel_available; then
        printf '内核 IPv6 控制：不可用\n'
        return
    fi

    printf '运行时关闭标志：\n'
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
            printf '网卡关闭标志：\n'
            printed_header=1
        fi
        printf '  %-10s %s\n' "$name" "$(read_flag "$path")"
    done
}

print_ipv6_addresses() {
    printf 'IPv6 地址：\n'

    if command -v ip >/dev/null 2>&1; then
        addr_output=$(ip -6 addr show 2>/dev/null)
        if [ -n "$addr_output" ]; then
            printf '%s\n' "$addr_output" | sed 's/^/  /'
        else
            printf '  无\n'
        fi
        if [ $? -eq 0 ]; then
            return
        fi
    fi

    if [ -r /proc/net/if_inet6 ]; then
        if [ ! -s /proc/net/if_inet6 ]; then
            printf '  无\n'
            return
        fi
        awk '{ print "  " $6 "  " $1 }' /proc/net/if_inet6 2>/dev/null || printf '  无法读取\n'
        return
    fi

    printf '  不可用\n'
}

print_ipv6_routes() {
    printf 'IPv6 默认路由：\n'

    if command -v ip >/dev/null 2>&1; then
        route_output=$(ip -6 route show default 2>/dev/null)
        if [ -n "$route_output" ]; then
            printf '%s\n' "$route_output" | sed 's/^/  /'
        else
            printf '  无\n'
        fi
        return
    fi

    printf '  ip 命令不可用\n'
}

report_other_persistent_disables() {
    found=0

    for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
        [ -f "$file" ] || continue
        [ "$file" = "$MANAGED_SYSCTL_FILE" ] && continue

        if grep -Eq '^[[:space:]]*net\.ipv6\.conf\..*\.disable_ipv6[[:space:]]*=[[:space:]]*1([[:space:]]*#.*)?$' "$file" 2>/dev/null; then
            if [ "$found" -eq 0 ]; then
                warn "仍检测到其他永久关闭 IPv6 的配置："
                found=1
            fi
            printf '  %s\n' "$file"
        fi
    done

    if [ "$found" -ne 0 ]; then
        warn "如果重启后 IPv6 又被关闭，请检查这些文件。"
    fi
}

status() {
    printf '%s\n' "${BOLD}IPv6 状态${RESET}"
    printf '本脚本管理的永久配置：'
    if [ -f "$MANAGED_SYSCTL_FILE" ]; then
        printf '%s\n' "存在（$MANAGED_SYSCTL_FILE）"
    else
        printf '%s\n' "不存在"
    fi

    if ipv6_kernel_available; then
        printf '内核 IPv6 控制：可用\n'
    else
        printf '内核 IPv6 控制：不可用\n'
    fi

    print_runtime_flags
    print_ipv6_routes
    print_ipv6_addresses
    report_other_persistent_disables
}

menu() {
    while :; do
        printf '\n%s\n' "${BOLD}IPv6 一键菜单${RESET}"
        printf '  1) 查看 IPv6 状态\n'
        printf '  2) 临时关闭 IPv6\n'
        printf '  3) 永久关闭 IPv6\n'
        printf '  4) 临时开启 IPv6\n'
        printf '  5) 永久开启 IPv6\n'
        printf '  0) 退出\n'
        printf '请选择：'
        read choice || exit 1

        case "$choice" in
            1) status ;;
            2) disable_temp ;;
            3) disable_perm ;;
            4) enable_temp ;;
            5) enable_perm ;;
            0) exit 0 ;;
            *) warn "无效选项：$choice" ;;
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
        err "未知命令：$1"
        usage
        exit 1
        ;;
esac
