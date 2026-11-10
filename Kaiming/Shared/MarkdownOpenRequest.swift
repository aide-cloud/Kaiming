import Foundation
import Combine

/// 外部打开 Markdown 目录/文件的请求通道。
///
/// 来源：应用中心「打开目录…」、CLI `kaiming ./docs`（经 `kaiming://` URL scheme）。
/// 由 `MarkdownWindowView` 消费；不包含 Markdown 模块类型，保持模块边界。
@MainActor
final class MarkdownOpenRequest: ObservableObject {
    struct Request: Equatable, Identifiable {
        let id = UUID()
        let folder: URL
        var file: URL?
    }

    static let shared = MarkdownOpenRequest()

    @Published private(set) var request: Request?

    private init() {}

    func open(folder: URL, file: URL? = nil) {
        request = Request(folder: folder, file: file)
        Log.markdown.info(
            "External folder open requested: \(folder.path, privacy: .public) file=\(file?.lastPathComponent ?? "-", privacy: .public)"
        )
    }

    /// 消费一次请求（Markdown 窗口处理完后调用）。
    func consume() -> Request? {
        defer { request = nil }
        return request
    }
}
