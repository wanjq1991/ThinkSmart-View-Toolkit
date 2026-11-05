# 改一个没有源码的 APK 的清单

Aerial（`app.orchard.tv`）装上后有两个问题：

1. **方向反了** —— 设备面板 1280×800 横放时，系统旋转是 `rotation 3`，而 APK 声明的是
   `landscape`（对应 `rotation 1`），画面整体倒 180°。
2. **抢默认桌面** —— 它声明了 `android.intent.category.HOME`，装完会打断原本的桌面。

它没有公开源码，也不想为了两个字段去反编译整个 App 再重打包（smali 回编译容易连带改坏
别的东西）。所以直接改 APK 里的二进制清单：**只覆盖已有的 4 字节字段，文件长度不变。**

实测从原始 APK 出发跑完这两步，得到的 `AndroidManifest.xml` 与手工改出来的成品
**逐字节相同**（16,912 字节，`md5 984b68abfa301b4fd27ca4dfaa049b56`）。

---

## AXML 里只改这几个字节

Android 的二进制 XML 是「chunk 链」，改值不需要重新序列化，只要找到属性记录：

```c
struct ResXMLTree_attribute {   // 20 字节
    uint32_t ns;                // +0
    uint32_t name;              // +4
    uint32_t rawValue;          // +8   ← 字符串池索引，PackageManager 读这个
    uint16_t size;              // +12
    uint8_t  res0;              // +14
    uint8_t  dataType;          // +15
    uint32_t data;              // +16  ← 类型化的值
};
```

元素 chunk 的起点 + `headerSize`（通常是 16）才是 element 扩展头，
属性表从 `ext + attributeStart` 开始，步长 `attributeSize`。
这两处偏移算错是这类脚本最常见的失败原因，`axml.py` 里每一步都写了注释。

| 目标 | 元素 / 属性 | 改哪里 |
|---|---|---|
| 方向 | `activity` / `screenOrientation` | `data`（+16），`0` → `8` |
| 去默认桌面 | `category` / `name`（第 1 个） | `rawValue`（+8）**和** `data`（+16），都指向 `DEFAULT` |

### 坑：只改 `data` 不生效

原始清单里 `category` 的第 1 项：

```
raw_idx = 54  -> android.intent.category.HOME
data_idx = 54 -> android.intent.category.HOME
```

`PackageManager` 解析 `category` 时读的是 **`rawValue`**，不是类型化的 `data`。
如果只把 `data` 改成 `DEFAULT` 而 `rawValue` 仍指向 `HOME`，系统照样认为它是桌面。

反过来，把 `rawValue` 清成 `0xFFFFFFFF` 只改 `data` 则会直接失败：

```
No value supplied for <android:name>
```

所以这两个字段必须一起写。`axml.py` 的 `set_string()` 就是这么做的。

### 坑：Aerial 有三个"像 HOME 但不是"的 category

```
android.intent.category.HOME            ← 只有这个参与默认桌面竞争
android.intent.category.COMMON_HOME     ← 厂商自定义，系统不认
android.intent.category.HOME.CC         ← 同上
```

看到后面两个会误判成"已经去掉了 HOME"。真正要去的是第 1 个。

---

## 用法

```bash
# 1. 先看清楚现在是什么
python patch_manifest.py list app.apk

# 2. 方向：0=landscape(rotation 1) -> 8=reverseLandscape(rotation 3)
python patch_manifest.py set-int app.apk step1.apk activity screenOrientation 8

# 3. 去默认桌面：把第 1 个 category 从 HOME 改成 DEFAULT
python patch_manifest.py set-str step1.apk step2.apk category name \
    android.intent.category.DEFAULT --index 0

# 4. 重新对齐 + 签名
BUILD_TOOLS=$ANDROID_HOME/build-tools/36.0.0 ./repack.sh step2.apk app-patched.apk
```

`set-str` 不会扩充字符串池，目标值必须已经在清单里出现过（`DEFAULT` 是标准 category，
一定存在）。这是刻意的：扩充池会改变文件长度，后面所有偏移全部要跟着重算。

`--index` 用于有多个同名元素时指定改哪一个。不给 `--index` 且匹配到多个时脚本会直接报错，
不会猜。

### 装回去

签名变了，**必须先卸载**，否则 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`：

```bash
adb uninstall app.orchard.tv
adb install -r -d app-patched.apk
```

卸载会清掉它的数据（包括"已完成引导"的标记），重装后要重新点一遍引导页。

---

## 验证方向到底对不对

**不要看截图。** `screencap` 是按当前显示旋转输出的，反了 180° 的截图在电脑上看依然是正的。
只能读系统的 override 值：

```bash
adb shell dumpsys display | grep -o 'mOverrideDisplayInfo.*rotation [0-9]'
# rotation 3 才是这块面板横放时的正向
```

改之前记得先唤醒屏幕，否则截出来是全黑：

```bash
adb shell input keyevent 224
```

---

## 适用范围与边界

- 只处理 `AndroidManifest.xml` 里的**定长整型**和**已有字符串引用**。
  加权限、加组件、改包名都做不到，那需要 aapt2 重新编译。
- 改完必须重签，因为任何字节变化都会让 v1/v2/v3 签名失效。
- 这套方法只用于**你自己合法持有**的 APK。

### 关于本目录里的 `aerial-app-patched.apk`

那是本机实测用的成品，两个补丁都已打好，用 `debug.keystore` 签名：

```
size    3,152,278
sha256  b265851a0cacd7dd1415b0f22ba9a2192cc4c947bc0cf3aee73808768ecbb5dd
```

Aerial 的版权归其作者，这个文件只是「免去自己跑一遍脚本」的便利副本，不是本项目的产物，
也不随本项目许可授权。**介意的话请删掉它，用上面的命令处理你自己下载的 APK** —— 结果完全等价。

因为签名是调试证书，装到别人设备上会与官方版冲突，需要先卸载原版。

