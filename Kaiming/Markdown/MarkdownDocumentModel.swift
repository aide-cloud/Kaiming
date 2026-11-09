import Foundation
import MarkdownEngine

/// Markdown 窗口的文档状态：正文、文件位置、每个文档稳定唯一的 `documentId`、
/// 脏标记与工具栏提示。
///
/// `documentId` 只在初始化和换文档（打开 / 新建 / 从剪贴板载入）时生成，
/// 视图每次重绘都复用同一个值，从而保住引擎的撤销栈与滚动位置归属。
@MainActor
final class MarkdownDocumentModel: ObservableObject {
    struct Status: Identifiable, Equatable {
        enum Kind {
            case info
            case success
        }

        let id = UUID()
        var text: String
        var kind: Kind
    }

    @Published var text: String
    @Published private(set) var documentURL: URL?
    @Published private(set) var documentId: String
    @Published private(set) var baselineText: String
    @Published private(set) var status: Status?
    @Published private(set) var errorMessage: String?

    /// 引擎配置只创建一次：`HighlightJSBridge` 内部持有 JavaScriptCore 上下文，
    /// `SwiftMathBridge` 持有渲染缓存，不能在每次 SwiftUI 重绘时重建。
    let configuration: MarkdownEditorConfiguration

    private var statusDismissTask: Task<Void, Never>?

    init() {
        configuration = Self.makeConfiguration()
        let welcome = Self.welcomeDocument
        text = welcome
        baselineText = welcome
        documentId = UUID().uuidString
    }

    // MARK: - 派生状态

    /// 与上次保存（或载入）的内容比较；欢迎文档本身是干净的。
    var isDirty: Bool { text != baselineText }

    var displayName: String {
        documentURL?.lastPathComponent ?? "未命名.md"
    }

    var suggestedFileName: String {
        guard let documentURL else { return "未命名" }
        return documentURL.deletingPathExtension().lastPathComponent
    }

    var characterCount: Int { MarkdownStatistics.characterCount(in: text) }

    var wordCount: Int { MarkdownStatistics.wordCount(in: text) }

    // MARK: - 文档操作

    func newDocument() {
        text = ""
        baselineText = ""
        documentURL = nil
        documentId = UUID().uuidString
        showStatus("已新建空白文档", kind: .info)
        Log.markdown.info("Created a new blank Markdown document")
    }

    func open(url: URL) {
        do {
            let contents = try MarkdownFileIO.read(from: url)
            text = contents
            baselineText = contents
            documentURL = url
            documentId = UUID().uuidString
            showStatus("已打开 \(url.lastPathComponent)", kind: .success)
            Log.markdown.info("Opened \(url.lastPathComponent, privacy: .public), \(contents.count) characters")
        } catch {
            presentError("无法打开文件：\(error.localizedDescription)")
        }
    }

    func replaceWithClipboardText(_ contents: String) {
        text = contents
        baselineText = ""
        documentURL = nil
        documentId = UUID().uuidString
        showStatus("已从剪贴板载入 \(contents.count) 个字符，尚未保存", kind: .success)
        Log.markdown.info("Loaded \(contents.count) characters from the clipboard")
    }

    func saveToExistingURL() {
        guard let documentURL else {
            presentError("当前文档还没有保存位置，请使用保存面板选择文件。")
            return
        }
        persist(to: documentURL)
    }

    func save(to url: URL) {
        persist(to: url)
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 提示

    func showStatus(_ text: String, kind: Status.Kind = .info) {
        let status = Status(text: text, kind: kind)
        self.status = status
        statusDismissTask?.cancel()
        statusDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            if self?.status?.id == status.id {
                self?.status = nil
            }
        }
    }

    func presentError(_ message: String) {
        Log.markdown.error("\(message, privacy: .public)")
        AppState.shared.flash(message, kind: .error)
        errorMessage = message
    }

    // MARK: - 私有

    private func persist(to url: URL) {
        do {
            try MarkdownFileIO.write(text: text, to: url)
            documentURL = url
            baselineText = text
            showStatus("已保存 \(url.lastPathComponent)", kind: .success)
            Log.markdown.info("Saved \(url.lastPathComponent, privacy: .public), \(self.text.count) characters")
        } catch {
            presentError("保存失败：\(error.localizedDescription)")
        }
    }

    private static func makeConfiguration() -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(
            syntaxHighlighter: HighlightJSBridge(),
            latex: SwiftMathBridge()
        )
        // 给正文留出页面边距，接近 Typora 的纸张观感。
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 20)
        return configuration
    }

    private static let welcomeDocument = #"""
    # 欢迎使用 Kaiming Markdown

    这是一个使用原生 TextKit 2 渲染的 Typora 式编辑器：左边不用写、右边不用看，输入即所得。

    ## 试试这些

    - **加粗**、*斜体*
    - 行内代码 `let value = 42`
    - [链接](https://example.com)
    - 任务列表：
      - [x] 打开 Markdown 窗口
      - [ ] 写下第一条笔记

    ## 代码块

    ```swift
    struct Greeting {
        let message = "你好，开明"
    }
    ```

    ## 表格与公式

    | 功能 | 状态 |
    | --- | --- |
    | 实时渲染 | 已启用 |
    | 代码高亮 | 已启用 |

    行内公式 $E = mc^2$，块公式：

    $$
    \int_0^1 x^2\,dx = \frac{1}{3}
    $$

    > 提示：⌘S 保存；工具栏可以调整字号、从剪贴板载入或复制全文。
    """#
}
