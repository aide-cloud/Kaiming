import AppKit
import MarkdownEngine
import SwiftUI
import UniformTypeIdentifiers

/// Markdown 独立窗口：原生 SwiftUI 工具栏 + TextKit 2 单栏实时渲染。
///
/// 窗口由 `KaimingApp` 的 `Window(id: "markdown")` 承载，本视图自带文档模型，
/// 所以菜单栏入口、全局快捷键（默认 ⌥⇧M，可自定义）与重复打开窗口都复用同一份文档状态。
@MainActor
struct MarkdownWindowView: View {
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var model = MarkdownDocumentModel()
    @StateObject private var find = MarkdownFindController()
    @ObservedObject private var openRequest = MarkdownOpenRequest.shared
    @ObservedObject private var folderTree = MarkdownFolderTree.shared
    @ObservedObject private var imageProvider = MarkdownImageProvider.shared

    @AppStorage("kaiming.markdown.sidebar.showsAllFiles") private var showsAllFiles = true

    @State private var isImporting = false
    @State private var importMode: ImportMode = .markdownFiles
    @State private var isExporting = false
    @State private var isShowingUnsavedDialog = false
    @State private var pendingAction: PendingAction?
    @State private var confirmedAction: PendingAction?
    @State private var isEditorFocused = true
    @State private var isSidebarVisible = false
    @State private var didInitialLoad = false
    @State private var preview: MarkdownPreview?
    @State private var isInspectorVisible = true
    @State private var headings: [MarkdownHeading] = []
    @State private var inspectorRefreshTask: Task<Void, Never>?
    @State private var scrollRequest: MarkdownScrollRequest?
    @State private var webScrollRequest: MarkdownWebScrollRequest?
    @State private var isRenderedPreviewVisible = false
    @State private var renderedDocument = MarkdownRenderedDocument()
    @State private var renderedPreviewTask: Task<Void, Never>?
    @State private var renderedPreviewDocumentURL: URL?
    @State private var hasHTMLBlocks = false
    @State private var documentScanTask: Task<Void, Never>?

    private enum PendingAction {
        case newDocument
        case openFile
        case loadClipboard
        case openFileURL(URL)
    }

    private enum ImportMode {
        case markdownFiles
        case folder
        case projectFolder
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let status = model.status {
                statusBanner(status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if hasHTMLBlocks && !isRenderedPreviewVisible && preview == nil {
                htmlHintBanner
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                if isSidebarVisible {
                    MarkdownSidebarView(
                        tree: folderTree,
                        showsAllFiles: $showsAllFiles,
                        currentFileURL: preview?.url ?? model.documentURL,
                        onOpenFolder: { beginImport(.projectFolder) },
                        onSelectFile: { handleFileSelection($0) },
                        onClose: { isSidebarVisible = false }
                    )
                    Divider()
                }

                richEditorArea
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .background(Color(nsColor: MarkdownGitHubTheme.canvas))
        .background(
            WindowChromeConfigurator(
                title: "\(model.displayName) — Kaiming",
                isDocumentEdited: model.isDirty
            )
            .frame(width: 0, height: 0)
        )
        .background(
            // 窗口首次出现时放到鼠标所在屏幕（见 WindowPlacement）。
            WindowPlacementProbe(scene: AppWindowScene.markdown)
                .frame(width: 0, height: 0)
        )
        .background(
            MarkdownFindKeyMonitor(
                isFindPresented: find.isPresented,
                onFind: { showsReplace in presentFind(showsReplace: showsReplace) },
                onFindNext: {
                    if find.isPresented { find.next() }
                },
                onFindPrevious: {
                    if find.isPresented { find.previous() }
                },
                onDismiss: {
                    find.dismiss()
                    if showEditor { isEditorFocused = true }
                }
            )
            .frame(width: 0, height: 0)
        )
        .background(
            MarkdownScrollZoomMonitor { step in
                adjustFontSize(by: Double(step))
            }
            .frame(width: 0, height: 0)
        )
        .animation(.easeInOut(duration: 0.16), value: model.status?.id)
        .confirmationDialog(
            "当前文档有未保存的修改",
            isPresented: $isShowingUnsavedDialog,
            titleVisibility: .visible
        ) {
            Button("放弃修改并继续", role: .destructive) {
                confirmedAction = pendingAction
            }
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
        } message: {
            Text("继续将丢失“\(model.displayName)”中尚未保存的修改。")
        }
        .onChange(of: isShowingUnsavedDialog) { _, isPresented in
            guard !isPresented else { return }
            let action = confirmedAction
            confirmedAction = nil
            pendingAction = nil
            if let action {
                perform(action)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importMode == .markdownFiles ? MarkdownFileTypes.importable : [.folder],
            allowsMultipleSelection: false
        ) { result in
            let mode = importMode
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    model.presentError(mode == .markdownFiles ? "没有选择文件。" : "没有选择文件夹。")
                    return
                }
                switch mode {
                case .folder:
                    openFolder(url, projectMode: false)
                case .projectFolder:
                    openFolder(url, projectMode: true)
                case .markdownFiles:
                    loadMarkdownFile(url)
                }
            case .failure(let error):
                let prefix = mode == .markdownFiles ? "打开文件失败" : "打开文件夹失败"
                model.presentError("\(prefix)：\(error.localizedDescription)")
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: MarkdownFileDocument(text: model.text),
            contentType: MarkdownFileTypes.markdown,
            defaultFilename: model.suggestedFileName
        ) { result in
            switch result {
            case .success(let url):
                model.save(to: url)
            case .failure(let error):
                model.presentError("保存文件失败：\(error.localizedDescription)")
            }
        }
        .alert("操作失败", isPresented: errorAlertBinding) {
            Button("好", role: .cancel) {
                model.dismissError()
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            handleInitialAppear()
        }
        .onChange(of: openRequest.request) { _, request in
            if request != nil {
                consumeOpenRequest()
            }
        }
        .onChange(of: folderTree.rootURL) { _, rootURL in
            if rootURL != nil {
                isSidebarVisible = true
                closePreview()
                showsAllFiles = true
            }
            syncReferenceBase()
            scheduleInspectorRefresh(immediate: true)
            if isRenderedPreviewVisible {
                scheduleRenderedPreviewReload()
            }
        }
        .onChange(of: model.documentURL) { _, _ in
            syncReferenceBase()
            scheduleInspectorRefresh(immediate: true)
            scheduleDocumentScan()
            if isRenderedPreviewVisible {
                loadRenderedPreview()
            }
        }
        .onChange(of: model.text) { _, _ in
            scheduleInspectorRefresh()
            scheduleDocumentScan()
            if isRenderedPreviewVisible {
                if renderedPreviewDocumentURL != model.documentURL {
                    loadRenderedPreview()
                } else {
                    scheduleRenderedPreviewReload()
                }
            }
            if find.isPresented, find.target == .editor {
                find.scheduleSearch(resetIndex: false)
            }
        }
        .onChange(of: isRenderedPreviewVisible) { _, _ in
            find.setTarget(currentFindTarget)
        }
        .onChange(of: preview?.url) { _, _ in
            if preview != nil {
                find.dismiss()
            }
            find.setTarget(currentFindTarget)
        }
        .onChange(of: renderedDocument.html) { _, html in
            guard html != nil, find.isPresented, find.target == .renderedPreview else { return }
            find.refreshSearchIfPresented()
        }
    }

    // MARK: - 查找

    /// 当前可见内容属于哪个查找目标。非 Markdown 文件预览（图片/二进制/文本
    /// 文件预览）没有可植入的查找视图，因此不在此开放查找。
    private var currentFindTarget: MarkdownFindTarget {
        if preview != nil { return .unavailable }
        if isRenderedPreviewVisible { return .renderedPreview }
        return .editor
    }

    private func presentFind(showsReplace: Bool) {
        // 普通文件预览（文本/图片/代码）不提供查找；Markdown 编辑与渲染预览都支持。
        guard preview == nil else {
            model.showStatus("当前文件预览不支持查找", kind: .info)
            return
        }
        find.present(target: currentFindTarget, showsReplace: showsReplace)
    }

    // MARK: - 编辑器

    /// 引擎只提供“始终实时”的内联渲染；设置里的“实时预览”关闭时映射为原始源码模式。
    private var editorConfiguration: MarkdownEditorConfiguration {
        var configuration = model.configuration
        configuration.rawSourceMode = !settings.markdownLivePreview
        return configuration
    }

    private var bodyFontSize: CGFloat {
        CGFloat(min(max(settings.markdownFontSize, 10), 36))
    }

    private var editor: some View {
        NativeTextViewWrapper(
            text: $model.text,
            configuration: editorConfiguration,
            fontName: "SF Pro",
            fontSize: bodyFontSize,
            documentId: model.documentId,
            isFocused: $isEditorFocused,
            onWebLinkClick: handleWebLinkClick,
            placeholder: placeholder,
            retainedScrollDocumentIds: [model.documentId]
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 预览时编辑器仍留在视图层级里（隐藏且不接收事件），从而保留未保存内容与撤销栈；
    /// 富内容 inspector 覆盖在编辑区右侧，不改变窗口/侧栏宽度，也不打断编辑。
    private var richEditorArea: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .trailing) {
                editorArea
                    // inspector 覆盖区让出空间，编辑内容重新排版而不是被遮住。
                    .padding(.trailing, isInspectorVisible ? 330 : 0)

                if isInspectorVisible {
                    MarkdownInspectorView(
                        headings: headings,
                        onSelectHeading: { selectHeading($0) },
                        onClose: {
                            isInspectorVisible = false
                            inspectorRefreshTask?.cancel()
                        }
                    )
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if find.isPresented {
                MarkdownFindBar(controller: find)
                    .padding(.top, 10)
                    .padding(.trailing, isInspectorVisible ? 342 : 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: isInspectorVisible)
        .animation(.easeInOut(duration: 0.14), value: find.isPresented)
    }

    private var showEditor: Bool {
        preview == nil && !isRenderedPreviewVisible
    }

    /// 页宽设置：默认/较宽给出居中的内容栏，全宽铺满。
    private var contentMaxWidth: CGFloat? {
        settings.markdownPageWidth.maxContentWidth
    }

    private var editorArea: some View {
        ZStack {
            editor
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(showEditor ? 1 : 0)
                .allowsHitTesting(showEditor)

            if let preview {
                MarkdownPreviewView(
                    preview: preview,
                    markdownIsDirty: model.isDirty,
                    onClose: closePreview,
                    onOpenExternal: { openWithDefaultApp(preview.url) },
                    onReveal: { revealInFinder(preview.url) }
                )
            } else if isRenderedPreviewVisible {
                MarkdownRenderedPreviewView(
                    document: renderedDocument,
                    sourceName: model.displayName,
                    onRefresh: { loadRenderedPreview() },
                    onClose: closeRenderedPreview,
                    baseURL: referenceBaseURL,
                    pageWidth: settings.markdownPageWidth,
                    fontSize: bodyFontSize,
                    onExportPDF: { exportPDF() },
                    scrollRequest: webScrollRequest,
                    searchRequest: find.webSearchRequest,
                    onSearchResult: { find.applyWebResult($0) },
                    onOpenLink: handleRenderedPreviewLink
                )
                .frame(maxWidth: contentMaxWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            MarkdownEditorScrollAccessor(request: scrollRequest)
                .frame(width: 0, height: 0)
        )
    }

    private var htmlHintBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10))
            Text("文档包含 HTML 块；编辑区显示源码。")
                .font(.system(size: 10))
            Button("渲染预览") {
                openRenderedPreview()
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }

    private var placeholder: NSAttributedString? {
        guard model.text.isEmpty else { return nil }
        return NSAttributedString(
            string: "开始输入 Markdown…",
            attributes: [
                .font: NSFont.systemFont(ofSize: bodyFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("doc.badge.plus", help: "新建 Markdown（⌘N）") {
                request(.newDocument)
            }
            .keyboardShortcut("n", modifiers: .command)

            toolbarButton("square.and.arrow.down", help: "保存（⌘S）") {
                save()
            }
            .keyboardShortcut("s", modifiers: .command)

            toolbarButton("doc.on.doc", help: "复制全文到剪贴板") {
                copyAllToClipboard()
            }

            toolbarButton(
                "sidebar.left",
                help: isSidebarVisible ? "隐藏目录树" : "显示目录树",
                isActive: isSidebarVisible,
                tooltipAlignment: .bottomTrailing
            ) {
                isSidebarVisible.toggle()
            }

            toolbarButton(
                "sidebar.right",
                help: isInspectorVisible ? "隐藏内容导航" : "显示内容导航（标题大纲）",
                isActive: isInspectorVisible,
                tooltipAlignment: .bottomTrailing
            ) {
                toggleInspector()
            }

            toolbarButton(
                "doc.richtext",
                help: isRenderedPreviewVisible ? "关闭渲染预览" : "渲染预览（HTML/Markdown，只读，含图片）",
                isActive: isRenderedPreviewVisible,
                tooltipAlignment: .bottomTrailing
            ) {
                toggleRenderedPreview()
            }

            toolbarDivider

            pageWidthMenu

            toolbarButton("arrow.down.doc", help: "导出为 PDF…", tooltipAlignment: .bottomTrailing) {
                exportPDF()
            }

            toolbarDivider

            fileSummary
                .layoutPriority(1)

            Spacer(minLength: 8)

            statistics

            toolbarDivider

            fontControls
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .zIndex(20)
    }

    private var pageWidthMenu: some View {
        Menu {
            ForEach(MarkdownPageWidth.allCases) { width in
                Button {
                    settings.markdownPageWidth = width
                } label: {
                    if settings.markdownPageWidth == width {
                        Label(width.title, systemImage: "checkmark")
                    } else {
                        Text(width.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.left.and.right.square")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .markdownTooltip("页宽：默认 / 较宽 / 全宽", alignment: .bottomTrailing)
        .accessibilityLabel("页宽")
    }

    private var fileSummary: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(model.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if model.isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .help("有未保存的修改")
                    .accessibilityLabel("有未保存的修改")
            }
        }
    }

    private var statistics: some View {
        Text("字符 \(model.characterCount) · 词 \(model.wordCount)")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .help("字符数（不含换行）与 CJK 感知的词数")
    }

    private var fontControls: some View {
        HStack(spacing: 0) {
            Button {
                adjustFontSize(by: -1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(settings.markdownFontSize <= 10)
            .markdownTooltip("减小正文字号", alignment: .bottomTrailing)
            .accessibilityLabel("减小正文字号")

            Text("\(Int(settings.markdownFontSize.rounded())) pt")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 42)
                .help("正文字号，可在偏好设置中调整")

            Button {
                adjustFontSize(by: 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(settings.markdownFontSize >= 36)
            .markdownTooltip("增大正文字号", alignment: .bottomTrailing)
            .accessibilityLabel("增大正文字号")
        }
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 6)
    }

    private func toolbarButton(
        _ symbol: String,
        help: String,
        isActive: Bool = false,
        tooltipAlignment: Alignment = .bottomLeading,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .markdownTooltip(help, alignment: tooltipAlignment)
        .accessibilityLabel(help)
    }

    private func statusBanner(_ status: MarkdownDocumentModel.Status) -> some View {
        let tint: Color = status.kind == .success ? .green : .accentColor
        return HStack(spacing: 6) {
            Image(systemName: status.kind == .success ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(status.text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
    }

    // MARK: - 动作

    private func request(_ action: PendingAction) {
        if model.isDirty {
            pendingAction = action
            isShowingUnsavedDialog = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .newDocument:
            closePreview()
            closeRenderedPreview()
            model.newDocument()
        case .openFile:
            beginImport(.markdownFiles)
        case .loadClipboard:
            closePreview()
            closeRenderedPreview()
            loadFromClipboard()
        case .openFileURL(let url):
            loadMarkdownFile(url)
        }
    }

    // MARK: - 目录树 / 外部打开

    private func beginImport(_ mode: ImportMode) {
        importMode = mode
        isImporting = true
    }

    private func handleInitialAppear() {
        guard !didInitialLoad else { return }
        didInitialLoad = true

        #if DEBUG
        // 仅调试构建：允许 CLI/快照直接载入一个 Markdown 文件与 inspector，
        // 不改变 release 行为，也不依赖屏幕交互。
        if let debugFile = debugMarkdownFileArgument {
            folderTree.open(folder: debugFile.deletingLastPathComponent(), remember: false)
            isSidebarVisible = true
            loadMarkdownFile(debugFile)
        }
        #endif

        // 外部请求优先于上次打开的目录。
        consumeOpenRequest()
        if folderTree.rootURL == nil {
            _ = folderTree.restoreRecentFolder()
        }
        if folderTree.rootURL != nil {
            isSidebarVisible = true
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--markdown-inspector") {
            isInspectorVisible = true
        }
        if ProcessInfo.processInfo.arguments.contains("--markdown-render-preview") {
            isRenderedPreviewVisible = true
            isEditorFocused = false
        }
        #endif

        syncReferenceBase()
        scanDocumentHTML()
        if isInspectorVisible {
            refreshRichContent()
        }
        if isRenderedPreviewVisible {
            loadRenderedPreview()
        }

        #if DEBUG
        // 快照验收查找条与查找高亮：--markdown-find [--markdown-find-query 词]
        // [--markdown-find-regex] [--markdown-find-replacement 词]
        // [--markdown-find-replace | --markdown-find-replace-all]
        if ProcessInfo.processInfo.arguments.contains("--markdown-find") {
            find.query = debugFindQueryArgument ?? "Markdown"
            find.useRegex = ProcessInfo.processInfo.arguments.contains("--markdown-find-regex")
            if let replacement = debugFindReplacementArgument {
                find.replacement = replacement
            }
            presentFind(showsReplace: true)
            find.scheduleSearch(resetIndex: true, immediate: true)

            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--markdown-find-replace")
                || arguments.contains("--markdown-find-replace-all") {
                let replaceAll = arguments.contains("--markdown-find-replace-all")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if replaceAll {
                        find.replaceAll()
                    } else {
                        find.replaceCurrent()
                    }
                }
            }
        }
        #endif
    }

    #if DEBUG
    private var debugMarkdownFileArgument: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--markdown-file"),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private var debugFindQueryArgument: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--markdown-find-query"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private var debugFindReplacementArgument: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--markdown-find-replacement"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif

    private var referenceBaseURL: URL? {
        if let documentURL = model.documentURL {
            return documentURL.deletingLastPathComponent()
        }
        return folderTree.rootURL
    }

    private func syncReferenceBase() {
        imageProvider.setBaseDirectory(referenceBaseURL)
    }

    // MARK: - 富内容 inspector

    private func toggleInspector() {
        isInspectorVisible.toggle()
        if isInspectorVisible {
            refreshRichContent()
        } else {
            inspectorRefreshTask?.cancel()
            inspectorRefreshTask = nil
        }
    }

    private func scheduleInspectorRefresh(immediate: Bool = false) {
        guard isInspectorVisible else { return }
        inspectorRefreshTask?.cancel()
        if immediate {
            refreshRichContent()
            return
        }
        inspectorRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            refreshRichContent()
        }
    }

    private func refreshRichContent() {
        guard isInspectorVisible else { return }
        headings = MarkdownOutlineParser.headings(in: model.text)
    }

    // MARK: - 渲染预览 / 大纲

    private func toggleRenderedPreview() {
        if isRenderedPreviewVisible {
            closeRenderedPreview()
        } else {
            closePreview()
            isRenderedPreviewVisible = true
            isEditorFocused = false
            loadRenderedPreview()
        }
    }

    private func openRenderedPreview() {
        if isRenderedPreviewVisible {
            loadRenderedPreview()
        } else {
            toggleRenderedPreview()
        }
    }

    private func closeRenderedPreview() {
        guard isRenderedPreviewVisible else { return }
        renderedPreviewTask?.cancel()
        renderedPreviewTask = nil
        isRenderedPreviewVisible = false
        isEditorFocused = true
    }

    private func loadRenderedPreview() {
        renderedPreviewTask?.cancel()
        renderedDocument = MarkdownRenderedDocument(isLoading: true)
        guard isRenderedPreviewVisible else { return }

        renderedPreviewDocumentURL = model.documentURL
        let markdown = model.text
        let baseURL = referenceBaseURL
        let configuration = model.configuration
        let options = MarkdownWebDocumentOptions(
            title: model.displayName,
            theme: .system,
            pageWidth: settings.markdownPageWidth,
            fontSize: bodyFontSize,
            // 预览不为远程图片阻塞：保留 https URL 交给 WKWebView 并行渐进加载。
            inlineRemoteImages: false
        )
        renderedPreviewTask = Task { @MainActor in
            let document = await MarkdownRenderedPreviewBuilder.build(
                markdown: markdown,
                baseURL: baseURL,
                configuration: configuration,
                options: options
            )
            guard !Task.isCancelled, isRenderedPreviewVisible else { return }
            renderedDocument = document
        }
    }

    private func scheduleRenderedPreviewReload() {
        guard isRenderedPreviewVisible else { return }
        renderedPreviewTask?.cancel()
        renderedPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, isRenderedPreviewVisible else { return }
            loadRenderedPreview()
        }
    }

    private func selectHeading(_ heading: MarkdownHeading) {
        // 渲染预览打开时，导航点击应滚动预览里的标题锚点，而不是把预览关掉。
        if isRenderedPreviewVisible {
            if let index = headings.firstIndex(where: { $0.id == heading.id }) {
                webScrollRequest = MarkdownWebScrollRequest(headingIndex: index)
            }
            return
        }
        closePreview()
        closeRenderedPreview()
        isEditorFocused = true
        scrollRequest = MarkdownScrollRequest(location: heading.location)
    }

    private func scanDocumentHTML() {
        documentScanTask?.cancel()
        hasHTMLBlocks = !MarkdownRichTextParser.htmlBlocks(in: model.text).isEmpty
    }

    private func scheduleDocumentScan() {
        documentScanTask?.cancel()
        documentScanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            hasHTMLBlocks = !MarkdownRichTextParser.htmlBlocks(in: model.text).isEmpty
        }
    }

    // MARK: - 链接

    private func handleWebLinkClick(_ url: URL) {
        switch MarkdownLinkRouter.route(url, baseDirectory: referenceBaseURL) {
        case .external(let externalURL):
            if !NSWorkspace.shared.open(externalURL) {
                model.showStatus("无法打开链接：\(externalURL.absoluteString)", kind: .info)
            }
        case .internalFile(let fileURL):
            openInternalReference(fileURL)
        case .invalid(let message):
            model.showStatus(message, kind: .info)
        }
    }

    /// 渲染预览里的链接：外部链接仍交给系统浏览器，内部文件链接留在应用内预览，
    /// 不再让默认 Markdown 应用弹出新窗口。
    private func handleRenderedPreviewLink(_ url: URL) -> Bool {
        switch MarkdownLinkRouter.route(url, baseDirectory: referenceBaseURL) {
        case .external(let externalURL):
            _ = NSWorkspace.shared.open(externalURL)
        case .internalFile(let fileURL):
            openInternalReferenceInPreview(fileURL)
        case .invalid(let message):
            model.showStatus(message, kind: .info)
        }
        // 已在 App 内处理（或已明确失败），不再让 WebView 自己打开。
        return true
    }

    private func openInternalReferenceInPreview(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            model.presentError("引用的文件不存在：\(url.lastPathComponent)")
            return
        }
        if isDirectory.boolValue {
            openFolder(url, projectMode: true)
            return
        }

        switch MarkdownFileTypes.kind(of: url) {
        case .markdown:
            // 保留渲染预览，只切换文档；`model.text` / `documentURL` 变化会
            // 触发预览重建，导航看起来与点击页内锚点一致。
            requestFileLoad(url)
            let standardized = url.standardizedFileURL
            Task { await folderTree.reveal(fileURL: standardized) }
        case .text, .image, .other:
            // 非 Markdown 文件沿用应用内的只读文件预览，而不是系统默认应用。
            showPreview(url)
        case .folder:
            openFolder(url, projectMode: true)
        }
    }

    private func openInternalReference(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            model.presentError("引用的文件不存在：\(url.lastPathComponent)")
            return
        }
        if isDirectory.boolValue {
            openFolder(url, projectMode: true)
            return
        }

        switch MarkdownFileTypes.kind(of: url) {
        case .markdown:
            requestFileLoad(url)
        case .text, .image, .other:
            showPreview(url)
        case .folder:
            openFolder(url, projectMode: true)
        }
    }

    private func consumeOpenRequest() {
        guard let request = openRequest.consume() else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            model.presentError("无法打开目录：路径不存在或不是文件夹（\(request.folder.lastPathComponent)）")
            return
        }

        // 外部目录按“项目预览”处理：默认展示全部文件；仅切换目录树不会改动当前文档。
        showsAllFiles = true
        closePreview()
        folderTree.open(folder: request.folder)
        isSidebarVisible = true
        Log.markdown.info("Consumed external open request for \(request.folder.path, privacy: .public)")

        if let file = request.file {
            handleFileSelection(file)
        }
    }

    private func openFolder(_ url: URL, projectMode: Bool) {
        if projectMode {
            showsAllFiles = true
        }
        closePreview()
        folderTree.open(folder: url)
        isSidebarVisible = true
    }

    /// 项目树点击入口：Markdown 走编辑器（保留脏文档确认），其他文件走只读预览。
    private func handleFileSelection(_ url: URL) {
        if MarkdownFileTypes.kind(of: url) == .markdown {
            requestFileLoad(url)
        } else {
            showPreview(url)
        }
    }

    private func requestFileLoad(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.presentError("无法打开文件：文件不存在（\(url.lastPathComponent)）")
            return
        }

        if model.isDirty {
            pendingAction = .openFileURL(url)
            isShowingUnsavedDialog = true
        } else {
            loadMarkdownFile(url)
        }
    }

    private func loadMarkdownFile(_ url: URL) {
        closePreview()
        // 渲染预览是独立的查看模式：切换 Markdown 文档时保留，预览内容随后自动刷新。
        model.open(url: url)
        isEditorFocused = true
        syncReferenceBase()

        let standardized = url.standardizedFileURL
        if model.documentURL?.standardizedFileURL == standardized {
            Task { await folderTree.reveal(fileURL: standardized) }
        }
    }

    private func showPreview(_ url: URL) {
        closeRenderedPreview()
        let kind = MarkdownFileTypes.kind(of: url)
        preview = MarkdownPreview(
            url: url,
            kind: kind,
            fileSize: 0,
            content: nil,
            isLoading: true,
            errorMessage: nil
        )
        isEditorFocused = false
        Log.markdown.info("Previewing file \(url.lastPathComponent, privacy: .public)")

        Task { @MainActor in
            let loaded = await MarkdownPreviewLoader.load(url: url)
            guard preview?.url == url else { return }
            preview = loaded
        }
    }

    private func closePreview() {
        guard preview != nil else { return }
        preview = nil
        isEditorFocused = true
    }

    private func openWithDefaultApp(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            model.showStatus("无法用默认应用打开 \(url.lastPathComponent)", kind: .info)
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func save() {
        if model.documentURL != nil {
            model.saveToExistingURL()
        } else {
            isExporting = true
        }
    }

    private func copyAllToClipboard() {
        let contents = model.text
        guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.showStatus("没有可复制的文本", kind: .info)
            return
        }

        Task { @MainActor in
            let succeeded = await MarkdownPasteboard.write(contents)
            if succeeded {
                model.showStatus("已复制全文到剪贴板", kind: .success)
                Log.markdown.info("Copied \(contents.count) characters to the clipboard")
            } else {
                model.presentError("复制到剪贴板失败。")
            }
        }
    }

    private func loadFromClipboard() {
        Task { @MainActor in
            guard let contents = await MarkdownPasteboard.readString() else {
                model.presentError("剪贴板中没有可读取的文本。")
                return
            }
            guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.presentError("剪贴板文本为空，未载入任何内容。")
                return
            }
            model.replaceWithClipboardText(contents)
        }
    }

    private func exportPDF() {
        let markdown = model.text
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.showStatus("没有可导出的内容", kind: .info)
            return
        }
        let baseURL = referenceBaseURL
        let configuration = model.configuration
        let fileName = model.displayName
        Task { @MainActor in
            do {
                if let url = try await MarkdownPDFExporter.exportInteractively(
                    markdown: markdown,
                    baseURL: baseURL,
                    configuration: configuration,
                    fileName: fileName,
                    presentingWindow: NSApp.keyWindow
                ) {
                    model.showStatus("已导出 PDF：\(url.lastPathComponent)", kind: .success)
                }
            } catch {
                model.presentError("导出 PDF 失败：\(error.localizedDescription)")
            }
        }
    }

    private func adjustFontSize(by delta: Double) {
        let next = min(max(settings.markdownFontSize + delta, 10), 36)
        guard next != settings.markdownFontSize else { return }
        settings.markdownFontSize = next
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissError()
                }
            }
        )
    }
}

// MARK: - 窗口标题与脏标记

/// 把文档名与“已编辑”圆点同步到真正的 NSWindow 标题栏。
private struct WindowChromeConfigurator: NSViewRepresentable {
    let title: String
    let isDocumentEdited: Bool

    func makeNSView(context: Context) -> WindowChromeHostingView {
        let view = WindowChromeHostingView()
        view.apply(title: title, isDocumentEdited: isDocumentEdited)
        return view
    }

    func updateNSView(_ nsView: WindowChromeHostingView, context: Context) {
        nsView.apply(title: title, isDocumentEdited: isDocumentEdited)
    }
}

private final class WindowChromeHostingView: NSView {
    private var desiredTitle = ""
    private var desiredDocumentEdited = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func apply(title: String, isDocumentEdited: Bool) {
        desiredTitle = title
        desiredDocumentEdited = isDocumentEdited
        applyToWindow()
    }

    private func applyToWindow() {
        guard let window else { return }
        if window.title != desiredTitle {
            window.title = desiredTitle
        }
        if window.isDocumentEdited != desiredDocumentEdited {
            window.isDocumentEdited = desiredDocumentEdited
        }
    }
}
