import AppKit
import CryptoKit
import Foundation
import MarkdownEngine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 整篇渲染模型

/// 整篇「渲染预览」的结果：一份自包含 HTML 文档，交给 WKWebView 真实排版。
///
/// `attributedText` 仅用于向后兼容旧调用点，WebView 预览不再生成富文本。
struct MarkdownRenderedDocument {
    var attributedText: NSAttributedString?
    var isLoading: Bool = false
    var errorMessage: String?
    var imageCount: Int = 0
    /// 完整 HTML（内联 CSS / Mermaid / highlight.js，图片为 data: URL）。
    var html: String?
    /// 文档所在目录，供相对链接解析。
    var baseURL: URL?
    /// 成功转换的 Mermaid 图形数量。
    var mermaidDiagramCount: Int = 0
    /// Markdown 标题锚点 id（顺序与 Markdown 渲染出的 h1-h6 一致；原始 HTML 块中的标题不参与）。
    var headingAnchorIDs: [String] = []
}

/// 「内容导航」点击标题时，让 WebView 预览滚到对应锚点的一次性请求。
///
/// 每次点击新建一个实例即可（`id` 是 UUID，变化即触发一次滚动）：
/// ```swift
/// MarkdownWebScrollRequest(headingIndex: index)
/// // 或
/// MarkdownWebScrollRequest(headingID: document.headingAnchorIDs[index])
/// ```
struct MarkdownWebScrollRequest: Equatable, Identifiable {
    let id: UUID
    let headingID: String

    init(id: UUID = UUID(), headingID: String) {
        self.id = id
        self.headingID = headingID
    }

    init(id: UUID = UUID(), headingIndex: Int) {
        self.id = id
        self.headingID = Self.headingID(for: headingIndex)
    }

    static func headingID(for index: Int) -> String {
        "kaiming-heading-\(max(0, index))"
    }
}

// MARK: - 渲染构建器

/// Markdown → 完整 HTML（WebView 预览 / PDF 导出共用）。
///
/// 处理流程：
/// 1. 原文按 HTML 块切分，Markdown 段交给 `MarkdownHTMLRenderer`；
/// 2. HTML 块沿用旧的 sanitize（去 script/style/iframe/object/embed 与 on* 事件）；
/// 3. ```mermaid 围栏转成图形容器（页面加载后由随包 mermaid.min.js 渲染）；
/// 4. 图片（相对/绝对/file:///http）解析为本地文件后内联成 `data:` URL，离线可用；
/// 5. 拼装 GitHub 风格 HTML 文档。
@MainActor
enum MarkdownRenderedPreviewBuilder {
    /// 单张图片内联上限（原图字节）。超过时显示占位提示，避免把几十 MB 塞进 WebView。
    private static let maxInlineImageBytes = 20 * 1_048_576
    private static let imageTagRegex = try! NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#)
    private static let srcAttrRegex = try! NSRegularExpression(
        pattern: #"(?is)\bsrc\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
    )
    private static let attributeRegexTemplate = #"(?is)\b%ATTRIBUTE%\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#

    private static var remoteFileCache: [String: URL] = [:]

    // MARK: 公开入口

    /// 向后兼容的旧签名（`MarkdownWindowView` 当前调用）。
    static func build(
        markdown: String,
        baseURL: URL?,
        configuration: MarkdownEditorConfiguration
    ) async -> MarkdownRenderedDocument {
        await build(
            markdown: markdown,
            baseURL: baseURL,
            configuration: configuration,
            options: MarkdownWebDocumentOptions()
        )
    }

    /// 带展示选项的构建入口：预览跟随设置的主题/字号/页宽，PDF 用 `isPrint`。
    static func build(
        markdown: String,
        baseURL: URL?,
        configuration: MarkdownEditorConfiguration,
        options: MarkdownWebDocumentOptions
    ) async -> MarkdownRenderedDocument {
        do {
            let content = try await buildContent(
                markdown: markdown,
                baseURL: baseURL,
                configuration: configuration,
                options: options
            )
            return MarkdownRenderedDocument(
                isLoading: false,
                imageCount: content.imageCount,
                html: content.html,
                baseURL: baseURL,
                mermaidDiagramCount: content.mermaidCount,
                headingAnchorIDs: content.headingAnchorIDs
            )
        } catch is CancellationError {
            return MarkdownRenderedDocument(isLoading: false, errorMessage: "渲染已取消。")
        } catch {
            return MarkdownRenderedDocument(
                isLoading: false,
                errorMessage: "渲染失败：\(error.localizedDescription)"
            )
        }
    }

    /// 只产出 HTML 字符串；PDF 导出直接复用，不依赖预览窗口是否打开。
    static func buildHTML(
        markdown: String,
        baseURL: URL?,
        configuration: MarkdownEditorConfiguration,
        options: MarkdownWebDocumentOptions
    ) async throws -> String {
        try await buildContent(
            markdown: markdown,
            baseURL: baseURL,
            configuration: configuration,
            options: options
        ).html
    }

    private struct Content {
        let html: String
        let imageCount: Int
        let mermaidCount: Int
        let headingAnchorIDs: [String]
    }

    private static func buildContent(
        markdown: String,
        baseURL: URL?,
        configuration: MarkdownEditorConfiguration,
        options: MarkdownWebDocumentOptions
    ) async throws -> Content {
        let composed = composeFragments(markdown: markdown, configuration: configuration)
        var body = MarkdownWebDocumentBuilder.transformMermaidFences(
            in: composed.fragments.joined(separator: "\n")
        )
        let rewritten = await rewriteImages(
            in: body,
            baseURL: baseURL,
            inlineRemoteImages: options.inlineRemoteImages
        )
        body = rewritten.html
        if Task.isCancelled { throw CancellationError() }
        let html = MarkdownWebDocumentBuilder.document(bodyHTML: body, options: options)
        return Content(
            html: html,
            imageCount: rewritten.imageCount,
            mermaidCount: MarkdownWebDocumentBuilder.mermaidFigureCount(in: body),
            headingAnchorIDs: composed.headingAnchorIDs
        )
    }

    // MARK: - Markdown/HTML 组合

    private struct ComposedBody {
        let fragments: [String]
        let headingAnchorIDs: [String]
    }

    private static let headingTagRegex = try? NSRegularExpression(
        pattern: #"(?is)<h([1-6])(\s[^>]*)?>"#
    )
    private static let idAttributeRegex = try? NSRegularExpression(
        pattern: #"(?is)\bid\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
    )

    private static func composeFragments(
        markdown: String,
        configuration: MarkdownEditorConfiguration
    ) -> ComposedBody {
        let blocks = MarkdownRichTextParser.htmlBlocks(in: markdown)
        let ns = markdown as NSString
        var fragments: [String] = []
        var headingAnchorIDs: [String] = []
        var headingIndex = 0
        var cursor = 0

        func appendMarkdownSegment(_ range: NSRange) {
            guard range.length > 0 else { return }
            let segment = ns.substring(with: range)
            let rendered = MarkdownHTMLRenderer.html(
                from: segment,
                extensions: configuration.extensions,
                directives: configuration.directives,
                directiveSettings: configuration.directiveSettings
            )
            // 只给 Markdown 段落渲染出的标题加锚点；原始 HTML 块（下面直接 append）不参与编号。
            let html = addHeadingAnchors(
                to: rendered,
                nextIndex: &headingIndex,
                collected: &headingAnchorIDs
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
        return ComposedBody(fragments: fragments, headingAnchorIDs: headingAnchorIDs)
    }

    /// 给一段 Markdown 渲染 HTML 的 h1-h6 顺序补 `id="kaiming-heading-N"`。
    ///
    /// 原始 HTML 块不经过这里，因此不会占用编号，内容导航的序号与 Markdown 标题一致。
    private static func addHeadingAnchors(
        to html: String,
        nextIndex: inout Int,
        collected: inout [String]
    ) -> String {
        guard let regex = headingTagRegex else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var replacements: [(range: NSRange, tag: String)] = []
        for match in matches {
            let level = ns.substring(with: match.range(at: 1))
            let attributes = match.range(at: 2).location == NSNotFound
                ? ""
                : ns.substring(with: match.range(at: 2))
            if let existing = existingID(in: attributes) {
                // 渲染器已带 id（极少见）：保留并记录，编号仍然前进，保证后续序号不串位。
                collected.append(existing)
                nextIndex += 1
                continue
            }
            let anchorID = "kaiming-heading-\(nextIndex)"
            nextIndex += 1
            collected.append(anchorID)
            replacements.append((match.range, "<h\(level) id=\"\(anchorID)\"\(attributes)>"))
        }
        guard !replacements.isEmpty else { return html }
        let mutable = NSMutableString(string: html)
        for replacement in replacements.reversed() {
            mutable.replaceCharacters(in: replacement.range, with: replacement.tag)
        }
        return mutable as String
    }

    private static func existingID(in attributes: String) -> String? {
        guard let regex = idAttributeRegex else { return nil }
        let ns = attributes as NSString
        guard let match = regex.firstMatch(
            in: attributes,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        for group in [2, 3, 4] where match.range(at: group).location != NSNotFound {
            return ns.substring(with: match.range(at: group))
        }
        return nil
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

    private enum ImageDataResult: Sendable {
        case success(String)
        case tooLarge
        case unreadable
    }

    private struct RemoteImageRequest: Sendable {
        let src: String
        let url: URL
        let alt: String
    }

    /// 图片改写：
    /// - `inlineRemoteImages == false`（预览）：远程图保留原始 https URL 作为 `src`，
    ///   交给 WKWebView 并行加载；本地图仍然内联成 `data:` URL。构建不会被网络阻塞。
    /// - `inlineRemoteImages == true`（PDF）：远程图有界并发（≤6）下载后内联，
    ///   每张超时 6s，整批总预算约 10s，失败/超时仍用占位提示。
    private static func rewriteImages(
        in html: String,
        baseURL: URL?,
        inlineRemoteImages: Bool
    ) async -> (html: String, imageCount: Int) {
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = imageTagRegex.matches(in: html, options: [], range: fullRange)
        guard !matches.isEmpty else { return (html, 0) }

        var resolvedSources: [String: String] = [:]
        var placeholders: [String: String] = [:]
        var remoteRequests: [RemoteImageRequest] = []
        var seenSources: Set<String> = []

        for match in matches {
            let tag = ns.substring(with: match.range)
            guard let rawSrc = attributeValue("src", in: tag) else { continue }
            // MarkdownHTMLRenderer 会把图片 title 一起塞进 src 并转义成 HTML 实体
            // （`diagram.png &quot;标题&quot;`）；先还原成原文再交给解析器。
            let src = decodeHTMLEntities(rawSrc)
            guard seenSources.insert(src).inserted else { continue }
            if Task.isCancelled { return (html, 0) }

            let alt = decodeHTMLEntities(attributeValue("alt", in: tag) ?? "图片")
            switch MarkdownImageResolver.target(for: src, baseDirectory: baseURL) {
            case .local(let url):
                switch await loadImageDataURL(for: url) {
                case .success(let dataURL):
                    resolvedSources[src] = dataURL
                case .tooLarge:
                    placeholders[src] = missingImageHTML("[图片过大，未内嵌：\(alt)]")
                case .unreadable:
                    placeholders[src] = missingImageHTML("[图片无法加载：\(alt)]")
                }
            case .remote(let url):
                if inlineRemoteImages {
                    remoteRequests.append(RemoteImageRequest(src: src, url: url, alt: alt))
                } else {
                    // 保留原始 URL（替换 src 属性时统一做 HTML 转义）。
                    resolvedSources[src] = src
                }
            case .none:
                placeholders[src] = missingImageHTML("[图片无法加载：\(alt)]")
            }
        }

        if !remoteRequests.isEmpty {
            let results = await inlineRemoteImagesConcurrently(remoteRequests)
            for request in remoteRequests {
                guard let result = results[request.src] else { continue }
                switch result {
                case .success(let dataURL):
                    resolvedSources[request.src] = dataURL
                case .tooLarge:
                    placeholders[request.src] = missingImageHTML("[远程图片过大，未内嵌：\(request.alt)]")
                case .unreadable:
                    placeholders[request.src] = missingImageHTML("[远程图片无法加载：\(request.alt)]")
                }
            }
        }

        let mutable = NSMutableString(string: html)
        var imageCount = 0
        for match in matches.reversed() {
            let tag = ns.substring(with: match.range)
            guard let rawSrc = attributeValue("src", in: tag) else { continue }
            let src = decodeHTMLEntities(rawSrc)
            if let replacement = resolvedSources[src] {
                mutable.replaceCharacters(
                    in: match.range,
                    with: replaceAttribute("src", with: replacement, in: tag)
                )
                imageCount += 1
            } else if let placeholder = placeholders[src] {
                mutable.replaceCharacters(in: match.range, with: placeholder)
            }
        }
        return (mutable as String, imageCount)
    }

    /// 远程图有界并发内联：上限 6 张同时下载，整批约 10s 预算，单张最多 6s。
    private static func inlineRemoteImagesConcurrently(
        _ requests: [RemoteImageRequest]
    ) async -> [String: ImageDataResult] {
        let maxConcurrent = 6
        let deadline = Date().addingTimeInterval(10)
        var results: [String: ImageDataResult] = [:]
        var iterator = requests.makeIterator()

        await withTaskGroup(of: (String, ImageDataResult).self) { group in
            var active = 0
            while active < maxConcurrent, let request = iterator.next() {
                group.addTask { await inlineRemoteImage(request, deadline: deadline) }
                active += 1
            }
            while let (src, result) = await group.next() {
                results[src] = result
                active -= 1
                if let next = iterator.next() {
                    group.addTask { await inlineRemoteImage(next, deadline: deadline) }
                    active += 1
                }
            }
        }
        return results
    }

    private static func inlineRemoteImage(
        _ request: RemoteImageRequest,
        deadline: Date
    ) async -> (String, ImageDataResult) {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.1 else {
            return (request.src, .unreadable)
        }
        if let cached = remoteFileCache[request.src],
           FileManager.default.fileExists(atPath: cached.path),
           case .success(let dataURL) = await loadImageDataURL(for: cached) {
            return (request.src, .success(dataURL))
        }
        let timeout = min(6, remaining)
        guard let local = await downloadRemoteImage(request.url, timeout: timeout) else {
            return (request.src, .unreadable)
        }
        remoteFileCache[request.src] = local
        let result = await loadImageDataURL(for: local)
        return (request.src, result)
    }

    private static func loadImageDataURL(for url: URL) async -> ImageDataResult {
        let limit = maxInlineImageBytes
        return await Task.detached(priority: .userInitiated) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                Log.markdown.error("Inline image unreadable: \(url.path, privacy: .public)")
                return .unreadable
            }
            guard data.count <= limit else {
                Log.markdown.error("Inline image too large: \(url.path, privacy: .public) (\(data.count) bytes)")
                return .tooLarge
            }
            // 缓存文件扩展名可能不可靠（例如把 SVG 存成 .png），MIME 以真实内容优先。
            let mime = sniffMIMEType(data) ?? mimeType(forExtension: url.pathExtension)
            return .success("data:\(mime);base64,\(data.base64EncodedString())")
        }.value
    }

    // MARK: - MIME / 内容嗅探

    /// 常见图片魔数 + SVG 文本嗅探。无法识别时返回 nil。
    ///
    /// SVG 没有稳定魔数：只在前 4 KB 文本里找 `<svg`，且必须先通过二进制图片的魔数判断，
    /// 避免把 PNG/JPEG 误判成文本。
    nonisolated private static func sniffMIMEType(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(512))
        if bytes.count >= 8,
           bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 4,
           bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "image/gif"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "image/webp"
        }
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self).lowercased()
            if brand == "avif" || brand == "avis" {
                return "image/avif"
            }
            if brand == "heic" || brand == "heix" || brand == "mif1" || brand == "msf1" {
                return "image/heic"
            }
        }
        if bytes.count >= 4,
           (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A) {
            return "image/tiff"
        }
        if bytes.count >= 4,
           bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01, bytes[3] == 0x00 {
            return "image/x-icon"
        }

        // SVG / XML（允许 XML 声明、注释、DOCTYPE 在 <svg> 之前）。
        let head = data.prefix(4096)
        let text = String(decoding: head, as: UTF8.self)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        let hasTextPrefix = lowered.hasPrefix("<?xml")
            || lowered.hasPrefix("<svg")
            || lowered.hasPrefix("<!doctype")
            || lowered.hasPrefix("<!--")
        if hasTextPrefix, lowered.contains("<svg") {
            return "image/svg+xml"
        }
        return nil
    }

    /// 只接受 `image/*` 的 Content-Type（去掉 charset 等参数）。
    nonisolated private static func normalizedMIMEType(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        if let separator = value.firstIndex(of: ";") {
            value = String(value[..<separator]).trimmingCharacters(in: .whitespaces)
        }
        return value.hasPrefix("image/") ? value : nil
    }

    nonisolated private static func mimeType(forExtension pathExtension: String) -> String {
        if !pathExtension.isEmpty,
           let type = UTType(filenameExtension: pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "image/png"
    }

    nonisolated private static func fileExtension(forMIMEType mimeType: String) -> String? {
        switch mimeType.lowercased() {
        case "image/svg+xml": return "svg"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg", "image/pjpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/avif": return "avif"
        case "image/heic", "image/heif": return "heic"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        case "image/x-icon", "image/vnd.microsoft.icon": return "ico"
        default: return nil
        }
    }

    /// 旧缓存文件是否仍是可用图片：内容嗅探优先，无法嗅探的格式看扩展名。
    private static func isUsableCachedImage(at url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 4096)) ?? Data()
        if sniffMIMEType(prefix) != nil { return true }
        return knownImageExtensions.contains(url.pathExtension.lowercased())
    }

    private static let knownImageExtensions = [
        "png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "heic", "bmp", "tiff", "ico"
    ]

    private static func missingImageHTML(_ text: String) -> String {
        "<span class=\"kaiming-missing-image\">\(escapeHTML(text))</span>"
    }

    /// 任务级超时包一层：URLSession 的 timeout 是空闲超时，不能保证整体 6s 内返回。
    private static func downloadRemoteImage(_ url: URL, timeout: TimeInterval) async -> URL? {
        let safeTimeout = max(timeout, 0.5)
        return await withTaskGroup(of: URL?.self) { group in
            group.addTask { await fetchRemoteImage(url, timeout: safeTimeout) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(safeTimeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// 下载远程图片并按真实内容写入缓存；成功后返回本地文件 URL。
    private static func fetchRemoteImage(_ url: URL, timeout: TimeInterval) async -> URL? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= maxInlineImageBytes,
              let http = response as? HTTPURLResponse,
              (200...399).contains(http.statusCode) else {
            return nil
        }

        // 扩展名/MIME 以真实内容优先，其次响应 Content-Type，最后才看 URL 扩展名。
        // `.../svg?repos=...` 这类没有扩展名的 URL 靠这一步得到 image/svg+xml + .svg。
        let mime = sniffMIMEType(data)
            ?? normalizedMIMEType(http.mimeType)
            ?? mimeType(forExtension: url.pathExtension)
        let ext = fileExtension(forMIMEType: mime)
            ?? (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())

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

        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        for directory in directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("\(digest).\(ext)")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if isUsableCachedImage(at: fileURL) {
                    return fileURL
                }
                // 损坏/内容不符：删掉重写。
                try? FileManager.default.removeItem(at: fileURL)
            }
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                continue
            }
            // 自愈：同一 URL 的旧缓存可能因为旧的扩展名推断被存成 .png（实际是 SVG）。
            // 新文件已正确落盘后，清掉同 digest 的其它扩展名文件。
            for legacyExtension in knownImageExtensions where legacyExtension != ext {
                let legacyURL = directory.appendingPathComponent("\(digest).\(legacyExtension)")
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    try? FileManager.default.removeItem(at: legacyURL)
                }
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
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

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - 渲染预览界面

/// 整篇「渲染预览」：WKWebView 真实排版 HTML / Mermaid，可导出 PDF。
///
/// 旧的 `attributedText` 参数保留为兜底路径（外部手动构造 document 时），
/// 正常构建的 document 一律走 `html`。
struct MarkdownRenderedPreviewView: View {
    let document: MarkdownRenderedDocument
    let sourceName: String
    let onRefresh: () -> Void
    let onClose: () -> Void
    /// 附加参数都有默认值，Lead 的旧调用点无需改动。
    var baseURL: URL? = nil
    var pageWidth: MarkdownPageWidth = .standard
    var fontSize: CGFloat = 14
    /// 提供后标题栏显示「导出 PDF」按钮；由窗口层接线（不依赖预览是否打开）。
    var onExportPDF: (() -> Void)? = nil
    /// 内容导航点击标题时传入；文档尚未加载完成也会保存为 pending，加载后自动生效。
    var scrollRequest: MarkdownWebScrollRequest? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: MarkdownGitHubTheme.canvas))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("渲染预览")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            badge("只读")
                .fixedSize(horizontal: true, vertical: false)

            Text(sourceName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if document.mermaidDiagramCount > 0 {
                Text("\(document.mermaidDiagramCount) 图表")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if document.imageCount > 0 {
                Text("\(document.imageCount) 图")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if document.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            if let onExportPDF {
                iconButton("square.and.arrow.down", help: "导出 PDF…", action: onExportPDF)
            }
            iconButton("arrow.clockwise", help: "重新渲染预览", action: onRefresh)
            iconButton("xmark", help: "关闭渲染预览，返回编辑器", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .zIndex(20)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
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
                Text("正在渲染 HTML、Mermaid 与图片…")
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
        } else if let html = document.html {
            MarkdownWebPreviewView(
                html: html,
                baseURL: document.baseURL ?? baseURL,
                pageWidth: pageWidth,
                fontSize: fontSize,
                scrollRequest: scrollRequest
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let attributedText = document.attributedText {
            // 兼容外部手动构造的旧 document（不经过 Builder）。
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
