import Foundation

/// 剪贴板历史的磁盘元数据存储。
///
/// 只保存元数据（文本、文件 URL、图片文件名），历史里的图片本体保存在
/// `AppPaths.clipboardStore/<UUID>.png`。文件读写全部由 `ClipboardManager`
/// 派发到专用 IO 队列，不占用主线程。
enum ClipboardHistoryStore {
    /// 磁盘格式。`ClipboardItem` 是冻结的公开类型，不额外加 Codable 字段，
    /// 这里用独立的存储结构承载（含图片内容哈希，用于去重）。
    struct StoredItem: Codable, Sendable {
        var id: UUID
        var kind: ClipboardKind
        var text: String?
        var imageFileName: String?
        var fileURLs: [URL]
        var createdAt: Date
        var isPinned: Bool
        var sourceBundleID: String?
        var imageHash: String?
    }

    struct StoredHistory: Codable, Sendable {
        var version: Int
        var items: [StoredItem]
        /// `UUID.uuidString` -> SHA-256（PNG 数据），键值均为值类型便于跨队列传递。
        var imageHashes: [String: String]
    }

    /// 加载结果：公开类型 + 图片哈希表。
    struct Loaded: Sendable {
        var items: [ClipboardItem]
        var imageHashes: [UUID: String]
    }

    static var fileURL: URL {
        AppPaths.clipboardStore.appendingPathComponent("history.json")
    }

    static func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Loaded(items: [], imageHashes: [:])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            // 用毫秒时间戳保存，保留同一秒内多条记录的先后顺序。
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let stored = try decoder.decode(StoredHistory.self, from: data)

            var hashes: [UUID: String] = [:]
            for (key, value) in stored.imageHashes {
                if let id = UUID(uuidString: key) {
                    hashes[id] = value
                }
            }

            let items = stored.items.map { storedItem in
                ClipboardItem(
                    id: storedItem.id,
                    kind: storedItem.kind,
                    text: storedItem.text,
                    imageFileName: storedItem.imageFileName,
                    fileURLs: storedItem.fileURLs,
                    createdAt: storedItem.createdAt,
                    isPinned: storedItem.isPinned,
                    sourceBundleID: storedItem.sourceBundleID
                )
            }

            Log.clipboard.info("Loaded clipboard history from disk: \(items.count, privacy: .public) items")
            return Loaded(items: items, imageHashes: hashes)
        } catch {
            Log.clipboard.error("Failed to load clipboard history: \(error.localizedDescription, privacy: .public)")
            return Loaded(items: [], imageHashes: [:])
        }
    }

    static func save(_ stored: StoredHistory) {
        do {
            try AppPaths.ensureDirectory(AppPaths.clipboardStore)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(stored)
            try data.write(to: fileURL, options: [.atomic])
            Log.clipboard.debug("Saved clipboard history: \(stored.items.count, privacy: .public) items")
        } catch {
            Log.clipboard.error("Failed to save clipboard history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
