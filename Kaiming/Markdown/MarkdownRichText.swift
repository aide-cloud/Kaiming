import AppKit
import Foundation
import SwiftUI

// MARK: - 解析

struct MarkdownHTMLBlock: Identifiable, Equatable {
    let id: Int
    let tagName: String
    let source: String
    let range: NSRange
}

enum MarkdownRichTextParser {
    private static let pairedTagRegex = try! NSRegularExpression(
        pattern: #"(?is)<(div|p|details|summary|ul|ol|li|table|thead|tbody|tr|td|th|blockquote|h[1-6]|section|article|figure|figcaption|pre|dl|dt|dd|center)\b[^>]*>.*?</\1\s*>"#
    )
    private static let anchorRegex = try! NSRegularExpression(
        pattern: #"(?is)<a\b[^>]*>.*?</a\s*>"#
    )
    private static let voidRegex = try! NSRegularExpression(
        pattern: #"(?is)<(?:img|br|hr)\b[^>]*/?>"#
    )
    private static let tagNameRegex = try! NSRegularExpression(
        pattern: #"(?is)^<\s*([a-z0-9]+)"#
    )

    /// 文档中的 HTML 块（限制单块大小与总数量，避免对超长文档做昂贵渲染）。
    ///
    /// 上限从 10 提到 64：README 里每个 shields 徽章 `<img>` 都算一个块，
    /// 旧上限会让排在后面的合法 HTML 块（例如 Star 趋势 `<p>`）被当作
    /// Markdown 文本转义输出。
    static func htmlBlocks(in text: String) -> [MarkdownHTMLBlock] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard fullRange.length > 0 else { return [] }

        let codeRanges = fencedCodeRanges(in: ns)
        var candidates: [(range: NSRange, source: String, tag: String)] = []

        for regex in [pairedTagRegex, anchorRegex, voidRegex] {
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                let range = match.range
                guard range.length > 0, range.length <= 100_000 else { return }
                guard !codeRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
                let source = ns.substring(with: range)
                candidates.append((range, source, firstTagName(in: source)))
            }
        }

        // 先按位置、再按长度排序；重叠时保留先出现（通常更大）的块。
        candidates.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length > $1.range.length
        }

        var blocks: [MarkdownHTMLBlock] = []
        var occupied: [NSRange] = []
        for candidate in candidates {
            guard blocks.count < 64 else { break }
            guard !occupied.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) else { continue }
            occupied.append(candidate.range)
            blocks.append(
                MarkdownHTMLBlock(
                    id: candidate.range.location,
                    tagName: candidate.tag,
                    source: candidate.source,
                    range: candidate.range
                )
            )
        }
        return blocks
    }

    // MARK: - 私有

    private static func firstTagName(in source: String) -> String {
        let range = NSRange(location: 0, length: (source as NSString).length)
        guard let match = tagNameRegex.firstMatch(in: source, range: range),
              match.numberOfRanges > 1 else { return "html" }
        return (source as NSString).substring(with: match.range(at: 1)).lowercased()
    }

    private static func fencedCodeRanges(in ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var fenceStart: Int?
        var offset = 0
        while offset < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let isFence = line.hasPrefix("```") || line.hasPrefix("~~~")
            if isFence {
                if let start = fenceStart {
                    ranges.append(NSRange(location: start, length: NSMaxRange(lineRange) - start))
                    fenceStart = nil
                } else {
                    fenceStart = lineRange.location
                }
            }
            offset = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        if let start = fenceStart {
            ranges.append(NSRange(location: start, length: ns.length - start))
        }
        return ranges
    }
}

// MARK: - 只读富文本视图

struct MarkdownAttributedTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 10, height: 8)
            textView.delegate = context.coordinator
            textView.textStorage?.setAttributedString(attributedText)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.textStorage?.isEqual(to: attributedText) != true {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            }
            if let string = link as? String, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }
    }
}
