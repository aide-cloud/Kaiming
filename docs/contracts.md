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
| Clipboard | `Kaiming/Clipboard/**` |
| SystemMonitor | `Kaiming/SystemMonitor/**` |
| Markdown | `Kaiming/Markdown/**` |

只在自己作用域内新增/修改文件。不要碰别人的目录，不要改 `Info.plist`、`SettingsStore`、`MenuBarPanel`、
`MarkdownKit/`（内嵌第三方源码，已有补丁，见 `docs/vendor.md`）。

## 3. 全局技术约束（来自项目规格）

1. Swift 6 语言模式，macOS 14.0 部署目标；SwiftUI 为主，AppKit 仅用于截图覆盖层与 Carbon 快捷键。
2. 编辑器用原生 TextKit 2 渲染；WebView 仅允许用于 Markdown 整篇渲染预览与 PDF 导出
   （系统 WKWebView，内容自包含、不联网；不引入第三方 WebView 或跨平台抽象）。
3. 截图必须用 `SCScreenshotManager.captureImage`（ScreenCaptureKit，macOS 14+）；不得用 `CGWindowListCreateImage` 等旧截图 API，不做 macOS 26 专属 API。唯一例外：SCK 的 `SCShareableContent.displays` 里根本没有某块显示器（部分扩展坞 / 虚拟显示器）时，允许用 `CGDisplayCreateImage(displayID)` 逐屏兜底，必须记录日志并在覆盖层里提示。
4. 所有 `NSPasteboard` 读写串行化到专用 `DispatchQueue`，禁止并发。
5. 截图历史 / 剪贴板缓存文件必须持久化到 `AppPaths` 下，不得指向临时目录。
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
    static var captures: URL             // .../Captures   ← 截图历史目录
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
    //       成品外观：screenshotImageWindowHeader（默认 true，设置可关闭）
    //       截图内容：screenshotHideOwnWindows（默认 false；关闭时 Markdown 等窗口进入截图）
    //       screenshotSaveDirectory: URL
    // 剪贴板：clipboardMonitoringEnabled / clipboardHistoryLimit / clipboardPollInterval
    // 快捷键：hotkeysEnabled
    // Markdown：markdownFontSize / markdownLivePreview
}

@MainActor final class AppState: ObservableObject {
    static let shared
    var selectedTab: PanelTab            // .screenshot / .clipboard / .system
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

struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32      // Carbon kVK_*
    var modifiers: UInt32    // cmdKey / optionKey / controlKey / shiftKey
    var displayString: String   // 由当前键盘布局实时推导
    var validationError: String?  // 至少需要 ⌘/⌥/⌃ 之一
}

@MainActor final class HotKeyManager: ObservableObject {
    static let shared
    // 动作：captureRegion / captureWindow / captureFullScreen / openClipboard / openMarkdown
    // 默认组合：⌥⇧ + S/W/F/C/M；实际组合来自 SettingsStore.hotKeyBindings
    // 回调路径：HotKeyManager → ScreenshotCoordinator.shared.start(mode:) / AppRouter.openMarkdown()
    func suspend()   // 录制期间临时注销全部热键
    func resume()    // 录制结束按设置重新注册
}

enum SettingsTab { case general, permissions, screenshot, clipboard, markdown, shortcuts, about }
@MainActor final class SettingsRoute: ObservableObject { static let shared; func request(_:); func consume() -> SettingsTab? }
// 权限唯一应用层入口，见第 23 节
@MainActor final class PermissionCenter: ObservableObject { static let shared /* … */ }
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

/// 列表分区：收藏（永久保留）/ 实时（按上限淘汰）。
enum ClipboardScope: String, CaseIterable, Identifiable, Sendable { case favorites, live }

struct ClipboardItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: ClipboardKind
    var text: String?
    var imageFileName: String?      // 相对 AppPaths.clipboardStore 的文件名
    var fileURLs: [URL]
    var createdAt: Date
    var isFavorite: Bool            // 收藏项永久保留，不计入上限
    var favoritedAt: Date?          // 「收藏」分区按它倒序
    var sourceBundleID: String?
}

@MainActor final class ClipboardManager: ObservableObject {
    static let shared: ClipboardManager
    private(set) var items: [ClipboardItem]
    private(set) var currentText: String?    // 当前剪贴板文本（非文本为 nil）
    var removableHistoryCount: Int           // 非收藏项数量（清空 / 淘汰的目标）
    func startMonitoring()
    func stopMonitoring()
    func refreshNow()
    func clearHistory()                      // 只清实时历史，收藏项及其图片保留
    func clearPasteboard()
    func copyToPasteboard(_ item: ClipboardItem)
    func delete(_ item: ClipboardItem)       // 收藏项同样会被删除
    func toggleFavorite(_ item: ClipboardItem)
    func entries(in scope: ClipboardScope) -> [ClipboardItem]
    func count(in scope: ClipboardScope) -> Int
}
struct ClipboardPanelView: View              // init(initialScope: ClipboardScope = .live)
```

`AppDelegate` 启动时调用 `startMonitoring()`、退出时 `stopMonitoring()`；
`SettingsView` 的「清空实时历史（保留收藏）」调用 `clearHistory()`。这些调用点已存在，签名必须保持。

### Markdown（`Kaiming/Markdown/`）

```swift
struct MarkdownWindowView: View   // 整个独立窗口内容；KaimingApp 已用 Window scene(id: "markdown") 承载
```

`MarkdownWindowView` 自带工具栏（载入剪贴板 / 打开文件 / 保存 / 复制），自行使用 `@EnvironmentObject var settings: SettingsStore`。
渲染库入口：`import MarkdownEngine` 后使用 `NativeTextViewWrapper(text:fontSize:documentId:)`；
代码高亮用 `HighlightJSBridge()`、LaTeX 用 `SwiftMathBridge()`（与本框架同一 module）。
`SettingsView` 已读取 `settings.markdownFontSize`、`markdownLivePreview`，请至少使用 `markdownFontSize`。

整篇渲染预览 / PDF 的冻结入口（`Kaiming/Markdown/`）：

```swift
@MainActor enum MarkdownRenderedPreviewBuilder {
    static func build(markdown: String, baseURL: URL?, configuration: MarkdownEditorConfiguration) async -> MarkdownRenderedDocument
    static func build(markdown: String, baseURL: URL?, configuration: MarkdownEditorConfiguration,
                      options: MarkdownWebDocumentOptions) async -> MarkdownRenderedDocument
}

struct MarkdownRenderedPreviewView: View {
    init(document: MarkdownRenderedDocument, sourceName: String,
         onRefresh: @escaping () -> Void, onClose: @escaping () -> Void,
         baseURL: URL? = nil, pageWidth: MarkdownPageWidth = .standard,
         fontSize: CGFloat = 14, onExportPDF: (() -> Void)? = nil)
}

@MainActor enum MarkdownPDFExporter {
    static func makePDF(markdown: String, baseURL: URL?, configuration: MarkdownEditorConfiguration,
                        title: String = "文档", fileName: String? = nil) async throws -> Result
    static func exportInteractively(markdown: String, baseURL: URL?, configuration: MarkdownEditorConfiguration,
                                    fileName: String? = nil, presentingWindow: NSWindow? = nil) async throws -> URL?
}
```

## 6. 截图历史约定

- 截图模块每次成功截取后，**除剪贴板外**，把 PNG 写入 `AppPaths.captures/`（文件名含时间戳），并只保留最近 30 张。
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

- `MarkdownOpenRequest` 是 CLI / URL scheme 打开目录的唯一通道；
  Markdown 模块用 `@ObservedObject` 观察并在 `onChange`/`onAppear` 消费。
- 辅助功能权限仅用于长截图的自动滚动。

## 11. 新增入口

```swift
// Clipboard
struct ClipboardPickerView: View   // 独立 Window scene(id: "clipboard-picker")，无参
struct ClipboardPickerSearchField: NSViewRepresentable  // NSTextField + delegate 接管 ↑/↓/Return/Esc
// 全局快捷键（默认 ⌥⇧C，可自定义）：HotKeyManager -> AppRouter.openClipboardPicker()
// AppRouter.registerClipboardPicker(_:)
```

- 剪贴板选择窗口：搜索框默认聚焦；↑/↓ 移动；Return 复制并关闭；Esc 关闭；空状态提示。
- 方向键 / Return / Esc 必须由搜索框的字段编辑器（`NSTextFieldDelegate.doCommandBy`）接住，
  不要依赖「窗口必须成为 key window + 全局事件监听」；IME 组合期间不抢键。
- 面板剪贴板页可增加「快速选择」提示（文案读当前自定义快捷键），但不得嵌入编辑器/复杂窗口。

## 12. Markdown 目录树

- 侧边栏目录树：项目模式展示所有文件/文件夹（可切换「仅 Markdown」）；点击 `.md/.markdown`
  载入编辑器，其他文本文件进入只读预览，图片/二进制提供默认应用/Finder 操作。
- 工具条「打开文件夹…」使用 `.fileImporter(allowedContentTypes: [.folder])`。
- 外部请求 `MarkdownOpenRequest`：打开目录树；若带 `file` 则同时载入该文件。
- 当前文档有未保存修改时，载入外部文件前必须确认；仅切换目录树不算破坏文档。

## 14. 截图：圆角、标注编辑与长截图

- 圆角：选区/标注工具栏提供 0–48pt 圆角调整，预览与最终 PNG 都应用圆角遮罩（圆角外透明）。
  覆盖层预览必须让四个圆角区域**完全不落笔**（底图与暗色遮罩只画在选区矩形之外，选区内部
  按圆角裁剪内容），从而使窗口透明、直接露出桌面；最终 PNG 由透明背景的 bitmap context
  裁剪生成，四角 alpha=0。不得用「先铺满底图再用 clear 混合挖洞」的方式实现预览。
- 已有标注编辑（「调整选区 / 编辑标注」工具，或刚画完的标注）：
  - 每次画完自动选中该标注；在任意绘制工具下，点击选中标注的包围盒即可整体拖动，
    点击空白处才收起选中并开始下一条标注。
  - 单击已有标注选中并整体拖动；拖动被限制在选区内，标注不会越界。后绘制的标注优先命中。
  - 矩形/马赛克显示 8 个缩放手柄；箭头显示起点/终点两个手柄；文字与手写笔迹只支持整体拖动。
  - 双击文字标注进入内容编辑：预填原文、Return 提交、Esc 取消；清空内容提交等同删除。
  - Delete / 前向删除删除选中标注；Esc 先取消选中、再取消截图；⌘Z 撤销上一步标注操作
    （新增、拖动、缩放、文字修改、删除均进入撤销栈，快照上限 50）。
  - 切换绘制工具时收起选中态；重新框选选区或进入长截图时清空标注与撤销栈；
    工具栏垃圾桶按钮仅在选中标注时可用。
- 画笔（手写）：工具栏「画笔」工具按住拖拽绘制自由笔迹；采样点按最小间距抽稀后
  用二次贝塞尔（相邻点中点为锚、原采样点为控制点）平滑，避免折线棱角；
  `round` 线帽/连接、默认 4pt 线宽，沿用当前标注颜色；松开鼠标生成一条可撤销的
  手写标注。预览与最终 PNG 共用 `AnnotationGeometry.freehandPath` 与
  `AnnotationDrawing.draw`，坐标随选区裁剪，点太少或过短的笔迹不落笔。
- 马赛克：工具栏「马赛克」工具拖拽出的矩形，对底图像素做块状像素化（默认块边长 12pt，
  按底图像素密度换算）；覆盖层预览与最终 PNG 共用 `MosaicRenderer` 取样，
  区域截图取冻结屏图、窗口 / 长截图预览取目标图，坐标映射必须一致；可撤销。
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

## 15. CLI（终端打开目录）

- CLI：`Scripts/kaiming ./docs` 经 `kaiming://open-folder?path=<base64url>` 唤起
  Markdown 目录树；URL scheme 已在 `Config/Info.plist` 注册。
- 打开目录会设置 `MarkdownOpenRequest.shared` 并 `AppRouter.openMarkdown()`。

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
- 开启「成品带窗口头部」后，成品宽度不变、高度 = 原生高度 + 头部高度（28pt × 像素密度）；
  关闭后与改动前完全一致。`--capture-test` 默认不叠加头部，保持原生像素尺寸校验。

## 19. Markdown 富内容
- `MarkdownImageProvider`：本地相对/绝对/file URL 与 http(s) 图片。
- `MarkdownLinkRouter`：相对文件路径点击在应用内打开（md→编辑器，文本/图片→预览），外部 URL 系统打开。
- `MarkdownKit` 第 6 条补丁：`onWebLinkClick` + 相对路径不再强制 https；升级需重放。
- 右侧 inspector 只保留标题大纲导航，不再渲染外链卡片/HTML 块；整篇渲染预览改为 WKWebView：GitHub Markdown CSS、HTML 块真实渲染（先清洗 script/iframe/on*）、Mermaid 图表、A4 PDF 导出。

# v1.5 扩展契约

## 20. 截图成品窗口头部

- 新增共享设置 `SettingsStore.screenshotImageWindowHeader`（键 `kaiming.screenshot.imageWindowHeader`，
  默认 `true`）。设置 → 截图 → 外观 →「截图成品带窗口头部圆点」直接读写，关闭后立即生效。
- `Screenshot/WindowHeaderDecoration.swift` 负责绘制：28pt 高、12pt 圆点、8pt 间距、左侧 13pt 缩进，
  按截图像素密度换算；头部背景按截图内容平均亮度自适应深/浅，与内容观感一致。
- 合成位置：
  - 区域 / 长截图：在 `AnnotationDrawing.render` 内先画内容与标注、再画头部，
    最后对「头部 + 内容」整体外框做圆角裁剪（`cornerRadius` 语义不变）。
  - 全屏截图：`ScreenshotCoordinator` 在 `completeCapture` 前调用 `WindowHeaderDecoration.decorate`。
  - 窗口截图：原图已含系统标题栏，不重复叠加。
- 成品尺寸：宽度不变，高度增加头部高度；剪贴板、自动保存、截图历史与面板预览使用同一张成品图。
- 关闭开关后不得改变任何既有截图像素/圆角/标注行为；`--capture-test` 默认跳过头部，
  `--capture-test-decorate` 可显式开启用于人工验收。

# v1.6 扩展契约

## 21. 菜单栏面板内的确认与弹窗

- 面板内容运行在 `MenuBarExtra(.window)` 里，**禁止**在面板内使用 `.confirmationDialog`、
  `.alert`、`.fileImporter` / `.fileExporter` 等系统弹窗：它们会抢走面板的 key 状态，面板被收起，
  且弹窗按钮的 action 在视图销毁后不执行（v1.5「清空历史」点确认后窗口关闭、历史未清空的根因）。
- 危险操作改为面板内内联确认：原位置切换为确认卡片 +「取消」/「确认」按钮，不打开新窗口。
- 面板收起时 SwiftUI 不销毁视图树，`@State` 会保留；本次打开才有效的临时状态（确认态等）
  必须在 `onAppear` / `onDisappear` / 承载窗口失 key 时复位
  （参考 `Clipboard/ClipboardPanelView.swift` 的 `PanelDismissObserver`）。
- 确实需要系统模态时用 AppKit `NSAlert` / `NSSavePanel`，以面板窗口为 sheet 锚点；
  锚不到窗口时不从面板发起。设置 / Markdown 是普通 `Window scene`，不受此约束。
- `ClipboardPanelView` 的公开形态保持无参 `View`；`ClipboardManager.clearHistory()` 签名不变。

# v1.7 扩展契约

## 23. 权限统一入口

权限的展示、检测、申请、跳转系统设置**只允许**出现在设置 → 权限页。共享类型由 Lead 维护：

```swift
enum KaimingPermission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording, accessibility
    // title / symbolName / purpose / consequence / requiresRelaunch / systemSettingsURL
}

struct PermissionStatus: Equatable, Sendable { var isGranted: Bool; var checkedAt: Date? }

@MainActor final class PermissionCenter: ObservableObject {
    static let shared
    func status(for permission: KaimingPermission) -> PermissionStatus
    var grantedCount: Int
    var allGranted: Bool
    @Published private(set) var isDetecting: Bool
    func refresh()            // preflight / AXIsProcessTrusted 同步刷新，不弹系统框
    func detectAll()          // 屏幕录制走真实 ScreenCaptureKit 探测；辅助功能读 AXIsProcessTrusted
    @discardableResult func request(_ permission: KaimingPermission) -> Bool
    func openSystemSettings(_ permission: KaimingPermission)
    @discardableResult func resetScreenRecording() -> Bool
}
```

- `SettingsTab` 与 `SettingsRoute` 在 `Shared/SettingsRoute.swift`；`SettingsTab` 含 `.permissions`「权限」。
  `AppRouter.shared.openSettings(tab: .permissions)` 先登记再打开设置窗口，`SettingsView` 在
  `onAppear` / `onChange` 中消费 `SettingsRoute.shared.pendingTab`。
- 设置「权限」页是唯一展示权限清单与状态的地方，每项必须提供：状态（检测中 / 已授权 / 未授权）、
  检测、请求权限、打开系统设置；屏幕录制额外提供「重置授权记录…」与「重启应用」。
- 菜单栏面板**删除**权限横幅；截图失败恢复框、长截图 HUD 等只提示并跳转
  `AppRouter.shared.openSettings(tab: .permissions)`，**不得**直接调用
  `CGRequestScreenCaptureAccess()` / `AXIsProcessTrustedWithOptions()`，也不得复制权限列表文案。
- `AppState.screenRecordingGranted` / `permissionProbeFinished` 保留为 `PermissionCenter` 的只读镜像，
  供既有调用点读取；新代码直接观察 `PermissionCenter.shared`。
- 测试钩子：`--snapshot-settings <png> --snapshot-settings-tab permissions` 渲染权限页快照。

## 24. v1.8 查找/替换与预览内链

- 共享设置新增 `SettingsStore.screenshotHideOwnWindows`（键 `kaiming.screenshot.hideOwnWindows`，
  默认 `false`）。`ScreenCaptureService.prepare(displayIDs:includeWindows:showsCursor:hideOwnWindows:)`
  新增最后一个参数；`false` 时不排除本应用窗口，Markdown 内容可进入冻结画面与窗口候选。
  长截图逐帧采集仍排除本应用，避免截图边框/HUD 被拼进结果。
- Markdown 查找/替换事件由 `Notification.Name` 承载（`Kaiming/Markdown/MarkdownFind.swift`）：
  `kaiming.markdown.find.query` / `.results` / `.clear` / `.replaceCurrent` / `.replaceAll`。
  `MarkdownEditorBus` 只绑定名称，匹配、高亮、写回都在引擎内完成。
- `MarkdownFindController` 是编辑器与渲染预览共用的状态机；渲染预览通过
  `MarkdownWebSearchRequest` / `MarkdownWebSearchResult` 与 `MarkdownWebPreviewView` 通信，
  JS 入口为 `window.KaimingPreview.find(options)` / `.clearFind()`。
- 渲染预览链接：`MarkdownWebPreviewView.onLinkActivated(URL) -> Bool` 返回 `true` 表示 App 内
  已处理（内部文件留在预览里跳转），`false` 时才交给 `NSWorkspace` 打开。

## 25. v1.9 快捷键自定义 / 多屏覆盖层 / 选择窗口方向键

- 快捷键改为可配置：`SettingsStore.hotKeyBindings`（键 `kaiming.hotkeys.bindings`，JSON
  `[actionRawValue: {keyCode, modifiers}]`）覆盖 `HotKeyAction.defaultBinding`；
  `HotKeyBinding.displayString` 用 `CGEvent.keyboardGetUnicodeString` 按当前键盘布局推导，
  不落盘显示字符串。设置页「保存快捷键」才写回并 `HotKeyManager.reload()`。
- 录制交互：点击组合键按钮进入录制态 → `HotKeyManager.suspend()` 注销全部热键 →
  本地 keyDown 监听录下键码 + 修饰键并显示 → Esc 取消 → `resume()` 重新注册。
  组合键必须含 ⌘/⌥/⌃ 至少一个；重复组合键在保存前拦截，注册失败仍显示在「注册失败」区。
- 剪贴板选择窗口：搜索框改为 `NSTextField` + `NSTextFieldDelegate.doCommandBy`
  （`moveUp:` / `moveDown:` / `insertNewline:` / `cancelOperation:`），IME 组合期间不抢键。
- 多显示器约束：
  - 覆盖层屏幕清单以**真正采集到的显示器**为准：先按 `NSScreenNumber == SCDisplay.displayID`
    配对 `NSScreen`，对不上时按屏幕全局几何位置回退匹配，不能因为 ID 不一致就丢掉副屏。
  - 单块显示器采集失败或不在 `SCShareableContent.displays` 里时：先重试一次，再尝试
    `CGDisplayCreateImage` 兜底；仍失败只影响该屏，其余屏幕照常显示覆盖层，
    并在覆盖层内提示「部分显示器无法截取画面」。
  - 每块屏幕一个 `.screenSaver` 级无边框窗口；`present()` 先 `NSApp.activate` 再
    `orderFrontRegardless`，下一轮 runloop 再校验/重排一次（`isVisible`、frame、
    activeSpace 都写日志）。
  - 非 key 窗口的覆盖层必须 `acceptsFirstMouse == true`，且点击时 `makeKey()`：
    否则副屏上的第一次按下会被系统吞掉（区域拖不动、窗口点不中）。
  - 调试：`--capture-test region` 的 stderr 会打印 `screens [...] captures [...] failed=[]`、
    `overlay presented ...`、每个覆盖层窗口的 `frame/visible/activeSpace`，用于多屏排查。

## 26. 剪贴板收藏与「收藏 / 实时」分区

- `ClipboardItem.isPinned` 更名为 `isFavorite`，新增 `favoritedAt`（收藏时间，参与「收藏」分区排序）。
  语义与旧「置顶」一致：**永久保留**，不计入条数上限、不会被自动淘汰，也不会被「清空实时历史」删除；
  用户可逐条取消收藏（回到普通历史）或直接删除。
- 磁盘格式升级为 `version: 2`。`ClipboardHistoryStore.StoredItem` 自定义 `init(from:)`：
  读不到 `isFavorite` 时回退读 v1 的 `isPinned`，旧历史里的置顶项自动变成收藏项（`favoritedAt` 为 nil，
  排序退回复制时间）。写盘时仍**镜像**写出 `isPinned`（与 `isFavorite` 同值）：旧版本的 `StoredItem`
  要求这个非可选字段，缺了会整份历史解码失败，镜像后降级运行不会丢历史。
- 分区由 `ClipboardScope` 表达，**不是两份数据**：`items` 仍是同一份历史。
  - `.live`：全部条目，按 `createdAt` 倒序；收藏项同样在列表里并带 ☆，避免「收藏后历史里找不到」。
  - `.favorites`：`isFavorite == true` 的条目，按 `favoritedAt` 倒序。
- 条数上限只约束非收藏项：`enforceHistoryLimit()` 淘汰最旧的未收藏记录；
  `removableHistoryCount` 是「清空实时历史」与按钮禁用态的判据。
- 面板（`ClipboardPanelView`）与快捷选择窗口（`ClipboardPickerView`）都用
  下划线分区呈现「收藏 N / 实时 N」，搜索、↑/↓ 选择都在当前分区内生效；切分区时选中项回到该分区第一条。
- 快捷选择窗口每行右侧提供 ☆ 按钮（已收藏为橙色实心），并支持 ⌘D 切换选中项收藏；
  点击 ☆ 不触发复制。若被收藏的是只存在于快捷选择里的「当前剪贴板」临时条目，
  `toggleFavorite` 会先把它写入历史再标记收藏，避免静默失败。
- 调试：`--snapshot-clipboard-scope favorites` 可让 `--snapshot-panel` / `--snapshot-clipboard-picker`
  直接渲染「收藏」页；`KAIMING_SUPPORT_DIR`（仅 DEBUG）把数据目录指到临时路径，避免截图污染真实历史。

## 27. 独立窗口出现在鼠标所在屏幕

- 统一实现 `WindowPlacement` / `WindowPlacementCenter`（`Kaiming/Shared/WindowPlacement.swift`），
  scene id 常量在 `AppWindowScene`；Markdown 与剪贴板快捷选择窗口都必须走这一套，不再靠
  `.defaultPosition(.center)` 或记忆的 frame 决定落点。
- 窗口首次挂载时内容里的 `WindowPlacementProbe(scene:)` 把真正的 `NSWindow` 登记进来：
  同步定位一次（赶在 `orderFront` 之前），下一轮 runloop 再校验一次——SwiftUI 之后还会套用
  `defaultSize` / `defaultPosition` / `NSWindow Frame <id>` 的 frame autosave，不能只放一次。
- `WindowPlacementCenter.willOpen(scene:)` 在 `openWindow(id:)` **之前**调用：窗口已存在
  （隐藏、被拖到别的屏幕、关闭后又被复用）就先搬过去；新窗口等挂载后再定位。
  入口：全局快捷键 / 菜单栏面板 Markdown 按钮 / 面板剪贴板「快速选择」按钮 / `AppRouter`。
- 落点：`NSEvent.mouseLocation` 所在 `NSScreen`（取不到回退 `NSScreen.main`），窗口在该屏
  `visibleFrame` 内**居中**；旧 frame 比新屏大时先收缩再居中，`setFrame(..., animate: false)`，
  不产生位移/缩放动画，避免窗口出现后再被系统推回屏幕内（“窗口自己滚动 / 抖动”）。
- 窗口已完整落在该屏可见区域内时保持用户摆放的位置（`keepIfUsable`）；只有剪贴板快捷选择
  窗口每次打开都强制居中。原生全屏窗口（`styleMask.contains(.fullScreen)`）不移动 frame。
- 独立窗口的 `collectionBehavior` 插入 `.moveToActiveSpace`：打开时跟着当前 Space 出现，
  不做整屏滑动切到窗口原来所在的桌面。`.canJoinAllSpaces` 的窗口（快照 / 覆盖层）不登记、不改行为。
- 调试：定位时打印 `Kaiming debug: placed <scene> window on screen <屏名> frame=<frame>`，
  多显示器 / 多 Space 排查用它确认目标屏与 frame。

---

# v2.0 功能收敛

## 28. 移除「应用」与「壁纸」功能

- 菜单栏面板只保留「截图 / 剪贴板」两个 tab；`AppState.PanelTab` 删除 `.apps`、`.wallpaper`。
- 删除 `Kaiming/AppCenter/**`、`Kaiming/Wallpaper/**` 两个模块；`AppPaths.wallpapers`、
  `Log.wallpaper` 同步移除。
- 截图后的快捷条只保留「保存副本 / 复制到剪贴板 / 收起」，不再提供「设为壁纸」。
- App 启动不再初始化壁纸模块；截图仍排除系统壁纸代理窗口（`com.apple.wallpaper.agent`），
  与已删除的功能模块无关。
- 因模块删除而作废的旧条目：第 5 节 Wallpaper 公开入口、第 6 节壁纸消费方、第 13 / 18 / 22 节。
- CLI 与 Markdown 打开通道保留（第 15 节）。
- 调试快照：`--snapshot-tab` 只接受 `clipboard`，其余值回退到截图页。

## 29. 系统资源模块（v1.2 新增）

- `AppState.PanelTab` 新增 `.system`；菜单栏面板为「截图 / 剪贴板 / 系统」三个 tab。
  第 28 节「只保留两个 tab」的表述以本节为准。
- 新增 `Kaiming/SystemMonitor/**`（Lead 维护），唯一入口：

```swift
@MainActor final class SystemMonitor: ObservableObject {
    static let shared: SystemMonitor
    // 只读快照：memory / cpu / disk / network / sensors / apps / networkHistory
    func startMonitoring()
    func stopMonitoring()
    func refreshNow() async
    func scanCachesIfNeeded()
    func scanCaches()
    func cleanSelectedCaches() async -> CacheCleanOutcome
    func releaseMemory() async -> MemoryReleaseResult
}
```

- `SystemPanelView(initialSection:)` 是新 tab 的根视图；`MenuBarPanel` 增加
  `systemSection: SystemSection = .clean` 仅供调试快照指定分区。
- 原 `ClipboardPanelView` 私有的面板收起观察器提升为 `Shared/PanelVisibilityObserver`，
  同时提供 `onVisible`；剪贴板与系统页共用。
- 调试快照新增：`--snapshot-tab system`、`--snapshot-system-section clean|features`；
  `KAIMING_SNAPSHOT_DELAY` 秒数控制等待（缓存的首次扫描约数秒）。
- 系统模块新增 `--logic-test-system` 自检入口（DEBUG）。

## 30. 状态栏指标（v1.2 新增）

- 新增 `Shared/SystemStatusMetric`（`.cpuTemperature / .cpuUsage / .fanSpeed / .memoryUsage /
  .diskUsage / .networkDownload / .networkUpload`），供设置与菜单栏共享。
- `SettingsStore` 新增 `statusBarMetrics: Set<SystemStatusMetric>`（键
  `kaiming.system.statusBarMetrics`）：未写入时默认全部；`toggleStatusMetric(_:)` 供界面切换；
  `resetToDefaults()` 恢复全部。
- `MenuBarLabel` 观察 `SystemMonitor.shared`，把选中的指标绘制成单张模板图片
  （开明 logo + SF Symbol + 数值；见 `MenuBarStatusImage`）；菜单栏采样由 `SystemMonitor` 的
  `panelActive || !statusMetrics.isEmpty` 驱动，面板收起后 3 秒轻量采样，全部关闭后停止。
- 调试快照新增 `--snapshot-menubar-label <path>`；`--logic-test-system` 覆盖状态栏循环下的采样串行化。

## 31. 应用卸载（v1.2 新增）

- 新增 `Kaiming/SystemMonitor/AppUninstaller.swift`（Lead 维护）：
  - `InstalledApp` / `UninstallCategory` / `UninstallItem` / `UninstallOutcome`；
  - `AppInventory.scan()`：`/Applications` + `~/Applications`，过滤 Apple / 开明自身 / 符号链接；
  - `AppResidueScanner.scan(app)`：按 bundle id（强匹配）与文件系统应用名（精确匹配）扫描
    `~/Library` 已知位置（含 Group Containers、插件/扩展），并扫描常用用户目录的顶层同名项，只读；
  - `AppResidueScanner.remove(items:app:)`：先删应用本体，失败立即中止；只允许选中的应用本体、
    `~/Library` 用户目录与常用用户目录的直接子项；返回成功数、释放字节与失败路径。
- 新增 `AppUninstallModel`（@MainActor）与 `AppUninstallPane`；`SystemSection` 新增 `.uninstall`。
- 运行中的应用用 `NSRunningApplication.terminate()` 退出，最多等待 3 秒，拒绝退出则中止。
- 不处理 `/Library` 系统级文件、Group Containers、App Store 收据与应用自定义目录；TCC 保护目录
  需要完全磁盘访问权限，失败项写入 `Log.system` 并保留在详情页。
- 新增 `--logic-test-uninstall <report>`（DEBUG），用带前缀的临时夹具验证扫描/删除/诱饵保留/安全护栏。
