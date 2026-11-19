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
        var isFavorite: Bool
        var favoritedAt: Date?
        var sourceBundleID: String?
        var imageHash: String?

        init(
            id: UUID,
            kind: ClipboardKind,
            text: String?,
            imageFileName: String?,
            fileURLs: [URL],
            createdAt: Date,
            isFavorite: Bool,
            favoritedAt: Date?,
            sourceBundleID: String?,
            imageHash: String?
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.imageFileName = imageFileName
            self.fileURLs = fileURLs
            self.createdAt = createdAt
            self.isFavorite = isFavorite
            self.favoritedAt = favoritedAt
            self.sourceBundleID = sourceBundleID
            self.imageHash = imageHash
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, text, imageFileName, fileURLs, createdAt, isFavorite, favoritedAt
            case sourceBundleID, imageHash
            /// v1 字段：当时叫「置顶」；v2 起统一为「收藏」，读旧文件时等价迁移，写盘时镜像回写。
            case legacyIsPinned = "isPinned"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decode(ClipboardKind.self, forKey: .kind)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
            fileURLs = try container.decodeIfPresent([URL].self, forKey: .fileURLs) ?? []
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            if let favorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) {
                isFavorite = favorite
            } else {
                // 旧版本只有「置顶」，语义一致（永久保留、不被淘汰），直接当作收藏。
                isFavorite = try container.decodeIfPresent(Bool.self, forKey: .legacyIsPinned) ?? false
            }
            favoritedAt = try container.decodeIfPresent(Date.self, forKey: .favoritedAt)
            sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
            imageHash = try container.decodeIfPresent(String.self, forKey: .imageHash)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
            try container.encode(fileURLs, forKey: .fileURLs)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(isFavorite, forKey: .isFavorite)
            try container.encodeIfPresent(favoritedAt, forKey: .favoritedAt)
            try container.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
            try container.encodeIfPresent(imageHash, forKey: .imageHash)
            // 兼容写：旧版本只认 `isPinned`，缺了它整份历史会解码失败。收藏与旧「置顶」语义一致，
            // 这里镜像写出，降到旧版本（或旧实例仍在运行并回写）时历史不会丢。
            try container.encode(isFavorite, forKey: .legacyIsPinned)
        }
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
                    isFavorite: storedItem.isFavorite,
                    favoritedAt: storedItem.favoritedAt,
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
