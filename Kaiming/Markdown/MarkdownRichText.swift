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

struct MarkdownHTMLPreview: Identifiable {
    let id: Int
    let tagName: String
    let sourceLength: Int
    let attributedText: NSAttributedString?
    let errorMessage: String?

    var displayHeight: CGFloat {
        guard let attributedText else { return 72 }
        let bounds = attributedText.boundingRect(
            with: NSSize(width: 292, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return min(max(bounds.height + 20, 64), 280)
    }
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
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)https?://[^\s<>"')\]}]+"#
    )
    private static let tagNameRegex = try! NSRegularExpression(
        pattern: #"(?is)^<\s*([a-z0-9]+)"#
    )
    private static let imageLinkRegex = try! NSRegularExpression(
        pattern: #"(?is)!\[[^\]]*\]\([^)]*\)"#
    )

    /// 文档中的 HTML 块（限制数量与大小，避免对超长文档做昂贵渲染）。
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
            guard blocks.count < 10 else { break }
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

    /// 文档中的 http(s) 链接（去重，最多 12 个）。
    static func externalLinks(in text: String) -> [URL] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard fullRange.length > 0 else { return [] }
        let codeRanges = fencedCodeRanges(in: ns)

        var imageRanges: [NSRange] = []
        imageLinkRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            if let match { imageRanges.append(match.range) }
        }

        var seen = Set<String>()
        var urls: [URL] = []
        urlRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, urls.count < 12 else { return }
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            // 图片目标不是“链接卡片”意义上的链接，避免为远程图片生成空卡片。
            guard !imageRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }

            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,;:!?)]}'\"".contains(last) {
                raw.removeLast()
            }
            guard !raw.isEmpty, let url = URL(string: raw) else { return }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return }
            urls.append(url)
        }
        return urls
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

// MARK: - HTML 原生渲染

enum MarkdownHTMLPreviewRenderer {
    static func render(block: MarkdownHTMLBlock, baseURL: URL?) -> MarkdownHTMLPreview {
        let sanitized = sanitize(block.source)
        guard let data = sanitized.data(using: .utf8) else {
            return MarkdownHTMLPreview(
                id: block.id, tagName: block.tagName, sourceLength: block.source.count,
                attributedText: nil, errorMessage: "无法编码这段 HTML。"
            )
        }

        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let baseURL {
            options[.baseURL] = baseURL
        }

        do {
            let rendered = try NSAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            )
            let normalized = NSMutableAttributedString(attributedString: rendered)
            normalizeForAppearance(normalized)
            return MarkdownHTMLPreview(
                id: block.id, tagName: block.tagName, sourceLength: block.source.count,
                attributedText: normalized, errorMessage: nil
            )
        } catch {
            return MarkdownHTMLPreview(
                id: block.id, tagName: block.tagName, sourceLength: block.source.count,
                attributedText: nil, errorMessage: "HTML 解析失败：\(error.localizedDescription)"
            )
        }
    }

    private static func sanitize(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "iframe", "object", "embed"] {
            result = result.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                with: "",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: #"(?i)\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: .regularExpression
        )
        // 远程图片不走 HTML importer 的同步网络加载；保留可读占位文字。
        result = result.replacingOccurrences(
            of: #"(?is)<img\b[^>]*\bsrc\s*=\s*("|')https?://[^"']*\1[^>]*>"#,
            with: #"<span>[远程图片已省略]</span>"#,
            options: .regularExpression
        )
        return result
    }

    private static func normalizeForAppearance(_ string: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: string.length)
        guard fullRange.length > 0 else { return }

        string.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            if value != nil {
                string.addAttributes(
                    [
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            } else {
                string.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        string.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                string.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range)
            }
        }
        string.addAttribute(.backgroundColor, value: NSColor.clear, range: fullRange)
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
