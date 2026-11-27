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
│    ├─ 系统页 ──────────────┤                                 │
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
| 功能模块 | `Screenshot/`、`Clipboard/`、`SystemMonitor/`、`Markdown/` | 各自 UI + 业务；对外只暴露冻结入口 |
| UI 组合 | `MenuBar/MenuBarPanel.swift` | 唯一把截图 / 剪贴板 / 系统面板拼在一起的地方 |
| 视觉 token | `Shared/PanelStyle.swift` | `panelCard` / `panelTile` / `PanelIconBadge` / `PanelHeader` / `PanelChip`，三页共用 |
| 渲染内核 | `MarkdownKit/`（framework target） | 内嵌 TextKit 2 Markdown 引擎（Swift 5 模式） |

## 3. 模块边界

- **Screenshot**：`ScreenshotCoordinator.shared.start(mode:)` 是唯一入口。
  它只依赖共享类型（`CaptureMode`、`SettingsStore`、`AppState`、`AppPaths`、`ScreenCapturePermission`、
  `AccessibilityPermission`、`PermissionCenter`、`Log`），
  不引用 Clipboard / Markdown 的代码。
- **Clipboard**：`ClipboardManager.shared` 自持串行队列与历史。
  UI 面板只调用 manager，不直接碰 `NSPasteboard`。
- **Markdown**：独立窗口，自持文档模型；与引擎的交互只通过 `import MarkdownEngine` 的公开 API。
- **SystemMonitor**：`SystemMonitor.shared` 是唯一入口。内存 / CPU / 磁盘 / 网络 / 进程采样在
  `Task.detached` 中完成，只把 Sendable 快照回主线程；传感器由 `SensorReader` actor 串行读取；
  UI 只读 `@Published` 快照并调用 `scanCaches` / `cleanSelectedCaches` / `releaseMemory`，
  不直接碰 `sysctl`、IOKit 或文件系统。
- **视觉一致性**：截图、剪贴板、快捷选择与系统页统一使用 `Shared/PanelStyle` 的卡片
  （9–10pt 圆角、4–6% 叠色、细描边）、图标徽章与胶囊标签；截图页使用三列模式磁贴、
  最近截图卡、能力/行为卡，剪贴板页使用当前项卡、下划线分区与历史卡，快捷选择使用
  搜索卡 + 下划线分区 + 行内 ☆ 收藏 + 键盘提示；设置窗口使用同款图标卡片。
  快捷选择每行右侧的 ☆ 与 ⌘D 走 `ClipboardManager.toggleFavorite`，临时「当前剪贴板」
  条目不存在于历史时会先写入历史再收藏。
- **组合层例外**：`MenuBar/MenuBarPanel.swift` 是 App 的组合层，唯一允许同时引用多个模块
  公开入口的位置（例如截图页的快捷操作条、面板顶部的 Markdown 按钮）。
  这属于 App 编排，不构成模块之间的依赖；四个功能模块本身不互相引用。

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
- 系统采样：`SystemMonitor` 为 `@MainActor`；后台任务返回 `Sendable` 值类型快照，CPU / 网络用
  上一帧累计值求差分。传感器 IOKit 连接只在 `SensorReader` actor 内访问。
- 菜单栏面板生命周期：`Shared/PanelVisibilityObserver` 监听承载窗口的 becomeKey / resignKey /
  willClose / 应用失活；面板收起时停止系统采样并复位内联确认，重新取得 key 时恢复采样。

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
  `didResignKey` 时复位（`Shared/PanelVisibilityObserver`）。
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

## 13. 系统资源模块

`SystemMonitor/` 只依赖 `Shared/`（`Log`）与系统框架，不引用截图 / 剪贴板 / Markdown。

| 数据 | 来源 | 口径 |
|---|---|---|
| 内存 | `host_statistics64(HOST_VM_INFO64)` + `sysctl vm.swapusage` | 已用 = (internal − purgeable) + wired + compressor，与活动监视器接近；可回收 = inactive + speculative + purgeable |
| CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 8 核 tick 差分（user + system + nice）/ 全部 tick；附 `getloadavg` 1 分钟负载 |
| 磁盘 | `URL.resourceValues` 的 `volumeTotalCapacity` / `volumeAvailableCapacity` | 用户主目录所在卷；可用容量取 macOS 的“可用”值 |
| 网络 | `getifaddrs` 的 `if_data.ifi_ibytes/obytes` | 仅物理接口（`en*` / `pdp*` / `ppp*`），排除 `lo0` / `utun` / `awdl` / `llw` / `bridge`，每 2 秒差分 |
| 应用内存 | `sysctl KERN_PROC_ALL` + `proc_pidpath` + `proc_pid_rusage(RUSAGE_INFO_V4)` | 按最外层 `.app` 聚合 physical footprint；名称与图标在主线程用 `NSRunningApplication` / `NSWorkspace` 补齐 |
| CPU 温度 | `IOHIDEventSystemClient`（`dlsym` 解析私有符号） | 取 `pACC` / `eACC` 簇最大值，退化为 `PMU tdie` / `SOC MTR`；无传感器时不显示 |
| 风扇 | AppleSMC `F0Ac / F0Mn / F0Mx` | 固定 80 字节 `SMCKeyData` 缓冲区，结构体字段小端、SMC 值按类型解码（`flt` / `fpe2`） |

清理只覆盖当前用户：`~/Library/Caches`、`~/Library/Logs`、`~/.Trash`；每个目录单次最多扫描 25 万文件；
清理跳过最近 1 小时内修改过的条目，删除失败不中断整轮。面板内的确认使用**内联确认卡片**
（原因见第 11 节），不使用 `.confirmationDialog`。

「释放内存」不是 root `purge`：以 32 MB 为块申请并立即归还（按压力等级限制在 256 MB–1 GB），
用短暂内存压力促使内核回收闲置页；结果取释放前后 `usedBytes` 的差值，不做“释放了 X GB”的夸大展示。

### 状态栏指标

- `Shared/SystemStatusMetric` 定义 7 个可展示指标；`SettingsStore.statusBarMetrics` 持久化选择，
  首次启动 / 未写入过键时默认 `allCases`（全部展示）。
- `MenuBarLabel` 直接观察 `SystemMonitor`，把选中指标绘制成单张模板 `NSImage`
  （`MenuBarStatusImage`：开明 logo + SF Symbol 图标 + 9pt 等宽数字，`NSBitmapImageRep` 按屏幕倍率光栅化），
  再作为单个 `Image` label。这样绕开 NSStatusItem 对多子视图 / 内联 SF Symbol 的限制，
  `isTemplate` 自动适配深浅色；每个指标预留固定文本宽度，数值变化时状态项不抖动。
  工具提示与无障碍标签给出完整单位。
- 采样循环由 `panelActive || !statusMetrics.isEmpty` 驱动：面板打开时 2 秒全量（含进程列表）；
  收起后 3 秒轻量（跳过 `appGroups`；未选择温度 / 风扇时跳过 IOKit 传感器）。全部取消且面板
  收起时完全停止，避免菜单栏常驻应用的持续采样开销。
- 刷新请求串行化：`refreshNow` 在 `isRefreshing` 期间等待上一帧结束，避免面板 / 状态栏 / 清理动作
  同时请求时拿到空值。

### 应用卸载

- `AppInventory.scan()` 枚举 `/Applications` 与 `~/Applications`（`.skipsPackageDescendants`，跳过
  `.app` 内部与符号链接），过滤 `com.apple.*` 与开明自身，返回 `InstalledApp`（url / bundle id /
  名称 / 版本）。
- `AppResidueScanner.scan(app)` 以 bundle id 为强匹配、文件系统应用名为辅助匹配，扫描
  `~/Library` 下的 Application Support / Caches / Containers / Group Containers /
  Preferences / ByHost / Saved Application State / WebKit / HTTPStorages / Cookies /
  Application Scripts / Logs / LaunchAgents；并从代码签名 entitlements 读取 App Group
  精确定位共享容器。bundle id 匹配允许 `id.helper` 这类后缀，但拒绝 `id2` 这类纯数字后缀。
  另外扫描 QuickLook / Spotlight / Services / PreferencePanes / Input Methods / Screen Savers /
  Audio Plug-Ins 等用户级插件目录，以及 `~/Documents`、`~/Downloads`、`~/Desktop`、
  `~/Pictures`、`~/Movies`、`~/Music`、`~/Public` 和家目录下与 App 同名的顶层文件/文件夹
  （用户目录项在 UI 中带橙色警告，可取消）。去重、按父目录剪枝，单条目最多统计 30 万文件。只读。
- `AppResidueScanner.remove(items:app:)` 的硬约束：
  - `.app` 条目必须与选中的应用路径完全一致，且位于 `/Applications` 或 `~/Applications`；
  - 其它条目必须位于当前用户 `~/Library/`，或属于常用用户目录的**直接子项**（拒绝目录根与
    Library/Applications 等受保护文件夹）；拒绝开明自身 bundle；
  - **先删应用本体**，失败立即中止（不继续清缓存，避免留下坏应用）；之后再删勾选项，失败逐条记录。
  - 删除跑在 `Task.detached`，UI 只接收 `UninstallOutcome`（释放字节 / 成功数 / 失败路径）。
- `AppUninstallModel`（@MainActor）负责列表、搜索、扫描、勾选与卸载状态；运行中的应用用
  `NSRunningApplication.terminate()` 退出并等待最多 3 秒，拒绝退出则中止。面板内仍使用内联确认。
- 已知边界：不扫描 `/Library` 系统级文件、Group Containers、App Store 收据与应用自定义目录；
  Cookies / 其他应用容器可能受 TCC 限制，需要完全磁盘访问权限。
