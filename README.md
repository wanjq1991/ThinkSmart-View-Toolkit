# ThinkSmart View 刷机与优化

[![release](https://img.shields.io/github/v/release/wanjq1991/ThinkSmart-View-Toolkit?label=release&color=blue)](https://github.com/wanjq1991/ThinkSmart-View-Toolkit/releases/latest)
[![license](https://img.shields.io/github/license/wanjq1991/ThinkSmart-View-Toolkit)](LICENSE)
[![platform](https://img.shields.io/badge/LineageOS-15.1%20%2F%20Android%208.1-green)](docs/flashing-guide.md)
[![device](https://img.shields.io/badge/device-CD--18781Y-orange)](#)

把联想 **ThinkSmart View（CD-18781Y）** 这台 8 寸 Teams 会议屏，改造成一台能用的
LineageOS 平板，并解决它作为「无电池、无电源键、2GB 内存」设备必然会踩的一堆坑。

所有脚本都是**在本机实测跑通并重启验证**过的，不是照着文档抄的。

```
设备    Lenovo ThinkSmart View  CD-18781Y
SoC     高通 APQ8053 / MSM8953   8×Cortex-A53  2GB RAM  3.8GB 存储
屏幕    8" 800×1280 (16:10)  横竖可旋转   无电池   无实体电源键
系统    LineageOS 15.1 (Android 8.1) + OpenGApps pico + Magisk 26.4
```

---

## 一键部署

前提：设备已刷好 LineageOS 15.1 + GApps，root 为 Magisk / KernelSU，能 `adb shell su`。

```bash
git clone https://github.com/wanjq1991/ThinkSmart-View-Toolkit.git
cd ThinkSmart-View-Toolkit
./install.sh --check     # 先体检，不做任何修改
./install.sh             # 确认没问题后正式部署，最后自动重启
```

装完这四样：

| 优化 | 解决什么 | 效果（实测） |
|---|---|---|
| 开机自动校时 | 无 RTC，断电后时间回到 1970；系统 NTP 走 UDP 123 被运营商拦 | 联网后 3 秒内自动校准 |
| zram 扩容 | 2GB 内存长期占用 96%，swap 吃掉 86MB，频繁 OOM | zram 509MB → **1GB**，空闲内存 63MB → **186–244MB** |
| 按键唤醒屏幕 | 外壳无电源键，熄屏后只能靠触摸，而触摸唤醒依赖主动显示 | 按音量键即可点亮，开机自启 |
| Apple TV 风格壁纸 | 原厂壁纸灰白单调 | 深色抽象光带，横屏 1:1 铺满 |

其他选项：

```bash
./install.sh --no-reboot       # 装完不重启
./install.sh --portrait        # 壁纸用竖屏版
./install.sh --no-wallpaper    # 不换壁纸
./uninstall.sh                 # 一键还原全部改动
```

不想用 git？直接下 [**v1.0 源码包**](https://github.com/wanjq1991/ThinkSmart-View-Toolkit/releases/latest)
（zip / tar.gz），解压后同样跑 `./install.sh`。

---

## 这个设备有四个绕不过去的坑

### 1. 无 RTC 电池 + NTP 被拦 = 时间永远不对

断电重启后内核时间是 `1970-01-01`。系统确实会去同步，但：

```
SntpClient: request time failed: SocketTimeoutException
```

`time.android.com` 国内不可达；换成 `ntp.aliyun.com` 后 `ping` 通（31ms）却依然超时——
**UDP 123 端口被拦截**，ICMP 通不代表 UDP 通，这是国内运营商常见情况，NTP 这条路彻底走不通。

所以改为 **HTTP Date 头**取时（走 TCP 80，国内直连稳定）。但有个坑：busybox 和 toybox 的
`date -d` **都不认** `Sat, 31 Oct 2026 05:13:23 GMT` 这种 RFC-1123 格式，必须自己用 awk
拆开再做历法换算，然后 `date -u -s`。

实测把时间故意改到 10:00:00，脚本检出 11721 秒偏差并自动纠正。

### 2. 无 battery + 只有 USB 500mA = 随机黑屏

这台机器没有电池，**完全靠外部供电**。接电脑 USB 数据口只有 500mA：

```
usb current_max = 500000 (500mA)
battery st=3 (Discharging)        ← 系统判定"正在放电"
充电电流 434mA → 46mA，电压 3.87V 来回波动
```

全亮屏 + WiFi + 2GB 内存的运行功耗经常超过 2.5W。表现是背光突然点不亮（但系统还活着，
`adb` 在线、截图有完整画面）、触摸失灵、卡顿，严重时直接重启。

**换 5V/2A 以上的电源适配器直接插墙**，不要用电脑 USB 口。这一条比任何软件优化都有效。

判断"熄屏"还是"真死机"：

| 现象 | adb | 结论 |
|---|---|---|
| 背光灭，截图有画面 | 在线 | 纯熄屏，点屏幕即可 |
| 背光灭，截图也黑 | 在线 | 显示链路问题 |
| 全黑，adb 断 | 断开 | 供电崩溃或死机，断电重上电 |

### 3. 无电源键，熄屏后怎么叫醒

外壳上只有一个音量键。`input keyevent KEYCODE_POWER` 也熄不掉屏（ROM 禁用了主动熄屏），
只能等超时。而超时熄屏后：

- `KEYCODE_WAKEUP` 走 `PhoneWindowManager` 的**防误触**分支，要先过距离传感器
- 本机 `VCNL4200 PRX` 在没有听筒结构的平板上**长期误报"被遮挡"**

```
PowerManagerService: Not waking up. Proximity sensor is blocked.
```

于是唤醒请求被无条件拒绝——**表现就是"第一次能亮，之后怎么按都不亮"**。
`KEYCODE_POWER` 走电源键路径，**不做防误触判断**，所以能唤醒；但它是真开关，
亮屏时发会关屏，脚本必须先查 `mWakefulness`，再加冷却锁。

还有个更隐蔽的坑：**音量加和音量减不是同一个输入设备**。

| 设备 | 驱动 | 声明的键 |
|---|---|---|
| `event0` | `qpnp_pon`（PMIC） | **KEY_VOLUMEDOWN**、KEY_POWER |
| `event3` | `gpio-keys`（GPIO） | KEY_VOLUMEUP、KEY_F11、KEY_HIRAGANA |

只监听 `event3`，音量减就完全没反应。必须两个都监听。

### 4. 桌面不横屏？不是旋转坏了，是密度算错了

设备横放时设置能横屏、桌面却锁死竖屏。原因不在系统旋转：

Trebuchet 能否旋转是**写死在资源里的**（手机版 `allow_rotation=false`，只有
`values-sw600dp/` 才是 true），那个"自动旋转"开关对它完全无效。而判定手机还是平板的
唯一标准是 `smallestWidth`：

```
800 ÷ 260 × 160 ≈ 492dp   < 600dp  →  当成手机  →  桌面锁竖屏
800 ÷ 213 × 160 ≈ 601dp   ≥ 600dp  →  平板模式  →  桌面立即横屏
```

`260` 这个出厂密度对 8 寸 1280×800 本来就偏大（相当于 5 寸手机的密度）。
改成 **213**（Nexus 7 同分辨率的原生值）后立即生效，不用重启。

⚠️ 副作用是整体 UI 变小一点。**别调到 240**——会跌破 600dp，桌面重新锁竖屏。

---

## 已知硬件限制（改不了，别浪费时间）

**没有 Widevine。** 这是对企业会议设备最致命的限制：

```
/vendor/lib/mediadrm/    只有 clearkey，没有 libwvhidl
/persist/drm/            空目录，没有 keybox
```

Widevine 需要三样：TEE 固件（有）、Android 侧插件库（无）、设备 keybox（无）。
keybox 是每台设备唯一、由厂商烧在安全分区的。这台机器出厂就没做流媒体 DRM 授权，
**不是刷机刷掉的，也补不回来**。

后果：Netflix / Disney+ / YouTube / 国内视频站 VIP 内容会直接报错。
**本地文件和局域网播放完全不受影响。**

**存储只有 3.8GB**，可用约 2.6GB。装不下两部 1080p 电影，影音必须走局域网（SMB / Jellyfin）。

**解码能力**（这块反倒很强）：H.264 / H.265 / VP9 / VP8 / MPEG4 / VC1 **全部硬解**，
1080p 无压力。没有 AV1。

---

## 刷机

完整流程、踩坑记录、驱动安装、救砖方法都在 **[docs/flashing-guide.md](docs/flashing-guide.md)**
（1100+ 行，含每个报错的对照表和实测命令）。

大致步骤：

1. **解 bootloader 签名校验** —— EDL 刷入 userdebug `aboot`
2. **EDL 全分区备份** —— 12 个分区，出问题能回滚（这步别跳）
3. **刷 LineageOS 15.1 starfire** —— recovery + ROM
4. **刷 GApps pico** —— arm / 8.1
5. **root** —— Magisk 26.4，用 `boot_patch.sh` 命令行修补（应用内修补会失败）
6. **跑本项目的 `install.sh`**

⚠️ **别用 addonsu**。这版 LineageOS 的 sepolicy 没有 `u:r:su:s0` 域，
`superuser.rc` 会让 init 卡死在 LENOVO logo。真卡住了不用重刷：音量+ 上电进 recovery，
删掉 `/system/xbin/su`、`/system/bin/su`、`/system/etc/init/superuser.rc`、
`/system/addon.d/51-addonsu.sh` 即可。

### 需要的文件与校验值

仓库不含大文件（ROM 400MB / 原厂包 1.3GB），请从上游下载后用下面的 SHA256 核对：

| 文件 | 大小 | SHA256 |
|---|---|---|
| `lineage-15.1-20240531-UNOFFICIAL-starfire.zip` | 403,552,061 | `aaeb4e387a3b1395c7567d60b34b78ef6cacab9e90f9576946b69fb49e9d7660` |
| `lineage-15.1-...-recovery.img` | 28,351,788 | `a1ee1abae40e9370fa97c7b9b50befa66ba0042859f4f89527de8e3cdba6588e` |
| `open_gapps-arm-8.1-pico-20220215.zip` | 191,618,543 | `034c91278ab3c7f9af15fb8a77633dabaf490105cc42ad7d5be616220202f2d4` |
| `Magisk-v26.4.apk` | 12,526,383 | `543a96fe26c012d99baf3a3aa5a97b80508d67cc641af7c12ce9f7b226b2b889` |
| `CD-18781Y.200628.084.zip`（原厂包） | 1,292,656,192 | `4356762c02e6d74ee4bb0ef83c9e4dba910453bb5f14fa3ac9ed321ec4bfa686` |

下载地址与备用镜像见 [docs/flashing-guide.md](docs/flashing-guide.md)。

---

## 目录结构

```
.
├── install.sh                  # 一键部署（含环境体检、幂等、型号校验）
├── uninstall.sh                # 一键还原
├── scripts/
│   ├── 97keywake.sh            # service.d      按键唤醒守护（双设备监听）
│   ├── 98zram.sh               # post-fs-data.d zram 扩容（带 OOM 保护）
│   └── 99timesync.sh           # service.d      开机 HTTP 校时
├── wallpaper/
│   ├── appletv_1280x800.jpg    # 横屏壁纸（默认）
│   ├── appletv_800x1280.jpg    # 竖屏壁纸
│   └── appletv_source_1536x1024.png
├── docs/
│   ├── flashing-guide.md       # 完整刷机手册 + 全部踩坑记录
│   └── tweaks.md               # 四个优化的原理与调试方法（可移植到别的机型）
└── tools/
    └── verify.sh               # 装完后自检，逐项确认是否真的生效
```

---

## 常用命令速查

```bash
# 看设备状态
adb shell dumpsys power | grep mWakefulness        # Awake / Dozing / Asleep
adb shell wm size; adb shell wm density
adb shell su -c 'cat /proc/swaps'                  # zram 用量
adb shell su -c 'cat /sys/block/zram0/disksize'    # zram 容量

# 看优化日志
adb shell su -c 'cat /data/adb/zram.log'
adb shell su -c 'cat /data/adb/timesync.log'
adb shell su -c 'tail -20 /data/adb/keywake.log'

# 唤醒屏幕（没按键时）
adb shell input keyevent KEYCODE_POWER

# 手动设置壁纸尺寸（换自己的图）
#   图片 = 屏幕尺寸（横 1280x800 / 竖 800x1280），见 docs/tweaks.md 附录 F
```

---

## 常见问题

**Q：桌面又锁回竖屏了？**
密度被改回 ≥240 了。`adb shell wm density 213` 即可。

**Q：按音量键能亮，但音量也跟着变了一格？**
同一个按键事件被守护脚本和 Android 各消费了一次，没有"纯唤醒不产生动作"的键码可用。
换成别的键只是换一种副作用，保持现状。

**Q：能不能看 Netflix / YouTube？**
不能，缺 Widevine keybox，硬件层面就没有。见上文「已知硬件限制」。

**Q：装了 Kodi 吗？**
没有。Kodi 镜像在本机实测只有 19–24 KB/s（67MB 要近 1 小时），APKPure / F-Droid
经代理均返回 502。**VLC 3.6.5 (armeabi-v7a)** 已实测 1080p 满屏硬解正常，日常够用。
设备是 32 位 arm，装 64 位包会失败。

**Q：Magisk 提示更新能点吗？**
**别点。** 会升到 30.6 与核心 26.4 不匹配，需要用 `adb install -r -d` 降回来。

---

## 致谢

- [LineageOS](https://lineageos.org/) 与 starfire 的维护者 deadman96385 / electimon
- [bkerler/edl](https://github.com/bkerler/edl) —— 高通 EDL 刷机工具链
- [OpenGApps](https://opengapps.org/)、[Magisk](https://github.com/topjohnwu/Magisk)、
  [VLC for Android](https://www.videolan.org/vlc/download-android.html)
- ThinkSmart View 社区里所有先把坑踩完的人

## 许可

脚本与文档：[MIT](LICENSE)。
壁纸图像由 AI 生成，随项目以相同许可提供，可自由使用。

---

**免责声明**：刷机会清空数据、有变砖风险（有 EDL 兜底可救）。照着自己负责。
