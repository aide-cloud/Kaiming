# Kaiming（开明）

> 《山海经·海内西经》："开明兽……目视四方。" 开明兽守护昆仑九门，明察万物。
> 取"截取屏幕所见、辨识剪贴板内容、开启 Markdown 文档"之意。

Kaiming 是一个 macOS 菜单栏常驻的四合一原生效率工具，用同一个入口整合：

| 模块 | 能力 |
|---|---|
| 截图 | 区域 / 窗口 / 全屏三种模式，AppKit 覆盖层框选与标注；支持圆角与长截图（默认手动滚动、保留选区边框，可切换自动滚动）；完成后 PNG 自动进剪贴板，并可在面板内一键复制 / 保存 / 设为壁纸 |
| 剪贴板 | 历史记录、类型识别、置顶、一键复制 / 清除；⌥⇧C 打开快捷选择窗口，键盘上下选中、Enter 复制 |
| 壁纸 | 从剪贴板 / 图片文件 / 最近截图设置壁纸；支持视频动态壁纸（桌面层实验方案）；多显示器独立设置，重启后保持 |
| Markdown | 独立 SwiftUI 窗口，Typora 式实时渲染（TextKit 2）；项目文件夹预览（完整文件树 / 仅 Markdown、文本只读预览、图片/二进制安全）、载入剪贴板 / 打开 / 编辑 / 保存；支持 `kaiming ./docs` 打开目录 |
| 应用中心 | 菜单栏「应用」页：已安装应用启动器、最近目录、打开目录；配合 CLI 直接进入 Markdown 文件树 |

纯 Swift 6 + Apple 原生框架，**没有 WebView**，不引入跨平台抽象。

![App icon](docs/app-icon-512.png)

## 界面一览

| 菜单栏面板 | Markdown 实时渲染 |
|---|---|
| ![菜单栏面板](docs/screenshots/panel-screenshot.png) | ![Markdown 编辑器](docs/screenshots/markdown-editor.png) |

| Markdown 目录树 | 剪贴板快捷选择（⌥⇧C） |
|---|---|
| ![Markdown 目录树](docs/screenshots/markdown-folder-tree.png) | ![剪贴板快捷选择](docs/screenshots/clipboard-picker.png) |

| 应用中心 | 视频动态壁纸 |
|---|---|
| ![应用中心](docs/screenshots/app-center.png) | ![视频动态壁纸](docs/screenshots/panel-wallpaper-video.png) |

| 剪贴板历史 | 多显示器壁纸 / 设置 |
|---|---|
| ![剪贴板](docs/screenshots/panel-clipboard.png) | ![壁纸](docs/screenshots/panel-wallpaper.png) |

| 截图圆角 + 标注 | 长截图（手动优先） |
|---|---|
| ![圆角选区](docs/screenshots/screenshot-rounded-overlay.png) | ![长截图](docs/screenshots/long-capture-manual-hud.png) |

| 项目文件夹预览 + 文本只读预览 |
|---|
| ![项目预览](docs/screenshots/markdown-project-preview.png) |

| 偏好设置 |
|---|
| ![设置](docs/screenshots/settings.png) |

## 技术栈

| 模块 | 实现 |
|---|---|
| 应用骨架 | Swift 6 + SwiftUI；`MenuBarExtra(.window)` + 独立 `Window` scene（Markdown / 设置 / 剪贴板快捷选择）；`LSUIElement` 常驻菜单栏 |
| 截图核心 | ScreenCaptureKit：`SCShareableContent` → `SCContentFilter` → `SCStreamConfiguration` → `SCScreenshotManager.captureImage`（macOS 14+） |
| 截图覆盖层 | AppKit：每屏一个无边框 `.screenSaver` 层级 `NSWindow`，冻结截图 + 8 手柄选区 + CG 标注 |
| 剪贴板 | AppKit `NSPasteboard`，专用串行 `DispatchQueue` + `changeCount` 轮询 |
| 壁纸 | AppKit `NSWorkspace.setDesktopImageURL`，文件持久化到 Application Support |
| Markdown | TextKit 2 原生编辑器（`swift-markdown-engine 0.15.0` 内嵌，见 [docs/vendor.md](docs/vendor.md)） |
| 全局快捷键 | Carbon `RegisterEventHotKey`（⌥⇧S / W / F / C / M） |
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
| ⌥⇧C | 剪贴板快捷选择（↑/↓ 选择，Enter 复制） |
| ⌥⇧M | 打开 Markdown 窗口 |

冲突时设置 → 快捷键页会显示注册失败原因；可关闭全局快捷键或调整冲突应用。

## 命令行（CLI）

`kaiming ./docs` 会通过 `kaiming://` URL scheme 让正在运行的 Kaiming 在 Markdown 窗口中打开该目录；
传入 `.md` 文件则同时打开文件。

```bash
# 安装（若 /usr/local/bin 需要权限，用 sudo 或指定 ~/.local/bin）
./Scripts/install-cli.sh
# 或手动
ln -sf "$PWD/Scripts/kaiming" /usr/local/bin/kaiming

kaiming .            # 在当前目录打开文件树
kaiming ./docs       # 打开 docs 目录
kaiming ./README.md  # 打开文件所在目录并载入文件
```

也可以在菜单栏「应用 → 打开目录…」选择目录，效果相同。

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

## GitHub Actions 打包

推送 `main`、`v*` tag 或手动运行 workflow 时，GitHub Actions 会在 `macos-15` 上：

1. 选择 Xcode 16+；
2. 构建 **universal（arm64 + x86_64）** Release 归档；
3. 生成 `Kaiming-<version>.zip`、`.dmg`、`SHA256SUMS.txt`；
4. 上传 artifact；tag 构建自动发布到 GitHub Release。

工作流：[`.github/workflows/package.yml`](.github/workflows/package.yml)，
说明见 [docs/ci.md](docs/ci.md)。CI 产物为 ad-hoc 签名，正式分发仍需 Developer ID +
公证（见分发文档）。

## 分发

```bash
# 1) Release 归档（默认 ad-hoc 签名）
./Scripts/archive.sh

# 2) 通用二进制归档
UNIVERSAL=1 ./Scripts/archive.sh

# 3) 生成 ZIP/DMG/校验和
./Scripts/package.sh build/export/Kaiming.app build/dist

# 4) 使用 Developer ID 签名 + 公证
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
- 屏幕录制授权与构建签名/CDHash 绑定：重新构建后系统设置可能仍显示已授权，但需要重启应用/重置权限。
  Kaiming 1.1.1 已改为以真实 ScreenCaptureKit 能力为准，并在失败时提供重启/重置入口。
- 未做开机自启的失败重试；`SMAppService` 在未签名的开发构建上可能拒绝注册，设置页会显示系统错误。
- macOS 14 + `LSUIElement` 下 SwiftUI `Settings` scene 的 `showSettingsWindow:` 会返回 handled
  但不创建窗口（本机实测），因此偏好设置改用独立 `Window(id: "settings")`，功能等价，
  ⌘, 仍可用；这是对规格中「Settings scene」的一处有据可查的工程偏离。
- 视频壁纸是**桌面层窗口**实现（macOS 没有公开 API 把视频设为系统壁纸）：
  Kaiming 必须保持运行，退出即停止；桌面图标保持在视频上层。
- 长截图默认进入**手动滚动**（保留选区边框，实时页面自行滚动）；点 HUD 的「自动滚动」才需要辅助功能（Accessibility）权限，未授权时保持手动。
- 壁纸的图片/视频选择使用 AppKit NSOpenPanel，菜单栏 popover 关闭不会取消选择。
- 应用中心只扫描 `/Applications`、`/System/Applications`、`~/Applications` 的顶层与二级 `.app`，不索引 Spotlight 全盘应用。
- 未实现云端同步/多设备历史；所有数据仅本机。

Copyright © 2026 Kaiming.
