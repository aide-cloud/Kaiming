import AppKit
import Foundation

/// Markdown 模块专用的剪贴板访问通道。
///
/// 项目全局约束：所有 `NSPasteboard` 读写必须串行化到专用队列，
/// 主线程只接收最终结果。这里使用 `withCheckedContinuation` 把队列结果
/// 安全地送回调用方（`String` / `Bool` 都是 `Sendable`）。
enum MarkdownPasteboard {
    /// 全局唯一剪贴板串行队列（见 Shared/PasteboardQueue.swift）。
    private static let queue = PasteboardQueue.serial

    /// 在专用队列读取当前剪贴板文本；非文本内容返回 `nil`。
    static func readString() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let string = NSPasteboard.general.string(forType: .string)
                continuation.resume(returning: string)
            }
        }
    }

    /// 在专用队列写入纯文本，返回是否成功。
    static func write(_ string: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let succeeded = pasteboard.setString(string, forType: .string)
                continuation.resume(returning: succeeded)
            }
        }
    }
}
