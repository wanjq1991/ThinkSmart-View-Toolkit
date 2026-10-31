# 各项优化的原理与调试方法

这份文档不讲"怎么做"（`install.sh` 已经做完了），讲**为什么这么做**和**怎么自己查出来**。
如果你手上是别的老 Android 设备，方法论可以直接搬过去。

---

## 0. 先分清问题在哪一层

老设备出问题，90% 的时间浪费在"改错层"。按这个顺序往下切：

| 层 | 怎么验证 | 典型症状 |
|---|---|---|
| 硬件/供电 | `dmesg \| grep -iE 'vbus\|charger\|thermal'`、`cat /sys/class/power_supply/*` | 随机黑屏、触摸失灵、莫名重启 |
| 内核 | `dmesg`、`/sys/kernel/debug/wakeup_sources`、`/proc/device-tree/` | 设备不响应、按键没注册成唤醒源 |
| HAL / vendor | `/vendor/lib*`、`dumpsys media.drm`、`getprop \| grep vendor` | 解码失败、DRM 报错、传感器乱报 |
| framework | `logcat -b system`、`dumpsys <service>` | 系统拒绝你的请求（**最容易被忽略的一层**） |
| 应用 | `logcat`、`dumpsys activity` | 单个 App 的问题 |

**关键教训**：Android 里"命令执行成功了"和"事情真的发生了"是两件事。
`input keyevent` 返回 0 不代表屏幕亮了，必须回读状态确认。

```bash
# 反例：只看返回码
adb shell input keyevent KEYCODE_WAKEUP; echo $?     # → 0，但屏幕可能没亮

# 正解：回读状态
adb shell dumpsys power | grep -m1 mWakefulness       # → Dozing 说明根本没亮
```

---

## 1. zram 扩容：509MB → 1GB

### 现象

`free -m` 显示内存占用 96.6%（1799/1862MB），`/proc/swaps` 里 zram 已用 86MB。
后台一多就杀应用，切回来重新加载。

### 定位

```bash
su -c 'cat /sys/block/zram0/disksize'      # → 533413200 (509MB)
su -c 'cat /proc/swaps'                    # → 已用 86MB
grep -i zram /vendor/etc/fstab.qcom        # → zramsize=533413200
cat /sys/block/zram0/comp_algorithm        # → lzo
```

出厂按 27% RAM 配。2GB 设备上这个比例偏保守。

### 尝试过的错路

想换 `lz4`（Android 11+ 默认，压缩快、解压更快）：

```bash
echo lz4 > /sys/block/zram0/comp_algorithm
cat /sys/block/zram0/comp_algorithm        # → 还是只有 lzo
```

**内核根本没编译 lz4**，写不进去。MSM8953 的 LineageOS 15.1 只带 `lzo`。
所以只能扩容量，压缩比实测 3.3:1（509MB 物理存了约 1.7GB 数据）。

### 一个差点造成死机的坑

改 zram 必须先 `swapoff`，而 `swapoff` 会把 zram 里的数据**全部解压回 RAM**。
当时状态是：swap 已用 88MB，RAM 只剩 63MB 空闲 → **直接执行必然 OOM 死机**。

所以脚本加了一道闸：只有 swap 用量 < 20MB 才动手。

```sh
used=$(awk '/zram0/ {print $4}' /proc/swaps)
if [ -n "$used" ] && [ "$used" -gt 20480 ]; then
    log "跳过: 当前 swap 已用 ${used}KB (>20MB)，运行时调整有 OOM 风险"
    exit 0
fi
```

正常运行脚本会被拒绝（实际日志：`跳过: 当前 swap 已用 91000KB`），
只有开机早期 `post-fs-data` 阶段（swap 接近 0）才会真正执行。

**为什么放 `post-fs-data.d` 而不是 `service.d`**：前者执行更早，那时 swap 还没被用起来。

---

## 2. 开机校时：NTP 走不通，改用 HTTP Date

### 三层原因，逐层排除

**第一层：没有 RTC。** 断电后 `dmesg` 里内核时间读出来是 `1970-01-01 00:36:39`。

**第二层：默认 NTP 服务器国内不可达。**

```bash
adb logcat -d | grep SntpClient
# SntpClient: request time failed: SocketTimeoutException
```

`settings get global ntp_server` 是 `null`，也就是用默认的 `time.android.com`。

**第三层（这一步最容易误判）：换成国内服务器也不行。**

```bash
ping -c 2 ntp.aliyun.com      # → 通，31ms
settings put global ntp_server ntp.aliyun.com
# 等 12 秒后再看 → 时间依旧不对
```

`ping` 通只证明 **ICMP** 通。NTP 走 **UDP 123**，国内运营商常把这个端口拦掉。
ICMP 通 ≠ UDP 通，这是排查网络服务时最容易犯的错。

验证方法：

```bash
# 看系统 NTP 到底有没有成功
adb logcat -d | grep -iE 'SntpClient|NtpTrustedTime'
```

### 解法：HTTP Date 头（TCP 80）

```bash
printf 'HEAD / HTTP/1.0\r\nHost: www.baidu.com\r\nConnection: close\r\n\r\n' \
  | busybox nc -w 5 www.baidu.com 80 | grep -i '^date:'
# → Date: Sat, 31 Oct 2026 05:13:01 GMT
```

三个接口都试过：

| 源 | 结果 |
|---|---|
| `www.baidu.com` / `www.163.com` / `www.qq.com` 的 `Date` 头 | ✅ 稳定可用 |
| `api.m.taobao.com` 返回时间戳 | ❌ DNS 被污染 |
| `busybox rdate`（TCP 37） | ❌ 端口不通 |

### 又一个坑：`date -d` 不认 RFC-1123

busybox 和 toybox 的 `date -d` 都**无法解析** `Sat, 31 Oct 2026 05:13:01 GMT`。
不能用 `date -d "..."` 直接转，只能自己用 awk 做历法换算：

```awk
function dfc(y, m, d,   era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int(y / 400); if (y < 0 && y % 400 != 0) era--
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468        # 距 1970-01-01 的天数
}
```

然后 `date -u -s "YYYY-MM-DD HH:MM:SS"` 写入（**必须是 UTC，不能用本地时间**）。

### 验证方法

不要只看"脚本跑完了"，要故意把时间改错再跑一遍：

```bash
busybox date -u -s "2026-10-31 02:00:00"     # 故意改错
sh /data/adb/service.d/99timesync.sh
cat /data/adb/timesync.log                    # → 检出 11721s 偏差并纠正
```

---

## 3. 按键唤醒：三层失败

目标：外壳没有电源键，按任意物理按键点亮屏幕。

### 失败 1：给 keylayout 加 `WAKE` 标记 —— 无效

```bash
mount -o remount,rw /vendor
sed -i 's|^key 115.*|key 115   VOLUME_UP   WAKE|' /vendor/usr/keylayout/gpio-keys.kl
mount -o remount,ro /vendor && reboot
```

按键后查内核：

```bash
cat /sys/kernel/debug/wakeup_sources | grep KeyEvents
# → event_count=601   wakeup_count=0
```

`event_count` 在涨说明**事件确实送到内核了**，但 `wakeup_count` 恒为 0 说明
**内核压根没把 gpio-keys 注册成唤醒源**。Android 层的 `WAKE` 标记只是应用层标签，
决定不了内核行为。

### 失败 2：后台 getevent 守护收不到事件

用 `nohup ... &` 启动脚本，日志为空。两个原因叠加：

1. **`su -c 'xxx &'` 里 su 一退出，子进程就被一起清理** → 必须 `setsid`
2. **`getevent` 输出到管道时按 4KB 块缓冲** → `while read` 永远读不到整行

```bash
# 错的：会阻塞在缓冲区
getevent -l /dev/input/event3 | while read line; do ...; done

# 对的：每次只取一个事件，进程退出时强制刷新
ev=$(getevent -c 1 -l /dev/input/event3)
```

### 失败 3（真正的拦路虎）：距离传感器

```bash
adb logcat -d | grep 'Not waking up'
# PowerManagerService: Not waking up. Proximity sensor is blocked.
```

- `KEYCODE_WAKEUP` 走 `PhoneWindowManager` 的**防误触**分支，要先过距离传感器
- 本机 `VCNL4200 PRX` 在没有听筒结构的平板上**长期误报"被遮挡"**
- 于是唤醒请求被无条件拒绝 → 表现为"第一次能亮，之后怎么按都不亮"

对比测试：

```bash
input keyevent KEYCODE_WAKEUP    # → 被拦
input keyevent KEYCODE_POWER     # → 亮了
```

**`KEYCODE_POWER` 走电源键路径，不做防误触判断。** 但它也是**真开关**：
亮屏时发会把屏关掉。所以脚本必须：

1. 先读 `mWakefulness`，`Awake` 直接返回
2. 加 3 秒冷却锁，防止连按"亮 → 灭"（看起来像没反应）

### 补充发现：音量加和音量减是两个设备

用户反馈"只有音量+能点亮"。逐个设备查声明键码：

```bash
for d in /dev/input/event*; do
    echo "== $d"; getevent -pl "$d" 2>/dev/null | grep -E 'name:|KEY \(0001\)'
done
```

| 设备 | 驱动 | 键 |
|---|---|---|
| `event0` | `qpnp_pon`（PMIC） | **KEY_VOLUMEDOWN**、KEY_POWER |
| `event3` | `gpio-keys`（GPIO） | KEY_VOLUMEUP、KEY_F11、KEY_HIRAGANA |

**加号走 GPIO、减号走 PMIC**，是两个独立 evdev 设备。只监听 `event3`，
减号的事件根本没被读到。

顺带一个连带问题：两个子进程各持一份 shell 变量，**内存里的冷却锁失效了**，
必须改成文件时间戳共享。

### 排障口诀

```
日志里没有 "按键:" 行       → 事件没读到（getevent 挂了 / 设备没监听）
有 "按键:" 但没有 "唤醒成功"  → 事件读到了但被系统拒绝（看 logcat 'Not waking up'）
```

---

## 4. 桌面横屏：改密度而不是改旋转

### 现象与误判

设备横放时「设置」能横屏，桌面却锁死竖屏。`user_rotation=1` 写进去了，
`mCurrentRotation` 一直是 0，重启也不变——差点误判成"这个 ROM 的旋转坏了"。

**真实原因是密度算出的小屏宽不到平板门槛。**

### 原理

Trebuchet 能否旋转是**写死在资源里的**：手机版 `allow_rotation=false`，
只有 `values-sw600dp/` 下才是 true。系统那个"自动旋转"开关对它完全无效。

判定手机/平板只看 `smallestWidth`：

```
sw = 屏幕短边像素 ÷ density × 160
800 ÷ 260 × 160 ≈ 492dp   < 600dp  →  手机模式  →  桌面锁竖屏
800 ÷ 213 × 160 ≈ 601dp   ≥ 600dp  →  平板模式  →  桌面可旋转
```

### 改法与边界

```bash
adb shell wm density 213      # 立即生效，不用重启
adb shell dumpsys window | grep -oE 'sw[0-9]+dp'
```

`213` 是 1280×800 这代面板的原生密度（Nexus 7 同款）。

**边界要记住**：

| 密度 | sw | 结果 |
|---|---|---|
| 240 | 533dp | ❌ 桌面锁竖屏 |
| **213** | **601dp** | ✅ 刚好过线 |
| 180 | 711dp | ✅ 但 UI 过小 |

`213` 是这个门槛上的临界值，**不能再往回调**。副作用是 UI 整体变小，可接受。

设置存在 `Settings.Secure.display_density_forced`，重启不丢。

---

## 5. 壁纸：Android 8.1 没有命令行入口

```bash
adb shell cmd wallpaper
# → No shell command implementation.
```

`service list` 里确实有 `wallpaper: [android.app.IWallpaperManager]`，但没有 shell 实现
（Android 11+ 才有 `cmd wallpaper`）。`service call` 要传 `ParcelFileDescriptor`，不现实。
重启 SystemUI 也没用——**壁纸 bitmap 缓存在 `system_server` 里**。

只能直接写文件：

```bash
# 必须：chown system:system + chmod 600 + restorecon
# 正确标签是 u:object_r:wallpaper_file:s0，标签错就读不到，回退默认壁纸
restorecon /data/system/users/0/wallpaper

# 必须重启（WallpaperManagerService 只在启动时读文件）
adb reboot
```

系统启动后会**自己重写** `wallpaper_info.xml`（补 `colorsCount` / `colorValue*`，
width 改成可滚动宽度 1600）并生成 `wallpaper_orig`——这不是失败，恰恰说明壁纸被接受了。

**静态壁纸不随屏幕旋转**：按横屏 1280×800 做，横屏 1:1 完美；竖放时系统放大裁剪中间一块。

---

## 6. 全屏沉浸式：policy_control 和那个没人点的弹窗

一行就能开：

```bash
adb shell settings put global policy_control immersive.full=*
```

它是 **sticky** 模式——导航栏只是被藏起来，从屏幕下缘上滑仍能临时唤出，5 秒无操作自动收起，
所以不会出现"全屏之后回不到桌面"。值写在 `global` 里，重启后依旧生效。

但只写这一行，无人值守的场景会翻车：

```bash
# 首次进入沉浸式，系统会弹一个"全屏提示"教学框，要你点"知道了"。
# 电视 / 相框场景没人点，画面就永远停在那个弹窗上。
# 先把这个确认标记写死，弹窗不再出现：
adb shell settings put secure immersive_mode_confirmations confirmed
```

只想藏导航栏、保留状态栏看时间和电量：

```bash
adb shell settings put global policy_control immersive.navigation=*
```

还原：

```bash
adb shell settings delete global policy_control   # 读回 null 即已退出沉浸式
```

`immersive.full=*` 是不分应用的，输入法和对话框也在全屏里，偶尔会出现键盘贴到屏幕最下缘的情况。
本机没有实体键、本来就当电视/相框用，这个代价可以接受；如果拿它当平板用，`--immersive-nav`
只藏导航栏更稳。

---

## 附：可复用的工程细节

这些坑和具体设备无关，做 adb 自动化都会遇到：

```bash
# 1. Git Bash / MSYS 下 adb 收到的 /data/... 会被转成 C:/...，必须关掉
export MSYS_NO_PATHCONV=1

# 2. /data/adb 是 root 独占，adb push 直接进去 Permission denied
#    而且错误只在 stderr，`| tail -1` 截断 stdout 会误判成功
adb push x.sh /data/local/tmp/x.sh          # 先推临时目录
adb shell su -c 'cp /data/local/tmp/x.sh /data/adb/service.d/x.sh'

# 3. su -c 'pkill -f 97keywake' 会匹配到自己的命令行，把执行 shell 一起杀掉
#    导致后续命令全部不生效且无输出
adb shell su -c 'pkill -f "[9]7keywake"'    # 用方括号规避自匹配

# 4. su 退出会带走子进程，需要脱离会话
adb shell su -c 'setsid sh /path/x.sh </dev/null >/dev/null 2>&1 &'

# 5. 截图不要用 exec-out（Windows 会做换行转换，破坏 PNG）
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png ./s.png

# 6. 单实例锁要核对 /proc/PID/cmdline，不能只 kill -0
#    重启后 PID 被别的进程复用，脚本会误以为自己在跑而拒绝启动
```
