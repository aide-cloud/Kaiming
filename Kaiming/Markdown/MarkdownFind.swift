import AppKit
import Foundation
import SwiftUI

// MARK: - 事件总线名称

/// Markdown 查找/替换事件。引擎只认通知名，因此 App 侧统一在这里定义，
/// 避免把字符串散落到各文件。
extension Notification.Name {
    static let kaimingMarkdownFindQuery = Notification.Name("kaiming.markdown.find.query")
    static let kaimingMarkdownFindResults = Notification.Name("kaiming.markdown.find.results")
    static let kaimingMarkdownFindClear = Notification.Name("kaiming.markdown.find.clear")
    static let kaimingMarkdownFindReplaceCurrent = Notification.Name("kaiming.markdown.find.replaceCurrent")
    static let kaimingMarkdownFindReplaceAll = Notification.Name("kaiming.markdown.find.replaceAll")
}

// MARK: - 查找目标

/// 当前查找作用在哪个视图上。渲染预览走 WKWebView 内的脚本查找，
/// 原生编辑器走 MarkdownEngine 的 find bus。
enum MarkdownFindTarget: Equatable {
    case editor
    case renderedPreview
    case unavailable
}

// MARK: - WebView 查找桥接类型

/// 一次 WebView 查找请求。每次请求带新的 `id`，用于：
/// 1. 让 SwiftUI `updateNSView` 只执行一次；
/// 2. 丢弃文档重载/快速输入后迟到的旧结果。
struct MarkdownWebSearchRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let query: String
    let useRegex: Bool
    let caseSensitive: Bool
    let currentIndex: Int
    let clear: Bool

    init(
        id: UUID = UUID(),
        query: String,
        useRegex: Bool = false,
        caseSensitive: Bool = false,
        currentIndex: Int = 0,
        clear: Bool = false
    ) {
        self.id = id
        self.query = query
        self.useRegex = useRegex
        self.caseSensitive = caseSensitive
        self.currentIndex = currentIndex
        self.clear = clear
    }
}

/// WebView 查找结果；`requestID` 必须与请求一致才被采纳。
struct MarkdownWebSearchResult: Equatable, Sendable {
    let requestID: UUID
    let count: Int
    let index: Int
    let errorMessage: String?
}

// MARK: - 查找状态

/// 编辑器与渲染预览共用的查找状态机。
///
/// - 编辑器模式：把请求通过 `Notification` 发给 `MarkdownEngine`，并监听
///   `findResults` 回传匹配数量；
/// - 渲染预览：驱动 `MarkdownWebPreviewView` 内的 JS 查找，结果由回调送回；
/// - 替换只在可编辑的原生编辑器里开放；渲染预览是只读视图，替换按钮禁用并给出说明。
@MainActor
final class MarkdownFindController: ObservableObject {
    @Published var isPresented = false
    @Published var showsReplace = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var useRegex = false
    @Published var caseSensitive = false
    @Published private(set) var matchCount = 0
    @Published private(set) var currentIndex = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var target: MarkdownFindTarget = .editor
    @Published private(set) var webSearchRequest: MarkdownWebSearchRequest?
    /// 每次显示/⌘F 重新聚焦输入框。
    @Published var focusToken = UUID()

    private var debounceTask: Task<Void, Never>?
    // `deinit` is nonisolated; the token is only touched from the main actor and
    // removed there. The explicit annotation keeps the Swift 6 deinit access legal.
    private nonisolated(unsafe) var editorObserver: NSObjectProtocol?
    private var lastWebRequestID: UUID?

    var canReplace: Bool { target == .editor }

    var statusText: String {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        guard !query.isEmpty else { return "" }
        if matchCount == 0 { return "0/0" }
        return "\(currentIndex + 1)/\(matchCount)"
    }

    var hasError: Bool {
        if let errorMessage, !errorMessage.isEmpty { return true }
        return false
    }

    init() {
        editorObserver = NotificationCenter.default.addObserver(
            forName: .kaimingMarkdownFindResults,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let count = notification.userInfo?["count"] as? Int ?? 0
            let index = notification.userInfo?["currentIndex"] as? Int ?? 0
            let error = notification.userInfo?["error"] as? String
            MainActor.assumeIsolated {
                self?.applyEditorResults(count: count, index: index, error: error)
            }
        }
    }

    deinit {
        if let editorObserver {
            NotificationCenter.default.removeObserver(editorObserver)
        }
    }

    // MARK: - 显示 / 关闭

    func present(target newTarget: MarkdownFindTarget, showsReplace: Bool) {
        if target != newTarget {
            switchTarget(to: newTarget)
        }
        isPresented = true
        if showsReplace && newTarget == .editor {
            self.showsReplace = true
        }
        focusToken = UUID()

        guard !query.isEmpty else {
            resetResults()
            clearActiveHighlights()
            return
        }
        scheduleSearch(resetIndex: true, immediate: true)
    }

    func dismiss() {
        guard isPresented else { return }
        debounceTask?.cancel()
        debounceTask = nil
        isPresented = false
        resetResults()
        clearActiveHighlights()
    }

    /// 模式切换（编辑 ↔ 渲染预览）时由窗口调用；查找条开着就立刻在新目标上重查。
    func setTarget(_ newTarget: MarkdownFindTarget) {
        guard target != newTarget else { return }
        switchTarget(to: newTarget)
        guard isPresented else { return }
        if query.isEmpty {
            clearActiveHighlights()
        } else {
            scheduleSearch(resetIndex: true, immediate: true)
        }
    }

    // MARK: - 查询

    /// 输入变化后稍作防抖再查，避免每个按键都重排整篇文档。
    func scheduleSearch(resetIndex: Bool, immediate: Bool = false) {
        debounceTask?.cancel()
        errorMessage = nil

        guard !query.isEmpty else {
            matchCount = 0
            currentIndex = 0
            clearActiveHighlights()
            return
        }

        if resetIndex { currentIndex = 0 }

        debounceTask = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.performSearch()
        }
    }

    /// Return 键：还没查过就先查；已经查过则跳到下一个。
    func submit() {
        guard !query.isEmpty else { return }
        if matchCount == 0 {
            scheduleSearch(resetIndex: true, immediate: true)
        } else {
            next()
        }
    }

    func next() {
        guard matchCount > 0 else {
            scheduleSearch(resetIndex: true, immediate: true)
            return
        }
        currentIndex = (currentIndex + 1) % matchCount
        performSearch()
    }

    func previous() {
        guard matchCount > 0 else {
            scheduleSearch(resetIndex: true, immediate: true)
            return
        }
        currentIndex = (currentIndex - 1 + matchCount) % matchCount
        performSearch()
    }

    /// 文档重载（编辑后自动刷新预览）时，用新文档重新落一次高亮。
    func refreshSearchIfPresented() {
        guard isPresented, !query.isEmpty else { return }
        scheduleSearch(resetIndex: false, immediate: true)
    }

    // MARK: - 替换（仅原生编辑器）

    func replaceCurrent() {
        guard canReplace, !query.isEmpty else { return }
        NotificationCenter.default.post(
            name: .kaimingMarkdownFindReplaceCurrent,
            object: nil,
            userInfo: [
                "query": query,
                "replacement": replacement,
                "currentIndex": currentIndex,
                "useRegex": useRegex,
                "caseSensitive": caseSensitive
            ]
        )
    }

    func replaceAll() {
        guard canReplace, !query.isEmpty else { return }
        NotificationCenter.default.post(
            name: .kaimingMarkdownFindReplaceAll,
            object: nil,
            userInfo: [
                "query": query,
                "replacement": replacement,
                "useRegex": useRegex,
                "caseSensitive": caseSensitive
            ]
        )
    }

    // MARK: - 结果回收

    func applyWebResult(_ result: MarkdownWebSearchResult) {
        guard target == .renderedPreview else { return }
        guard result.requestID == lastWebRequestID else { return }
        matchCount = max(0, result.count)
        currentIndex = matchCount == 0 ? 0 : min(max(result.index, 0), matchCount - 1)
        errorMessage = result.errorMessage
    }

    // MARK: - 私有

    private func applyEditorResults(count: Int, index: Int, error: String?) {
        guard target == .editor else { return }
        matchCount = max(0, count)
        currentIndex = matchCount == 0 ? 0 : min(max(index, 0), matchCount - 1)
        errorMessage = error
    }

    private func resetResults() {
        matchCount = 0
        currentIndex = 0
        errorMessage = nil
    }

    private func switchTarget(to newTarget: MarkdownFindTarget) {
        if target == .editor {
            NotificationCenter.default.post(name: .kaimingMarkdownFindClear, object: nil)
        } else if target == .renderedPreview {
            issueWebClear()
        }
        target = newTarget
        resetResults()
    }

    private func clearActiveHighlights() {
        switch target {
        case .editor:
            NotificationCenter.default.post(name: .kaimingMarkdownFindClear, object: nil)
        case .renderedPreview:
            issueWebClear()
        case .unavailable:
            break
        }
    }

    private func performSearch() {
        guard !query.isEmpty else {
            clearActiveHighlights()
            resetResults()
            return
        }

        switch target {
        case .editor:
            NotificationCenter.default.post(
                name: .kaimingMarkdownFindQuery,
                object: nil,
                userInfo: [
                    "query": query,
                    "currentIndex": currentIndex,
                    "useRegex": useRegex,
                    "caseSensitive": caseSensitive
                ]
            )

        case .renderedPreview:
            issueWebSearch()

        case .unavailable:
            matchCount = 0
            currentIndex = 0
            errorMessage = "此文件预览不支持查找"
        }
    }

    private func issueWebSearch() {
        let request = MarkdownWebSearchRequest(
            query: query,
            useRegex: useRegex,
            caseSensitive: caseSensitive,
            currentIndex: currentIndex
        )
        lastWebRequestID = request.id
        errorMessage = nil
        webSearchRequest = request
    }

    private func issueWebClear() {
        let request = MarkdownWebSearchRequest(
            query: "",
            currentIndex: 0,
            clear: true
        )
        lastWebRequestID = request.id
        webSearchRequest = request
    }
}

// MARK: - 查找快捷键

/// 在 Markdown 窗口内安装本地键盘监听。
///
/// 不用 SwiftUI `keyboardShortcut`：编辑器是 AppKit `NSTextView`（TextKit 2），
/// 虽然 Cmd+F 通常不会被它吞掉，但 `keyboardShortcut` 依赖隐藏按钮是否仍在
/// 键等价链里，行为不够确定。本地监听只在本窗口是事件窗口时生效，既能覆盖
/// 编辑器里的输入焦点，也不会影响设置等其它窗口。
struct MarkdownFindKeyMonitor: NSViewRepresentable {
    var isFindPresented: Bool
    var onFind: (_ showsReplace: Bool) -> Void
    var onFindNext: () -> Void
    var onFindPrevious: () -> Void
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.update(
            isFindPresented: isFindPresented,
            onFind: onFind,
            onFindNext: onFindNext,
            onFindPrevious: onFindPrevious,
            onDismiss: onDismiss
        )
        return view
    }

    func updateNSView(_ nsView: KeyMonitorView, context: Context) {
        nsView.update(
            isFindPresented: isFindPresented,
            onFind: onFind,
            onFindNext: onFindNext,
            onFindPrevious: onFindPrevious,
            onDismiss: onDismiss
        )
    }

    final class KeyMonitorView: NSView {
        private var monitor: Any?
        private var isFindPresented = false
        private var onFind: ((Bool) -> Void)?
        private var onFindNext: (() -> Void)?
        private var onFindPrevious: (() -> Void)?
        private var onDismiss: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func update(
            isFindPresented: Bool,
            onFind: @escaping (Bool) -> Void,
            onFindNext: @escaping () -> Void,
            onFindPrevious: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.isFindPresented = isFindPresented
            self.onFind = onFind
            self.onFindNext = onFindNext
            self.onFindPrevious = onFindPrevious
            self.onDismiss = onDismiss
            installMonitorIfNeeded()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            #if DEBUG
            NSLog("Kaiming debug: markdown find key monitor installed")
            #endif
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed: Bool = MainActor.assumeIsolated {
                    self?.handleKeyDown(event) ?? false
                }
                return consumed ? nil : event
            }
        }

        @MainActor
        private func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 { // Esc
                guard isFindPresented else { return false }
                onDismiss?()
                return true
            }

            guard flags.contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return false
            }

            switch key {
            case "f":
                onFind?(flags.contains(.option))
                return true
            case "g":
                if flags.contains(.shift) {
                    onFindPrevious?()
                } else {
                    onFindNext?()
                }
                return true
            default:
                return false
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}


/// Safari 风格的内嵌查找条：⌘F 出现，支持上一个/下一个、区分大小写、
/// 正则、替换当前/全部。渲染预览下替换按钮禁用并显示原因。
struct MarkdownFindBar: View {
    @ObservedObject var controller: MarkdownFindController
    @FocusState private var queryFocused: Bool
    @FocusState private var replacementFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            searchRow
            if controller.showsReplace {
                Divider()
                replaceRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .onExitCommand { controller.dismiss() }
        .onAppear { focusQueryField() }
        .onChange(of: controller.focusToken) { _, _ in focusQueryField() }
        .onChange(of: controller.query) { _, _ in controller.scheduleSearch(resetIndex: true) }
        .onChange(of: controller.useRegex) { _, _ in controller.scheduleSearch(resetIndex: true) }
        .onChange(of: controller.caseSensitive) { _, _ in controller.scheduleSearch(resetIndex: true) }
    }

    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("查找", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($queryFocused)
                .onSubmit { controller.submit() }
                .frame(minWidth: 150)

            Text(controller.statusText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(controller.hasError ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 44, alignment: .trailing)
                .help(controller.hasError ? controller.statusText : "")

            optionButton("Aa", help: "区分大小写", active: controller.caseSensitive) {
                controller.caseSensitive.toggle()
            }
            optionButton(".*", help: "正则表达式", active: controller.useRegex) {
                controller.useRegex.toggle()
            }

            iconButton("chevron.up", help: "上一个（⇧⌘G）") {
                controller.previous()
            }
            iconButton("chevron.down", help: "下一个（⌘G）") {
                controller.next()
            }

            Button {
                controller.showsReplace.toggle()
                if controller.showsReplace {
                    DispatchQueue.main.async { replacementFocused = true }
                }
            } label: {
                Image(systemName: controller.showsReplace ? "chevron.up" : "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.showsReplace ? "收起替换" : "替换")
            .accessibilityLabel("替换")

            Button {
                controller.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
            .accessibilityLabel("关闭查找")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("替换为", text: $controller.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($replacementFocused)
                .onSubmit { controller.replaceCurrent() }
                .disabled(!controller.canReplace)

            Button("替换") { controller.replaceCurrent() }
                .controlSize(.small)
                .disabled(!controller.canReplace || controller.matchCount == 0)

            Button("全部替换") { controller.replaceAll() }
                .controlSize(.small)
                .disabled(!controller.canReplace || controller.matchCount == 0)

            Spacer(minLength: 0)

            if !controller.canReplace {
                Text("渲染预览只读，替换请在编辑模式进行")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func focusQueryField() {
        DispatchQueue.main.async {
            queryFocused = true
        }
    }

    private func optionButton(
        _ title: String,
        help: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.22) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
