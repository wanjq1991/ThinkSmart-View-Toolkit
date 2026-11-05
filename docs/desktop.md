# 桌面层改造：从一个空系统到能天天用的学习终端

刷完系统、跑完 `install.sh` 之后，设备能亮、能联网、能横屏，但还是一台"空的 Android"。
这份文档记录把桌面那一层做成成品的过程：重启入口、第三方桌面、每日一句、以及
**装完第三方桌面之后冒出来的、文档里查不到的那几个坑**。

桌面 App 本身基于 [samyeei/thinksmart-learning-station](https://github.com/samyeei/thinksmart-learning-station)
（见文末致谢）。这里讲的是在它之上做的改动，以及每一处改动背后的实测依据。

---

## 0. 顺序很重要

同一套操作，换个顺序结果就不一样：

| 先做 | 后做 | 为什么 |
|---|---|---|
| 系统层优化（`install.sh`） | 装第三方桌面 | 桌面会覆盖 `policy_control` 等设置，反过来要再跑一次 |
| 去第三方桌面的 HOME 声明 | 设默认桌面 | 否则 `set-home-activity` 设完，一开机又被抢回去 |
| 禁用对方开机广播 | 设默认桌面 | 同上，两个都要做才稳 |
| 定默认桌面 | 日常使用 | 之后每次重装桌面 APK 都会重置，记住要重设 |

---

## 1. 重启按钮：为什么"HTTP 接口"这条路必然失败

### 现象

点桌面的重启卡片，弹「暂时无法重启」。系统明明有 root。

### 原设计

原来那张卡不是直接重启，而是 POST 到 `http://127.0.0.1:8767/api/reboot`，
带一个 64 位十六进制 `X-Api-Key`，由 FreeKiosk 这个 kiosk 应用执行重启。
API Key 存在 `shared_prefs/reboot.xml`。

### 三层排查，每层都是死的

```bash
# 第一层：钥匙在哪
adb shell su -c 'ls /data/data/local.thinksmart.dashboard/shared_prefs/'
# → 只有 dashboard.xml，根本没有 reboot.xml。api_key 从来没被写入过

# 第二层：门在哪
adb shell 'cat /proc/net/tcp | grep -i 223F'      # 8767 = 0x223F
# → 空。127.0.0.1:8767 没有任何监听

# 第三层：谁该开门
adb shell pm list packages | grep -i kiosk
# → 没有 FreeKiosk
adb shell dumpsys device_policy | grep -i owner
# → 没有 DeviceOwner
```

三层同时不成立：钥匙没配、服务没起、负责执行的 App 根本没装。
这个按钮从设计上就只在一个特定的 kiosk 部署里能用，普通刷机环境永远点不动。

### 改法：直接走 root

设备本来就有 Magisk，没必要再架一层本地 HTTP。

```java
/** 先确认真的拿到了 uid 0，再把重启交给 root shell。 */
private boolean rebootAsRoot() {
    if (!"0".equals(runRoot("id -u").trim())) return false;
    // 不要 waitFor：reboot(2) 不返回，shell 会跟着内核一起消失
    new ProcessBuilder("su", "-c", "sync; /system/bin/reboot").start();
    return true;
}
```

三个细节：

1. **先验 `id -u`**。`Runtime.exec("su")` 成功不代表拿到了 root —— Magisk 可能弹窗被拒、
   可能超时返回 0。必须读回 uid。
2. **不等待进程结束**。`reboot` 系统调用不返回，`waitFor()` 会一直挂到进程被内核杀掉，
   界面就卡在"正在重启"上。用 `start()` 后立即返回。
3. **先 `sync`**。不刷盘直接重启，每日诗句的锚点（写在 SharedPreferences 里）会丢。

FreeKiosk 那条路径保留成回退，但加了前置条件：只有 `api_key` 真的是 64 位十六进制才尝试，
否则直接跳过，不再空等 4 秒连接超时。

```java
private boolean rebootViaKiosk() {
    String key = getSharedPreferences("reboot", 0).getString("api_key", "");
    if (!key.matches("[a-f0-9]{64}")) return false;   // 没配就不要再试
    ...
}
```

### 让 Magisk 不弹窗

无人值守设备上，弹窗等于失败。Magisk 的授权策略存在数据库里，**运行时实时读取**，
写进去立即生效、重启也保留：

```bash
adb shell su -c "magisk --sqlite \"INSERT OR REPLACE INTO policies(uid,policy,until,logging,notification) VALUES(10109,2,0,1,1)\""
```

`policy=2` 是 allow，`10109` 是桌面 App 的 uid（`adb shell dumpsys package local.thinksmart.dashboard | grep userId`）。

⚠️ 别用改 `shared_prefs` 或 `magiskpkg.db` 文件的方式 —— 数据库在内存里有连接，
直接改文件会被回写覆盖。

---

## 2. 第三方桌面：方向反了 180°

Aerial 装上后画面是倒的。原因不是"它不支持横屏"，而是**它支持的横屏和这块面板的横屏不是一个方向**：

| 声明 | 系统 rotation | 这块面板的物理正向 |
|---|---|---|
| `landscape` | 1 | ❌ 倒 180° |
| `reverseLandscape` | 3 | ✅ 正 |

面板是 1280×800、默认横装的，`ro.sf.hwrotation` 已经把基准转过了，
所以规范里的 `landscape` 到了这台机器上反而是反的。

改法、AXML 细节和验证命令见 **[../tools/aerial-patch/README.md](../tools/aerial-patch/README.md)**。
一句话：`screenOrientation` 的 `data` 从 `0` 改成 `8`，只动 4 字节，文件长度不变。

### 验证别靠截图

```bash
adb shell dumpsys display | grep -o 'mOverrideDisplayInfo.*rotation [0-9]'
```

`screencap` 会按当前显示方向输出，倒 180° 的截图在电脑上看依然是正的 —— 这是最容易误判的一步。

---

## 3. 「装完就抢桌面」：真凶不是 HOME 声明

### 第一次误判

Aerial 的清单里有 `android.intent.category.HOME`，第一反应是把它改掉。
改完（`HOME` → `DEFAULT`）重启，**还是被抢**。

### logcat 里找到真凶

```bash
adb logcat -b all -d | grep -iE 'orchard|boot.?receiver'
# app.orchard.tv/.guard.BootReceiver  BOOT_COMPLETED  +
```

它有个 `directBootAware="true"` 的 `BootReceiver`，在 **`LOCKED_BOOT_COMPLETED`** 阶段就启动，
比用户解锁、比 `HOME` 解析都早。这个阶段系统还没确定默认桌面，它先把自己塞进前台，
后面 `HOME` 键回到的就是它。

`HOME` category 只影响"系统问你要不要当桌面"，管不了"开机时谁先起来"。

### 处理

```bash
adb shell su -c "pm disable --user 0 app.orchard.tv/app.orchard.tv.guard.BootReceiver"
```

用 `--user 0` 只禁用当前用户，不动系统分区、不影响升级、可逆：

```bash
adb shell su -c "pm enable --user 0 app.orchard.tv/app.orchard.tv.guard.BootReceiver"
```

⚠️ `pm disable` 走 shell 会报 `SecurityException`，必须 `su -c`。

### 然后才设默认桌面

```bash
adb shell cmd package set-home-activity local.thinksmart.dashboard/.MainActivity

# 确认
adb shell cmd package resolve-activity -c android.intent.category.HOME
# → priority=0 ... local.thinksmart.dashboard/.MainActivity
```

桌面 App 的清单里给 HOME 的 `intent-filter` 加了 `android:priority="1000"`，
避免和系统桌面并列时每次开机弹选择框。

> 重装桌面 APK（签名变化必须卸载重装）会重置默认桌面，记得重设。

---

## 4. 每日一句：365 条怎么排、怎么手动切

### 数据

`tools/quotes/quotes.txt`，一行一条，`句子|出处`：

```
不积跬步，无以至千里。|荀子《劝学》
学而不思则罔，思而不学则殆。|《论语·为政》
```

编译进 APK 的 `DailyContent.QUOTES`，不联网、不请求接口。用脚本生成 Java 数组：

```bash
awk -F'|' '{printf "  {\"%s\",\"%s\"},\n", $1, $2}' tools/quotes/quotes.txt
```

### 排期：锚点法，不是"第几天 % 365"

朴素做法是 `dayOfYear % 365`，问题在于**手动切换之后第二天该显示什么**。
用户切到第 100 条，第二天应该是第 101 条，而不是回到日历算出来的那条。

所以存两个值，组成一个锚点：

```
anchor_day   最后一次手动切换发生在哪一天（epoch day）
anchor_index 那天切到了第几条
```

当天的条目：

```
index = (今天 - anchor_day + anchor_index) mod 365
```

手动切换时，**把锚点移到今天、值设成切换后的条目**：

```java
void advanceQuote(int dir) {
    long now = System.currentTimeMillis();
    int next = DailyContent.step(DailyContent.scheduled(now, qAnchorDay, qAnchor), dir);
    qAnchorDay = DailyContent.day(now);
    qAnchor = next;
    prefs.edit().putLong("anchor_day", qAnchorDay).putInt("anchor_index", qAnchor).apply();
}
```

于是"第二天从切换后的下一条继续"是算法的自然结果，不需要额外写跨天逻辑。

三个工程细节：

- 用 `Math.floorMod` 而不是 `%`。用户往回翻到负索引时，`%` 在 Java 里返回负数，
  会直接 `ArrayIndexOutOfBounds`。
- 锚点存在 `SharedPreferences("daily")`，`apply()` 即可（异步落盘，不阻塞点击）。
  但**重启前必须 `sync`**，见第 1 节。
- 没有锚点记录时回落到一个固定基准日（`BASE`），保证全新安装也有确定的第 1 条。

### 点哪里切下一条、点哪里切上一条

需求是"整行都能点下一条，只有句首一小块是上一条"。难点是**这一小块多宽**：
固定 160px 在长句上太窄、在短句上可能占满整行。

```java
float backZone(TextView v) {
    CharSequence t = v.getText();
    int n = Math.min(8, t.length());
    float w = v.getPaint().measureText(t, 0, n);     // 前 8 个字的实际宽度
    return Math.max(160, Math.min(w, v.getWidth() * 0.4f));
}
```

- 用 `measureText` 而不是按字数乘平均字宽，中文标点、英文混排都能算准
- 下限 160px：短句（7 个字）也要点得到
- 上限 40% 宽度：长句不至于让"上一条"吃掉半屏

### 手感与无障碍的取舍

`OnTouchListener` 返回 `true` 会吃掉后续的 click，TalkBack 的双击就失效了。
两个都挂上：

```java
quote.setOnTouchListener(qt);       // 负责分区
quote.setOnClickListener(v -> advanceQuote(1));   // 兜底给 TalkBack
```

同时给控件写清楚 `contentDescription`：

```java
quote.setContentDescription("每日诗句，点句首看上一句，其余看下一句");
```

每次切换加一次 `performHapticFeedback(KEYBOARD_TAP)` —— 这设备是触摸屏、没有实体反馈，
不震动的话用户不确定点到了没有。

---

## 5. 五张卡片的映射

改完之后桌面是这样一个布局，卡片 index 与入口的对应关系写死在 `launch(int which)` 里：

| index | 入口 | 备注 |
|---|---|---|
| 0 | DeepSeek 网页 | 走 `WebActivity`，需要 `INTERNET` |
| 1 | 豆包网页 | 同上 |
| 2 | 落雪音乐 | 本地播放器 |
| 3 | 不息屏开关 | 通过 `content://` 调另一个 App 的 service |
| 4 | **Aerial** | 点击打开；**长按**进重启确认 |
| 5 | 系统桌面 | 回到原生 Launcher 找其他应用 |
| 6 | 箭头音乐 | 本地播放器 |

第 4 张卡把"打开电视桌面"和"重启"合到一个位置：短按是高频操作，长按是低频危险操作，
共用一张卡比多占一格划算。

```java
if (index == 4) card.setOnLongClickListener(v -> {
    tryStart("local.thinksmart.reboot", "local.thinksmart.reboot.MainActivity");
    return true;      // 不返回 true，长按之后还会补一次 click，直接打开 Aerial
});
```

---

## 6. 验收清单

改完逐条过一遍，别凭印象：

```bash
# 方向：必须是 rotation 3
adb shell dumpsys display | grep -o 'mOverrideDisplayInfo.*rotation [0-9]'

# 默认桌面：必须是自己的包
adb shell cmd package resolve-activity -c android.intent.category.HOME | grep -i packageName

# 抢桌面的广播：必须是 disabled
adb shell pm list packages -d | grep orchard

# 诗句内容（当前显示的是第几条）
adb shell uiautomator dump /sdcard/u.xml && adb pull /sdcard/u.xml
# 在 XML 里搜 content-desc="每日诗句"，看 text 属性

# 重启按钮：点确认后约 40 秒回到桌面
adb shell getprop sys.boot_completed      # 重启后应为 1
```

> `uiautomator dump` 是取控件文字最省事的办法 —— 自绘 Canvas 的界面没有标准 View 树，
> 只有 `contentDescription` 能被 dump 出来，这也是当初给每个控件补 `contentDescription` 的原因之一。

---

## 致谢

桌面这一层的起点是 **[samyeei/thinksmart-learning-station](https://github.com/samyeei/thinksmart-learning-station)**
—— 卡片布局、时钟、Wi-Fi 指示、每日句子的原始形态都来自这个项目，作者 **samyeei**。
本仓库的改动（root 重启、Aerial 集成、诗句扩容到 365 条与排期重做、开机抢桌面处理）
是在它之上做的增量。

整理成文档的过程由 **WorkBuddy** 协助完成。
