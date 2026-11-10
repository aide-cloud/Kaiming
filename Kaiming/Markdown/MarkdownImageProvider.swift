import AppKit
import Combine
import Foundation
import MarkdownEngine

/// 解析 Markdown 图片目标：相对路径 / 绝对路径 / file:// / http(s)。
enum MarkdownImageTarget: Equatable {
    case local(URL)
    case remote(URL)
}

enum MarkdownImageResolver {
    static func target(for rawValue: String, baseDirectory: URL?) -> MarkdownImageTarget? {
        var raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // 去掉标准 Markdown 图片的可选 title：![alt](path "title")
        if let titleRange = raw.range(of: #"\s+["'][^"']*["']\s*$"#, options: .regularExpression) {
            raw = String(raw[..<titleRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if raw.hasPrefix("<"), raw.hasSuffix(">"), raw.count > 2 {
            raw = String(raw.dropFirst().dropLast())
        }
        guard !raw.isEmpty else { return nil }

        let lowercased = raw.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return URL(string: raw).map { .remote($0) }
        }
        if lowercased.hasPrefix("file://") {
            guard let url = URL(string: raw) else { return nil }
            return .local(URL(fileURLWithPath: url.path))
        }
        if lowercased.hasPrefix("data:") {
            return nil
        }

        let decoded = raw.removingPercentEncoding ?? raw
        if decoded.hasPrefix("~/") {
            return .local(URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath))
        }
        if decoded.hasPrefix("/") {
            return .local(URL(fileURLWithPath: decoded))
        }
        guard let baseDirectory else { return nil }
        return .local(baseDirectory.appendingPathComponent(decoded).standardizedFileURL)
    }
}

/// 内嵌 MarkdownEngine 的图片服务。
///
/// - 本地图片同步读取并缓存（缓存键包含修改时间/大小，文件更新后自动换图）；
/// - 远程图片首次请求返回 nil 并异步下载，成功后递增 `revision`，
///   引擎根据 `fingerprint()` 变化重新排版；
/// - 找不到/下载失败的图片返回 nil，引擎保留 Markdown 源码，不崩溃。
final class MarkdownImageProvider: ObservableObject, EmbeddedImageProvider, @unchecked Sendable {
    static let shared = MarkdownImageProvider()

    @Published private(set) var revision = 0

    private let lock = NSLock()
    private var baseDirectory: URL?
    private var imageCache: [String: NSImage] = [:]
    private var failedRemoteKeys: Set<String> = []
    private var pendingRemoteKeys: Set<String> = []
    private let session: URLSession

    private static let maxRemoteBytes = 20 * 1_048_576

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: configuration)
    }

    // MARK: - Base directory

    func setBaseDirectory(_ url: URL?) {
        let standardized = url?.standardizedFileURL
        lock.lock()
        let changed = baseDirectory != standardized
        baseDirectory = standardized
        lock.unlock()
        if changed {
            // fingerprint() 已包含 baseDirectory；这里不必主动 bump revision，
            // 调用方（视图）因文档切换本就会重新渲染并触发引擎重排。
            Log.markdown.debug("Image base directory: \(standardized?.path ?? "-", privacy: .public)")
        }
    }

    // MARK: - EmbeddedImageProvider

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let base: URL?
        lock.lock()
        base = baseDirectory
        lock.unlock()

        guard let target = MarkdownImageResolver.target(for: reference.name, baseDirectory: base) else {
            return nil
        }
        switch target {
        case .local(let url):
            return loadLocal(url)
        case .remote(let url):
            return loadRemote(url)
        }
    }

    func fingerprint() -> AnyHashable {
        let base: String
        lock.lock()
        base = baseDirectory?.path ?? "-"
        lock.unlock()
        return "markdown-images:\(base):\(revision)"
    }

    // MARK: - Local

    private func loadLocal(_ url: URL) -> NSImage? {
        let key = localCacheKey(for: url)
        lock.lock()
        if let cached = imageCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = NSImage(contentsOf: url), image.isValid else {
            return nil
        }
        lock.lock()
        imageCache[key] = image
        lock.unlock()
        return image
    }

    private func localCacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
    }

    // MARK: - Remote

    private func loadRemote(_ url: URL) -> NSImage? {
        let key = url.absoluteString
        lock.lock()
        if let cached = imageCache[key] {
            lock.unlock()
            return cached
        }
        if failedRemoteKeys.contains(key) || pendingRemoteKeys.contains(key) {
            lock.unlock()
            return nil
        }
        pendingRemoteKeys.insert(key)
        lock.unlock()

        session.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode
            let data = data.flatMap { $0.count <= Self.maxRemoteBytes ? $0 : nil }

            DispatchQueue.main.async {
                let image = data.flatMap { NSImage(data: $0) }
                let valid = error == nil
                    && (httpStatus ?? 200) >= 200 && (httpStatus ?? 200) < 300
                    && image?.isValid == true

                self.lock.lock()
                self.pendingRemoteKeys.remove(key)
                if valid, let image {
                    self.imageCache[key] = image
                } else {
                    self.failedRemoteKeys.insert(key)
                }
                self.lock.unlock()

                if valid {
                    self.revision += 1
                    Log.markdown.info("Downloaded remote image \(url.absoluteString, privacy: .public)")
                } else {
                    Log.markdown.info("Remote image unavailable \(url.absoluteString, privacy: .public)")
                }
            }
        }.resume()

        return nil
    }
}
