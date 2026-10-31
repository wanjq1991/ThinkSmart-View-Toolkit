#!/system/bin/sh
# 96keywake.sh v5 — 任意物理按键唤醒屏幕（无电源键的 ThinkSmart View）
#
# 失败历史与结论：
#   v1：getevent 输出到管道是 4KB 块缓冲，while read 读不到整行。
#   v2：能读按键、也发出 KEYCODE_WAKEUP，但被系统拒绝：
#       PowerManagerService: Not waking up. Proximity sensor is blocked.
#       → KEYCODE_WAKEUP 走 PhoneWindowManager 的"防误触"分支，要过距离传感器；
#         本机 VCNL4200 一直误报"遮挡"，所以全被拦。
#   v3：实测 KEYCODE_POWER 走电源键路径，不做防误触判断 → 能唤醒。
#       但它是**开关**：亮屏时发会关屏，故必须严格判断状态。
#   v4：加 3 秒冷却锁，避免连按导致"唤醒后立刻又被关掉"。
#   v5：发现音量加/减分属两个输入设备！只监听 event3 会导致"音量减无反应"：
#         event0 (qpnp_pon)  → KEY_VOLUMEDOWN / KEY_POWER   ← 音量减、PMIC
#         event3 (gpio-keys) → KEY_VOLUMEUP / KEY_F11 / KEY_HIRAGANA
#       改为同时监听两个设备，并把冷却锁改为跨进程共享（文件时间戳）。
#
# 关闭：touch /data/adb/keywake.off
# 日志：/data/adb/keywake.log

LOG=/data/adb/keywake.log
OFF=/data/adb/keywake.off
LAST=/data/adb/keywake.last
PIDF=/data/adb/keywake.pid
DEVS="/dev/input/event0 /dev/input/event3"
COOLDOWN=3

# 定位 busybox：兼容 Magisk / KernelSU / APatch / 系统自带
BB=""
for c in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
         /data/adb/ap/bin/busybox /system/xbin/busybox /system/bin/busybox; do
    [ -x "$c" ] && { BB="$c"; break; }
done
[ -z "$BB" ] && BB=$(command -v busybox 2>/dev/null)
if [ -z "$BB" ]; then
    echo "未找到 busybox，无法记录日志与计时，脚本退出" >&2
    exit 0
fi

log() { echo "$($BB date '+%F %T') $*" >> "$LOG"; }

# 单实例锁：防止重复启动导致多个 getevent 抢同一个输入设备
# 必须核对 cmdline，否则重启后 PID 被别的进程复用会导致脚本不敢启动
if [ -f "$PIDF" ]; then
    old=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$old" ] && [ -r "/proc/$old/cmdline" ] &&
       tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q keywake; then
        exit 0
    fi
fi
echo $$ > "$PIDF"

# 等输入设备就绪
i=0
while [ ! -e /dev/input/event3 ] && [ $i -lt 30 ]; do
    sleep 2
    i=$((i + 1))
done
sleep 5

# 保持 CPU 不休眠，保证熄屏时按键事件仍能送达
echo keywake > /sys/power/wake_lock 2>/dev/null

is_awake() {
    dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | grep -q 'Awake'
}

# 唤醒逻辑（两个设备的子进程共用，冷却锁走文件，避免各自为政）
try_wake() {
    ev="$1"
    dev="$2"
    [ -f "$OFF" ] && return
    is_awake && return

    now=$($BB date +%s)
    last=$(cat "$LAST" 2>/dev/null)
    [ -z "$last" ] && last=0
    [ $((now - last)) -lt $COOLDOWN ] && return
    echo "$now" > "$LAST"

    log "按键[$dev]: $ev"
    input keyevent KEYCODE_POWER
    sleep 2
    if is_awake; then
        log "-> POWER 唤醒成功"
    else
        log "-> POWER 未生效，改试 WAKEUP"
        input keyevent KEYCODE_WAKEUP
        sleep 2
        if is_awake; then
            log "-> WAKEUP 唤醒成功"
        else
            log "-> 仍失败（疑似距离传感器拦截）"
        fi
    fi
}

if is_awake; then st=Awake; else st=非Awake; fi
log "v5 启动（监听 $DEVS），当前=$st"

for d in $DEVS; do
    # 开机时设备节点可能晚到，逐个等一会儿，别直接跳过
    i=0
    while [ ! -e "$d" ] && [ $i -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    if [ ! -e "$d" ]; then
        log "跳过不存在的设备 $d"
        continue
    fi
    (
        while true; do
            ev=$(getevent -c 1 -l "$d" 2>/dev/null)
            [ -z "$ev" ] && { sleep 1; continue; }
            case "$ev" in
                *DOWN*) try_wake "$ev" "$d" ;;
            esac
        done
    ) &
done

wait
