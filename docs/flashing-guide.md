# ThinkSmart View (CD-18781Y) 刷 LineageOS 15.1 实操手册

> 适用机型：Lenovo ThinkSmart View，型号 **CD-18781Y**，8 寸 1280×800 触摸屏，高通 MSM8953 平台，2GB RAM / 8GB eMMC，无电池。
> 目标系统：LineageOS 15.1（Android 8.1，代号 **starfire**，deadman96385 维护的非官方版）。
> 原厂 Teams Display 系统早已停更、没有 OTA，刷机是这台机器唯一的出路。

---

## 0. 先搞清楚三个概念

| 概念 | 说明 |
|---|---|
| **EDL / 9008** | 高通芯片的底层烧写模式（Emergency Download）。不管系统怎么坏、怎么砖，只要 EDL 能进就能救回来 |
| **firehose / QFIL** | 通过 EDL 整盘写入分区镜像的工具链。`prog_emmc_firehose_8953_ddr.mbn` 是 8953 平台的引导程序 |
| **aboot** | 安卓的引导加载器分区。刷入泄露的 userdebug 版 `emmc_appsboot.mbn` 后，机器才允许启动自定义 recovery |
| **sideload** | 在 recovery 里通过 `adb sideload xxx.zip` 刷系统包，全程不用 root、不用解锁 BL |

刷机链路一句话：
**EDL 灌原厂 userdebug 镜像 → 单独刷 aboot + 自定义 recovery → recovery 里 sideload LineageOS → 双清 → 开机**

---

## 1. 物料清单

### 硬件
- [ ] **USB-A 转 USB-C 数据线**（必须是数据线，能传文件；充电线不行）
- [ ] **USB 2.0 口**（黑色口，不是蓝色 3.0/3.1）——这条是成败关键，见第 7 节
- [ ] 电脑：Windows 10/11（主路线）或 Linux / 树莓派（可选路线）
- [ ] 小号十字螺丝刀（拆底盖，如果橡胶塞抠不出来）
- [ ] 键盘 + 鼠标（可选，首次配置时比虚拟键盘舒服）

### 文件（4 个，缺一不可）

| 文件 | 作用 | 大小 | 地址 |
|---|---|---|---|
| `CD-18781Y.200628.084.zip` | 联想泄露的 userdebug 固件（含 109 个分区文件） | 1.29 GB | `https://s3.wasabisys.com/filestash-buk/lenovo-thinksmart-view/CD-18781Y.200628.084.zip` |
| `lineage-15.1-20240531-UNOFFICIAL-starfire-recovery.img` | 自定义 recovery | 28 MB | `https://s3.us-west-1.wasabisys.com/rom-release/LineageOS/15.1/starfire/lineage-15.1-20240531-UNOFFICIAL-starfire-recovery.img` |
| `lineage-15.1-20240531-UNOFFICIAL-starfire.zip` | 系统包 | 403 MB | 同上目录，改后缀为 `.zip` |
| `open_gapps-arm-8.1-pico-20220215.zip` | Google 服务（可选，只用 HA/标牌可以不刷） | 约 100 MB | SourceForge: `opengapps/files/arm/20220215/` |

> **重要修正**：网上大量教程写的是 `20240602` 那版系统包，但该文件已从镜像站撤下（403）。当前镜像上只有 **20240531** 的 zip 和 recovery，**两个都用 0531 这一对**，版本要对齐。
> 下载完先核对大小，1.29GB / 28MB / 403MB 对得上再动手。

### 工具
- [ ] **QDLoader HS-USB Driver**（高通 9008 驱动）
- [ ] **QPST 2.7.496**（内含 QFIL 工具）
- [ ] **ADB & Fastboot++**（自带驱动与 adb 环境）
- [ ] 备选 Linux 路线：`pip install edl`（bkerler/edl）

> Windows 工具合集在 XDA 那个帖子的附件区，或 pgale 仓库里给的网盘链接。装完驱动后系统会进 **测试模式**（桌面右下角有水印），这是正常的，因为驱动未签名。

---

## 2. 目录准备

```
C:\Users\<你>\Desktop\ThinkSmartView\
├── image\                                        ← 从 CD-18781Y.200628.084.zip 里解出来的整个 image 文件夹
│   ├── prog_emmc_firehose_8953_ddr.mbn
│   ├── rawprogram_unsparse.xml
│   ├── patch0.xml
│   ├── emmc_appsboot.mbn
│   └── ...（共 109 个文件）
├── lineage-15.1-20240531-UNOFFICIAL-starfire-recovery.img
├── lineage-15.1-20240531-UNOFFICIAL-starfire.zip     ← 不要解压
└── open_gapps-arm-8.1-pico-20220215.zip              ← 不要解压
```

三个大文件**保持 zip/img 原样，绝对不要解压**。

---

## 3. 进入 EDL 模式（关键动作）

1. 断电（拔插头，或关掉插排开关 —— 比拔设备端那根很紧的电源线省力）
2. 撬开屏幕**底部（横放时）的橡胶塞/脚垫**，露出 USB-C 口，插上线到电脑
3. **同时按住两个音量键不放**
4. 上电
5. 听到 Windows 的“设备接入”提示音（或数 5 秒）后松开音量键
6. 屏幕保持全黑 = 已进 EDL。设备管理器里应出现 `Qualcomm HS-USB QDLoader 9008 (COMx)`

> 进了 EDL 别晾太久，超过一两分钟容易出现 `main:320 Uploading Image using Sahara protocol failed`，重新断电来过即可。

---

## 4. 阶段一：灌原厂镜像（QFIL，Windows）

先刷回原厂 `200628.084`，从已知状态出发，能规避后面 90% 的玄学问题。

1. 打开 QFIL（开始菜单搜 QFIL）
2. **Select Build Type** → `Flat Build`
3. **Select Programmer** → 选 `image\prog_emmc_firehose_8953_ddr.mbn`
4. **Load XML** → 选 `rawprogram_unsparse.xml`，弹窗再选 `patch0.xml`
5. 设备先进 EDL（第 3 节），然后点 **Select Port** → 选中那个 Qualcomm COM 口
6. 点 **Download**，等状态栏跑完显示 `Download Succeed`

**Linux 等价操作**（更稳，推荐有树莓派就用这条）：

```bash
~/edl/edl qfil ~/ThinkSmartView/image/rawprogram_unsparse.xml \
  ~/ThinkSmartView/image/patch0.xml ~/ThinkSmartView/image \
  --loader=$HOME/ThinkSmartView/image/prog_emmc_firehose_8953_ddr.mbn
```

设备同样在命令执行后再按双音量键上电进 EDL。

灌完镜像后机器会自己重启到原厂 Teams 系统，**先别管它**，直接进下一步。

---

## 5. 阶段二：刷 aboot + recovery

Linux 路线直接在 EDL 下写三个分区（一条一条执行）：

```bash
edl w aboot    ~/ThinkSmartView/image/emmc_appsboot.mbn
edl w abootbak ~/ThinkSmartView/image/emmc_appsboot.mbn
edl w recovery ~/ThinkSmartView/lineage-15.1-20240531-UNOFFICIAL-starfire-recovery.img
```

Windows 路线：QFIL 灌完原厂包后，同样用 QFIL 的 **Tools → Partition Manager** 或再走一次 Flat Build 只写这三个分区；社区更常见的做法是用 QFIL 灌完原厂包后，用 `edl` 的 Windows 版（同一套 Python 工具在 Windows 下也能跑）执行上面三条命令，比在 QFIL 里逐分区折腾省事。

写完断电，按住 **音量+** 上电：

- 出现 Lenovo 开机画面时**松开音量+**
- 进入 LineageOS recovery（蓝/黑底文字菜单）

---

## 6. 阶段三：sideload 系统

> 这个 recovery **没有触摸**，操作靠：**音量键上下移动光标**，**滑动摄像头挡板 = 确认/选择**（对，就是那个物理遮摄像头的小滑块，它就是“回车键”）。

1. `Apply update` → 滑挡板确认
2. `Apply from ADB` → 滑挡板确认 → 屏幕显示 `ADB Sideload`
3. 电脑上执行（每次 sideload 前都要重新选一次 `Apply from ADB`，超时很快）：

```bash
adb devices
# 应显示 xxxxxxxx    sideload

adb sideload lineage-15.1-20240531-UNOFFICIAL-starfire.zip
```

4. 刷完回到菜单，再 `Apply update → Apply from ADB`，然后：

```bash
adb sideload open_gapps-arm-8.1-pico-20220215.zip
```

5. **双清**：`Factory reset` → `Wipe data / factory reset` → `Yes`
6. `Reboot system now`，**不要按任何按键**
7. Lenovo 开机画面之后是 LineageOS 开机动画，首次约 1–2 分钟

---

## 7. 报错对照表（提前看，能省两小时）

| 现象 | 原因 | 处理 |
|---|---|---|
| QFIL 卡一分钟然后报 **Sahara** 错误 | USB 口/线不兼容（最常见） | 换 **USB 2.0 黑口**、换线；设备管理器里确认挂在 USB 2.0 总线上；老电脑更容易成功 |
| 设备管理器看不到 9008 设备 | 驱动没装好 / 未签名驱动被拦 | 装 QDLoader 驱动，接受测试模式；Win11 需关“内存完整性” |
| `adb: sideload connection failed: no devices/emulators found` | sideload 会话超时 | 回 recovery，重新选 `Apply from ADB`，10 秒内发命令 |
| `E1001: Failed to update system image` | 首次 sideload 常见报错 | 重启回 recovery 重刷，第二次基本就过 |
| 卡在 47% 一两分钟 | 正常，在写 system 分区 | 别拔线 |
| 开机后弹 `Speech Services by Google has stopped` | 已知无害 | 点掉即可 |
| 首启 WiFi 后卡死在 `Checking for updates` | Lineage 已知 bug | 等几秒后**点屏幕返回键**（会有一层新页面从左侧滑入），再点返回就能跳过 |
| 刷完黑屏/反复重启 | aboot 没写对 | 重新进 EDL，补刷 `aboot` + `abootbak` |

---

## 8. 阶段四：首启配置（照抄即可）

- 语言/时区：手动设成 Asia/Shanghai（自动有时区偏差）
- 亮度 100%、**关自适应亮度**、**关 LiveDisplay**、休眠设 30 分钟
- 屏幕旋转：先打开再关闭一次自动旋转（绕过初始状态 bug）
- 电池图标隐藏（这机器没电池）
- 声音：先把媒体音量调到 60–80%，避免开机静音以为什么都没响
- 关于手机 → 连点版本号 → 开发者选项 → **ADB 调试开**、root 权限设为 ADB only
- ADB over WiFi（不用每次插线）：

```bash
adb tcpip 5555
adb connect <设备IP>:5555
```

---

## 9. 刷完之后能干什么

| 用途 | 关键 App / 做法 |
|---|---|
| **Home Assistant 中控** | Fully Kiosk Browser 锁 dashboard，设开机自启 + 常亮 + 隐藏状态栏 |
| **语音助手终端** | View Assist（HA 侧配套），麦克风和喇叭在 Lineage 下可用 |
| **3D 打印上位屏** | KlipperScreen（Moonraker 直连）或 OctoPrint 的 Kiosk 模式 |
| **数字标牌 / 车间看板** | 任意网页 + Fully Kiosk；或用 Fully 的 REST API 远程切 URL |
| **监控常显** | Frigate / WebRTC 网页流，2GB 内存跑 1–2 路刚好 |
| **电子相框 / 桌面钟** | Fotoo（相框）、各类 clock widget |
| **当 Linux 小终端** | postmarketOS（Alpine 基础），折腾成本明显更高，不建议首选 |

性能上限提醒：2GB RAM + Android 8.1，复杂网页会卡；想装新 App 注意最低系统版本要求。可以手动 sideload 兼容 8.1 的新版 Android System WebView（125.x arm）获得一点渲染提速。

---

## 10. 救砖 & 回原厂

**几乎所有砖都能救**，因为 firehose 在只读 ROM 里：

1. 断电，双音量键上电 → EDL（屏幕黑、电脑出 9008 端口 = 有救）
2. 重跑第 4 节的 QFIL/edl 整盘写入 `200628.084`
3. 想彻底回原厂：只做第 4 节，不刷 aboot、不刷 recovery，开机就是 Teams Display

真正救不回来的情况：硬件损坏、eMMC 挂了、EDL 认不到端口 —— 这时候才是真砖。

---

## 11. 风险与注意

- 无官方支持，**保修作废**，联想不提供任何刷机协助
- 刷机过程中断电有小概率写坏分区表，靠 EDL 重来即可，但**别在写入时拔线**
- 拆底盖/抠橡胶塞会留痕迹，二手转卖会掉价
- 机器无电池，断电即重启；做常亮看板建议配 UPS 或走 PoE 转 USB-C
- 原厂 Teams Display 生态已停，别再指望用它开 Teams 会议

---

## 12. 一句话流程速查

```
双音量键上电 → EDL → QFIL 灌 200628.084 → 写 aboot/abootbak/recovery
→ 音量+ 上电进 recovery → sideload lineage-15.1-20240531.zip
→ sideload opengapps-pico → 双清 → 重启 → 配置
```

---

# 附录 A：本机实测状态（2026-10-31 实机读取）

## A1. 硬件与系统实况

| 项目 | 实测结果 |
|---|---|
| 序列号 | `HUA0BNEU` |
| USB | `VID_05C6 PID_901D`（高通 ADB 复合设备），挂在 **USB 3.0 根集线器**（Intel USB 3.20 xHCI） |
| Android | 8.1.0，`OPM1.171019.026`，32 位用户空间（`msm8953_32`） |
| 构建 | `msm8953_32-user 8.1.0 ... eng.penghu.20220620.090723 test-keys` |
| 构建者 | `penghuijun@liujun-T630`，2022-06-20 |
| 显示名 | `Lenovo_Kingston_OS_PV_220620_V0.0.40` |
| 内核 | `3.18.71-perf-ge1d404943da7-dirty`，2022-06-17 自编译 |
| 安全补丁 | 2018-07-05 |
| 内存 / 存储 | 1866 MB / eMMC 7,634,944 KB（≈7.28 GiB） |
| 屏幕 | 800×1280，density 240 |
| CPU | 8 核 Cortex-A53（MSM8953），ARMv7 |
| 分区方案 | **A-only**（无 `_a/_b`），system=p24、vendor=p25、cache=p26、data=p51 |
| 磁盘占用 | /system 1.2G / 1.4G；/data 989M / 3.2G |
| 引导状态 | `flash.locked=1`、`verifiedbootstate=green`、`veritymode=enforcing` |
| OEM 解锁 | `ro.oem_unlock_supported=true` 但 `sys.oem_unlock_allowed=0` |
| root | 无 su，`ro.debuggable=0`，`id` = shell(2000) |

## A2. 关键结论：这台是「改机版」，不是联想原厂 Teams 固件

- 已装第三方 App：抖音（`com.ss.android.ugc.aweme`）、华为应用市场、X-Plore 文件管理器、
  Rotation Lock、两个本地播放器（`com.player.ku9`、`com.amcfy.player`），桌面是原生 `launcher3`。
- 系统构建者 `penghuijun@liujun-T630` 是个人 PC 名，内核带 `-dirty` 后缀 —— 前手/卖家自编的 ROM。
- 也就是说：**这台机器已经被 EDL 整盘刷过一次**，当前 aboot 很可能已经是放行签名的版本
  （否则那个自编译内核根本起不来）。这是后面能走「只写 recovery」捷径的依据。

## A3. 两条路线

**Plan A（首选，省 1.29 GB 下载）**
1. 进 EDL，`edl r` 备份 `aboot / abootbak / boot / recovery / persist`
2. 只写 `recovery` = Lineage recovery
3. 音量+ 上电进 recovery → sideload LineageOS → 双清 → 开机
4. 失败则用备份回滚，转 Plan B

**Plan B（保险，官方教程路线）**
1. EDL 整盘刷 `CD-18781Y.200628.084`
2. 写 `aboot + abootbak + recovery`
3. sideload 同上

## A4. 本机环境限制（实测）

| 限制 | 影响 | 对策 |
|---|---|---|
| 只有 USB 3.20 xHCI 根集线器，无 EHCI | Sahara 错误高风险 | 中间串一个 USB 2.0 HUB；或换老机器 |
| `wsl.exe` 被安全策略拉黑 | 无法走 Linux 路线 | 改用 Windows 原生工具链 |
| `reg.exe` 被安全策略拉黑 | `edl.py` 启动即调 `reg query`，被拦 | 白名单放行 `reg.exe`，或改用 QFIL |
| wasabisys 单线程 13 KB/s，32 线程 ≈500 KB/s | 1.29 GB 要下很久 | 已用分段并发下载器 `_diag/pdl.py` |

## A5. 本地已就绪

- `_tools_edl/` —— bkerler/edl 源码版（依赖已装，`python edl.py --help` 可跑，keystone 缺失仅影响可选功能）
- `_diag/zadig.exe` —— 用于把 9008 设备绑定到 libusb/WinUSB
- `_diag/pdl2.py` —— 32 线程分段下载器（严格校验 206 + Content-Range）
- `_diag/dl.sh` —— curl 版分段下载器（对 SourceForge 这类 urllib 握手超时的站点更稳）
- `_diag/getprop-before.txt` —— 刷机前 432 行完整属性快照

## A6. 目标配置（用户确认）

| 组件 | 选择 | 说明 |
|---|---|---|
| 系统 | LineageOS 15.1 `starfire` 20240531 | 干净 AOSP，无预装 |
| 谷歌服务 | OpenGApps **pico** arm-8.1（20220215） | 只要 Play 商店 + Play 服务核心，2GB 内存必须用 pico |
| root | ~~优先 Lineage 自带 su~~ → **直接上 Magisk v26.4** | 实测 `addonsu` 在这版会卡开机，详见附录 B4。Magisk v26.4 是最后几个对 Android 8.1 兼容良好的版本 |

### root 两条路径

**路径 1：Lineage 自带 su（推荐先试）**
- 系统是 userdebug 构建，`adb root` 可用；开发者选项里有「Root access」→ 选「应用和 ADB」
- 优点：零风险、不影响 OTA 逻辑、不需要动 boot 分区

**路径 2：Magisk（要装模块 / LSPosed / 隐藏 root 时）**
1. `adb root` 拿到 root shell
2. 把 boot 分区 dump 出来：`dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot.img`
3. 装 Magisk v26.4 APK → 选「安装 → 选择并修补一个文件」→ 选 boot.img
4. 把 `magisk_patched.img` 用同样方式 dd 回 boot 分区（或重进 EDL 用 `edl w boot`）
5. 重启，Magisk 生效

> 注意：**不需要 fastboot**。这台机器 bootloader 锁着（`flash.locked=1`），所有写分区操作走 EDL 或 `adb root` + dd。

## A7. 实测下载环境

| 源 | 行为 |
|---|---|
| `s3.us-west-1.wasabisys.com`（ROM/recovery） | 单连接仅 13 KB/s，多连接上限约 200 KB/s（再多线程也不涨） |
| SourceForge（OpenGApps） | urllib HEAD 会 TLS 握手超时，必须用 curl；16 线程可跑满 5 MB/s |
| GitHub Releases（Magisk） | 约 850 KB/s，正常 |
| Google Drive | 直连超时不可达 |
| `reg.exe` | 被安全策略拉黑，`edl.py` 启动时的驱动自检会报一次错，不影响后续流程 |

---

# 附录 B：本机实测全过程与终态（2026-10-31 完成）

> 这一节是真实操作记录，和前面的通用教程有出入的地方以本节为准。

## B1. 终态验收（已实测通过）

| 项目 | 结果 |
|---|---|
| 系统 | LineageOS **15.1** / Android **8.1.0**，`lineage_starfire-userdebug OPM7.181205.001`，test-keys |
| 开机时间 | 约 **16 秒**到桌面（此前 addonsu 故障时会卡 LENOVO logo） |
| root | **Magisk 26.4**，`su -c id` → `uid=0(root) context=u:r:magisk:s0`，`magisk -v` → `26.4:MAGISK:R` |
| Google 服务 | OpenGApps **pico**，GMS 已自更新至 `26.42.31` |
| Play 商店 | `com.android.vending` **53.8.11**（自更新成功），中文界面，保护机制已开启 |
| 账号 | 已登录 `wanjianqiang1991@gmail.com`（`dumpsys account` 可见 `type=com.google`） |
| 分区备份 | 12 个（aboot/abootbak/boot/recovery/persist/splash/modemst1/modemst2/fsg/sec/devcfg/devcfgbak）+ boot 三份 |

## B2. 实际走的路线：Plan A（只换 recovery，不动整盘）

没有重刷那 1.29 GB 的原厂包，因为原机是第三方改机版、aboot 早已放行签名。实际只做了两件事：

```bash
# 1) 刷 userdebug aboot，彻底解除 bootloader 签名校验
python edl.py --loader=fw_loader/prog_emmc_firehose_8953_ddr.mbn w aboot fw_loader/emmc_appsboot.mbn

# 2) 刷 Lineage recovery
python edl.py --loader=fw_loader/prog_emmc_firehose_8953_ddr.mbn w recovery lineage-15.1-20240531-UNOFFICIAL-starfire-recovery.img
```

然后音量+ 上电进 recovery → sideload 系统包 + OpenGApps → 双清 → 开机。

## B3. 9008 驱动：不用 Zadig 的做法（更可靠）

Zadig 图形界面容易点错设备。改用「自签证书 + 文件目录签名 + pnputil」：

```powershell
# 生成自签证书（CurrentUser\My）
$c = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=QUSB WinUSB" `
     -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10)
# 打包 INF 为 CAT 并签名
New-FileCatalog -Path .\qusb_winusb.inf -CatalogFilePath .\qusb_winusb.cat -CatalogVersion 2.0
Set-AuthenticodeSignature .\qusb_winusb.cat -Certificate $c
# 安装到受信任发布者 + 添加驱动
Export-Certificate -Cert $c -FilePath qusb.cer
Import-Certificate -FilePath qusb.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
pnputil /add-driver .\qusb_winusb.inf /install
```

装完 `libusb_open` 就不再报 `NOT_SUPPORTED`。

## B4. 三个坑（都会让流程停住）

### 坑 1：`addonsu-15.1-arm-signed.zip` 在这版上会卡 LENOVO logo —— 不要刷

LineageOS 15.1 已把 su 从系统移除，`addonsu` 依赖 sepolicy 里有 `u:r:su:s0` 域。starfire 这版构建**没有**该域，
`superuser.rc` 在 init 阶段反复重试，直接把开机卡死在 logo。

救法（不用重刷）：
1. 音量+ 上电进 recovery
2. 挂载 `/system`，删除以下四项：
   - `/system/xbin/su`
   - `/system/bin/su`
   - `/system/etc/init/superuser.rc`
   - `/system/addon.d/51-addonsu.sh`
3. 重启，16 秒正常开机

**结论：要 root 直接上 Magisk，别碰 addonsu。**

### 坑 2：Magisk 应用内「选择并修补一个文件」报 `! Unable to unpack boot image`

应用内修补在这台机器上失败（`magiskboot` 解包正常，是应用调用链的问题）。改用官方 `boot_patch.sh` 命令行一次成功：

```bash
# 从 Magisk-v26.4.apk 里取出 boot_patch.sh / magiskboot / magiskinit / magisk32 / busybox / stub.apk
# 放到同一目录，boot.img 也放进去
BOOTMODE=false KEEPVERITY=true KEEPFORCEENCRYPT=true sh boot_patch.sh boot.img
# 产出 new-boot.img
```

拿到 `new-boot.img` 后走 EDL 写回 boot 分区（`edl w boot`），或在 `adb root` 下 dd 回去。

### 坑 3：Magisk 装完弹「需要修复运行环境」

因为 `/data/adb/magisk` 是空的。点「确定」让应用自己补齐 `busybox / magisk32 / magiskboot / magiskinit / magiskpolicy / stub.apk` 即可，不要手动拷。

另外两个干扰项：
- 弹「检测到 recovery 模式」是**误报**（ramdisk 里 `RECOVERYMODE=false` 已确认），点取消。
- 应用会自动升级到 30.6，与核心 26.4 不匹配 → 用 `adb install -r -d Magisk-v26.4.apk` 降级。
  **不要点 Magisk 里的「更新」按钮。**

## B5. 授权 root 给 shell / ADB（可选但常用）

Magisk 默认对 shell 不授权，`su -c` 会静默失败。写入策略：

```bash
su
magisk --sqlite "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES (2000,2,0,1,1)"
# 2000 = shell，policy=2 表示 allow
```

## B6. Play 商店登录的网络前置条件（本机实际配置）

**本机实测生效的方式是「WiFi 静态代理」**，不是 `settings put global http_proxy`：

| 项 | 值 |
|---|---|
| 代理地址 | `192.168.0.145:7890`（Clash 跑在局域网另一台机器上，不是刷机这台电脑） |
| 配置位置 | WiFi → 长按已连网络 → 修改网络 → 高级选项 → 代理 → 手动 |
| 存储位置 | `/data/misc/wifi/WifiConfigStore.xml`（`ProxySettings=STATIC`） |

查看当前值：

```bash
adb shell "su -c 'grep -A3 -E \"ProxyHost|ProxyPort|ProxySettings\" /data/misc/wifi/WifiConfigStore.xml'"
```

**重要：`ping play.googleapis.com` 不通是正常的**，HTTP/HTTPS 代理不转发 ICMP。
判断代理是否生效不能靠 ping，要看 GMS / Play 商店能否自我更新 —— 商店版本从 29.2.15 涨到 53.8.11
就说明链路完全通了。

如果改用全局代理（不推荐长期开）：

```bash
adb shell settings put global http_proxy 192.168.0.x:7890   # 设置
adb shell settings put global http_proxy :0                 # 撤掉
```

## B7. 后续可选

| 想做的事 | 做法 |
|---|---|
| 装 Google TV 内容应用 | `com.google.android.videos` 可与手机版 Play 共存；**TV 版 Play 商店同包名 `com.android.vending`，不能共存** |
| LSPosed 等模块 | Magisk 设置里开 **Zygisk**（26.4 支持），重启后刷 LSPosed zip |
| 当桌面时钟/相框 | 装 Fully Kiosk Browser 或 WallPanel，配 HA |
| 回滚到原系统 | EDL 用 `backup/*.img` 逐个 `edl w <分区>` 写回；或整盘刷 `CD-18781Y.200628.084` |

## B8. 系统级提醒

- 设备**无电池**，断电即关机。刷机中途断电是唯一真正的变砖风险（但有 EDL 兜底，能救）。
- 时间若出现偏移，见附录 C —— 已装开机自动校时脚本，不再需要手动干预。
- 别长期把 `/system` 挂成 rw，改完立刻 `mount -o remount,ro /system`。

## B9. 屏幕变黑（熄屏 vs 真死机）

### 这台机器的特殊之处：没有实体电源键

**外壳上没有电源键**，也没有音量键。所以熄屏之后，**唯一的手动唤醒方式就是触摸屏幕**
（默认两次点击，`double_tap_to_wake=1`）。熄屏也只能靠超时触发，不能手动关屏。

实测依据：

```bash
# 按键控制器里确实有 POWER，但没有实体按键接到 gpio-keys 上
cat /vendor/usr/keylayout/qpnp_pon.kl   # key 116  POWER   ← PON 芯片内部映射
cat /vendor/usr/keylayout/gpio-keys.kl  # 只有 key 115 VOLUME_UP / key 172 HOMEPAGE

# 主动熄屏被 ROM 禁掉了，KEYCODE_POWER 无效（发了也亮着）
adb shell input keyevent KEYCODE_POWER     # ← 实测无效，屏幕不会关
adb shell settings put system screen_off_timeout 5000   # ← 只能靠超时熄屏
```

### 熄屏后怎么点亮

**用手指点一下屏幕**（或双击），实测有效，`logcat -b events` 里能看到：

```
13:50:15  screen_toggled: 0     ← 超时熄屏
13:54:18  screen_toggled: 1     ← 手指点击，点亮
```

点亮后**直接回到熄屏前的界面，没有锁屏拦截**（`isStatusBarKeyguard=false`），不需要上滑。

用电脑唤醒也可以：

```bash
adb shell input keyevent KEYCODE_WAKEUP
```

### 判断是熄屏还是死机

```bash
adb devices                      # 还能列出设备 → 系统活着
adb shell dumpsys power | grep -E "mWakefulness=|Display Power"
#   mWakefulness=Dozing + Display Power: state=OFF  → 熄屏（背光关了）
adb shell screencap -p /sdcard/w.png    # 截图有内容 → framebuffer 正常，纯背光问题
```

### 熄屏时间怎么调

设置 → 显示 → **高级** → **休眠**，这是唯一入口。命令行等价：

```bash
adb shell settings put system screen_off_timeout 300000      # 5 分钟
adb shell settings put system screen_off_timeout 1800000     # 30 分钟
adb shell settings put system screen_off_timeout 2147483647  # 永不熄屏
```

**注意：`stay_on_while_plugged_in` 在这个 ROM 上无效**。设成 7（插电常亮）也不会挡住熄屏，
因为该 ROM 改过熄屏逻辑。想常亮只能靠 `screen_off_timeout` 设成极大值。

**供电是隐藏原因，必须知道**

这台机器没有电池，全靠外部供电。接电脑 USB 口时实测：

```
usb current_max = 500000 (500mA)     # USB 2.0 数据口上限
battery st=3 (Discharging)           # 系统判定"在放电"（无电池时的正常误判）
充电电流 434mA → 46mA，电压 3.87V 波动
```

500mA @ 5V ≈ 2.5W，屏幕全亮 + WiFi + 2GB 内存的实际功耗常常超过它，会表现为：
**随机黑屏、触摸失灵、卡顿、甚至重启**。所以要长期跑，**务必用 5V/2A 以上的电源适配器直接插墙**，
不要用电脑 USB 口或键盘上的 USB 口。

区分三种"黑屏"：

| 现象 | adb | 判断 | 处理 |
|---|---|---|---|
| 背光灭、截图有画面 | 通 | 熄屏（最常见） | **手指点屏幕**；或 `KEYCODE_WAKEUP` |
| 背光灭、截图也黑/adb 断 | 断 | 供电崩溃或死机 | **拔插数据线**（无电池，拔电即关机，插上自动开机） |
| 插着电却反复黑屏 | 时通时断 | **供电不足** | 换 ≥5V/2A 适配器 |

> **摸到规律**：这台机器熄屏后点屏幕能亮，但 2026-10-31 实测有一次点亮后 20 秒又被熄掉，
> 当时 `screen_off_timeout` 被临时设成 5 秒。超时值设长（5 分钟以上）就不会这样。
> 如果以后出现"点了亮一下又黑"，先查 `settings get system screen_off_timeout` 是不是被改小了。

---

# 附录 C：2GB 设备优化（2026-10-31 已实施并重启验证）

## C1. 改了什么

| 项目 | 改前 | 改后 | 位置 |
|---|---|---|---|
| zram 容量 | 509 MB（fstab `zramsize=533413200`） | **1 GB** | `/data/adb/post-fs-data.d/98zram.sh` |
| 开机自动校时 | 无（时间常回退到 1970 或慢几小时） | 联网后自动对准 | `/data/adb/service.d/99timesync.sh` |
| 动画缩放 | 默认 1.0 | **0.5** | `settings global` |
| 系统 NTP 服务器 | `null`（默认 time.android.com，国内不通） | `ntp.aliyun.com` | `settings global` |

实测内存：`free` 从 `free 63MB` 改善到 `free 186–244MB`，swap 容量 508MB → 1023MB。

卸载任一优化 = 删掉对应脚本 + 重启，不留痕迹。

脚本源文件在 `ThinkSmartView/scripts/`，重装时：

```bash
adb push ThinkSmartView/scripts/99timesync.sh /data/local/tmp/
adb push ThinkSmartView/scripts/98zram.sh    /data/local/tmp/
adb shell "su -c 'cp /data/local/tmp/99timesync.sh /data/adb/service.d/ && \
                  cp /data/local/tmp/98zram.sh /data/adb/post-fs-data.d/ && \
                  chmod 755 /data/adb/service.d/99timesync.sh /data/adb/post-fs-data.d/98zram.sh'"
```

> Git Bash 下 `adb push` 必须加 `export MSYS_NO_PATHCONV=1`，否则 `/data/local/tmp/`
> 会被当成 Windows 路径，报 `secure_mkdirs failed`。

## C2. 时间问题的真正根因（三层，缺一不可）

排查顺序和结论：

1. **无 RTC**：设备没电池，断电后 RTC 归零。开机读到的内核时间是
   `1970-01-01 00:36:39` 这类值（实测），而不是当前时间。
2. **系统 NTP 服务器在国内不通**：默认 `time.android.com`，
   `settings get global ntp_server` 是 `null`。日志里能直接看到失败：
   ```
   D SntpClient: request time failed: java.net.SocketTimeoutException: Poll timed out
   ```
3. **换成国内 NTP 仍然失败**：`settings put global ntp_server ntp.aliyun.com` 之后，
   `ping` 通（31ms），但 UDP 123 端口被拦，`SntpClient` 继续超时。
   —— 这是国内运营商/路由器的常见限制，**NTP 这条路走不通**。

**可用方案：HTTP Date 头**

TCP 80 是可以的，百度等站点响应头里带标准 RFC-1123 时间：

```bash
printf 'HEAD / HTTP/1.0\r\nHost: www.baidu.com\r\nConnection: close\r\n\r\n' \
  | busybox nc -w 5 www.baidu.com 80 | grep -i '^date:'
# → Date: Sat, 31 Oct 2026 05:15:12 GMT
```

坑：**busybox 的 `date -d` 和 toybox 的 `date -d` 都不认 RFC-1123 格式**
（`date: invalid date 'Sat, 31 Oct 2026 05:13:23 GMT'`），必须自己用 awk 拆成
`YYYY-MM-DD HH:MM:SS` 再 `date -u -s`。脚本里的 awk 还顺带算了 epoch，
用的是 Howard Hinnant 的 `days_from_civil` 算法，实测与系统时间完全吻合。

## C3. 校时脚本要点

- 装在 `service.d`（late_start 阶段），此时 WiFi 通常还没连上，所以内置**最多 90 秒重试**
  （30 次 × 3 秒），拿到时间就退出。
- 三个时间源轮询：百度 → 163 → QQ，任一个成功即停。
- **只在偏差 > 30 秒时才真的改时间**，避免无意义抖动。
- 日志：`/data/adb/timesync.log`，自动滚动保留约 200 行。
- 手动执行一次验证：`su -c 'sh /data/adb/service.d/99timesync.sh'`

实测开机日志（注意第一行还是 1970，说明脚本确实工作在"时间未对"的窗口里）：

```
1970-01-01 08:36:39 === 开机校时开始 ===
2026-10-31 11:16:39 网络=2026-10-31 05:17:28 (epoch 1793423848) 本地epoch=1793416599 偏差=7249s
2026-10-31 13:17:28 已校时 → 2026-10-31 13:17:28 CST
```

## C4. zram 脚本为什么必须放在 post-fs-data 而不是运行时

运行中 `swapoff` 会把 zram 里的数据压回 RAM。这台机器实测
`Swap used 88MB / RAM free 63MB`，直接 swapoff **必然 OOM**。

所以脚本里有硬保护：

```sh
used=$(awk '/zram0/ {print $4}' /proc/swaps)
[ "$used" -gt 20480 ] && exit 0    # >20MB 就跳过，下次开机再试
```

只有开机 `post-fs-data` 阶段（swap 用量接近 0）才真正执行
`swapoff → reset → set disksize → mkswap → swapon`。

实测运行时手动跑会被正确拒绝：
```
跳过: 当前 swap 已用 91000KB (>20MB)，运行时调整有 OOM 风险；下次开机再试
```
重启后日志：
```
1970-01-01 00:36:39 调整 zram: 533413888 -> 1073741824
1970-01-01 00:36:39 结果: disksize=1073741824 swap=[1048572KB used 0KB]
```

## C5. 压缩算法换不了

`/sys/block/zram0/comp_algorithm` 只有 `[lzo]`，写 `lz4` 无效 ——
内核没编 lz4 模块。Android 11+ 默认的 lz4 在这台用不上，只能继续 lzo。
实测压缩比约 **3.3:1**（71.7MB 原始 → 21.5MB 压缩 → 30MB 实际占用）。

## C6. 已知无害噪音：xtra-daemon 崩溃

开机 crash buffer 里有约 12 次：

```
CANNOT LINK EXECUTABLE "xtra-daemon": cannot locate symbol
"_ZN8loc_util6LocIpc4sendEPKcRKNSt3__112basic_stringIcNS3_11char_traitsIcEENS3_9allocatorIcEEEE"
```

这是高通 GNSS 的 XTRA 辅助定位守护进程，原厂 `/vendor/bin/xtra-daemon`
依赖的 `libloc_util` 与 LineageOS 的系统库符号对不上。这台设备**没有 GPS 硬件**，
崩完 init 就不再重启（实测崩溃全部集中在开机 1 秒内，之后无进程存活）。

不用处理。如果确实想让日志干净，可以在 `/data/adb/post-fs-data.d/` 加一句
`stop xtra-daemon`，但收益极小，不建议动系统。

## C7. 建议但未实施（等用户确认用途）

当前内存大户（`dumpsys meminfo` 实测）：

| 进程 | PSS | 说明 |
|---|---|---|
| `com.android.vending` 三件套 | **258 MB** | Play 商店主体 + background + quick_launch |
| `com.google.android.gms` 三件套 | **245 MB** | GMS + gms.ui + gms.unstable |
| `system` | 91 MB | 系统服务 |
| `com.android.systemui` | 67 MB | 状态栏/导航 |
| WebView sandbox ×2 | 68 MB | 网页渲染子进程 |

如果想进一步省内存，可考虑停用（**均可逆，用 `pm enable` 恢复**）：

```bash
# Google TTS（不用语音朗读时可停，省约 16MB）
pm disable-user --user 0 com.google.android.tts
# 日历同步（不用 Google 日历时可停，省约 15MB）
pm disable-user --user 0 com.google.android.syncadapters.calendar
```

不建议动 GMS 和 Play 商店，会导致登录失效或商店打不开。

---

# 附录 D：影音播放专项配置（2026-10-31 实测）

> 用户明确用途：**主要影音播放**，片源在**电脑 / NAS 局域网共享**。
> 本节所有结论均为实机验证，不是推测。

## D1. 屏幕方向：桌面不转的根因（已解决）

**现象**：打开系统自动旋转后，`设置` 应用能横屏，但**主页桌面死活不横**。
一开始误判成"ROM 的 rotation 坏了"，实际是另外一个原因。

**根因**：Trebuchet 的旋转能力是**资源硬编码**的，不看系统旋转开关。
`res/values/config.xml` 里 `allow_rotation=false`，
只有 `res/values-sw600dp/config.xml` 里才是 `true`。
而这台机器 `wm density` 被设成 **260**，算出来：

```
smallestWidth = 800 / 260 × 160 ≈ 492dp   →  小于 600  →  被当成手机 → 锁竖屏
```

**解法**（一条命令，可逆）：

```bash
adb shell wm density 213
# 213 → 800 / 213 × 160 = 601dp ≥ 600dp → 平板模式 → 桌面开始支持横屏
```

验证：

```bash
adb shell dumpsys window | grep -oE 'sw[0-9]+dp'   # 应输出 sw600dp
```

实测结果：桌面立即变成横屏布局（1080×675，图标右侧竖排），且 VLC 播放时
`mCurrentRotation=3`，画面满屏无变形。

> 顺带一提，**260 对这块 8 寸 1280×800 屏本来就偏大**（相当于 5 寸手机的密度），
> 213 才是这代面板的标准值（Nexus 7 同分辨率就是 213）。改完字更小但更清晰，
> 一屏能放更多内容。嫌小可以 `wm density 240` 回退，但那样 sw 又跌破 600，桌面会重新锁竖屏。
> 恢复出厂密度：`wm density reset`。

## D2. 没有 Widevine —— 这是硬限制，补不回来

流媒体能不能看，取决于三件东西：

| 组件 | 本机状态 |
|---|---|
| TEE 里的 Widevine TA | ✅ 有，`/firmware/image/widevine.b00~b06 + .mdt`（2019-10-11） |
| Android 侧 DRM 插件库 | ❌ 无，`/vendor/lib/mediadrm/` 只有 `libdrmclearkeyplugin.so`，全盘搜 `*wv*` 零结果 |
| 设备 keybox | ❌ 无，`/persist/drm` 是**空目录**，`/data/mediadrm` 也是空的 |

`service list` 里 `drm.drmManager`、`media.drm`、`drm-hal-1-0` 都在跑，
但**没有 Widevine 实现**，等于有插座没电器。

**结论**：
- ❌ Netflix、Disney+、Amazon Prime、YouTube —— 全部报错
- ❌ 国内视频站的 VIP 会员内容（多数走 DRM）
- ✅ 本地文件、局域网文件、无 DRM 的在线视频 —— 正常

**为什么补不了**：keybox 是每台设备唯一的、烧在安全分区的凭证。没有它，
即使把插件库从别的机器搬过来也过不了授权校验。这是**出厂就没给企业设备做 DRM 授权**，
不是刷机刷掉的（`/persist/drm` 空 + vendor 是第三方改机包，两个证据都在）。

## D3. 存储是硬伤

```
/data  总 3.8 GB，已用 1.1 GB，可用 2.6 GB
```

一部 1080p 电影 2–4 GB，**机内只放得下 1 部**。所以片源必须走局域网，
这也正好符合用户的实际用法。

## D4. 实测硬解能力

从 `/vendor/etc/media_codecs.xml` 提取，硬件解码器齐全：

| 编码 | 支持 | 说明 |
|---|---|---|
| H.264 / AVC | ✅ `avc` + `avc.secure` | 主流 mp4/mkv 主力 |
| H.265 / HEVC | ✅ `hevc` + `hevc.secure` | 高压缩比片源 |
| VP9 | ✅ `vp9` | YouTube/WebM 常用 |
| VP8 | ✅ `vp8` | |
| MPEG4 / H.263 / MPEG2 | ✅ | 老片源 |
| VC-1 | ✅ | 部分蓝光转码 |
| AV1 | ❌ | 8.1 时代不存在，软解也跑不动 |

实测：1080p H.264 播放流畅，无掉帧。
屏幕本身 1280×800，1080p 片源会缩放，画质损失可忽略。

## D5. 已装的播放器：VLC 3.6.5

选 VLC 而不是 MX Player / Kodi 的理由：开源无广告、全格式、SMB/UPnP 都能连、
2GB 内存下比 Kodi 轻。

```bash
# 下载（设备是 32 位 arm，必须选 armeabi-v7a，64 位包装不上）
curl -L -o VLC-3.6.5-armv7.apk \
  https://get.videolan.org/vlc-android/3.6.5/VLC-Android-3.6.5-armeabi-v7a.apk
adb install -r VLC-3.6.5-armv7.apk
```

APK 已备份在 `_diag/apk/VLC-3.6.5-armv7.apk`（46 MB）。
设备里还留了个 1 MB 测试片 `/sdcard/Movies/test_1080p.mp4`（Big Buck Bunny 10 秒 1080p），
用来随时验证播放和横屏是否正常。

**如果更想要海报墙媒体库**：装 Kodi（<https://mirrors.kodi.tv/releases/android/arm/>，
选 armeabi-v7a）。Kodi 21 对 2GB 内存偏重，卡的话降到 Kodi 19.5。

## D6. 局域网 SMB 播放

VLC 里连电脑共享：

1. 侧栏 → **本地网络**
2. 右上角 `+` → 输入 `smb://192.168.0.x/共享名`
3. 填 Windows 账号密码

电脑端要先开共享：文件夹右键 → 属性 → 共享 → 高级共享 → 勾选"共享此文件夹"，
并确保"网络和共享中心"里**启用了密码保护的共享**（Android 的 SMB 客户端对匿名共享支持差）。

如果 VLC 死活连不上 SMB，两条备选：
- 电脑装 **Jellyfin / Emby** 做媒体服务器，VLC 用 UPnP 直接发现，不用填路径
- 换 **Kodi**，SMB 支持比 VLC 成熟得多

## D7. 影音相关的系统设置（已生效）

| 项目 | 值 | 作用 |
|---|---|---|
| `screen_off_timeout` | 1800000（30 分钟） | 看片不会一分钟就黑屏 |
| `svc power stayon true` | 开 | 插电时永不息屏（`mStayOn=true`） |
| `accelerometer_rotation` | 1 | 自动旋转，横放即横屏 |
| 动画缩放 | 0.5× | 界面响应更跟手 |
| density | 213（override） | 桌面支持横屏 + 平板布局 |

## D8. 一句话总结这个用途的可行边界

**能做的**：局域网/本地播放 1080p H.264/H.265/VP9，横屏满屏，硬解流畅，
当一台 8 寸小电视完全够用。

**做不到的**：任何需要 Widevine 的流媒体（Netflix / YouTube / 国内 VIP 内容）。

**空间约束**：机内 2.6 GB，片源必须放电脑或 NAS。

---

# 附录 E：任意物理按键唤醒屏幕（无电源键设备的专项方案）

这台机器**外壳上没有电源键**，熄屏后只能点屏幕唤醒。而触摸唤醒依赖「主动显示」，
状态不稳定。目标：**按任意一个物理按键都能点亮屏幕**。

## E1. 先摸清硬件到底有什么键

```bash
# 按键设备与键码
su -c 'getevent -pl /dev/input/event3 | head -30'
# 设备树里的实体按键
su -c 'ls /proc/device-tree/soc/gpio_keys/'
```

实测结果：

| 节点 | 键码 | 说明 |
|---|---|---|
| `vol_up` | 115 | 音量加 |
| `mute` | 91 | 静音 |
| `camera_switch` | 87 | 相机切换 |

外壳只做了音量键，另外两个是空焊。`qpnp_pon.kl` 里虽然有 `key 116 POWER`，
但那是 SoC 的 PMIC 按键通道，外壳没接出来。

### ⚠️ 关键：音量加和音量减不在同一个输入设备上

这是最容易踩的坑——只监听 `event3` 会导致**音量加能用、音量减完全没反应**：

```bash
for d in 0 3; do echo "== event$d"; su -c "getevent -pl /dev/input/event$d | grep -E 'name:|KEY \(0001\)'"; done
```

实测各设备声明的键码：

| 设备 | 内核驱动 | 声明的键 |
|---|---|---|
| `event0` | `qpnp_pon`（PMIC） | **KEY_VOLUMEDOWN**、KEY_POWER |
| `event3` | `gpio-keys` | KEY_VOLUMEUP、KEY_F11、KEY_HIRAGANA |
| `event5` | 耳机按键 Jack | VOLUMEDOWN / VOLUMEUP（无耳机时无效） |

也就是说：**加号走 GPIO，减号走 PMIC**，是两个独立设备。守护脚本必须同时监听
`event0` 和 `event3`，少一个就有一半按键是死的。

## E2. 第一反应（无效）：给 keylayout 加 WAKE 标记

```bash
su -c 'mount -o remount,rw /vendor'
su -c 'sed -i "s|^key 115.*|key 115   VOLUME_UP   WAKE|" /vendor/usr/keylayout/gpio-keys.kl'
su -c 'mount -o remount,ro /vendor'
```

**无效**，原因要看内核：

```bash
su -c 'cat /sys/kernel/debug/wakeup_sources | grep KeyEvents'
# → event_count=601  wakeup_count=0
```

`event_count` 说明按键事件确实送到了内核，`wakeup_count=0` 说明**内核压根没把
gpio-keys 注册成唤醒源**。Android 层的 `WAKE` 标记只是应用层标签，决定不了内核行为。

## E3. 真正的拦路虎：距离传感器

从 logcat 里能直接看到：

```
PowerManagerService: Not waking up. Proximity sensor is blocked.
```

- `KEYCODE_WAKEUP` 会经过 `PhoneWindowManager` 的**防误触**分支，要先过距离传感器检查
- 本机的 `VCNL4200 PRX`（Capella）在没有听筒结构的平板上**长期误报"被遮挡"**
- 于是唤醒请求被无条件拒绝——**表现就是"第一次能亮，之后怎么按都不亮"**

对比之下，`KEYCODE_POWER` 走**电源键路径，不做防误触判断**，所以能正常唤醒。

⚠️ **但 POWER 是真正的开关**：亮屏时发它会把屏幕关掉。所以脚本必须先查真实状态。

```bash
su -c 'dumpsys power | grep -m1 mWakefulness'   # Awake / Dozing / Asleep
su -c 'input keyevent KEYCODE_POWER'             # Dozing → Awake；Awake → Dozing
```

## E4. 落地方案：service.d 后台守护

脚本：`/data/adb/service.d/97keywake.sh`（本项目 `ThinkSmartView/scripts/97keywake.sh`）

核心逻辑（每个设备一个子进程，冷却锁走文件共享）：

```sh
DEVS="/dev/input/event0 /dev/input/event3"   # 减号在 event0，加号在 event3

try_wake() {
    [ -f "$OFF" ] && return
    is_awake && return                                   # 亮屏时不动作，避免反把屏关掉
    now=$($BB date +%s); last=$(cat "$LAST" 2>/dev/null)
    [ $((now - ${last:-0})) -lt 3 ] && return            # 3 秒冷却（跨进程共享）
    echo "$now" > "$LAST"
    input keyevent KEYCODE_POWER
    sleep 2
    is_awake || input keyevent KEYCODE_WAKEUP            # 兜底
}

for d in $DEVS; do
    ( while true; do
          ev=$(getevent -c 1 -l "$d" 2>/dev/null)        # 每次只读一个事件
          case "$ev" in *DOWN*) try_wake "$ev" "$d" ;; esac
      done ) &
done
wait
```

五个关键点，少一个都不行：

| 要点 | 不这么做会怎样 |
|---|---|
| `getevent -c 1` 而不是管道 `read` | 输出到管道是 4KB 块缓冲，`while read` 永远读不到整行，按键全被吞 |
| **同时监听 event0 + event3** | 只监听 event3 时音量加能用、音量减完全没反应（两者属不同设备） |
| 先查 `mWakefulness` 再发 POWER | 亮屏时误发 POWER 会把屏幕关掉，且它不做防误触检查，关得毫不犹豫 |
| 3 秒冷却锁（写成文件） | 连按两次会"亮→灭"，看起来像没反应；两个子进程各自的变量不共享，必须走文件 |
| 单实例锁（核对 `/proc/PID/cmdline`） | 多个 getevent 抢同一设备，且重启后 PID 复用会让脚本拒绝启动 |


另外脚本会写 `/sys/power/wake_lock` 保持 CPU 运行，确保熄屏时按键事件仍能送达。
本机实测 `dmesg` 里 `PM: suspend` 为 0 条，系统从不真正挂起，所以这个开销可忽略。

## E5. 验证与排障

```bash
# 守护是否在跑
su -c 'cat /data/adb/keywake.log'
su -c 'cat /data/adb/keywake.pid; ps -A | grep getevent'

# 系统层事件（最权威）
logcat -b events -d | grep screen_toggled
#   screen_toggled: 1 = 亮，0 = 灭
```

正常日志长这样（注意 `[设备]` 字段，能直接看出走的是哪个通道）：

```
14:28:56 按键[/dev/input/event0]: EV_KEY  KEY_VOLUMEDOWN  DOWN   ← 音量减（PMIC）
14:28:59 -> POWER 唤醒成功
14:29:18 （20 秒超时自动熄屏）
14:29:24 按键[/dev/input/event0]: EV_KEY  KEY_VOLUMEDOWN  DOWN
14:29:27 -> POWER 唤醒成功
14:29:54 按键[/dev/input/event3]: EV_KEY  KEY_VOLUMEUP    DOWN   ← 音量加（GPIO）
14:29:57 -> POWER 唤醒成功
```

排障顺序：**先看 log 有没有 `按键[设备]:` 行** ——
没有 = 事件没读到（看 getevent 是否存活、**该设备是否在监听列表里**）；
有但没唤醒 = 被系统拒绝（看 logcat 的 `Not waking up` 原因）。

**"某个键有用、某个键没用"几乎一定是设备没被监听**：先 `getevent -pl` 查这个键在
哪个 `eventN` 上，再对照脚本里的 `DEVS` 有没有它。

## E6. 关闭 / 卸载

```bash
su -c 'touch /data/adb/keywake.off'      # 临时停用（不杀进程）
su -c 'rm /data/adb/service.d/97keywake.sh; kill $(cat /data/adb/keywake.pid)'  # 彻底移除
```

## E7. 一个无法避免的副作用

同一个按键事件会被两方消费：守护脚本看到它去唤醒屏幕，Android 也照常收到它去调音量。
所以**熄屏时按音量键，屏幕亮了，音量也会跟着变一格**。

改成别的键码只是换一种副作用（改成播放键就会同时暂停），并没有"纯唤醒"的键码可用。
除非把该键从 keylayout 里彻底删掉——那样音量键就废了，更不值得。所以保持现状即可。

---

# 附录 F：更换系统壁纸（含 Apple TV 风格做法）

桌面壁纸在这台机器上有个坑：**没有"设为壁纸"的快捷入口**，`cmd wallpaper` 也只是
接口壳子（`No shell command implementation`）。所以必须直接改系统壁纸文件。

## F1. 壁纸存在哪

```bash
su -c 'ls -l /data/system/users/0/wallpaper*'
```

| 文件 | 作用 |
|---|---|
| `/data/system/users/0/wallpaper` | 壁纸原图字节（JPEG/PNG 均可） |
| `/data/system/users/0/wallpaper_info.xml` | 尺寸与裁剪区域 |
| `/data/system/users/0/wallpaper_orig` | 系统自动生成的原始副本 |
| `/data/system/users/0/wallpaper_lock` | 锁屏壁纸（本机无锁屏，通常不存在） |

**注意**：出厂状态可能只有 `wallpaper_info.xml` 而没有 `wallpaper` 文件，
说明系统在用内置默认壁纸。这时自己建 `wallpaper` 文件即可。

## F2. 尺寸怎么定

屏幕物理 **800×1280**，横屏即 **1280×800**（16:10）。影音用途按横屏做：

```
图片 1280×800  +  crop 区域 = 全图
```

`wallpaper_info.xml` 写：

```xml
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<wp id="1" width="1280" height="800" cropLeft="0" cropTop="0" cropRight="1280" cropBottom="800" name="" backup="true" />
```

⚠️ 系统启动后**会自己重写这个文件**，补上 `colorsCount` / `colorValue*` / `colorHints`
并可能把 width 改成 1600（可滚动宽度）。这是正常行为，说明壁纸被接受了，不要去改回来。

## F3. 写入并生效

```bash
# 1. 推到临时目录（/data/system 是 root 独占，push 直接进去会 Permission denied）
adb push wall.jpg /data/local/tmp/wp.jpg
adb push wallpaper_info.xml /data/local/tmp/wp_info.xml

# 2. 备份 + 写入 + 权限 + SELinux 标签
su -c 'cp /data/system/users/0/wallpaper_info.xml /data/adb/wallpaper_info.xml.bak'
su -c 'cp /data/local/tmp/wp.jpg     /data/system/users/0/wallpaper'
su -c 'cp /data/local/tmp/wp_info.xml /data/system/users/0/wallpaper_info.xml'
su -c 'chown system:system /data/system/users/0/wallpaper /data/system/users/0/wallpaper_info.xml'
su -c 'chmod 600 /data/system/users/0/wallpaper /data/system/users/0/wallpaper_info.xml'
su -c 'restorecon /data/system/users/0/wallpaper /data/system/users/0/wallpaper_info.xml'

# 3. 重启（WallpaperManagerService 只在启动时读文件，没有热重载手段）
adb reboot
```

`restorecon` 不能省：`/data/system/users/0/wallpaper` 的正确标签是
`u:object_r:wallpaper_file:s0`，标签不对 WallpaperManager 读不到，会回退默认壁纸。

**没有热重载的绕法**：`cmd wallpaper`（Android 8.1 是空壳）、`service call wallpaper`
（要传 ParcelFileDescriptor，不现实）、重启 SystemUI（壁纸缓存在 system_server 里，
无效）。所以就是重启，30 秒的事。

## F4. 回滚

```bash
su -c 'cp /data/adb/wallpaper_info.xml.bak /data/system/users/0/wallpaper_info.xml'
su -c 'rm /data/system/users/0/wallpaper'
adb reboot
```

## F5. Apple TV 风格壁纸的做法

tvOS 壁纸的视觉特征很固定，照着抓就能出效果：

| 要素 | 具体做法 |
|---|---|
| 底色 | 近黑（#101014 左右），不是纯黑，留一点灰调显质感 |
| 主体 | 2–4 条**半透明丝带状**光带，斜向流动、互相交叠 |
| 配色 | 深青 + 午夜蓝 + 紫罗兰 + 一点洋红，末端带暖琥珀 |
| 质感 | 体积光晕 + 极轻颗粒感，边缘柔化无锐利线条 |
| 构图 | **左侧留大片暗区**放图标，视觉重心落在右侧 |
| 禁忌 | 不要文字、logo、具体物体，不要高对比细节 |

生成后用 Pillow 做三步处理：

```python
from PIL import Image, ImageFilter
im = Image.open(src).convert("RGB")

# 1) 裁掉模型水印条带（右下角），顺带把比例裁到 ≈1.6
crop = im.crop((0, 0, im.width, 928))          # 1536x1024 → 1536x928

# 2) 精确适配 1280x800
wall = crop.resize((1280, 800), Image.LANCZOS)

# 3) 轻微锐化，抵消缩放带来的软化
wall = wall.filter(ImageFilter.UnsharpMask(radius=1.2, percent=45, threshold=2))

wall.save("appletv_1280x800.jpg", "JPEG", quality=94, subsampling=0, optimize=True)
```

`subsampling=0`（4:4:4）对大面积极平滑渐变很重要，默认的 4:2:0 会在彩色光带边缘
产生可见色块。

成品在本项目 `ThinkSmartView/wallpaper/`：

| 文件 | 说明 |
|---|---|
| `appletv_1280x800.jpg` | 横屏主用（已装到设备） |
| `appletv_800x1280.jpg` | 竖屏备用版 |
| `appletv_source_1536x1024.png` | 未处理原图 |
| `wallpaper_info_1280x800.xml` | 配套 info 文件 |

## F6. 一个必须理解的限制

Android 的静态壁纸是**固定方向**的位图，不随屏幕旋转。所以：

- 壁纸按横屏 1280×800 做 → **横屏时 1:1 像素映射，构图完整**
- 竖放时 → 系统会放大裁剪中间一块，只剩光带局部（不影响美观，但不是原构图）

这台机器主要影音用途，按横屏做是对的。如果哪天改成竖放使用，换
`appletv_800x1280.jpg` 重跑 F3 即可。
