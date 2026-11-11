import AppKit
import SwiftUI

// MARK: - 大纲解析

struct MarkdownHeading: Identifiable, Equatable {
    let id: Int          // source UTF-16 location
    let level: Int
    let title: String
    let location: Int
}

enum MarkdownOutlineParser {
    /// 提取 ATX 标题（# ... ######），跳过 fenced code / 缩进代码 / 4 空格以上缩进。
    static func headings(in text: String) -> [MarkdownHeading] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var headings: [MarkdownHeading] = []
        var offset = 0
        var inFence = false

        while offset < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                offset = NSMaxRange(lineRange)
                if lineRange.length == 0 { break }
                continue
            }

            if !inFence {
                let leadingSpaces = line.prefix { $0 == " " }.count
                if leadingSpaces <= 3, let hashIndex = line.firstIndex(of: "#") {
                    var level = 0
                    var index = hashIndex
                    while index < line.endIndex, line[index] == "#" {
                        level += 1
                        index = line.index(after: index)
                    }
                    let afterHashes = index
                    let hasValidSuffix: Bool = {
                        guard afterHashes < line.endIndex else { return true }
                        let char = line[afterHashes]
                        return char == " " || char == "\t"
                    }()
                    if (1...6).contains(level), hasValidSuffix {
                        var rawTitle = String(line[afterHashes...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        rawTitle = rawTitle.replacingOccurrences(
                            of: #"\s+#+\s*$"#,
                            with: "",
                            options: .regularExpression
                        )
                        rawTitle = rawTitle.replacingOccurrences(
                            of: #"\[([^\]]+)\]\([^)]*\)"#,
                            with: "$1",
                            options: .regularExpression
                        )
                        rawTitle = rawTitle.replacingOccurrences(
                            of: #"[*_`~]"#,
                            with: "",
                            options: .regularExpression
                        )
                        rawTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if rawTitle.isEmpty { rawTitle = "标题" }

                        let prefix = line[line.startIndex..<hashIndex]
                        let location = lineRange.location + prefix.utf16.count
                        headings.append(
                            MarkdownHeading(
                                id: location,
                                level: level,
                                title: rawTitle,
                                location: location
                            )
                        )
                    }
                }
            }

            offset = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        return headings
    }
}

// MARK: - 编辑器滚动

struct MarkdownScrollRequest: Equatable {
    let id = UUID()
    let location: Int
}

@MainActor
enum MarkdownEditorScrolling {
    @discardableResult
    static func scroll(to location: Int, in window: NSWindow) -> Bool {
        guard let textView = findEditableTextView(in: window.contentView) else { return false }
        let length = (textView.string as NSString).length
        let safeLocation = min(max(0, location), length)
        let range = NSRange(location: safeLocation, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        window.makeFirstResponder(textView)
        return true
    }

    static func findEditableTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView, textView.isEditable {
            return textView
        }
        for subview in view.subviews {
            if let found = findEditableTextView(in: subview) {
                return found
            }
        }
        return nil
    }
}

/// 零尺寸探针：收到大纲点击的滚动请求后，找到编辑器 NSTextView 并滚动到源码位置。
struct MarkdownEditorScrollAccessor: NSViewRepresentable {
    let request: MarkdownScrollRequest?

    func makeNSView(context: Context) -> MarkdownEditorScrollHostView {
        let view = MarkdownEditorScrollHostView()
        view.pendingRequest = request
        return view
    }

    func updateNSView(_ nsView: MarkdownEditorScrollHostView, context: Context) {
        nsView.pendingRequest = request
        nsView.applyIfNeeded()
    }
}

final class MarkdownEditorScrollHostView: NSView {
    var pendingRequest: MarkdownScrollRequest?
    private var appliedRequestID: UUID?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    func applyIfNeeded() {
        guard let request = pendingRequest,
              request.id != appliedRequestID,
              let window else { return }
        if MarkdownEditorScrolling.scroll(to: request.location, in: window) {
            appliedRequestID = request.id
        }
    }
}
