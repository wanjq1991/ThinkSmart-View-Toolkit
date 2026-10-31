#!/usr/bin/env bash
# ============================================================================
#  ThinkSmart View (CD-18781Y) 一键优化部署脚本
#
#  把本项目调好的五项优化一次性装到已刷 LineageOS + Magisk 的设备上：
#    1. 开机自动校时   —— 本机无 RTC 电池，且系统 NTP 走 UDP 123 被运营商拦截
#    2. zram 扩容      —— 509MB → 1GB，缓解 2GB 内存下频繁 OOM
#    3. 按键唤醒屏幕   —— 本机外壳无电源键，熄屏后只能点屏幕
#    4. 全屏沉浸式     —— 隐藏状态栏与导航栏，当电视盒子/相框用时画面更干净
#    5. Apple TV 风格壁纸（可选）
#
#  前置条件：设备已刷 LineageOS 15.1 + GApps，且 root 为 Magisk / KernelSU
#  用法：./install.sh --help
# ============================================================================
set -uo pipefail

VERSION="1.0.1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------- 默认参数 --------------------------------------
SERIAL=""
DENSITY=213
TIMEOUT_MS=300000
DO_WALLPAPER=1
DO_TWEAK=1
DO_REBOOT=1
DO_SYNC=1
DO_IMMERSIVE=1
IMMERSIVE_MODE="full"
PORTRAIT=0
CHECK_ONLY=0
FORCE=0

# ---------------------------- 输出样式 --------------------------------------
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
ThinkSmart View 一键优化部署

用法:
  ./install.sh [选项]

选项:
  -s, --serial <SN>     指定设备序列号（连了多台设备时必填）
      --density <N>     屏幕密度，默认 213（桌面横屏分界点，见 README）
      --timeout <MS>    熄屏超时毫秒，默认 300000（5 分钟）
      --portrait        壁纸用竖屏版（默认横屏版）
      --no-wallpaper    不更换壁纸
      --no-tweak        只装开机脚本，不改系统设置
      --no-sync         不安装开机自动校时
      --no-immersive    不开启全屏沉浸式（保留状态栏和导航栏）
      --immersive-nav   只隐藏导航栏，保留状态栏
      --no-reboot       全部装完后不自动重启
      --check           只做环境检测，不做任何修改
  -f, --force           跳过设备型号校验（刷了别的机型时用）
  -h, --help            显示本帮助

示例:
  ./install.sh                      # 全量部署，最后自动重启
  ./install.sh --no-reboot          # 装完不重启，自己找时间重启
  ./install.sh --check              # 先看看设备状态是否满足条件
  ./install.sh -s HUA0BNEU --portrait
  ./install.sh --no-immersive       # 桌面想要状态栏就别开全屏
EOF
}

# ---------------------------- 参数解析 --------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial)     SERIAL="${2:-}"; shift 2 ;;
        --density)       DENSITY="${2:-}"; shift 2 ;;
        --timeout)       TIMEOUT_MS="${2:-}"; shift 2 ;;
        --portrait)      PORTRAIT=1; shift ;;
        --no-wallpaper)  DO_WALLPAPER=0; shift ;;
        --no-tweak)      DO_TWEAK=0; shift ;;
        --no-sync)       DO_SYNC=0; shift ;;
        --no-immersive)  DO_IMMERSIVE=0; shift ;;
        --immersive-nav) DO_IMMERSIVE=1; IMMERSIVE_MODE="navigation"; shift ;;
        --no-reboot)     DO_REBOOT=0; shift ;;
        --check)         CHECK_ONLY=1; shift ;;
        -f|--force)      FORCE=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

# Git Bash / MSYS 下必须关掉路径转换，否则 adb 收到的 /data/... 会变成 C:/...
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
        export MSYS_NO_PATHCONV=1
        # 但关掉转换后，adb.exe 也认不了 /c/Users/... 这种本地路径，
        # 所以先把仓库路径转成 C:/Users/... 混合格式喂给它
        if command -v cygpath >/dev/null 2>&1; then
            ROOT_DIR="$(cygpath -m "$ROOT_DIR")"
        fi
        ;;
esac

# ---------------------------- 定位 adb --------------------------------------
find_adb() {
    if [ -n "${ADB:-}" ] && [ -x "${ADB}" ]; then echo "$ADB"; return 0; fi
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    for p in \
        "$HOME/Library/Android/sdk/platform-tools/adb" \
        "$HOME/Android/Sdk/platform-tools/adb" \
        "/c/Users/${USER:-user}/AppData/Local/Android/Sdk/platform-tools/adb.exe" \
        "/c/Program Files (x86)/Android/android-sdk/platform-tools/adb.exe" \
        "/e/MySoft/YesStbTool-V6D3/win-x64/adb.exe" ; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

ADB_BIN="$(find_adb)"
[ -z "$ADB_BIN" ] && die "找不到 adb。请安装 platform-tools，或设置环境变量 ADB=/path/to/adb 后重试。"

ab() {
    if [ -n "$SERIAL" ]; then "$ADB_BIN" -s "$SERIAL" "$@"; else "$ADB_BIN" "$@"; fi
}
# 在设备上以 root 执行（不能用单引号包裹参数）
sh_root() { ab shell "su -c '$*'"; }

# ---------------------------- 环境检测 --------------------------------------
printf '\n%sThinkSmart View 一键部署 v%s%s\n\n' "$C_B" "$VERSION" "$C_0"

info "adb: $ADB_BIN"

# 1) 设备在线
# 注意：adb daemon 首次启动会把 "* daemon not running..." 打到 stdout，
# 必须先跳过表头再解析，否则会被误判成设备行
STATES="$(ab devices 2>/dev/null | tr -d '\r' | awk '/^List of devices attached/{f=1;next} f && NF>=2 {print $1" "$2}')"
[ -z "$STATES" ] && die "没有检测到设备。请确认 USB 已连接、且已在设备上允许 USB 调试。"

N_ONLINE=$(printf '%s\n' "$STATES" | grep -c ' device$' || true)
if [ "$N_ONLINE" -eq 0 ]; then
    printf '%s\n' "$STATES" | sed 's/^/    /'
    die "设备存在但状态不是 device（上面显示 offline/unauthorized）。请在设备上确认授权弹窗，或重新插拔 USB。"
fi
if [ "$N_ONLINE" -gt 1 ] && [ -z "$SERIAL" ]; then
    printf '%s\n' "$STATES" | sed 's/^/    /'
    die "检测到多台设备，请用 -s <序列号> 指定目标设备。"
fi

SN="$(ab shell getprop ro.serialno 2>/dev/null | tr -d '\r')"
MODEL="$(ab shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
DEVICE="$(ab shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
REL="$(ab shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
SDK="$(ab shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
ok "设备: $MODEL ($DEVICE)  Android $REL / SDK $SDK  序列号 ${SN:-$SERIAL}"

# 2) 机型校验
case "$DEVICE" in
    starfire) ;;
    *)
        if [ "$FORCE" -eq 1 ]; then
            warn "机型不是 starfire（实际 $DEVICE），已按 --force 继续，风险自负"
        else
            die "机型不匹配：期望 starfire，实际 $DEVICE。确认要装请加 --force"
        fi
        ;;
esac

# 3) root
ROOT_UID="$(ab shell 'su -c id' 2>/dev/null | tr -d '\r')"
case "$ROOT_UID" in
    *"uid=0"*) ok "root 可用: $ROOT_UID" ;;
    *)
        warn "su 不可用或未授权: ${ROOT_UID:-<空>}"
        die "本脚本需要 root。请先在设备上用 Magisk 授权 shell（或装 KernelSU）。"
        ;;
esac

# 4) root 框架的执行目录（Magisk / KernelSU / APatch 都有 /data/adb）
if ab shell "su -c 'test -d /data/adb'" >/dev/null 2>&1; then
    ok "root 框架目录 /data/adb 存在"
else
    die "/data/adb 不存在，无法安装开机脚本。请确认 Magisk / KernelSU 已正确安装。"
fi

# 5) busybox
BBDETECT="$(ab shell "su -c 'for c in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /system/xbin/busybox /system/bin/busybox; do [ -x \$c ] && echo \$c && break; done'" 2>/dev/null | tr -d '\r')"
if [ -n "$BBDETECT" ]; then
    ok "busybox: $BBDETECT"
else
    die "找不到 busybox。三个开机脚本都依赖它（date/nc/awk/swapoff）。请先安装 Magisk。"
fi

# 6) 输入设备（按键唤醒依赖）
DEVS="$(ab shell "su -c 'ls /dev/input/event* 2>/dev/null'" | tr -d '\r' | tr '\n' ' ')"
if printf '%s' "$DEVS" | grep -q 'event0'; then
    ok "输入设备: $DEVS"
else
    warn "未发现 /dev/input/event0，按键唤醒可能失效"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    printf '\n'
    ok "环境检测通过（--check 模式，未做任何修改）"
    exit 0
fi

# ---------------------------- 安装开机脚本 ----------------------------------
# 目标：Magisk/KernelSU 会在开机时依次执行这两个目录下的脚本
#   post-fs-data.d —— 更早（zram 必须在这里，swap 还几乎是空的）
#   service.d      —— 稍晚（校时需要网络，按键唤醒需要 framework 就绪）
install_script() {
    local src="$1" dst="$2"
    local name; name="$(basename "$src")"
    if ! ab push "$src" "/data/local/tmp/$name" >/dev/null 2>&1; then
        die "推送 $name 失败（本地路径: $src）"
    fi
    sh_root "mkdir -p $(dirname "$dst")" >/dev/null 2>&1
    if sh_root "cp -f /data/local/tmp/$name $dst && chmod 755 $dst && chown 0:0 $dst"; then
        ok "已安装 $dst"
    else
        die "安装 $dst 失败"
    fi
    sh_root "rm -f /data/local/tmp/$name" >/dev/null 2>&1
}

printf '\n'
info "安装开机脚本"

if [ "$DO_SYNC" -eq 1 ]; then
    install_script "$ROOT_DIR/scripts/99timesync.sh" /data/adb/service.d/99timesync.sh
else
    dim "跳过开机校时（--no-sync）"
fi

install_script "$ROOT_DIR/scripts/98zram.sh" /data/adb/post-fs-data.d/98zram.sh
install_script "$ROOT_DIR/scripts/97keywake.sh" /data/adb/service.d/97keywake.sh

# ---------------------------- 系统设置 --------------------------------------
if [ "$DO_TWEAK" -eq 1 ]; then
    printf '\n'
    info "应用系统设置"

    # 动画缩放 0.5：2GB 内存设备体感提升最明显的一项，且完全可逆
    ab shell settings put global window_animation_scale 0.5 >/dev/null 2>&1
    ab shell settings put global transition_animation_scale 0.5 >/dev/null 2>&1
    ab shell settings put global animator_duration_scale 0.5 >/dev/null 2>&1
    ok "动画缩放 → 0.5x"

    # 密度：sw = 800/dpi*160，213 → 601dp，刚好跨过 600dp 的平板分界，
    # Trebuchet 桌面才会允许旋转。260 → 492dp 会被当成手机而锁竖屏。
    ab shell "wm density $DENSITY" >/dev/null 2>&1
    NEWSW="$(ab shell "wm density | tail -1" | tr -d '\r')"
    ok "屏幕密度 → $DENSITY  ($NEWSW，需 ≥213 桌面才能横屏)"

    # 熄屏超时不设成永不：本机可按键唤醒，正常熄屏更省背光寿命
    ab shell "settings put system screen_off_timeout $TIMEOUT_MS" >/dev/null 2>&1
    ok "熄屏超时 → ${TIMEOUT_MS}ms"

    # 双击唤醒：熄屏后点屏幕也能亮（与按键唤醒互为备份）
    ab shell settings put secure double_tap_to_wake 1 >/dev/null 2>&1
    ok "双击唤醒 → 开启"

    # 自动旋转
    ab shell settings put system accelerometer_rotation 1 >/dev/null 2>&1
    ok "自动旋转 → 开启"

    # 全屏沉浸式：本机本来就没有实体键，把状态栏和导航栏藏起来，画面全给应用。
    # policy_control 走 immersive sticky —— 从屏幕下缘上滑可临时呼出导航栏，
    # 5 秒无操作自动收起，所以不会出现"全屏后回不到桌面"的情况。
    # 它属于 global 设置，重启后依然生效；还原用 settings delete global policy_control。
    if [ "$DO_IMMERSIVE" -eq 1 ]; then
        # 第一次进入沉浸式时，系统会弹一个"全屏提示"教学对话框要你点确认。
        # 这台设备是当电视/相框用的，弹窗卡在那儿没人点，所以先把确认标记写死跳过。
        ab shell "settings put secure immersive_mode_confirmations confirmed" >/dev/null 2>&1
        case "$IMMERSIVE_MODE" in
            navigation)
                ab shell "settings put global policy_control immersive.navigation=*" >/dev/null 2>&1
                WANT_PC="immersive.navigation=*"
                ok "全屏沉浸式 → 只隐藏导航栏（状态栏保留）"
                ;;
            *)
                ab shell "settings put global policy_control immersive.full=*" >/dev/null 2>&1
                WANT_PC="immersive.full=*"
                ok "全屏沉浸式 → 隐藏状态栏 + 导航栏（下缘上滑可临时呼出）"
                ;;
        esac
        PC_NOW="$(ab shell "settings get global policy_control" 2>/dev/null | tr -d '\r')"
        if [ "$PC_NOW" = "$WANT_PC" ]; then
            dim "已生效: policy_control=$PC_NOW"
        else
            warn "写入后读回为 '${PC_NOW:-<空>}'，与预期 '$WANT_PC' 不一致"
            dim "可手动执行: adb shell settings put global policy_control '$WANT_PC'"
        fi
    else
        dim "跳过全屏沉浸式（--no-immersive）"
    fi
else
    printf '\n'
    dim "跳过系统设置（--no-tweak）"
fi

# ---------------------------- 壁纸 ------------------------------------------
if [ "$DO_WALLPAPER" -eq 1 ]; then
    printf '\n'
    info "安装壁纸"

    if [ "$PORTRAIT" -eq 1 ]; then
        WP_IMG="$ROOT_DIR/wallpaper/appletv_800x1280.jpg"
        W="800"; H="1280"
        ok "使用竖屏版壁纸 800x1280"
    else
        WP_IMG="$ROOT_DIR/wallpaper/appletv_1280x800.jpg"
        W="1280"; H="800"
        ok "使用横屏版壁纸 1280x800"
    fi

    if [ ! -f "$WP_IMG" ]; then
        warn "壁纸文件不存在: $WP_IMG，跳过"
    else
        # info 文件按实际尺寸生成，避免两份一致性问题
        WP_INFO_TMP="$ROOT_DIR/.wp_info.tmp.xml"
        printf "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<wp id=\"1\" width=\"%s\" height=\"%s\" cropLeft=\"0\" cropTop=\"0\" cropRight=\"%s\" cropBottom=\"%s\" name=\"\" backup=\"true\" />\n" \
            "$W" "$H" "$W" "$H" > "$WP_INFO_TMP"

        ab push "$WP_IMG" /data/local/tmp/_wp.jpg >/dev/null 2>&1 || die "推送壁纸失败"
        ab push "$WP_INFO_TMP" /data/local/tmp/_wp_info.xml >/dev/null 2>&1 || die "推送壁纸配置失败"
        rm -f "$WP_INFO_TMP"

        sh_root "cp -f /data/system/users/0/wallpaper_info.xml /data/adb/wallpaper_info.xml.bak" >/dev/null 2>&1

        if sh_root "cp -f /data/local/tmp/_wp.jpg /data/system/users/0/wallpaper && \
                    cp -f /data/local/tmp/_wp_info.xml /data/system/users/0/wallpaper_info.xml && \
                    chown system:system /data/system/users/0/wallpaper /data/system/users/0/wallpaper_info.xml && \
                    chmod 600 /data/system/users/0/wallpaper /data/system/users/0/wallpaper_info.xml && \
                    restorecon /data/system/users/0/wallpaper /data/system/users/0/wallpaper_info.xml"; then
            ok "壁纸已写入（restorecon 已执行）"
        else
            warn "壁纸写入失败，跳过（不影响其他优化）"
        fi
        sh_root "rm -f /data/local/tmp/_wp.jpg /data/local/tmp/_wp_info.xml" >/dev/null 2>&1
    fi
fi

# ---------------------------- 完成 ------------------------------------------
printf '\n'
info "部署完成，汇总："
dim "开机脚本: /data/adb/service.d/{99timesync,97keywake}.sh  /data/adb/post-fs-data.d/98zram.sh"
dim "日志位置: /data/adb/{timesync,zram,keywake}.log"
if [ "$DO_TWEAK" -eq 1 ] && [ "$DO_IMMERSIVE" -eq 1 ]; then
    dim "全屏沉浸式: 立即生效（不用等重启），下缘上滑可呼出导航栏"
    dim "       关掉它: adb shell settings delete global policy_control"
fi
dim "立即验证: adb shell su -c 'cat /data/adb/keywake.log'"

if [ "$DO_REBOOT" -eq 1 ]; then
    printf '\n'
    warn "即将重启设备，让全部改动生效（壁纸必须重启才能加载）"
    printf '%s' "    5 秒后重启，Ctrl+C 可取消 ... "
    for i in 5 4 3 2 1; do printf '%s ' "$i"; sleep 1; done
    printf '\n'
    ab reboot
    printf '%s' "    等待设备重新上线 "
    for i in $(seq 1 40); do
        st="$(ab get-state 2>/dev/null | tr -d '\r')"
        if [ "$st" = "device" ]; then
            b="$(ab shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
            if [ "$b" = "1" ]; then printf ' 完成（约 %s 秒）\n' "$((i*3))"; break; fi
        fi
        sleep 3
        printf '.'
    done
    printf '\n'
    ok "已重启。请按一下机身音量键，屏幕应能点亮"
    dim "验证: adb shell su -c 'cat /data/adb/zram.log'"
    dim "      adb shell su -c 'cat /data/adb/timesync.log'"
    dim "      adb shell su -c 'tail -5 /data/adb/keywake.log'"
else
    printf '\n'
    warn "已跳过重启（--no-reboot）。壁纸与 zram 需要重启后才会生效："
    dim "adb reboot"
fi

printf '\n'
