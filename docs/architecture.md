# 架构

## 1. 总览

```
┌─────────────────────────────────────────────────────────────┐
│                        Kaiming.app                           │
│  LSUIElement=true（无 Dock 图标，NSApp.activationPolicy=.accessory）│
│                                                             │
│  MenuBarExtra(.window) ──── 菜单栏面板（400×580）              │
│    ├─ 截图页 ──────────────┐                                 │
│    ├─ 剪贴板页 ────────────┤                                 │
│    ├─ 壁纸页 ──────────────┤                                 │
│    └─ Markdown 按钮 ───────┼──> Window scene(id:"markdown")   │
│                            │        MarkdownWindowView        │
│  设置 Window scene ────────┘                                 │
│                                                             │
│  HotKeyManager(Carbon) ──> ScreenshotCoordinator             │
│                        └─> AppRouter.openMarkdown()          │
└─────────────────────────────────────────────────────────────┘
          │                     │                    │
    ScreenCaptureKit      NSPasteboard.general   NSWorkspace
    + AppKit overlay      （模块唯一数据通路）     + 文件系统
```

## 2. 分层

| 层 | 文件 | 职责 |
|---|---|---|
| 应用壳 | `App/KaimingApp.swift`、`App/AppDelegate.swift` | scene 组合（MenuBarExtra + Markdown + 设置）、启动/退出、权限刷新、登录项 |
| 共享基础 | `Shared/*` | 设置、状态、路由、权限、快捷键、日志、路径、截图模式 |
| 功能模块 | `Screenshot/`、`Clipboard/`、`Wallpaper/`、`Markdown/` | 各自 UI + 业务；对外只暴露冻结入口 |
| UI 组合 | `MenuBar/MenuBarPanel.swift` | 唯一把三个模块面板拼在一起的地方 |
| 渲染内核 | `MarkdownKit/`（framework target） | 内嵌 TextKit 2 Markdown 引擎（Swift 5 模式） |

## 3. 模块边界

- **Screenshot**：`ScreenshotCoordinator.shared.start(mode:)` 是唯一入口。
  它只依赖共享类型（`CaptureMode`、`SettingsStore`、`AppState`、`AppPaths`、`ScreenCapturePermission`、`Log`），
  不引用 Clipboard / Wallpaper / Markdown 的代码。
- **Clipboard**：`ClipboardManager.shared` 自持串行队列与历史。
  UI 面板只调用 manager，不直接碰 `NSPasteboard`。
- **Wallpaper**：`WallpaperManager.shared` 负责多屏映射、持久化与 `NSWorkspace` 调用。
  数据源是剪贴板（通过自己的串行队列读）、用户选的图片文件、`AppPaths.captures` 目录。
- **Markdown**：独立窗口，自持文档模型；与引擎的交互只通过 `import MarkdownEngine` 的公开 API。
- **组合层例外**：`MenuBar/MenuBarPanel.swift` 是 App 的组合层，唯一允许同时引用多个模块
  公开入口的位置（例如「截图后快捷操作」直接调用 `WallpaperManager.setWallpaper`）。
  这属于 App 编排，不构成模块之间的依赖；四个功能模块本身不互相引用。

### 数据通路

1. 截图完成 → `NSPasteboard.general`（图片）+ `AppPaths.captures/`（文件）→ 剪贴板模块 / 壁纸模块各自按需读取。
2. 剪贴板 → Markdown（读取文本）、壁纸（读取图片）。
3. 没有任何模块互相 `import` 或持有对方的 manager；共享状态只来自 `Shared/`。

## 4. 关键并发模型

- UI / AppKit 状态：`@MainActor`。
- 剪贴板：`DispatchQueue(label: "com.kaiming.clipboard", qos: .utility)` 串行执行所有
  `NSPasteboard` 访问；结果经 `DispatchQueue.main.async` 或 `Task { @MainActor in }` 回传。
- 截图：`ScreenshotCoordinator` 为 `@MainActor`；ScreenCaptureKit 的 async 采集返回后回主线程
  弹覆盖层 / 写剪贴板。
- 壁纸设置：`NSWorkspace.setDesktopImageURL` 必须主线程；图片落盘可在后台完成后再回主线程设置。
- Carbon 热键回调：C 函数指针 → `DispatchQueue.main.async` → `MainActor.assumeIsolated` 分发。

## 5. 截图流程（区域模式）

```
start(mode:.region)
  ├─ 权限预检（CGPreflightScreenCaptureAccess）
  │    └─ 未授权 → flash + 打开系统设置（结束）
  ├─ SCShareableContent（排除本应用）
  │    └─ displays 为空 → 视为权限问题，可操作提示（结束）
  ├─ 逐屏 SCScreenshotManager.captureImage（冻结图）
  ├─ 显示每屏覆盖窗口（.screenSaver / canJoinAllSpaces）
  ├─ 拖拽选区 + 8 手柄调整 + 标注
  ├─ Return 确认 / Esc 取消
  ├─ 按屏幕 pixelScale 裁剪 + 拍平
  └─ 编码 → 剪贴板 / 自动保存 / Captures 历史 / 声音 / 面板预览
       └─ 面板快捷条：复制 / 保存副本 / 直接设为壁纸（App 组合层调用）
```

关键点：**先截屏，再显示覆盖层**，避免把覆盖层自身拍进画面；同时 `SCContentFilter`
排除本应用进程，双保险。

## 6. Markdown 渲染

- 上游：`nodes-app/swift-markdown-engine` 0.15.0（TextKit 2，AppKit 编辑器桥到 SwiftUI）。
- 因当前工具链/Sandbox 下无法通过 SwiftPM 解析，按固定 commit 内嵌为 `MarkdownEngine` framework；
  源码改动仅 5 处 Bundle/import 机械替换，见 [vendor.md](vendor.md)。
- 服务注入：`HighlightJSBridge`（代码高亮，highlight.js）、`SwiftMathBridge`（LaTeX，SwiftMath）。
- 资源：`highlight.min.js`、`mathFonts.bundle` 放在 app bundle，`Bundle.main` 读取。

## 7. 失败与权限策略

- 截图权限：显式预检 + 空结果判定 + 可操作横幅（绝不静默）。
- 壁纸设置：文件存在性校验 + 错误提示；不因单屏失败而中断其他屏。
- 剪贴板：内容不可读时跳过并记录日志，不崩溃。
- 所有模块的错误都通过 `AppState.flash(_, kind: .error)` 反馈到面板，同时写 `os.Logger`。

## 8. 偏好设置为什么用 Window scene

规格建议 SwiftUI `Settings` scene。实际在本机 macOS 14.5 + `LSUIElement` 验证：

- `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` 返回 `true`；
- 但 `NSApp.windows` 中没有任何设置窗口，`CGWindowList` 也没有；
- `SettingsLink` 依赖同一套呈现路径，存在同样风险。

因此改为 `Window("设置 — Kaiming", id: "settings")`，由 `AppRouter.openSettings()` +
`openWindow(id:)` 打开，并把「设置…」放进 `CommandGroup(replacing: .appSettings)` 保留 ⌘,。
功能与 Settings scene 等价，且窗口可重复打开、可验证。

## 9. 剪贴板串行化

四个模块共享 `Shared/PasteboardQueue.swift` 的**全局唯一串行队列**，
所有 `NSPasteboard` 读写都在该队列执行（截图写回用 `sync` 等待完成，其余用 `async`），
避免跨模块并发访问。剪贴板监控的状态也由该队列串行保护。

## 10. v1.1 新增能力

### 剪贴板快捷选择

`⌥⇧C` → `HotKeyManager` → `AppRouter.openClipboardPicker()` → `Window(id: "clipboard-picker")`。
窗口内搜索框聚焦，↑/↓ 选择、Return 复制并关闭、Esc 关闭；关闭后在无其他可见窗口时
`NSApp.hide(nil)` 把焦点交还前一个应用，便于直接 ⌘V。

### 应用中心与 CLI

- 菜单栏第 4 个 tab「应用」由 `AppCenter` 模块实现：扫描 `/Applications`、`/System/Applications`、
  `~/Applications`（二级以内），展示图标网格并可启动；「打开目录…」与最近目录调用
  `MarkdownOpenRequest` + `AppRouter.openMarkdown()`。
- CLI `kaiming ./docs` 把绝对路径做 base64url 编码后打开 `kaiming://open-folder?path=...`；
  `AppDelegate.application(_:open:)` 解码并设置 `MarkdownOpenRequest`，再打开 Markdown 窗口。
  URL scheme 在 `Config/Info.plist` 注册。

### Markdown 目录树

- `MarkdownFolderTree`（App 级 shared）只展示目录与 `.md/.markdown`，文件夹优先、懒加载；
  `MarkdownSidebarView` 260pt，支持展开/折叠、刷新、当前文件高亮。
- 外部请求与手动打开共用同一加载路径；脏文档载入文件前确认，仅切换目录不影响当前文档。

### 视频动态壁纸

macOS 没有公开 API 把视频设为系统壁纸。实现为每屏一个桌面层窗口：

```
level = CGWindowLevelForKey(.desktopWindow) + 1   // -2147483622
collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
ignoresMouseEvents = true, hasShadow = false
AVQueuePlayer + AVPlayerLooper（静音循环）+ AVPlayerLayer(resizeAspectFill)
```

状态持久化为 `Application Support/Kaiming/Wallpapers/dynamic-wallpaper.json`（视频路径 + 屏幕集合），
App 启动时由 `WallpaperManager.init` 延迟恢复；静态壁纸应用到某屏时停止该屏动态壁纸。
限制：App 必须运行；登录/锁屏不显示；全屏应用会覆盖；逐屏解码有性能成本。
