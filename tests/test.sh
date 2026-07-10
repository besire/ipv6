#!/bin/sh

# Side-effect-free regression tests for ipv6.sh.

TEST_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
PROJECT_DIR=$(CDPATH='' cd "$TEST_DIR/.." && pwd) || exit 1
SCRIPT_FILE="$PROJECT_DIR/ipv6.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ipv6-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' 0

IPV6_CONTROL_SOURCE_ONLY=1
export IPV6_CONTROL_SOURCE_ONLY
# shellcheck source=ipv6.sh
. "$SCRIPT_FILE"

COUNT=0
FAILED=0
OUTPUT=""
RC=0
CASE_NO=0

pass() { printf 'ok %s - %s\n' "$COUNT" "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'not ok %s - %s\n' "$COUNT" "$1"; }

assert_eq() {
    COUNT=$((COUNT + 1))
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3"; printf '  expected=[%s] actual=[%s]\n' "$1" "$2"; fi
}

assert_contains() {
    COUNT=$((COUNT + 1))
    case "$1" in *"$2"*) pass "$3" ;; *) fail "$3"; printf '  missing=[%s]\n' "$2" ;; esac
}

assert_not_contains() {
    COUNT=$((COUNT + 1))
    case "$1" in *"$2"*) fail "$3"; printf '  unexpected=[%s]\n' "$2" ;; *) pass "$3" ;; esac
}

assert_success() {
    COUNT=$((COUNT + 1))
    if [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1"; printf '  rc=%s output=%s\n' "$RC" "$OUTPUT"; fi
}

assert_failure() {
    COUNT=$((COUNT + 1))
    if [ "$RC" -ne 0 ]; then pass "$1"; else fail "$1"; fi
}

run_capture() {
    capture="$CASE_DIR/output.$COUNT"
    ( "$@" ) >"$capture" 2>&1
    RC=$?
    OUTPUT=$(cat "$capture")
}

reset_case() {
    CASE_NO=$((CASE_NO + 1))
    CASE_DIR="$TMP_ROOT/case-$CASE_NO"
    IPV6_CONF_DIR="$CASE_DIR/proc/conf"
    IF_INET6_FILE="$CASE_DIR/proc/if_inet6"
    MANAGED_SYSCTL_FILE="$CASE_DIR/etc/sysctl.d/99-ipv6-control.conf"
    mkdir -p "$IPV6_CONF_DIR"
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
    RUNTIME_RC=0
    RUNTIME_VALUE_FILE=""
}

write_flag() {
    mkdir -p "$IPV6_CONF_DIR/$1"
    printf '%s\n' "$2" > "$IPV6_CONF_DIR/$1/disable_ipv6"
}

write_legacy_config() {
    mkdir -p "$(dirname "$MANAGED_SYSCTL_FILE")"
    {
        printf '%s\n' '# 由 ipv6.sh 管理'
        printf '%s\n' '# 删除此文件，或执行：ipv6.sh enable-perm'
        printf '%s\n' 'net.ipv6.conf.all.disable_ipv6 = 1'
        printf '%s\n' 'net.ipv6.conf.default.disable_ipv6 = 1'
        printf '%s\n' 'net.ipv6.conf.lo.disable_ipv6 = 1'
    } > "$MANAGED_SYSCTL_FILE"
}

# Keep all mutations inside the temporary tree.
# shellcheck disable=SC2317
is_root() { return 0; }
report_other_persistent_disables() { return 0; }

printf 'TAP version 13\n'

reset_case
write_flag all 0
write_flag default 0
write_flag lo 0
write_flag eth0 0
run_capture status
assert_success 'status succeeds'
assert_contains "$OUTPUT" '当前接口状态：已开启' 'status reports enabled interfaces'
assert_contains "$OUTPUT" '新建接口默认：已开启' 'status reports enabled default'

reset_case
write_flag all 1
write_flag default 1
write_flag lo 1
write_flag eth0 1
run_capture status
assert_contains "$OUTPUT" '当前接口状态：已关闭' 'status reports disabled interfaces'

reset_case
write_flag all 0
write_flag default 0
write_flag lo 0
write_flag eth0 1
run_capture status
assert_contains "$OUTPUT" '当前接口状态：部分关闭' 'status reports mixed interfaces'

reset_case
write_flag all 0
write_flag default 0
write_flag lo 0
write_flag eth0 0
run_capture apply_runtime_value 1
assert_success 'runtime disable succeeds in fixture'
assert_eq 1 "$(sed -n '1p' "$IPV6_CONF_DIR/eth0/disable_ipv6")" 'runtime disable writes one'
run_capture apply_runtime_value 0
assert_success 'runtime enable succeeds in fixture'
assert_eq 0 "$(sed -n '1p' "$IPV6_CONF_DIR/eth0/disable_ipv6")" 'runtime enable writes zero'

reset_case
write_flag all 0
write_flag default 0
write_flag lo 0
mkdir -p "$IPV6_CONF_DIR/bad0"
ln -s /dev/full "$IPV6_CONF_DIR/bad0/disable_ipv6"
run_capture apply_runtime_value 1
assert_failure 'runtime write failure is propagated'

# Stub runtime writes for command and persistent-file tests.
apply_runtime_value() {
    if [ -n "$RUNTIME_VALUE_FILE" ]; then printf '%s\n' "$1" > "$RUNTIME_VALUE_FILE"; fi
    return "$RUNTIME_RC"
}

reset_case
RUNTIME_RC=1
run_capture disable_temp
assert_failure 'disable-temp propagates failure'
assert_not_contains "$OUTPUT" '成功:' 'disable-temp does not print success after failure'
run_capture enable_temp
assert_failure 'enable-temp propagates failure'
assert_not_contains "$OUTPUT" '成功:' 'enable-temp does not print success after failure'

reset_case
RUNTIME_VALUE_FILE="$CASE_DIR/runtime-value"
run_capture disable_temp
assert_eq 1 "$(cat "$RUNTIME_VALUE_FILE")" 'disable-temp requests value one'
run_capture enable_temp
assert_eq 0 "$(cat "$RUNTIME_VALUE_FILE")" 'enable-temp requests value zero'

reset_case
RUNTIME_VALUE_FILE="$CASE_DIR/runtime-value"
run_capture disable_perm
assert_success 'disable-perm creates config'
assert_eq current "$(managed_file_kind)" 'created config is managed'
assert_eq 1 "$(cat "$RUNTIME_VALUE_FILE")" 'disable-perm requests value one'
run_capture enable_perm
assert_success 'enable-perm removes managed config'
assert_eq absent "$(managed_file_kind)" 'managed config is removed'
assert_eq 0 "$(cat "$RUNTIME_VALUE_FILE")" 'enable-perm requests value zero'

reset_case
mkdir -p "$(dirname "$MANAGED_SYSCTL_FILE")"
printf '%s\n' 'administrator content' > "$MANAGED_SYSCTL_FILE"
before=$(cat "$MANAGED_SYSCTL_FILE")
RUNTIME_VALUE_FILE="$CASE_DIR/runtime-value"
run_capture disable_perm
assert_failure 'disable-perm refuses conflicting file'
assert_eq "$before" "$(cat "$MANAGED_SYSCTL_FILE")" 'conflicting file is not overwritten'
assert_eq no "$(if [ -e "$RUNTIME_VALUE_FILE" ]; then printf yes; else printf no; fi)" 'conflict prevents runtime change'
run_capture enable_perm
assert_failure 'enable-perm refuses conflicting file'
assert_eq "$before" "$(cat "$MANAGED_SYSCTL_FILE")" 'conflicting file is not deleted'

reset_case
write_legacy_config
assert_eq legacy "$(managed_file_kind)" 'legacy config is recognized'
run_capture enable_perm
assert_success 'legacy config can be removed'
assert_eq absent "$(managed_file_kind)" 'legacy config is removed'

reset_case
write_flag all 0
write_flag default 0
write_flag lo 0
printf '%s\n' '20010db8000000000000000000000001 02 40 00 80 eth-test' > "$IF_INET6_FILE"
mkdir -p "$CASE_DIR/bin"
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'exit 1'
} > "$CASE_DIR/bin/ip"
chmod +x "$CASE_DIR/bin/ip"
PATH="$CASE_DIR/bin:$PATH"
export PATH
run_capture status_full
assert_success 'status-full survives ip failure'
assert_contains "$OUTPUT" 'eth-test' 'address query falls back to if_inet6'

reset_case
run_capture main status extra
assert_eq 2 "$RC" 'extra argument returns two'
run_capture main unknown
assert_eq 2 "$RC" 'unknown command returns two'

printf '1..%s\n' "$COUNT"
printf '# %s passed, %s failed\n' "$((COUNT - FAILED))" "$FAILED"
[ "$FAILED" -eq 0 ]
