#!/usr/bin/env bash
# ============================================================================
#  验证 ThinkSmart View 的四项优化是否真的生效
#
#  用法: ./tools/verify.sh [-s 序列号]
#  建议在 install.sh 跑完并重启之后再执行。
# ============================================================================
set -uo pipefail

SERIAL=""
[ "${1:-}" = "-s" ] && SERIAL="${2:-}"

if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

find_adb() {
    [ -n "${ADB:-}" ] && [ -x "${ADB}" ] && { echo "$ADB"; return 0; }
    command -v adb >/dev/null 2>&1 && { command -v adb; return 0; }
    for p in "$HOME/Library/Android/sdk/platform-tools/adb" \
             "$HOME/Android/Sdk/platform-tools/adb" \
             "/c/Users/${USER:-user}/AppData/Local/Android/Sdk/platform-tools/adb.exe"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}
ADB_BIN="$(find_adb)"
[ -z "$ADB_BIN" ] && { echo "找不到 adb，请设置 ADB=/path/to/adb"; exit 1; }

ab() { if [ -n "$SERIAL" ]; then "$ADB_BIN" -s "$SERIAL" "$@"; else "$ADB_BIN" "$@"; fi; }
q()  { ab shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
kv() { ab shell "$*" 2>/dev/null | tr -d '\r'; }

PASS=0; FAIL=0; WARN=0
row() {  # row 名称 状态(ok|warn|fail) 实际值 [期望值]
    local name="${1:-}" st="${2:-ok}" actual="${3:-}" expect="${4:-}"
    case "$st" in
        ok)   printf '  %s✔%s %s: %s\n'        "$C_G" "$C_0" "$name" "$actual"; PASS=$((PASS+1)) ;;
        warn) printf '  %s!%s %s: %s %s（期望 %s）%s\n' "$C_Y" "$C_0" "$name" "$actual" "$C_D" "$expect" "$C_0"; WARN=$((WARN+1)) ;;
        *)    printf '  %s✘%s %s: %s %s（期望 %s）%s\n' "$C_R" "$C_0" "$name" "$actual" "$C_D" "$expect" "$C_0"; FAIL=$((FAIL+1)) ;;
    esac
}
note() { printf '  %s·%s %s: %s\n' "$C_D" "$C_0" "$1" "$2"; }

# adb daemon 首次启动的提示会打到 stdout，取最后一行才可靠
[ "$(ab get-state 2>/dev/null | tr -d '\r' | tail -1)" = "device" ] || { echo "设备未连接"; exit 1; }

printf '\n%sThinkSmart View 优化验证%s\n\n' "$C_B" "$C_0"

printf '%s设备%s\n' "$C_B" "$C_0"
note "型号" "$(kv getprop ro.product.model)"
note "系统" "Android $(kv getprop ro.build.version.release) / SDK $(kv getprop ro.build.version.sdk)"
note "root" "$(ab shell 'su -c id' 2>/dev/null | tr -d '\r' | cut -c1-46)"
printf '\n'

printf '%s1. zram 扩容%s\n' "$C_B" "$C_0"
ZS="$(q 'cat /sys/block/zram0/disksize')"
if [ "$ZS" = "1073741824" ]; then
    row "zram 容量" ok "1 GB"
else
    row "zram 容量" fail "${ZS:-读取失败}" "1073741824"
fi
SW="$(q 'cat /proc/swaps' | awk '/zram0/ {printf "%d MB（已用 %d KB）", $3/1024, $4}')"
note "swap" "${SW:-无}"
MEM="$(ab shell free -m 2>/dev/null | awk '/Mem:/ {printf "%d/%d MB 已用（%d%%）", $3, $2, $3*100/$2}' | tr -d '\r')"
note "内存" "${MEM:-读取失败}"
printf '\n'

printf '%s2. 开机自动校时%s\n' "$C_B" "$C_0"
TS="$(q 'tail -4 /data/adb/timesync.log' 2>/dev/null)"
if [ -z "$TS" ]; then
    row "校时日志" fail "不存在" "有记录"
elif printf '%s' "$TS" | grep -q '已校时\|偏差在\|跳过'; then
    row "校时日志" ok "正常"
else
    row "校时日志" warn "有日志但未见结论" "含「已校时」"
fi
note "设备当前时间" "$(kv "date '+%F %T %Z'")"
note "最近一行日志" "$(printf '%s' "$TS" | tail -1)"
printf '\n'

printf '%s3. 按键唤醒屏幕%s\n' "$C_B" "$C_0"
KPID="$(q 'cat /data/adb/keywake.pid')"
if [ -n "$KPID" ] && q "test -r /proc/$KPID/cmdline" >/dev/null 2>&1; then
    row "守护进程" ok "PID $KPID 运行中"
else
    row "守护进程" fail "${KPID:-无 PID 文件}" "运行中"
fi
NG="$(q 'ps -A -o cmd 2>/dev/null' | grep -c '[g]etevent' || true)"
if [ "$NG" = "2" ]; then
    row "getevent 实例" ok "$NG 个（event0 + event3）"
else
    row "getevent 实例" warn "$NG 个" "2"
fi
KG="$(q 'tail -8 /data/adb/keywake.log' 2>/dev/null)"
if printf '%s' "$KG" | grep -q '唤醒成功'; then
    row "唤醒记录" ok "有成功记录"
else
    row "唤醒记录" warn "尚无成功记录" "唤醒成功"
fi
note "日志尾部" "$(printf '%s' "$KG" | tail -1)"
printf '\n'

printf '%s4. 显示与桌面%s\n' "$C_B" "$C_0"
# wm density 会输出两行（Physical / Override），取最后一行才是实际生效值
DEN="$(kv "wm density" | grep -oE '[0-9]+$' | tail -1)"
if [ -n "${DEN}" ] && [ "${DEN}" -ge 213 ] 2>/dev/null; then
    row "屏幕密度" ok "$DEN"
else
    row "屏幕密度" fail "${DEN:-?}" ">=213"
fi
note "smallestWidth" "$(ab shell dumpsys window 2>/dev/null | grep -oE 'sw[0-9]+dp' | head -1 | tr -d '\r')（≥600dp 才走平板布局）"
ANI="$(kv settings get global window_animation_scale)"
if [ "$ANI" = "0.5" ]; then row "动画缩放" ok "0.5x"; else row "动画缩放" warn "${ANI:-1.0}" "0.5"; fi
note "熄屏超时" "$(kv settings get system screen_off_timeout) ms"
DTW="$(kv settings get secure double_tap_to_wake)"
note "双击唤醒" "${DTW:-0}"
WP="$(q 'ls -l /data/system/users/0/wallpaper' 2>/dev/null | awk '{print $5}')"
if [ -n "$WP" ]; then row "壁纸" ok "${WP} 字节"; else row "壁纸" warn "无自定义壁纸" "已写入"; fi
printf '\n'

printf '%s结果%s  %s%d 项通过%s' "$C_B" "$C_0" "$C_G" "$PASS" "$C_0"
[ "$WARN" -gt 0 ] && printf '  %s%d 项警告%s' "$C_Y" "$WARN" "$C_0"
[ "$FAIL" -gt 0 ] && printf '  %s%d 项失败%s' "$C_R" "$FAIL" "$C_0"
printf '\n\n'

if [ "$FAIL" -gt 0 ]; then
    printf '%s排障提示%s\n' "$C_B" "$C_0"
    printf '  zram 未生效  → cat /data/adb/zram.log（开机时 swap 已用超过 20MB 会主动跳过，下次开机会重试）\n'
    printf '  校时未生效   → cat /data/adb/timesync.log（需联网，最多等 90 秒）\n'
    printf '  守护未运行   → 确认 /data/adb/service.d/97keywake.sh 存在且权限 755\n'
    printf '  唤醒无记录   → 先看 getevent 是否两个实例；只有一个说明 event0 被跳过\n'
    printf '  密度不足     → adb shell wm density 213\n\n'
    exit 1
fi
exit 0
