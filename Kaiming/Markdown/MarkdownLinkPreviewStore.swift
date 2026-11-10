import AppKit
import Foundation

// MARK: - 卡片模型

struct MarkdownLinkCard: Identifiable {
    let url: URL
    var title: String?
    var description: String?
    var icon: NSImage?
    var isLoading: Bool
    var errorMessage: String?

    var id: String { url.absoluteString }

    var domain: String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }
}

/// 文档内 http(s) 链接的原生预览卡片缓存。
///
/// 只在 inspector 可见时通过 `update(urls:)` 触发网络请求；元数据在内存中
/// 缓存 30 分钟，失败保留域名/URL 占位，不阻塞编辑。
@MainActor
final class MarkdownLinkPreviewStore: ObservableObject {
    @Published private(set) var cards: [MarkdownLinkCard] = []

    private struct CacheEntry {
        let metadata: MarkdownLinkMetadata
        let icon: NSImage?
        let date: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let cacheLifetime: TimeInterval = 30 * 60

    func update(urls: [URL]) {
        var unique: [URL] = []
        var seen = Set<String>()
        for url in urls where seen.insert(url.absoluteString).inserted {
            unique.append(url)
            if unique.count >= 12 { break }
        }

        var next: [MarkdownLinkCard] = []
        for url in unique {
            let key = url.absoluteString
            if let entry = cache[key], Date().timeIntervalSince(entry.date) < cacheLifetime {
                next.append(card(for: url, metadata: entry.metadata, icon: entry.icon, isLoading: false))
                continue
            }
            if let existing = cards.first(where: { $0.id == key }) {
                next.append(existing)
                startFetchIfNeeded(url)
                continue
            }
            next.append(
                MarkdownLinkCard(
                    url: url,
                    title: nil,
                    description: nil,
                    icon: nil,
                    isLoading: true,
                    errorMessage: nil
                )
            )
            startFetchIfNeeded(url)
        }
        cards = next
    }

    func refresh() {
        cache.removeAll()
        let urls = cards.map(\.url)
        cards = []
        update(urls: urls)
    }

    // MARK: - 私有

    private func card(
        for url: URL,
        metadata: MarkdownLinkMetadata,
        icon: NSImage?,
        isLoading: Bool
    ) -> MarkdownLinkCard {
        MarkdownLinkCard(
            url: url,
            title: metadata.title ?? url.host,
            description: metadata.description,
            icon: icon,
            isLoading: isLoading,
            errorMessage: nil
        )
    }

    private func startFetchIfNeeded(_ url: URL) {
        let key = url.absoluteString
        guard tasks[key] == nil else { return }

        tasks[key] = Task { [weak self] in
            let result = await MarkdownLinkMetadataFetcher.fetch(url: url)
            guard let self else { return }
            self.tasks[key] = nil
            guard self.cards.contains(where: { $0.id == key }) else { return }

            switch result {
            case .success(let metadata):
                let icon = metadata.iconData.flatMap { NSImage(data: $0) }
                self.cache[key] = CacheEntry(metadata: metadata, icon: icon, date: Date())
                if let index = self.cards.firstIndex(where: { $0.id == key }) {
                    self.cards[index] = self.card(for: url, metadata: metadata, icon: icon, isLoading: false)
                }
            case .failure(let message):
                if let index = self.cards.firstIndex(where: { $0.id == key }) {
                    self.cards[index].isLoading = false
                    self.cards[index].errorMessage = message
                    self.cards[index].title = url.host
                }
            }
        }
    }
}

// MARK: - 元数据抓取

struct MarkdownLinkMetadata: Sendable {
    let title: String?
    let description: String?
    let iconData: Data?
}

enum MarkdownLinkFetchResult: Sendable {
    case success(MarkdownLinkMetadata)
    case failure(String)
}

enum MarkdownLinkMetadataFetcher {
    static func fetch(url: URL) async -> MarkdownLinkFetchResult {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Kaiming Link Preview", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
                return .failure("HTTP \(http.statusCode)")
            }
            let html = decodeHTML(data.prefix(512 * 1024))
            let parsed = parseHTML(html, pageURL: url)
            let iconURL = parsed.iconURL ?? URL(string: "/favicon.ico", relativeTo: url)
            let iconData = await fetchIconData(from: iconURL)
            return .success(
                MarkdownLinkMetadata(
                    title: parsed.title,
                    description: parsed.description,
                    iconData: iconData
                )
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - HTML 解析

    private struct ParsedHTML {
        var title: String?
        var description: String?
        var iconURL: URL?
    }

    private static func decodeHTML(_ data: Data) -> String {
        if let string = String(data: Data(data), encoding: .utf8) {
            return string
        }
        return String(decoding: Data(data), as: UTF8.self)
    }

    private static func parseHTML(_ html: String, pageURL: URL) -> ParsedHTML {
        var parsed = ParsedHTML()

        if let title = firstMatch(
            pattern: #"(?is)<title[^>]*>(.*?)</title\s*>"#,
            in: html,
            group: 1
        ) {
            parsed.title = cleanText(title)
        }

        var meta: [String: String] = [:]
        let metaRegex = try? NSRegularExpression(pattern: #"(?is)<meta\b[^>]*>"#)
        let ns = html as NSString
        metaRegex?.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let tag = ns.substring(with: match.range)
            let attributes = parseAttributes(in: tag)
            guard let content = attributes["content"] else { return }
            let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
            if !key.isEmpty, meta[key] == nil {
                meta[key] = content
            }
        }

        if let title = meta["og:title"] ?? meta["twitter:title"], !title.isEmpty {
            parsed.title = cleanText(title)
        }
        if let description = meta["og:description"] ?? meta["description"] ?? meta["twitter:description"],
           !description.isEmpty {
            parsed.description = cleanText(description)
        }

        let linkRegex = try? NSRegularExpression(pattern: #"(?is)<link\b[^>]*>"#)
        linkRegex?.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, parsed.iconURL == nil else { return }
            let tag = ns.substring(with: match.range)
            let attributes = parseAttributes(in: tag)
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon"),
                  let href = attributes["href"],
                  let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL else { return }
            parsed.iconURL = resolved
        }

        return parsed
    }

    private static func firstMatch(pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > group else { return nil }
        return ns.substring(with: match.range(at: group))
    }

    private static func parseAttributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        ) else { return [:] }

        var attributes: [String: String] = [:]
        let ns = tag as NSString
        regex.enumerateMatches(in: tag, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value: String
            if match.range(at: 3).location != NSNotFound {
                value = ns.substring(with: match.range(at: 3))
            } else if match.range(at: 4).location != NSNotFound {
                value = ns.substring(with: match.range(at: 4))
            } else if match.range(at: 5).location != NSNotFound {
                value = ns.substring(with: match.range(at: 5))
            } else {
                value = ""
            }
            attributes[name] = value
        }
        return attributes
    }

    private static func cleanText(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        if result.count > 280 {
            result = String(result.prefix(280)) + "…"
        }
        return result
    }

    // MARK: - 图标

    private static func fetchIconData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= 1_048_576,
              let http = response as? HTTPURLResponse,
              (200...399).contains(http.statusCode) else {
            return nil
        }
        return data
    }
}
