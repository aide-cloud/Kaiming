# Kaiming 模块契约（冻结）

> 本文件是并行开发的唯一接口约定。**不要修改已冻结的公开签名**；确需变更先通知 Lead。
> 工程使用 Xcode 16 的 *File System Synchronized Groups*：`Kaiming/` 下新增 `.swift` 文件会自动进入 target，
> **不要手改 `Kaiming.xcodeproj/project.pbxproj`**。

## 1. 构建命令

每个成员使用**独立的 DerivedData 与 SPM 目录**，避免并发构建互相踩踏：

```bash
TMPDIR="$PWD/build/tmp-<name>" CLANG_MODULE_CACHE_PATH="$PWD/build/mcache-<name>" \
xcodebuild -project Kaiming.xcodeproj -scheme Kaiming -configuration Debug \
  -derivedDataPath "$PWD/build/dd-<name>" \
  -clonedSourcePackagesDirPath "$PWD/build/spm-<name>" \
  CODE_SIGNING_ALLOWED=NO build
```

- 工程有两个 target：`Kaiming`（Swift 6，App）与 `MarkdownEngine`（Swift 5，内嵌第三方渲染框架）。
  构建命令会自动构建依赖，无需额外步骤；首次全量约 1–2 分钟。
- `MarkdownEngine.framework` 的源码在 `MarkdownKit/`（只读，Lead 维护）。App 代码中使用时写 `import MarkdownEngine`。
- 第三方库的 API 文档：`MarkdownKit/MarkdownEngine/TextView/NativeTextViewWrapper.swift` 的公开注释、
  `docs/vendor.md`，或上游 README（`/Users/hubiao/aide-family/Kaiming/.probe/engine/.build/checkouts/swift-markdown-engine`）。
- 必须自己跑通构建再汇报；报告里贴最终 `BUILD SUCCEEDED` 与警告摘要。

## 2. 文件所有权（写作用域）

| 所有者 | 目录 / 文件 |
|---|---|
| Lead | `Kaiming.xcodeproj/`、`Config/`、`Kaiming/App/`、`Kaiming/Shared/`、`Kaiming/MenuBar/`、`Kaiming/Settings/`、`Kaiming/Resources/`、`MarkdownKit/`、`docs/`、`Scripts/`、`README.md` |
| Screenshot | `Kaiming/Screenshot/**` |
| Clipboard + Wallpaper | `Kaiming/Clipboard/**`、`Kaiming/Wallpaper/**` |
| Markdown | `Kaiming/Markdown/**` |

只在自己作用域内新增/修改文件。不要碰别人的目录，不要改 `Info.plist`、`SettingsStore`、`MenuBarPanel`、
`MarkdownKit/`（内嵌第三方源码，已有补丁，见 `docs/vendor.md`）。

## 3. 全局技术约束（来自项目规格）

1. Swift 6 语言模式，macOS 14.0 部署目标；SwiftUI 为主，AppKit 仅用于截图覆盖层与 Carbon 快捷键。
2. 禁止 WebView；Markdown 用原生 TextKit 2 渲染。
3. 截图必须用 `SCScreenshotManager.captureImage`（ScreenCaptureKit，macOS 14+）；不得用旧 API，不做 macOS 26 专属 API。
4. 所有 `NSPasteboard` 读写串行化到专用 `DispatchQueue`，禁止并发。
5. 壁纸/截图历史文件必须持久化到 `AppPaths` 下，不得指向临时目录。
6. 模块间只通过 `NSPasteboard.general` 交换数据，**不得直接引用其他模块的类型**（`AppState` / `AppRouter` / `SettingsStore` / `ScreenCapturePermission` / `Log` / `AppPaths` / `CaptureMode` 是共享基础，允许使用）。
7. 权限未授权时必须给出明确、可操作的提示，禁止静默失败。
8. 所有面向用户的文案用中文；日志用 `Log.*`（`os.Logger`，字符串插值加 `privacy: .public` 才会出现在 log stream 中）。

## 4. 冻结的共享类型（Lead 维护，只读）

```swift
enum CaptureMode: String, CaseIterable, Identifiable, Sendable { case region, window, fullScreen }
// .title / .subtitle / .symbolName

enum ScreenshotFormat: String, CaseIterable, Identifiable, Sendable { case png, jpeg }
// .title / .fileExtension

enum AppPaths {
    static var applicationSupport: URL   // ~/Library/Application Support/Kaiming
    static var wallpapers: URL           // .../Wallpapers
    static var captures: URL             // .../Captures   ← 截图历史目录（双方约定）
    static var clipboardStore: URL       // .../Clipboard
    static var defaultScreenshots: URL   // ~/Pictures/Kaiming
    static func ensureDirectory(_ url: URL) throws -> URL
}

enum ScreenCapturePermission {
    static var isGranted: Bool
    @discardableResult static func request() -> Bool
    static func openSystemSettings()
}

@MainActor final class SettingsStore: ObservableObject {
    static let shared: SettingsStore
    // 截图：copyScreenshotToClipboard / playCaptureSound / captureCursor
    //       screenshotFormat / autoSaveScreenshots / screenshotSaveDirectoryPath
    //       screenshotSaveDirectory: URL
    // 剪贴板：clipboardMonitoringEnabled / clipboardHistoryLimit / clipboardPollInterval
    // 快捷键：hotkeysEnabled
    // Markdown：markdownFontSize / markdownLivePreview
}

@MainActor final class AppState: ObservableObject {
    static let shared
    var selectedTab: PanelTab            // .screenshot / .clipboard / .wallpaper
    private(set) var screenRecordingGranted: Bool
    private(set) var lastCapturedImage: NSImage?
    private(set) var lastCaptureDate: Date?
    func refreshPermission()
    func recordCapture(_ image: NSImage) // 截图完成后调用
    func flash(_ text: String, kind: AppState.Notice.Kind = .info)
}

@MainActor final class AppRouter {
    static let shared
    func capture(_ mode: CaptureMode)
    func openMarkdown()
}

@MainActor final class HotKeyManager: ObservableObject {
    static let shared
    // 快捷键动作固定：⌥⇧S 区域 / ⌥⇧W 窗口 / ⌥⇧F 全屏 / ⌥⇧M Markdown
    // 快捷键回调路径：HotKeyManager → ScreenshotCoordinator.shared.start(mode:) / AppRouter.openMarkdown()
}
```

## 5. 模块必须提供的公开入口

### Screenshot（`Kaiming/Screenshot/`）

```swift
@MainActor final class ScreenshotCoordinator {
    static let shared: ScreenshotCoordinator
    func start(mode: CaptureMode)   // 入口：快捷键 / 菜单栏都调它
}
struct ScreenshotPanelView: View   // 菜单栏面板「截图」页，无参初始化
```

### Clipboard（`Kaiming/Clipboard/`）

```swift
enum ClipboardKind: String, Codable, Sendable { case text, image, fileURLs, richText, other }

struct ClipboardItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: ClipboardKind
    var text: String?
    var imageFileName: String?      // 相对 AppPaths.clipboardStore 的文件名
    var fileURLs: [URL]
    var createdAt: Date
    var isPinned: Bool
    var sourceBundleID: String?
}

@MainActor final class ClipboardManager: ObservableObject {
    static let shared: ClipboardManager
    private(set) var items: [ClipboardItem]
    private(set) var currentText: String?    // 当前剪贴板文本（非文本为 nil）
    func startMonitoring()
    func stopMonitoring()
    func refreshNow()
    func clearHistory()
    func clearPasteboard()
    func copyToPasteboard(_ item: ClipboardItem)
    func delete(_ item: ClipboardItem)
    func togglePin(_ item: ClipboardItem)
}
struct ClipboardPanelView: View
```

`AppDelegate` 启动时调用 `startMonitoring()`、退出时 `stopMonitoring()`；
`SettingsView` 的「清空全部历史记录」调用 `clearHistory()`。这些调用点已存在，签名必须保持。

### Wallpaper（`Kaiming/Wallpaper/`）

```swift
struct ScreenInfo: Identifiable, Equatable {
    let id: String                  // NSScreen 的稳定标识（如 "display-<CGDirectDisplayID>"）
    var name: String
    var isMain: Bool
    var currentWallpaper: URL?
    var pixelSize: CGSize
}

@MainActor final class WallpaperManager: ObservableObject {
    static let shared: WallpaperManager
    private(set) var screens: [ScreenInfo]
    func refreshScreens()
    func setWallpaper(image: NSImage, screenIDs: Set<String>)
    func setWallpaper(fileURL: URL, screenIDs: Set<String>)
    func setFromPasteboard(screenIDs: Set<String>)
}
struct WallpaperPanelView: View
```

失败（无权限、图片不可读等）用 `AppState.shared.flash("…", kind: .error)` 明确提示，不要静默。

### Markdown（`Kaiming/Markdown/`）

```swift
struct MarkdownWindowView: View   // 整个独立窗口内容；KaimingApp 已用 Window scene(id: "markdown") 承载
```

`MarkdownWindowView` 自带工具栏（载入剪贴板 / 打开文件 / 保存 / 复制），自行使用 `@EnvironmentObject var settings: SettingsStore`。
渲染库入口：`import MarkdownEngine` 后使用 `NativeTextViewWrapper(text:fontSize:documentId:)`；
代码高亮用 `HighlightJSBridge()`、LaTeX 用 `SwiftMathBridge()`（与本框架同一 module）。
`SettingsView` 已读取 `settings.markdownFontSize`、`markdownLivePreview`，请至少使用 `markdownFontSize`。

## 6. 截图 ↔ 壁纸的「截图历史」约定

- 截图模块每次成功截取后，**除剪贴板外**，把 PNG 写入 `AppPaths.captures/`（文件名含时间戳），并只保留最近 30 张。
- 壁纸模块通过扫描 `AppPaths.captures/` 展示「最近截图」作为数据源（文件系统约定，不 import 截图类型）。
- 截图模块调用 `AppState.shared.recordCapture(image)` 更新面板预览。

## 7. 完成标准（各模块）

- `xcodebuild … build` 通过（Swift 6，无 error）。
- 关键路径有 `Log` 日志；错误路径有用户可见提示。
- 无 `TODO`/占位假数据；不引入新第三方依赖。
- 回报：改动文件清单、构建结果、已验证 / 未验证的行为、已知风险。

---

# v1.1 扩展契约（新增需求）

## 10. 新增共享类型

```swift
@MainActor final class MarkdownOpenRequest: ObservableObject {
    struct Request: Equatable, Identifiable { let id: UUID; let folder: URL; var file: URL? }
    static let shared
    @Published private(set) var request: Request?
    func open(folder: URL, file: URL? = nil)
    func consume() -> Request?
}

enum AccessibilityPermission {
    static var isTrusted: Bool
    @discardableResult static func prompt() -> Bool
    static func openSystemSettings()
}
```

- `MarkdownOpenRequest` 是应用中心 / CLI / URL scheme 打开目录的唯一通道；
  Markdown 模块用 `@ObservedObject` 观察并在 `onChange`/`onAppear` 消费。
- 辅助功能权限仅用于长截图的自动滚动。

## 11. 新增入口

```swift
// Clipboard
struct ClipboardPickerView: View   // 独立 Window scene(id: "clipboard-picker")，无参
// 全局快捷键 ⌥⇧C：HotKeyManager -> AppRouter.openClipboardPicker()
// AppRouter.registerClipboardPicker(_:)
```

- 剪贴板选择窗口：搜索框默认聚焦；↑/↓ 移动；Return 复制并关闭；Esc 关闭；空状态提示。
- 面板剪贴板页可增加「⌥⇧C 快速选择」提示，但不得嵌入编辑器/复杂窗口。

## 12. Markdown 目录树

- 侧边栏目录树：项目模式展示所有文件/文件夹（可切换「仅 Markdown」）；点击 `.md/.markdown`
  载入编辑器，其他文本文件进入只读预览，图片/二进制提供默认应用/Finder 操作。
- 工具条「打开文件夹…」使用 `.fileImporter(allowedContentTypes: [.folder])`。
- 外部请求 `MarkdownOpenRequest`：打开目录树；若带 `file` 则同时载入该文件。
- 当前文档有未保存修改时，载入外部文件前必须确认；仅切换目录树不算破坏文档。

## 13. 壁纸视频（动态壁纸）

- 支持导入 `.mp4` / `.mov` 等视频；复制持久化到 `AppPaths.wallpapers`（UUID 文件名）。
- macOS **没有公开 API** 把视频设为系统壁纸；实现为桌面层窗口：
  `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)`，
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`、
  `ignoresMouseEvents = true`、无阴影，AVQueuePlayer + AVPlayerLooper 循环、静音。
- 多显示器各一个窗口/播放器；关闭「动态壁纸」或退出 App 即停止；桌面图标应保持在上层。
- 选择静态壁纸时，应停止对应屏幕的动态壁纸。
- 在 `WallpaperManager.init` 中恢复上次启用的动态壁纸（App 启动时 `AppDelegate`
  已 `_ = WallpaperManager.shared` 触发；恢复需延迟到窗口可用）。
- 错误必须 `AppState.flash(.error)`；视频不可播放时拒绝并提示。

## 14. 截图：圆角与长截图

- 圆角：选区/标注工具栏提供 0–48pt 圆角调整，预览与最终 PNG 都应用圆角遮罩（圆角外透明）。
- 长截图（仅区域模式）：
  - **默认手动滚动**：点击长截图立即开始手动采集，不再要求先选择模式；保留 border-only
    选区边框窗口（`.screenSaver`、`ignoresMouseEvents`、透明、只画边框），用户实时滚动。
    HUD 提供「自动滚动 / 完成 / 取消」，自动切换复用当前拼接内容。
  - 自动滚动：需 `AccessibilityPermission.isTrusted`；未授权时调用 `prompt()` 并说明，
    保持手动模式。
  - 自动滚动通过 `CGEvent` 向选区下方窗口发送滚轮事件；覆盖层在滚动/采集期间必须
    忽略鼠标事件（避免拦截滚轮），结束后恢复。
  - 每次滚动后用 `SCScreenshotManager.captureImage` 重新截取选区（本次运行不依赖冻结图），
    用行哈希/重叠匹配拼接；无重叠或无变化时停止；最大高度 20000px。
  - 采集期间显示进度与 Esc 取消；完成后进入预览/确认，复用现有编码/剪贴板/历史管线。
  - 不允许静默失败；权限/未检测到滚动/高度超限都要有可操作提示。
- 长截图与圆角可组合；普通截图行为不得回归。

## 15. 应用中心与 CLI（Lead 负责）

- 菜单栏面板新增第 4 个 tab「应用」：已安装应用网格（`/Applications`、`/System/Applications`、
  `~/Applications`，可搜索、点击启动）+ 最近文件夹 + 「打开目录…」。
- 打开目录会设置 `MarkdownOpenRequest.shared` 并 `AppRouter.openMarkdown()`。
- CLI：`Scripts/kaiming ./docs` 经 `kaiming://open-folder?path=<base64url>` 唤起
  Markdown 目录树；URL scheme 已在 `Config/Info.plist` 注册。
- 该 tab 由 Lead 实现，不要修改。

## 16. 测试钩子（DEBUG）

```bash
Kaiming --open-clipboard
Kaiming --open-folder /abs/path
Kaiming --snapshot-clipboard-picker /tmp/picker.png
Kaiming --capture-test full [--capture-test-copy]
```

`--capture-test` 只覆盖本次采集的剪贴板/声音行为，**不修改 SettingsStore/UserDefaults**。


---

# v1.3 扩展契约

## 17. 截图原生像素
- `SCDisplay.width/height` 是点；使用 `SCContentFilter.pointPixelScale` 与
  `CGDisplayMode.pixelWidth/Height` 计算目标像素，`captureResolution = .best`、`scalesToFit = false`。
- 全屏/区域冻结图/长截图逐帧/窗口截图共用像素尺寸策略；标注拍平保持底图像素尺寸。

## 18. 壁纸来源
- 壁纸 UI 不再展示/扫描 `AppPaths.captures`；来源仅剪贴板图片、用户选择图片、视频、轮换文件夹。

## 19. Markdown 富内容
- `MarkdownImageProvider`：本地相对/绝对/file URL 与 http(s) 图片。
- `MarkdownLinkRouter`：相对文件路径点击在应用内打开（md→编辑器，文本/图片→预览），外部 URL 系统打开。
- `MarkdownKit` 第 6 条补丁：`onWebLinkClick` + 相对路径不再强制 https；升级需重放。
- 外链卡片/HTML 块在右侧 inspector 原生渲染；HTML 脚本/CSS、远程 img 不执行。
