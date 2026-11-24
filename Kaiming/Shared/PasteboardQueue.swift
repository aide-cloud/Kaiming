import Foundation

/// 全局唯一的剪贴板访问队列。
///
/// 项目约束（规格第六节 #4）：所有 `NSPasteboard` 读写必须串行化，禁止并发访问。
/// 截图、剪贴板、Markdown 三个模块都必须通过本队列访问剪贴板，
/// 不允许各自持有独立队列（各自队列仍可能跨模块并发）。
enum PasteboardQueue {
    static let serial = DispatchQueue(label: "com.kaiming.pasteboard", qos: .userInitiated)
}
