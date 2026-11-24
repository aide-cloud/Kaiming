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
| 共享基础 | `Shared/*` | 设置、状态、路由、权限（`PermissionCenter`）、快捷键、日志、路径、截图模式 |
| 功能模块 | `Screenshot/`、`Clipboard/`、`Markdown/` | 各自 UI + 业务；对外只暴露冻结入口 |
| UI 组合 | `MenuBar/MenuBarPanel.swift` | 唯一把截图与剪贴板面板拼在一起的地方 |
| 渲染内核 | `MarkdownKit/`（framework target） | 内嵌 TextKit 2 Markdown 引擎（Swift 5 模式） |

## 3. 模块边界

- **Screenshot**：`ScreenshotCoordinator.shared.start(mode:)` 是唯一入口。
  它只依赖共享类型（`CaptureMode`、`SettingsStore`、`AppState`、`AppPaths`、`ScreenCapturePermission`、
  `AccessibilityPermission`、`PermissionCenter`、`Log`），
  不引用 Clipboard / Markdown 的代码。
- **Clipboard**：`ClipboardManager.shared` 自持串行队列与历史。
  UI 面板只调用 manager，不直接碰 `NSPasteboard`。
- **Markdown**：独立窗口，自持文档模型；与引擎的交互只通过 `import MarkdownEngine` 的公开 API。
- **组合层例外**：`MenuBar/MenuBarPanel.swift` 是 App 的组合层，唯一允许同时引用多个模块
  公开入口的位置（例如截图页的快捷操作条、面板顶部的 Markdown 按钮）。
  这属于 App 编排，不构成模块之间的依赖；三个功能模块本身不互相引用。

### 数据通路

1. 截图完成 → `NSPasteboard.general`（图片）供剪贴板模块读取；同时留档到 `AppPaths.captures/`。
2. 剪贴板 → Markdown（读取文本）。
3. 没有任何模块互相 `import` 或持有对方的 manager；共享状态只来自 `Shared/`。

## 4. 关键并发模型

- UI / AppKit 状态：`@MainActor`。
- 剪贴板：`DispatchQueue(label: "com.kaiming.clipboard", qos: .utility)` 串行执行所有
  `NSPasteboard` 访问；结果经 `DispatchQueue.main.async` 或 `Task { @MainActor in }` 回传。
- 截图：`ScreenshotCoordinator` 为 `@MainActor`；ScreenCaptureKit 的 async 采集返回后回主线程
  弹覆盖层 / 写剪贴板。
- Carbon 热键回调：C 函数指针 → `DispatchQueue.main.async` → `MainActor.assumeIsolated` 分发。

## 5. 截图流程（区域模式）

```
start(mode:.region)
  ├─ preflight 只用于日志，不拦截（TCC 可能绑定旧构建签名）
  ├─ SCShareableContent（排除本应用）
  │    └─ displays 为空 → 视为权限问题，可操作提示（结束）
  ├─ 逐屏 SCScreenshotManager.captureImage（冻结图；单屏失败重试 → CGDisplayCreateImage 兜底）
  ├─ 按「实际采集到的显示器」配对 NSScreen（ID → 几何位置回退）
  ├─ 显示每屏覆盖窗口（.screenSaver / canJoinAllSpaces / stationary；先激活再置前）
  ├─ 拖拽选区 + 8 手柄调整 + 标注
  ├─ Return 确认 / Esc 取消
  ├─ 按屏幕 pixelScale 裁剪 + 拍平
  ├─ （可选）成品顶部合成 macOS 标准窗口头部（红黄绿圆点，设置可关闭）
  └─ 编码 → 剪贴板 / 自动保存 / Captures 历史 / 声音 / 面板预览
       └─ 面板快捷条：复制 / 保存副本
```

实际采集失败时只弹恢复框：「打开权限设置 / 重启 Kaiming / 取消」，权限的检测与申请统一在
设置 → 权限 完成，截图流程不重复展示权限 UI。

关键点：**先截屏，再显示覆盖层**，避免把覆盖层自身拍进画面；同时 `SCContentFilter`
排除本应用进程，双保险。

## 6. Markdown 渲染

- 上游：`nodes-app/swift-markdown-engine` 0.15.0（TextKit 2，AppKit 编辑器桥到 SwiftUI）。
- 因当前工具链/Sandbox 下无法通过 SwiftPM 解析，按固定 commit 内嵌为 `MarkdownEngine` framework；
  源码改动仅 5 处 Bundle/import 机械替换，见 [vendor.md](vendor.md)。
- 服务注入：`HighlightJSBridge`（代码高亮，highlight.js）、`SwiftMathBridge`（LaTeX，SwiftMath）。
- 资源：`highlight.min.js`、`mathFonts.bundle` 放在 app bundle，`Bundle.main` 读取。
- 整篇渲染预览（`MarkdownRenderedPreview.swift` + `MarkdownWebDocumentBuilder.swift` +
  `MarkdownWebPreviewView.swift`）：Markdown → `MarkdownHTMLRenderer` HTML → 自包含 HTML
  文档 → 系统 `WKWebView` 排版。CSS 采用 GitHub Markdown 风格并跟随系统深浅色；HTML 块
  仍先 sanitize（去 script/style/iframe/on*）；图片解析后内联为 `data:` URL（离线）；
  ```mermaid 围栏交给随包的 `mermaid.min.js` 渲染（主题：深色画布 + 青绿 accent）。
- PDF（`MarkdownPDFExporter.swift`）：离屏 `WKWebView.createPDF` 抓取整篇内容，JS 按块级
  元素边界计算分页点，再用 CoreGraphics 裁切/缩放到 A4 页面（18mm / 16mm 边距），
  不依赖预览窗口是否打开。

## 7. 失败与权限策略

- 截图权限：真实 ScreenCaptureKit 能力探测 + 空结果判定；失败时跳转设置 → 权限（唯一入口），
  菜单栏面板不再显示权限横幅，绝不静默失败。
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

三个模块共享 `Shared/PasteboardQueue.swift` 的**全局唯一串行队列**，
所有 `NSPasteboard` 读写都在该队列执行（截图写回用 `sync` 等待完成，其余用 `async`），
避免跨模块并发访问。剪贴板监控的状态也由该队列串行保护。

## 10. v1.1 新增能力

### 剪贴板快捷选择

`HotKeyAction.openClipboard`（默认 ⌥⇧C，可在设置 → 快捷键自定义）→ `HotKeyManager` →
`AppRouter.openClipboardPicker()` → `Window(id: "clipboard-picker")`。
窗口内搜索框聚焦，↑/↓ 选择、Return 复制并关闭、Esc 关闭（由 NSTextField 字段编辑器的
`doCommandBy` 接管，中文输入法组合期间不抢键）；关闭后在无其他可见窗口时
`NSApp.hide(nil)` 把焦点交还前一个应用，便于直接 ⌘V。

### CLI 与 Markdown 打开通道

- CLI `kaiming ./docs` 把绝对路径做 base64url 编码后打开 `kaiming://open-folder?path=...`；
  `AppDelegate.application(_:open:)` 解码并设置 `MarkdownOpenRequest`，再打开 Markdown 窗口。
  URL scheme 在 `Config/Info.plist` 注册。
- Markdown 窗口的「打开文件夹…」选择目录后同样载入目录树；外部 `MarkdownOpenRequest` 与手动打开共用同一加载逻辑。

### Markdown 目录树

- `MarkdownFolderTree`（App 级 shared）只展示目录与 `.md/.markdown`，文件夹优先、懒加载；
  `MarkdownSidebarView` 260pt，支持展开/折叠、刷新、当前文件高亮。
- 外部请求与手动打开共用同一加载路径；脏文档载入文件前确认，仅切换目录不影响当前文档。

## 11. 菜单栏面板里不能弹系统模态

`MenuBarExtra(.window)` 的窗口在失去 key 时会收起。面板内使用 `.confirmationDialog` / `.alert`
（以及 `.fileImporter` / `.fileExporter`）时，系统弹窗会抢走 key，面板先被关闭；
SwiftUI 随即销毁弹窗宿主，弹窗按钮的 action 不再执行。v1.5 的「清空历史」症状
（点确认后窗口关闭、历史没清空、下次打开仍停在确认页）就是这个原因。

约定：

- 面板内的危险操作一律做成**内联确认**：在原位置把按钮换成确认卡片（说明文案 + 取消/确认），
  不打开任何新窗口。实现见 `Clipboard/ClipboardPanelView.swift` 的 `clearSection`。
- 菜单栏面板收起时 SwiftUI 不销毁视图树，`@State` 会保留；只属于本次打开的状态
  （确认态、输入焦点等）必须在 `onAppear` / `onDisappear` 以及承载窗口
  `didResignKey` 时复位（`PanelDismissObserver`）。
- 必须用系统模态时，改用 AppKit 的 `NSAlert` / `NSSavePanel`，以面板窗口为 sheet 锚点；
  锚不到窗口就不要从面板发起。设置窗口、Markdown 窗口是普通 `Window scene`，不受此限制。

## 12. 剪贴板「收藏 / 实时」分区

剪贴板只有**一份**历史（`ClipboardManager.items`），收藏是条目上的 `isFavorite` 标记，
不是第二份数据 —— 这样复制、去重、图片文件清理都只需要一条链路。

- 实时：`createdAt` 倒序；条数上限只约束非收藏项，淘汰时跳收藏项与「当前剪贴板」条目。
- 收藏：`favoritedAt` 倒序；不参与淘汰，也不被「清空实时历史」删除，只能逐条取消收藏或删除。
- 收藏项仍出现在实时列表里并带 ☆：避免「收藏后从历史里消失」的错觉，也保持复制回剪贴板后
  仍有一条连续的时间线。
- 面板与快捷选择窗口都用同一个 `ClipboardScope` + 分段 tab；搜索、↑/↓ 选择在当前分区内生效。
- 旧版 `isPinned`（置顶）在读取时等价迁移为收藏：两者语义相同（永久保留、不被淘汰），
  磁盘格式因此升到 `version: 2`。
