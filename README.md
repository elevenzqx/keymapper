<div align="center">

# KeyMapper

**为每一把键盘单独定制按键映射的 macOS 菜单栏工具**

*Per-keyboard key remapping for macOS — a lightweight menu bar utility.*

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)](https://swift.org)
[![UI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-blue)](#技术栈)
[![Build](https://img.shields.io/badge/build-SwiftPM-success)](#构建与打包)
[![Docs](https://img.shields.io/badge/docs-中文%20%7C%20English-informational)](#chinese)

[简体中文](#chinese) · [English](#english)

</div>

---

<a id="chinese"></a>

# 简体中文

## 目录

- [项目简介](#项目简介)
- [核心特性](#核心特性)
- [工作原理](#工作原理)
- [系统要求](#系统要求)
- [构建与打包](#构建与打包)
- [使用指南](#使用指南)
- [配置文件](#配置文件)
- [项目结构](#项目结构)
- [技术栈](#技术栈)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [许可证](#许可证)

## 项目简介

**KeyMapper** 是一款运行在 macOS 菜单栏的轻量级按键映射工具。它的最大特点是**按键盘个体区分映射规则**——当你同时连接多把键盘（例如笔记本内置键盘 + 一把外接机械键盘 + 一把蓝牙键盘）时，可以为其中任意一把单独设置按键映射，而完全不影响其他键盘。

系统自带的键盘设置、以及其他同类工具大多只能做到"全局映射"，无法区分按键来自哪块键盘。KeyMapper 通过 **IOKit 底层设备指纹 + CGEventTap 事件时间戳归属** 的组合方案，精确识别每一次按键的物理来源，从而实现真正意义上的"单设备映射"。

> 典型场景：笔记本外接一把 60% 紧凑键盘，希望把小键盘区缺失的数字输入交给主键盘数字行；或者把某把键盘的 `Caps Lock`、方向键重映射为更顺手的布局，同时完全保留内置键盘的原生手感。

## 核心特性

| 能力 | 说明 |
| --- | --- |
| **单设备独立映射** | 按键盘个体（内置 / USB / 蓝牙 / 2.4G 无线）区分规则，互不干扰 |
| **稳定的设备指纹** | 优先使用设备序列号，无序列号时回退到 `VendorID + ProductID + LocationID`，重启、重连后规则依旧生效 |
| **键位级映射** | 以 `CGKeyCode` 为粒度，支持任意源键 → 目标键的映射 |
| **实时状态感知** | 界面实时显示设备在线状态与"使用中"标记，按键瞬间高亮闪烁 |
| **规则持久化** | 规则以 JSON 存储在本地，设备离线或断开后规则仍被保留 |
| **一键预设** | 内置「主键盘数字行 → 小键盘数字」预设，一键完成数字键盘补齐 |
| **随时暂停** | 菜单栏可全局暂停 / 恢复映射，调试或临时恢复原生布局都很方便 |
| **纯菜单栏运行** | 不占用 Dock、无主窗口，随开随用，常驻后台开销极低 |
| **零证书分发** | 打包脚本使用 ad-hoc 本地签名，无需 Apple 开发者账号即可运行 |

## 工作原理

KeyMapper 的难点在于：**CGEventTap 只能拿到按键事件，却无法直接得知它来自哪把键盘**。为此，项目采用双通道方案：

```
        ┌─────────────────────────┐        ┌──────────────────────────┐
        │   IOHIDManager          │        │   CGEventTap             │
        │  （专用后台线程 + RunLoop）│        │  （拦截全局 keyDown/Up）   │
        └───────────┬─────────────┘        └────────────┬─────────────┘
                    │ 枚举键盘设备、注册输入回调             │ 读取按键 keyCode
                    │ 记录 IOHIDValue 时间戳 + 设备指纹     │ 读取 event.timestamp
                    ▼                                      ▼
        ┌─────────────────────────────────────────────────────────────┐
        │              DeviceManager：按键来源归属                      │
        │  1) 时间戳精确匹配（同源 mach absolute time，容差 5ms）        │
        │  2) 回退：最近活跃设备（80ms 窗口内）                          │
        │  3) 兜底：系统仅有一把在线键盘时直接归属                       │
        │  4) 归属失败：放弃映射，避免规则串扰                           │
        └───────────────────────────┬─────────────────────────────────┘
                                    ▼
        ┌─────────────────────────────────────────────────────────────┐
        │   MappingEngine：查表并改写 keyCode 后回写事件                 │
        └─────────────────────────────────────────────────────────────┘
```

1. **设备枚举与指纹**：`DeviceManager` 在独立后台线程上启动 `IOHIDManager`，只匹配键盘类设备（`GenericDesktop / Keyboard`）。对每个设备读取 `VendorID`、`ProductID`、`LocationID`、序列号、传输类型等属性，生成稳定指纹作为持久化键。
2. **事件记录**：为每个设备注册 `IOHIDDeviceRegisterInputValueCallback`，把每次按键的 `IOHIDValue` 时间戳与设备指纹写入环形缓冲区。`IOHIDValue` 与 `CGEvent` 的时间戳同源（均为 mach absolute time），因此可以精确对齐。
3. **来源归属**：`MappingEngine` 在事件回调中先用 `event.timestamp` 在缓冲区内做容差匹配，失败则回退到"最近活跃设备"，再失败则判断系统是否仅有一把在线键盘。
4. **映射改写**：命中该设备的规则后，直接改写 `event.keyboardEventKeycode` 并把事件放行，其余按键原样透传。

这样，即使多把键盘同时在线，规则也只会作用于它所属的那把键盘。

## 系统要求

- **macOS 13.0 (Ventura) 或更高版本**
- 构建需要 **Xcode Command Line Tools**（提供 `swift` 工具链，Swift 5.9+）
- 运行需要授予 **「辅助功能」（Accessibility）** 权限

## 构建与打包

```bash
# 1. 克隆仓库
git clone git@github.com:elevenzqx/keymapper.git
cd keymapper/KeyMapper

# 2. 一键打包（编译 release + 生成 .app + ad-hoc 签名 + 清理 .build）
./build-app.sh
```

打包成功后产物位于 `dist/KeyMapper.app`，双击即可运行，也可以拖入 `/Applications`：

```bash
cp -R dist/KeyMapper.app /Applications/
```

> `build-app.sh` 会在打包完成后自动删除 `.build` 中间构建目录，保持工程目录整洁。下次打包会重新编译。

如需手动开发调试：

```bash
swift build            # 调试构建
swift build -c release # 发布构建
swift run              # 直接运行（调试用）
```

## 使用指南

1. **启动应用**：首次打开后会出现在菜单栏（键盘图标），无 Dock 图标。
2. **授予权限**：首次运行会提示需要「辅助功能」权限。在 `系统设置 → 隐私与安全性 → 辅助功能` 中勾选 KeyMapper。设置界面顶部也会显示橙色引导横幅，点击「去授权」可直接跳转。
   > 授权后建议退出并重新启动应用，确保事件拦截立即生效。
3. **打开设置**：点击菜单栏图标 → `打开设置…`（快捷键 `⌘,`）。
4. **添加映射**：在设备列表中找到目标键盘，点击展开，选择「源按键」与「目标按键」，点击 `添加`。
5. **管理规则**：每条规则可单独开关，或用垃圾桶按钮删除；也可使用「数字键 → 小键盘」预设一键生成，或「清空所有规则」重置。
6. **暂停映射**：菜单栏点击 `⏸ 暂停映射` 可临时禁用全部改写，恢复原生行为。

界面中的状态标记含义：

| 标记 | 含义 |
| --- | --- |
| 🟢 | 使用中（最近 5 秒内有按键活动） |
| ⚪️ | 已连接（在线但当前无操作） |
| ⚫️ | 离线（规则仍保留，重新连接后自动生效） |

## 配置文件

映射规则以 JSON 持久化保存在：

```
~/Library/Application Support/KeyMapper/config.json
```

结构示意（`deviceID` 为设备指纹）：

```json
{
  "deviceMappings": {
    "sn:F0X123456789": [
      { "sourceKeyCode": 18, "targetKeyCode": 83, "enabled": true },
      { "sourceKeyCode": 19, "targetKeyCode": 84, "enabled": true }
    ],
    "vp:1452-590-null": []
  }
}
```

| 字段 | 说明 |
| --- | --- |
| `sourceKeyCode` | 源按键虚拟键码（`CGKeyCode`） |
| `targetKeyCode` | 目标按键虚拟键码 |
| `enabled` | 该条规则是否启用 |

## 项目结构

```
KeyMapper/
├── KeyMapper/                   # 源码目录
│   ├── KeyMapperApp.swift       # 应用入口（菜单栏 App，无主窗口）
│   ├── AppDelegate.swift        # 菜单栏项、设置窗口、生命周期与权限申请
│   ├── AppState.swift           # 全局共享状态（暂停、权限、在线设备）
│   ├── Models.swift             # 设备 / 映射数据模型与设备指纹算法
│   ├── DeviceManager.swift      # IOHID 设备枚举、输入回调与按键来源归属
│   ├── MappingEngine.swift      # CGEventTap 拦截、查表与按键改写
│   ├── KeyCodeMap.swift         # keyCode 与可读名称的双向映射表
│   ├── ConfigStore.swift        # 规则的 JSON 持久化
│   ├── SettingsView.swift       # SwiftUI 设置界面与设备列表
│   └── Info.plist               # 应用元信息（LSUIElement = true）
├── Resources/AppIcon.icns       # 应用图标
├── KeyMapper.entitlements       # 关闭沙盒（需要底层 HID 与事件拦截）
├── Package.swift                # SwiftPM 清单
├── build-app.sh                 # 一键打包脚本
└── README.md
```

## 技术栈

- **语言**：Swift 5.9
- **界面**：SwiftUI（设置界面）+ AppKit（菜单栏 `NSStatusItem`、窗口管理）
- **设备层**：IOKit / HID（`IOHIDManager`、`IOHIDDevice`）
- **事件层**：CoreGraphics `CGEventTap`、ApplicationServices（辅助功能授权）
- **构建**：Swift Package Manager
- **持久化**：`Codable` + JSON 文件

## 常见问题

**Q：为什么映射不生效？**
A：绝大多数情况是缺少「辅助功能」权限。请到 `系统设置 → 隐私与安全性 → 辅助功能` 勾选 KeyMapper，然后重启应用。

**Q：为什么同一把键盘有时会被识别成不同设备？**
A：设备指纹优先使用序列号；若设备不提供序列号，则回退到 `VendorID + ProductID + LocationID`。蓝牙键盘的 `LocationID` 可能随连接变化，此时建议优先使用带序列号的设备，或重新配置规则。

**Q：重连键盘后规则会丢失吗？**
A：不会。设备断开时只标记为「离线」，规则依旧保留在配置文件里，重新连接后自动恢复生效。

**Q：权限已授予，但多键盘场景偶尔不生效？**
A：多设备同时在线时的归属依赖时间戳匹配。若某把键盘没有提供可用的 HID 输入回调，引擎会放弃映射以避免规则串扰（终端有限流警告）。此时可尝试重新检测设备或重新插拔键盘。

**Q：如何完全重置？**
A：删除 `~/Library/Application Support/KeyMapper/config.json` 后重启应用。

## 已知限制

- 仅处理 `keyDown` / `keyUp` 事件的 `keyCode` 改写，不涉及组合键宏、文本展开或系统级快捷键重绑定。
- 多键盘同时在线且设备无法提供 HID 输入回调时，来源归属可能失败，此时为保证安全会跳过映射。
- 应用采用 ad-hoc 签名，首次运行需在「隐私与安全性」中手动放行。

## 许可证

本项目为本地自用工具。如需商用或二次分发，请先与作者联系。

---

<a id="english"></a>

# English

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [How It Works](#how-it-works)
- [Requirements](#requirements)
- [Build & Package](#build--package)
- [Usage](#usage)
- [Configuration](#configuration)
- [Project Structure](#project-structure)
- [Tech Stack](#tech-stack)
- [FAQ](#faq)
- [Known Limitations](#known-limitations)
- [License](#license)

## Overview

**KeyMapper** is a lightweight key remapping utility that lives in your macOS menu bar. Its defining feature is **per-keyboard mapping** — when several keyboards are connected at once (e.g. a laptop's built-in keyboard, an external mechanical board, and a Bluetooth keyboard), you can define remapping rules for any single one of them without affecting the others.

Most built-in settings and third-party tools can only remap keys *globally*, and cannot tell which physical keyboard a keystroke came from. KeyMapper combines **IOKit low-level device fingerprints** with **CGEventTap timestamp-based event attribution** to reliably identify the physical origin of every keystroke, enabling genuinely per-device remapping.

> Typical use case: pair a 60% compact keyboard with your laptop, then route numeric input from the main number row to the (missing) numeric keypad — or remap `Caps Lock` and arrow keys on one board while leaving your built-in keyboard completely untouched.

## Key Features

| Feature | Description |
| --- | --- |
| **Per-device mapping** | Rules are scoped to an individual keyboard (built-in / USB / Bluetooth / 2.4G wireless) and never leak to others |
| **Stable device fingerprint** | Uses the serial number when available, otherwise `VendorID + ProductID + LocationID`, so rules survive restarts and reconnections |
| **Key-code level remapping** | Any source `CGKeyCode` can be mapped to any target `CGKeyCode` |
| **Live status awareness** | Shows online state and an "in use" indicator, with a brief highlight flash on every keystroke |
| **Persistent rules** | Rules are stored as local JSON and preserved even when a device goes offline |
| **One-click presets** | Built-in "main number row → numeric keypad" preset for instant numeric input |
| **Pause anytime** | Toggle all remapping on/off from the menu bar |
| **Menu bar only** | No Dock icon, no main window — low overhead and always within reach |
| **Certificate-free distribution** | The packaging script uses ad-hoc local signing, so no Apple Developer account is required |

## How It Works

The core challenge: **a CGEventTap sees keystrokes but cannot tell which keyboard produced them.** KeyMapper solves this with a two-channel design:

```
        ┌─────────────────────────┐        ┌──────────────────────────┐
        │   IOHIDManager          │        │   CGEventTap             │
        │  (dedicated thread +    │        │  (intercepts global      │
        │   run loop)             │        │   keyDown / keyUp)       │
        └───────────┬─────────────┘        └────────────┬─────────────┘
                    │ enumerate keyboards,              │ read keyCode,
                    │ register input callbacks,          │ read event.timestamp
                    │ record IOHIDValue timestamp        │
                    ▼                                    ▼
        ┌─────────────────────────────────────────────────────────────┐
        │      DeviceManager — keystroke attribution                   │
        │  1) Exact timestamp match (shared mach time, 5 ms tolerance) │
        │  2) Fallback: most recently active device (80 ms window)     │
        │  3) Fallback: sole online keyboard                           │
        │  4) Attribution failure: skip mapping to prevent cross-talk  │
        └───────────────────────────┬─────────────────────────────────┘
                                    ▼
        ┌─────────────────────────────────────────────────────────────┐
        │   MappingEngine — look up rules, rewrite keyCode, pass on    │
        └─────────────────────────────────────────────────────────────┘
```

1. **Enumeration & fingerprinting** — `DeviceManager` runs an `IOHIDManager` on a dedicated background thread, matching keyboard-class devices only (`GenericDesktop / Keyboard`). It reads `VendorID`, `ProductID`, `LocationID`, serial number and transport type to build a stable fingerprint used as the persistence key.
2. **Event recording** — Each device gets an `IOHIDDeviceRegisterInputValueCallback`, pushing its `IOHIDValue` timestamp and fingerprint into a ring buffer. `IOHIDValue` and `CGEvent` share the same time base (mach absolute time), so they can be aligned precisely.
3. **Attribution** — In the event callback, `MappingEngine` first attempts a tolerance-based timestamp match, then falls back to the most recently active device, and finally to the sole online keyboard.
4. **Rewriting** — If a rule matches the attributed device, `event.keyboardEventKeycode` is rewritten and the event is passed through; all other keystrokes are forwarded untouched.

As a result, rules only ever apply to the keyboard they were configured for — even with multiple boards connected.

## Requirements

- **macOS 13.0 (Ventura) or later**
- **Xcode Command Line Tools** for building (provides the Swift 5.9+ toolchain)
- **Accessibility** permission at runtime

## Build & Package

```bash
# 1. Clone
git clone git@github.com:elevenzqx/keymapper.git
cd keymapper/KeyMapper

# 2. One-command packaging
#    (release build + .app bundle + ad-hoc signing + .build cleanup)
./build-app.sh
```

The output is `dist/KeyMapper.app`. Double-click to run, or install it:

```bash
cp -R dist/KeyMapper.app /Applications/
```

> `build-app.sh` removes the `.build` intermediate directory after a successful package to keep the repository clean. The next run will rebuild from scratch.

For manual development:

```bash
swift build            # debug build
swift build -c release # release build
swift run              # run directly (for debugging)
```

## Usage

1. **Launch** — The app appears in the menu bar (keyboard icon) with no Dock icon.
2. **Grant permission** — On first launch you'll be asked for Accessibility permission. Enable KeyMapper under `System Settings → Privacy & Security → Accessibility`. An orange banner in the settings window also links straight there.
   > After granting access, quit and relaunch the app so event interception takes effect immediately.
3. **Open settings** — Click the menu bar icon → `打开设置…` (`⌘,`).
4. **Add a mapping** — Expand the target keyboard in the device list, choose a source key and a target key, then click `添加` (Add).
5. **Manage rules** — Each rule can be toggled individually or deleted with the trash button. Use the numeric-keypad preset to generate a full set in one click, or clear all rules to reset.
6. **Pause** — Choose `⏸ 暂停映射` in the menu bar to temporarily disable all remapping and restore native behavior.

Status indicators in the UI:

| Marker | Meaning |
| --- | --- |
| 🟢 | In use (keystroke activity within the last 5 seconds) |
| ⚪️ | Connected (online but idle) |
| ⚫️ | Offline (rules are kept and re-applied on reconnect) |

## Configuration

Rules are persisted as JSON at:

```
~/Library/Application Support/KeyMapper/config.json
```

Example (the key is the device fingerprint):

```json
{
  "deviceMappings": {
    "sn:F0X123456789": [
      { "sourceKeyCode": 18, "targetKeyCode": 83, "enabled": true },
      { "sourceKeyCode": 19, "targetKeyCode": 84, "enabled": true }
    ],
    "vp:1452-590-null": []
  }
}
```

| Field | Description |
| --- | --- |
| `sourceKeyCode` | Virtual key code of the source key (`CGKeyCode`) |
| `targetKeyCode` | Virtual key code of the target key |
| `enabled` | Whether this rule is active |

## Project Structure

```
KeyMapper/
├── KeyMapper/                   # Source
│   ├── KeyMapperApp.swift       # App entry point (menu bar app, no main window)
│   ├── AppDelegate.swift        # Status item, settings window, lifecycle, permission prompt
│   ├── AppState.swift           # Shared global state (pause, permission, online devices)
│   ├── Models.swift             # Device / mapping models and fingerprint algorithm
│   ├── DeviceManager.swift      # IOHID enumeration, input callbacks, attribution
│   ├── MappingEngine.swift      # CGEventTap interception, rule lookup, key rewriting
│   ├── KeyCodeMap.swift         # keyCode ↔ human-readable name lookup
│   ├── ConfigStore.swift        # JSON persistence of rules
│   ├── SettingsView.swift       # SwiftUI settings UI and device list
│   └── Info.plist               # App metadata (LSUIElement = true)
├── Resources/AppIcon.icns       # App icon
├── KeyMapper.entitlements       # Sandbox disabled (needs low-level HID + event taps)
├── Package.swift                # SwiftPM manifest
├── build-app.sh                 # One-command packaging script
└── README.md
```

## Tech Stack

- **Language**: Swift 5.9
- **UI**: SwiftUI (settings window) + AppKit (`NSStatusItem`, window management)
- **Device layer**: IOKit / HID (`IOHIDManager`, `IOHIDDevice`)
- **Event layer**: CoreGraphics `CGEventTap`, ApplicationServices (Accessibility)
- **Build**: Swift Package Manager
- **Persistence**: `Codable` + JSON file

## FAQ

**Q: Why aren't my mappings taking effect?**
A: In almost every case, the Accessibility permission is missing. Enable KeyMapper under `System Settings → Privacy & Security → Accessibility`, then relaunch the app.

**Q: Why is the same keyboard sometimes detected as different devices?**
A: The fingerprint prefers the serial number and falls back to `VendorID + ProductID + LocationID`. Bluetooth `LocationID` values may change across connections; in that case, prefer devices that report a serial number, or reconfigure the rules.

**Q: Are rules lost after reconnecting a keyboard?**
A: No. On disconnect a device is merely flagged as offline; its rules remain in the config file and are re-applied automatically on reconnect.

**Q: Permission is granted, but it occasionally fails with multiple keyboards.**
A: Attribution with several devices online relies on timestamp matching. If a keyboard doesn't expose a working HID input callback, the engine skips mapping to avoid applying one device's rules to another (a rate-limited warning is printed). Try re-detecting devices or re-plugging the keyboard.

**Q: How do I fully reset?**
A: Delete `~/Library/Application Support/KeyMapper/config.json` and relaunch the app.

## Known Limitations

- Only `keyCode` rewriting for `keyDown` / `keyUp`; no combined-key macros, text expansion, or system-level shortcut rebinding.
- With several keyboards online and a device lacking HID input callbacks, attribution may fail — the engine then skips mapping as a safety measure.
- The app is ad-hoc signed, so first launch requires manual approval under "Privacy & Security".

## License

This project is a personal local-use tool. For commercial use or redistribution, please contact the author first.
