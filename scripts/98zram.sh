#!/system/bin/sh
# ============================================================
# zram 扩容 —— ThinkSmart View (2GB RAM)
# 原厂 fstab 配的是 zramsize=533413200 (约 509MB / 27% RAM)，
# 实测内存占用长期 96%，swap 已吃掉 86MB，容易触发 OOM。
# 扩到 1GB（约 54% RAM），压缩比实测 3.3:1，实际 RAM 开销有限。
#
# 内核只编了 lzo，无法换 lz4（comp_algorithm 写 lz4 无效）。
#
# 安装位置: /data/adb/post-fs-data.d/98zram.sh   权限 755
# 日志:     /data/adb/zram.log
# 卸载:     直接删除本文件即可恢复原状
# ============================================================

LOG=/data/adb/zram.log
ZRAM=/dev/block/zram0
TARGET=1073741824

# 定位 busybox：兼容 Magisk / KernelSU / APatch / 系统自带
BB=""
for c in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
         /data/adb/ap/bin/busybox /system/xbin/busybox /system/bin/busybox; do
    [ -x "$c" ] && { BB="$c"; break; }
done
[ -z "$BB" ] && BB=$(command -v busybox 2>/dev/null)
if [ -z "$BB" ]; then
    echo "未找到 busybox，脚本退出" >&2
    exit 0
fi

log() { echo "$($BB date '+%F %T') $*" >>"$LOG"; }

if [ -f "$LOG" ] && [ "$($BB wc -l <"$LOG")" -gt 100 ]; then
    $BB tail -50 "$LOG" >"$LOG.tmp" 2>/dev/null
    $BB mv "$LOG.tmp" "$LOG" 2>/dev/null
fi

# 等 zram 设备就绪（最多 10 秒）
n=0
while [ ! -e "$ZRAM" ] && [ $n -lt 20 ]; do
    $BB sleep 0.5
    n=$((n + 1))
done

cur=$($BB cat /sys/block/zram0/disksize 2>/dev/null)
if [ "$cur" = "$TARGET" ]; then
    exit 0
fi

# 只有 swap 用量极低（开机早期）才允许调整；否则 swapoff 会把数据压回 RAM 触发 OOM
# 阈值 20MB：运行时通常已用 80MB+，会被拒绝；开机 post-fs-data 阶段接近 0
used=$($BB awk '/zram0/ {print $4}' /proc/swaps 2>/dev/null)
if [ -n "$used" ] && [ "$used" -gt 20480 ]; then
    log "跳过: 当前 swap 已用 ${used}KB (>20MB)，运行时调整有 OOM 风险；下次开机再试"
    exit 0
fi

log "调整 zram: ${cur:-unknown} -> $TARGET"

$BB swapoff "$ZRAM" 2>/dev/null
echo 1 >/sys/block/zram0/reset 2>/dev/null
echo "$TARGET" >/sys/block/zram0/disksize 2>/dev/null
$BB mkswap "$ZRAM" >/dev/null 2>&1
$BB swapon "$ZRAM" 2>/dev/null

now=$($BB cat /sys/block/zram0/disksize 2>/dev/null)
swap=$($BB awk '/zram0/ {print $3"KB used "$4"KB"}' /proc/swaps 2>/dev/null)
log "结果: disksize=$now swap=[$swap]"
