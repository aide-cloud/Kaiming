# Kaiming（开明）

> 《山海经·海内西经》："开明兽……目视四方。" 开明兽守护昆仑九门，明察万物。
> 取"截取屏幕所见、辨识剪贴板内容、开启 Markdown 文档"之意。

Kaiming 是一个 macOS 菜单栏常驻的四合一原生效率工具，用同一个入口整合：

| 模块 | 能力 |
|---|---|
| 截图 | 区域 / 窗口 / 全屏三种模式，AppKit 覆盖层框选与标注，完成后 PNG 自动进剪贴板，并可在面板内一键复制 / 保存 / 设为壁纸 |
| 剪贴板 | 历史记录、类型识别、置顶、一键复制 / 清除，所有读写串行化 |
| 壁纸 | 从剪贴板 / 图片文件 / 最近截图设置壁纸，多显示器独立设置，重启后保持 |
| Markdown | 独立 SwiftUI 窗口，Typora 式实时渲染（TextKit 2），载入剪贴板 / 打开 / 编辑 / 保存 |

纯 Swift 6 + Apple 原生框架，**没有 WebView**，不引入跨平台抽象。

![App icon](docs/app-icon-512.png)

## 界面一览

| 菜单栏面板（未授权时的权限引导） | Markdown 实时渲染 |
|---|---|
| ![菜单栏面板](docs/screenshots/panel-screenshot.png) | ![Markdown 编辑器](docs/screenshots/markdown-editor.png) |

| 剪贴板历史 | 多显示器壁纸 |
|---|---|
| ![剪贴板](docs/screenshots/panel-clipboard.png) | ![壁纸](docs/screenshots/panel-wallpaper.png) |

| 偏好设置 |
|---|
| ![设置](docs/screenshots/settings.png) |

## 技术栈

| 模块 | 实现 |
|---|---|
| 应用骨架 | Swift 6 + SwiftUI；`MenuBarExtra(.window)` + 独立 `Window` scene（Markdown / 设置）；`LSUIElement` 常驻菜单栏 |
| 截图核心 | ScreenCaptureKit：`SCShareableContent` → `SCContentFilter` → `SCStreamConfiguration` → `SCScreenshotManager.captureImage`（macOS 14+） |
| 截图覆盖层 | AppKit：每屏一个无边框 `.screenSaver` 层级 `NSWindow`，冻结截图 + 8 手柄选区 + CG 标注 |
| 剪贴板 | AppKit `NSPasteboard`，专用串行 `DispatchQueue` + `changeCount` 轮询 |
| 壁纸 | AppKit `NSWorkspace.setDesktopImageURL`，文件持久化到 Application Support |
| Markdown | TextKit 2 原生编辑器（`swift-markdown-engine 0.15.0` 内嵌，见 [docs/vendor.md](docs/vendor.md)） |
| 全局快捷键 | Carbon `RegisterEventHotKey`（⌥⇧S / W / F / M） |
| 偏好设置 | 独立 `Window` scene + `UserDefaults`（`SettingsStore` 单一来源） |

## 构建与运行

### Xcode

```bash
open Kaiming.xcodeproj
# 选择 Kaiming scheme，⌘R
```

要求：macOS 14+、Xcode 16+（Swift 6 工具链）。

### 命令行

```bash
# Debug 构建（DerivedData 留在工作区内，方便 CI/沙箱环境）
./Scripts/build.sh

# 构建并启动
./Scripts/run.sh
```

产物：`build/dd/Build/Products/Debug/Kaiming.app`。

> 工程包含两个 target：`Kaiming`（Swift 6，App）与 `MarkdownEngine`（Swift 5，内嵌第三方
> TextKit 2 渲染框架）。后者用 Swift 5 语言模式编译，避免对上游源码做大范围并发标注。

## 首次运行：屏幕录制权限

截图依赖 macOS 的「屏幕录制」TCC 权限：

1. 启动后菜单栏出现取景器图标；未授权时面板顶部显示橙色提示。
2. 点「请求权限」或「打开系统设置」，在 **系统设置 → 隐私与安全性 → 屏幕录制** 中勾选 Kaiming。
3. **重新打开 Kaiming** 后生效（TCC 对已运行进程不刷新）。

未授权时 ScreenCaptureKit 会**静默返回空列表**，因此 Kaiming 在每次截图前显式预检，
并在空结果时给出可操作提示，不会静默失败。详见 [docs/permissions.md](docs/permissions.md)。

## 快捷键

| 快捷键 | 动作 |
|---|---|
| ⌥⇧S | 区域截图 |
| ⌥⇧W | 窗口截图 |
| ⌥⇧F | 全屏截图（鼠标所在屏幕） |
| ⌥⇧M | 打开 Markdown 窗口 |

冲突时设置 → 快捷键页会显示注册失败原因；可关闭全局快捷键或调整冲突应用。

## 数据目录

| 内容 | 路径 |
|---|---|
| 壁纸持久副本 | `~/Library/Application Support/Kaiming/Wallpapers/` |
| 截图历史（最近 30 张） | `~/Library/Application Support/Kaiming/Captures/` |
| 剪贴板图片与历史元数据 | `~/Library/Application Support/Kaiming/Clipboard/` |
| 截图默认保存目录 | `~/Pictures/Kaiming/`（可在设置中修改） |

所有文件仅保存在本机，不上传网络。

## 项目结构

```
Kaiming.xcodeproj/          # 两个 target；File System Synchronized Groups
Config/                     # Info.plist（LSUIElement / 权限用途）、entitlements
Kaiming/
  App/                      # @main、AppDelegate、权限启动检查
  Shared/                   # SettingsStore、AppState、AppRouter、快捷键、日志、路径
  MenuBar/                  # MenuBarExtra 面板与标签
  Settings/                 # 偏好设置
  Screenshot/               # ScreenCaptureKit 采集 + AppKit 覆盖层 + 标注
  Clipboard/                # 串行队列监控 + 历史
  Wallpaper/                # 多显示器壁纸
  Markdown/                 # 独立窗口 + 引擎适配
  Resources/                # 图标、highlight.js、mathFonts.bundle
MarkdownKit/                # 内嵌第三方源码（只读，独立 framework）
Scripts/                    # 构建 / 运行 / 签名 / 公证
docs/                       # 架构、权限、分发、测试、第三方说明
```

## 架构与约束

- 菜单栏是唯一入口；Markdown 用独立 `Window` scene，不嵌入菜单栏面板或截图覆盖窗口。
- 模块之间**只通过 `NSPasteboard` 交换数据**；「最近截图」通过 `Application Support/Kaiming/Captures`
  文件目录约定共享，不产生模块类型依赖。
- 所有剪贴板读写走专用串行队列；壁纸文件不指向临时路径；权限失败必须有可操作提示。
- UI 框架策略：SwiftUI 为主；AppKit 仅用于截图覆盖层、Carbon 全局快捷键，以及剪贴板/壁纸/图片处理所需的系统 API（NSPasteboard、NSWorkspace、NSImage）。

详见 [docs/architecture.md](docs/architecture.md)。

## 分发

```bash
# 1) Release 归档（默认 ad-hoc 签名）
./Scripts/archive.sh

# 2) 使用 Developer ID 签名 + 公证
export DEVELOPMENT_TEAM=ABCDE12345
export APPLE_ID=you@example.com
export APPLE_TEAM_ID=ABCDE12345
export APP_NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx
./Scripts/archive.sh --sign
./Scripts/notarize.sh build/export/Kaiming.app
```

未签名/未公证的构建仅适合本机开发。Developer ID + 公证流程见 [docs/distribution.md](docs/distribution.md)。

> App Sandbox 默认关闭：Developer ID 分发不强制沙盒，而壁纸持久文件需要让系统壁纸服务可读。
> `Config/Kaiming.entitlements` 是一份沙盒模板，**当前未接入 build settings**；启用沙盒需要在
> target 上显式设置 `CODE_SIGN_ENTITLEMENTS = Config/Kaiming.entitlements`，并把壁纸目录改为
> 用户通过 `NSOpenPanel` 选择的目录 + security-scoped bookmark（详见分发文档）。

## 测试

自动化构建检查：

```bash
./Scripts/build.sh
```

手工验收清单（截图/剪贴板/壁纸/Markdown/权限/重启保持）见 [docs/testing.md](docs/testing.md)。

## 第三方组件

| 组件 | 版本 | 许可 |
|---|---|---|
| swift-markdown-engine | 0.15.0 | Apache-2.0 |
| SwiftMath | 1.7.3 | MIT |
| highlight.js | 随 engine 0.15.0 | BSD-3-Clause |

许可证全文见 [docs/licenses](docs/licenses)。内嵌原因与补丁见 [docs/vendor.md](docs/vendor.md)。

## 已知限制

- 最低 macOS 14.0；不使用 macOS 26 的 `captureScreenshot` 一次性 API（其非前台 Space 返回 -3811 的已知问题与 14 基线不匹配）。
- 剪贴板的 `detectedPatterns`（macOS 15.4+）在 SDK 15.2 中不可用，类型识别使用 `changeCount` + pasteboard 类型检查。
- 未做开机自启的失败重试；`SMAppService` 在未签名的开发构建上可能拒绝注册，设置页会显示系统错误。
- macOS 14 + `LSUIElement` 下 SwiftUI `Settings` scene 的 `showSettingsWindow:` 会返回 handled
  但不创建窗口（本机实测），因此偏好设置改用独立 `Window(id: "settings")`，功能等价，
  ⌘, 仍可用；这是对规格中「Settings scene」的一处有据可查的工程偏离。
- 未实现云端同步/多设备历史；所有数据仅本机。

Copyright © 2026 Kaiming.
