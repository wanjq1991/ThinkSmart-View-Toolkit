#!/system/bin/sh
# ============================================================
# 开机自动校时 —— ThinkSmart View (CD-18781Y)
# 本机无 RTC 电池，断电后内核时间会回退到 1970 或上次的值。
# 系统自带 NTP 走 UDP 123，本机实测被拦截（SntpClient 一直 SocketTimeout）。
# 改用 HTTP Date 头取时，走 TCP 80，国内直连稳定。
#
# 安装位置: /data/adb/service.d/99timesync.sh   权限 755
# 日志:     /data/adb/timesync.log
# ============================================================

LOG=/data/adb/timesync.log
THRESHOLD=30

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

# 日志滚动，最多保留约 200 行
if [ -f "$LOG" ] && [ "$($BB wc -l <"$LOG")" -gt 200 ]; then
    $BB tail -100 "$LOG" >"$LOG.tmp" 2>/dev/null
    $BB mv "$LOG.tmp" "$LOG" 2>/dev/null
fi

# 从 HTTP Date 头取时，输出: "<epoch> <YYYY-MM-DD HH:MM:SS>"
get_time() {
    for h in www.baidu.com www.163.com www.qq.com; do
        line=$(printf 'HEAD / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$h" \
            | $BB nc -w 5 "$h" 80 2>/dev/null \
            | $BB grep -i '^date:' | $BB head -1 | $BB tr -d '\r')
        [ -z "$line" ] && continue
        out=$(echo "$line" | $BB sed 's/^[Dd]ate: *//' | $BB awk '
            function dfc(y, m, d,   era, yoe, doy, doe) {
                y -= (m <= 2)
                era = int(y / 400); if (y < 0 && y % 400 != 0) era--
                yoe = y - era * 400
                doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
                doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
                return era * 146097 + doe - 719468
            }
            {
                split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
                d = $2 + 0; mon = $3; y = $4 + 0
                m = 0; for (i = 1; i <= 12; i++) if (mn[i] == mon) m = i
                if (m == 0 || y < 2020 || y > 2100) exit
                split($5, t, ":")
                e = dfc(y, m, d) * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
                printf "%d %04d-%02d-%02d %02d:%02d:%02d\n", e, y, m, d, t[1], t[2], t[3]
            }')
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    return 1
}

log "=== 开机校时开始 ==="

# 等网络就绪，最多 30 次 × 3 秒 = 90 秒
i=0
r=""
while [ $i -lt 30 ]; do
    r=$(get_time)
    [ -n "$r" ] && break
    i=$((i + 1))
    $BB sleep 3
done

if [ -z "$r" ]; then
    log "失败: 90 秒内无法获取网络时间"
    exit 0
fi

net_epoch=${r%% *}
net_fmt=${r#* }

cur=$($BB date +%s)
diff=$((net_epoch - cur))
abs=$diff
[ "$abs" -lt 0 ] && abs=$((-abs))

log "网络=$net_fmt (epoch $net_epoch) 本地epoch=$cur 偏差=${diff}s"

if [ "$abs" -gt "$THRESHOLD" ]; then
    $BB date -u -s "$net_fmt" >/dev/null 2>&1
    now=$($BB date '+%F %T %Z')
    if [ $? -eq 0 ]; then
        log "已校时 → $now"
    else
        log "校时命令失败"
    fi
else
    log "偏差在 ${THRESHOLD}s 内，跳过"
fi

log "=== 完成 ==="
