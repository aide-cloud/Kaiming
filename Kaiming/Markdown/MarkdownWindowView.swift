import AppKit
import MarkdownEngine
import SwiftUI
import UniformTypeIdentifiers

/// Markdown 独立窗口：原生 SwiftUI 工具栏 + TextKit 2 单栏实时渲染。
///
/// 窗口由 `KaimingApp` 的 `Window(id: "markdown")` 承载，本视图自带文档模型，
/// 所以菜单栏入口、全局快捷键（⌥⇧M）与重复打开窗口都复用同一份文档状态。
@MainActor
struct MarkdownWindowView: View {
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var model = MarkdownDocumentModel()
    @ObservedObject private var openRequest = MarkdownOpenRequest.shared
    @ObservedObject private var folderTree = MarkdownFolderTree.shared

    @State private var isImporting = false
    @State private var importMode: ImportMode = .markdownFiles
    @State private var isExporting = false
    @State private var isShowingUnsavedDialog = false
    @State private var pendingAction: PendingAction?
    @State private var confirmedAction: PendingAction?
    @State private var isEditorFocused = true
    @State private var isSidebarVisible = false
    @State private var didInitialLoad = false

    private enum PendingAction {
        case newDocument
        case openFile
        case loadClipboard
        case openFileURL(URL)
    }

    private enum ImportMode {
        case markdownFiles
        case folder
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let status = model.status {
                statusBanner(status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 0) {
                if isSidebarVisible {
                    MarkdownSidebarView(
                        tree: folderTree,
                        currentFileURL: model.documentURL,
                        onOpenFolder: { beginImport(.folder) },
                        onSelectFile: { requestFileLoad($0) },
                        onClose: { isSidebarVisible = false }
                    )
                    Divider()
                }

                editor
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .background(Color(nsColor: .textBackgroundColor))
        .background(
            WindowChromeConfigurator(
                title: "\(model.displayName) — Kaiming",
                isDocumentEdited: model.isDirty
            )
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
            allowedContentTypes: importMode == .folder ? [.folder] : MarkdownFileTypes.importable,
            allowsMultipleSelection: false
        ) { result in
            let mode = importMode
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    model.presentError(mode == .folder ? "没有选择文件夹。" : "没有选择文件。")
                    return
                }
                switch mode {
                case .folder:
                    openFolder(url)
                case .markdownFiles:
                    model.open(url: url)
                }
            case .failure(let error):
                let prefix = mode == .folder ? "打开文件夹失败" : "打开文件失败"
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
            }
        }
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
            placeholder: placeholder,
            retainedScrollDocumentIds: [model.documentId]
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            toolbarButton("doc.on.clipboard", help: "从剪贴板载入文本") {
                request(.loadClipboard)
            }

            toolbarButton("folder", help: "打开 Markdown 文件（⌘O）") {
                request(.openFile)
            }
            .keyboardShortcut("o", modifiers: .command)

            toolbarButton("square.and.arrow.down", help: "保存（⌘S）") {
                save()
            }
            .keyboardShortcut("s", modifiers: .command)

            toolbarButton("doc.on.doc", help: "复制全文到剪贴板") {
                copyAllToClipboard()
            }

            toolbarButton("folder.badge.plus", help: "打开文件夹…") {
                beginImport(.folder)
            }

            toolbarButton(
                "sidebar.left",
                help: isSidebarVisible ? "隐藏目录树" : "显示目录树",
                isActive: isSidebarVisible
            ) {
                isSidebarVisible.toggle()
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
            .help("减小正文字号")
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
            .help("增大正文字号")
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
        .help(help)
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
            model.newDocument()
        case .openFile:
            beginImport(.markdownFiles)
        case .loadClipboard:
            loadFromClipboard()
        case .openFileURL(let url):
            model.open(url: url)
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

        // 外部请求优先于上次打开的目录。
        consumeOpenRequest()
        if folderTree.rootURL == nil {
            _ = folderTree.restoreRecentFolder()
        }
        if folderTree.rootURL != nil {
            isSidebarVisible = true
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

        // 仅切换目录树不会改动当前文档，因此这里不需要确认。
        folderTree.open(folder: request.folder)
        isSidebarVisible = true
        Log.markdown.info("Consumed external open request for \(request.folder.path, privacy: .public)")

        if let file = request.file {
            requestFileLoad(file)
        }
    }

    private func openFolder(_ url: URL) {
        folderTree.open(folder: url)
        isSidebarVisible = true
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
            model.open(url: url)
        }
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
