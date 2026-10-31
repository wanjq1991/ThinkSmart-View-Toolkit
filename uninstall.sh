#!/usr/bin/env bash
# ============================================================================
#  ThinkSmart View 优化项卸载脚本
#
#  把 install.sh 做的改动逐项还原：
#    - 停掉按键唤醒守护，删除三个开机脚本与日志
#    - 动画缩放 / 密度 / 熄屏超时 / 双击唤醒 恢复默认
#    - 全屏沉浸式关闭（删掉 policy_control，状态栏与导航栏重新出现）
#    - 壁纸恢复为安装前的备份
#
#  注意：zram 扩容在重启后自动回到原厂配置（不再被脚本改写），无需额外处理。
# ============================================================================
set -uo pipefail

VERSION="1.0.1"
SERIAL=""
DO_REBOOT=1
DO_WALLPAPER=1
CHECK_ONLY=0

if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
dim()  { printf '%s    %s%s\n' "$C_D" "$*" "$C_0"; }

usage() {
    cat <<'EOF'
ThinkSmart View 优化项卸载

用法:
  ./uninstall.sh [选项]

选项:
  -s, --serial <SN>   指定设备序列号
      --keep-wallpaper  保留当前壁纸
      --no-reboot       不自动重启
      --check           只列出会被删除的内容
  -h, --help          显示本帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial)      SERIAL="${2:-}"; shift 2 ;;
        --keep-wallpaper) DO_WALLPAPER=0; shift ;;
        --no-reboot)      DO_REBOOT=0; shift ;;
        --check)          CHECK_ONLY=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

find_adb() {
    if [ -n "${ADB:-}" ] && [ -x "${ADB}" ]; then echo "$ADB"; return 0; fi
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    for p in \
        "$HOME/Library/Android/sdk/platform-tools/adb" \
        "$HOME/Android/Sdk/platform-tools/adb" \
        "/c/Users/${USER:-user}/AppData/Local/Android/Sdk/platform-tools/adb.exe" \
        "/c/Program Files (x86)/Android/android-sdk/platform-tools/adb.exe" ; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

ADB_BIN="$(find_adb)"
[ -z "$ADB_BIN" ] && die "找不到 adb，请设置环境变量 ADB=/path/to/adb"

ab() { if [ -n "$SERIAL" ]; then "$ADB_BIN" -s "$SERIAL" "$@"; else "$ADB_BIN" "$@"; fi; }
sh_root() { ab shell "su -c '$*'"; }

printf '\n%sThinkSmart View 优化项卸载 v%s%s\n\n' "$C_B" "$VERSION" "$C_0"

# adb daemon 首次启动的提示会打到 stdout，取最后一行才可靠
[ "$(ab get-state 2>/dev/null | tr -d '\r' | tail -1)" = "device" ] || die "设备未连接"
case "$(ab shell 'su -c id' 2>/dev/null | tr -d '\r')" in
    *"uid=0"*) ok "root 可用" ;;
    *) die "需要 root 才能卸载" ;;
esac

info "将处理以下内容："
dim "停止守护      /data/adb/keywake.pid 对应进程"
dim "删除脚本      /data/adb/service.d/99timesync.sh"
dim "              /data/adb/service.d/97keywake.sh"
dim "              /data/adb/post-fs-data.d/98zram.sh"
dim "删除日志      /data/adb/{timesync,zram,keywake}.log"
dim "恢复设置      动画缩放 / 密度 / 熄屏超时 / 双击唤醒 / 全屏沉浸式"
[ "$DO_WALLPAPER" -eq 1 ] && dim "恢复壁纸      /data/adb/wallpaper_info.xml.bak"

if [ "$CHECK_ONLY" -eq 1 ]; then
    printf '\n'
    ok "--check 模式，未做任何修改"
    exit 0
fi

printf '\n'
info "停止按键唤醒守护"
sh_root "touch /data/adb/keywake.off" >/dev/null 2>&1
sh_root "pkill -9 -f \"[9]7keywake\"; pkill -9 -f \"[g]etevent\"" >/dev/null 2>&1
ok "已停止（残留进程会随下次重启彻底消失）"

printf '\n'
info "删除开机脚本与日志"
if sh_root "rm -f /data/adb/service.d/99timesync.sh \
                 /data/adb/service.d/97keywake.sh \
                 /data/adb/post-fs-data.d/98zram.sh \
                 /data/adb/timesync.log /data/adb/zram.log /data/adb/keywake.log \
                 /data/adb/keywake.off /data/adb/keywake.last /data/adb/keywake.pid"; then
    ok "已删除"
else
    warn "部分文件删除失败，请手动检查"
fi

printf '\n'
info "恢复系统设置"
ab shell settings put global window_animation_scale 1.0 >/dev/null 2>&1
ab shell settings put global transition_animation_scale 1.0 >/dev/null 2>&1
ab shell settings put global animator_duration_scale 1.0 >/dev/null 2>&1
ab shell "wm density reset" >/dev/null 2>&1
ab shell settings put system screen_off_timeout 60000 >/dev/null 2>&1
ab shell settings put secure double_tap_to_wake 0 >/dev/null 2>&1
ab shell settings put system accelerometer_rotation 1 >/dev/null 2>&1
ab shell "settings delete global policy_control" >/dev/null 2>&1
ok "动画 1.0x / 密度恢复原厂 / 熄屏 60s / 双击唤醒关闭 / 全屏已退出"

# 注意：密度恢复原厂（260）后 sw 掉到 492dp，桌面会重新锁竖屏。
dim "提示：密度恢复后桌面会锁回竖屏，这是原厂行为，不是故障。"

if [ "$DO_WALLPAPER" -eq 1 ]; then
    printf '\n'
    info "恢复壁纸"
    if sh_root "test -f /data/adb/wallpaper_info.xml.bak"; then
        if sh_root "cp -f /data/adb/wallpaper_info.xml.bak /data/system/users/0/wallpaper_info.xml && \
                    rm -f /data/system/users/0/wallpaper && \
                    chown system:system /data/system/users/0/wallpaper_info.xml && \
                    chmod 600 /data/system/users/0/wallpaper_info.xml && \
                    restorecon /data/system/users/0/wallpaper_info.xml"; then
            ok "壁纸已恢复为安装前状态"
        else
            warn "壁纸恢复失败（不影响使用，可在桌面长按重新设置）"
        fi
    else
        warn "找不到安装前的壁纸备份，保留当前壁纸"
    fi
fi

printf '\n'
if [ "$DO_REBOOT" -eq 1 ]; then
    warn "即将重启以完成还原"
    printf '%s' "    5 秒后重启，Ctrl+C 可取消 ... "
    for i in 5 4 3 2 1; do printf '%s ' "$i"; sleep 1; done
    printf '\n'
    ab reboot
    ok "已重启。zram 会回到原厂 509MB，按键唤醒与自动校时不再生效"
else
    warn "已跳过重启（--no-reboot）：adb reboot"
fi

printf '\n'
