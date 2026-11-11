import AppKit
import CryptoKit
import Foundation
import MarkdownEngine
import SwiftUI

// MARK: - 整篇渲染模型

struct MarkdownRenderedDocument {
    var attributedText: NSAttributedString?
    var isLoading: Bool = false
    var errorMessage: String?
    var imageCount: Int = 0
}

/// 整篇「渲染预览」：Markdown → HTML（MarkdownHTMLRenderer）→ NSAttributedString(html:)。
/// HTML 块按原文拼入；图片先解析/下载成本地文件再交给 HTML importer，包含相对/绝对/file:///http(s)。
@MainActor
enum MarkdownRenderedPreviewBuilder {
    private static let maxImageBytes = 20 * 1_048_576
    private static let imageTagRegex = try! NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#)
    private static let srcAttrRegex = try! NSRegularExpression(
        pattern: #"(?is)\bsrc\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
    )
    private static let attributeRegexTemplate = #"(?is)\b%ATTRIBUTE%\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#

    private static var remoteFileCache: [String: URL] = [:]

    static func build(
        markdown: String,
        baseURL: URL?,
        configuration: MarkdownEditorConfiguration
    ) async -> MarkdownRenderedDocument {
        let fragments = composeFragments(markdown: markdown, configuration: configuration)
        let html = fragments.joined(separator: "\n")
        let rewritten = await rewriteImages(in: html, baseURL: baseURL)
        if Task.isCancelled {
            return MarkdownRenderedDocument(isLoading: false, errorMessage: "渲染已取消。")
        }

        let imageCount = imageTagRegex.numberOfMatches(
            in: rewritten,
            range: NSRange(location: 0, length: (rewritten as NSString).length)
        )
        let fullHTML = wrapHTML(rewritten)
        guard let data = fullHTML.data(using: .utf8) else {
            return MarkdownRenderedDocument(isLoading: false, errorMessage: "无法编码渲染 HTML。")
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
            return MarkdownRenderedDocument(
                attributedText: normalized,
                isLoading: false,
                imageCount: imageCount
            )
        } catch {
            return MarkdownRenderedDocument(
                isLoading: false,
                errorMessage: "渲染失败：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Markdown/HTML 组合

    private static func composeFragments(
        markdown: String,
        configuration: MarkdownEditorConfiguration
    ) -> [String] {
        let blocks = MarkdownRichTextParser.htmlBlocks(in: markdown)
        let ns = markdown as NSString
        var fragments: [String] = []
        var cursor = 0

        func appendMarkdownSegment(_ range: NSRange) {
            guard range.length > 0 else { return }
            let segment = ns.substring(with: range)
            let html = MarkdownHTMLRenderer.html(
                from: segment,
                extensions: configuration.extensions,
                directives: configuration.directives,
                directiveSettings: configuration.directiveSettings
            )
            if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fragments.append(html)
            }
        }

        for block in blocks {
            if block.range.location > cursor {
                appendMarkdownSegment(
                    NSRange(location: cursor, length: block.range.location - cursor)
                )
            }
            fragments.append(sanitizeHTMLBlock(block.source))
            cursor = NSMaxRange(block.range)
        }
        if cursor < ns.length {
            appendMarkdownSegment(NSRange(location: cursor, length: ns.length - cursor))
        }
        return fragments
    }

    private static func sanitizeHTMLBlock(_ html: String) -> String {
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
        return result
    }

    // MARK: - 图片

    private static func rewriteImages(in html: String, baseURL: URL?) async -> String {
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = imageTagRegex.matches(in: html, options: [], range: fullRange)
        guard !matches.isEmpty else { return html }

        var resolvedSources: [String: String] = [:]
        var missingSources: Set<String> = []
        for match in matches {
            let tag = ns.substring(with: match.range)
            guard let src = attributeValue("src", in: tag) else { continue }
            if resolvedSources[src] != nil || missingSources.contains(src) { continue }
            if Task.isCancelled { return html }

            switch MarkdownImageResolver.target(for: src, baseDirectory: baseURL) {
            case .local(let url):
                if FileManager.default.fileExists(atPath: url.path) {
                    resolvedSources[src] = url.absoluteString
                } else {
                    missingSources.insert(src)
                }
            case .remote(let url):
                if let cached = remoteFileCache[src],
                   FileManager.default.fileExists(atPath: cached.path) {
                    resolvedSources[src] = cached.absoluteString
                } else if let local = await downloadRemoteImage(url) {
                    remoteFileCache[src] = local
                    resolvedSources[src] = local.absoluteString
                } else {
                    missingSources.insert(src)
                }
            case .none:
                missingSources.insert(src)
            }
        }

        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            let tag = ns.substring(with: match.range)
            guard let src = attributeValue("src", in: tag) else { continue }
            if let replacement = resolvedSources[src] {
                let newTag = replaceAttribute("src", with: replacement, in: tag)
                mutable.replaceCharacters(in: match.range, with: newTag)
            } else if missingSources.contains(src) {
                let alt = attributeValue("alt", in: tag) ?? "图片"
                mutable.replaceCharacters(
                    in: match.range,
                    with: "<span>[\(escapeHTML(alt))]</span>"
                )
            }
        }
        return mutable as String
    }

    private static func downloadRemoteImage(_ url: URL) async -> URL? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= maxImageBytes,
              let http = response as? HTTPURLResponse,
              (200...399).contains(http.statusCode) else {
            return nil
        }

        // 预览图片是临时资源：优先临时目录（受限沙盒/CI 也可写），失败再退回 Caches。
        var directories: [URL] = [
            FileManager.default.temporaryDirectory
                .appendingPathComponent("KaimingRenderedPreview", isDirectory: true)
        ]
        if let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Kaiming/RenderedPreview", isDirectory: true) {
            directories.append(caches)
        }

        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        for directory in directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("\(digest).\(ext)")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
            do {
                try data.write(to: fileURL, options: .atomic)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    return fileURL
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        let pattern = attributeRegexTemplate.replacingOccurrences(of: "%ATTRIBUTE%", with: name)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        if match.range(at: 2).location != NSNotFound {
            return ns.substring(with: match.range(at: 2))
        }
        if match.range(at: 3).location != NSNotFound {
            return ns.substring(with: match.range(at: 3))
        }
        if match.range(at: 4).location != NSNotFound {
            return ns.substring(with: match.range(at: 4))
        }
        return nil
    }

    private static func replaceAttribute(_ name: String, with value: String, in tag: String) -> String {
        guard let regex = srcAttrRegex.firstMatch(
            in: tag,
            options: [],
            range: NSRange(location: 0, length: (tag as NSString).length)
        ) else {
            return tag
        }
        let mutable = NSMutableString(string: tag)
        mutable.replaceCharacters(in: regex.range, with: "\(name)=\"\(escapeHTML(value))\"")
        return mutable as String
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - 外观

    private static func wrapHTML(_ body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; font-size: 14px; line-height: 1.55; }
        h1 { font-size: 26px; margin: 18px 0 10px; }
        h2 { font-size: 21px; margin: 16px 0 8px; }
        h3 { font-size: 18px; margin: 14px 0 6px; }
        h4, h5, h6 { font-size: 15px; margin: 12px 0 6px; }
        p { margin: 8px 0; }
        pre { font-family: Menlo, monospace; font-size: 12px; padding: 8px; }
        code { font-family: Menlo, monospace; font-size: 12px; }
        a { color: #4aa3ff; text-decoration: underline; }
        img { max-width: 100%; }
        blockquote { color: #888888; border-left: 3px solid #888888; padding-left: 10px; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #888888; padding: 4px 8px; }
        </style></head><body>\(body)</body></html>
        """
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
                string.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: range)
            }
        }
        string.addAttribute(.backgroundColor, value: NSColor.clear, range: fullRange)

        let maxImageWidth: CGFloat = 720
        string.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var bounds = attachment.bounds
            if bounds.width > maxImageWidth {
                let scale = maxImageWidth / bounds.width
                bounds.size = NSSize(width: maxImageWidth, height: bounds.height * scale)
                attachment.bounds = bounds
            }
        }
    }
}

// MARK: - 渲染预览界面

struct MarkdownRenderedPreviewView: View {
    let document: MarkdownRenderedDocument
    let sourceName: String
    let onRefresh: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("渲染预览")
                .font(.system(size: 12, weight: .semibold))

            Text("只读")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )

            Text(sourceName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if document.imageCount > 0 {
                Text("\(document.imageCount) 张图片")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if document.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            iconButton("arrow.clockwise", help: "重新渲染预览", action: onRefresh)
            iconButton("xmark", help: "关闭渲染预览，返回编辑器", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .zIndex(20)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .markdownTooltip(help, alignment: .bottomTrailing)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var content: some View {
        if document.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在渲染 HTML 与图片…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = document.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let attributedText = document.attributedText {
            MarkdownAttributedTextView(attributedText: attributedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("没有可渲染内容。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
