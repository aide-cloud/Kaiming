import AppKit
import Combine
import Foundation

/// 剪贴板内容类型。
enum ClipboardKind: String, Codable, Sendable {
    case text
    case image
    case fileURLs
    case richText
    case other
}

/// 一条剪贴板历史。图片以文件名形式落盘到 Application Support/Kaiming/Clipboard。
struct ClipboardItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: ClipboardKind
    var text: String?
    var imageFileName: String?
    var fileURLs: [URL]
    var createdAt: Date
    /// 是否已收藏：收藏项永久保留，不计入条数上限，也不会被「清空实时历史」删除。
    var isFavorite: Bool
    /// 收藏时间（用于「收藏」分区排序）；未收藏为 nil。
    var favoritedAt: Date?
    var sourceBundleID: String?
}

/// 剪贴板模块入口。
///
/// 约定：所有 `NSPasteboard` 读写都由 `ClipboardPasteboardWorker` 串行化到专用队列，
/// 主线程只接收不可变快照并更新 `@Published` 状态。
@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var currentText: String?
    /// 当前剪贴板内容的快照（用于「当前剪贴板」卡片）。非文本时 `currentText` 为 nil。
    @Published private(set) var currentItem: ClipboardItem?
    /// 监控是否真正在轮询（设置开关 + 已启动）。
    @Published private(set) var isMonitoring = false

    private let worker = ClipboardPasteboardWorker()
    private let ioQueue = DispatchQueue(label: "com.kaiming.clipboard.io", qos: .utility)

    private var cancellables: Set<AnyCancellable> = []
    /// 图片内容哈希（item id -> SHA-256），用于图片去重；随历史一起持久化。
    private var imageHashes: [UUID: String] = [:]

    private var started = false
    private var workerStarted = false
    private var historyLoaded = false
    private var pendingRefresh = false

    private var settings: SettingsStore { SettingsStore.shared }

    private init() {}

    // MARK: - 生命周期

    func startMonitoring() {
        guard !started else {
            Log.clipboard.info("Clipboard monitoring already started")
            return
        }
        started = true
        historyLoaded = false
        pendingRefresh = false
        observeSettings()

        // 先恢复磁盘历史，再启动轮询，避免启动快照与历史恢复互相覆盖。
        ioQueue.async { [weak self] in
            let loaded = ClipboardHistoryStore.load()
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.applyLoadedHistory(loaded)

                let settings = SettingsStore.shared
                let enabled = settings.clipboardMonitoringEnabled
                let interval = settings.clipboardPollInterval
                self.isMonitoring = enabled
                // 只有监控开启时才读取启动时的剪贴板，避免关闭监控仍产生历史与图片文件。
                self.worker.start(enabled: enabled, interval: interval, readCurrent: enabled) { [weak self] event in
                    self?.handle(event)
                }
                self.workerStarted = true
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.worker.refresh()
                }
                Log.clipboard.info(
                    "Clipboard monitoring started, enabled=\(enabled, privacy: .public), interval=\(interval, privacy: .public)"
                )
            }
        }
    }

    func stopMonitoring() {
        guard started else { return }
        started = false
        workerStarted = false
        pendingRefresh = false
        isMonitoring = false
        cancellables.removeAll()
        worker.stop()
        // 退出前同步落盘一次，避免异步写丢失；历史还没加载完成时不要用空数组覆盖磁盘。
        if historyLoaded {
            let stored = makeStoredHistory()
            ioQueue.sync {
                ClipboardHistoryStore.save(stored)
            }
        }
        Log.clipboard.info("Clipboard monitoring stopped")
    }

    // MARK: - 设置热更新

    private func observeSettings() {
        let settings = SettingsStore.shared

        settings.$clipboardMonitoringEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                Task { @MainActor [weak self] in
                    self?.applyMonitoringPreference(enabled)
                }
            }
            .store(in: &cancellables)

        settings.$clipboardPollInterval
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] interval in
                Task { @MainActor [weak self] in
                    self?.applyPollIntervalPreference(interval)
                }
            }
            .store(in: &cancellables)

        settings.$clipboardHistoryLimit
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyHistoryLimitPreference()
                }
            }
            .store(in: &cancellables)
    }

    private func applyMonitoringPreference(_ enabled: Bool) {
        guard started else { return }
        isMonitoring = enabled
        worker.updateSettings(enabled: enabled, interval: settings.clipboardPollInterval)
        Log.clipboard.info("Clipboard monitoring preference changed to \(enabled, privacy: .public)")
    }

    private func applyPollIntervalPreference(_ interval: Double) {
        guard started else { return }
        worker.updateSettings(enabled: settings.clipboardMonitoringEnabled, interval: interval)
        Log.clipboard.info("Clipboard poll interval changed to \(interval, privacy: .public)s")
    }

    private func applyHistoryLimitPreference() {
        if enforceHistoryLimit() {
            Log.clipboard.info("Clipboard history limit applied: \(self.clampedLimit, privacy: .public)")
        }
    }

    // MARK: - 手动操作

    func refreshNow() {
        if workerStarted {
            worker.refresh()
        } else {
            pendingRefresh = true
            Log.clipboard.info("Clipboard refresh queued until worker starts")
        }
    }

    func clearHistory() {
        // 「收藏」永久保留：清空只针对实时历史，收藏项及其图片文件都不动。
        let removedItems = items.filter { !$0.isFavorite }
        let keptFavorites = items.filter(\.isFavorite)
        let removedImageNames = removedItems.compactMap(\.imageFileName)

        items = keptFavorites
        for item in removedItems {
            imageHashes[item.id] = nil
            if let fileName = item.imageFileName {
                ClipboardThumbnailCache.shared.remove(fileName: fileName)
            }
        }

        // 当前剪贴板内容在实时历史里被删掉时，同步清掉「当前剪贴板」卡片。
        if let current = currentItem, !keptFavorites.contains(where: { $0.id == current.id }) {
            currentItem = nil
            currentText = nil
        }

        removeImageFiles(removedImageNames)
        persistHistory()

        if removedItems.isEmpty {
            AppState.shared.flash(
                keptFavorites.isEmpty ? "剪贴板历史已经是空的" : "实时历史已经是空的，收藏项已保留",
                kind: .info
            )
        } else if keptFavorites.isEmpty {
            AppState.shared.flash("已清空全部实时历史", kind: .success)
        } else {
            AppState.shared.flash(
                "已清空 \(removedItems.count) 条实时历史，收藏 \(keptFavorites.count) 条已保留",
                kind: .success
            )
        }
        Log.clipboard.info(
            "Clipboard live history cleared: removed=\(removedItems.count, privacy: .public), favorites=\(keptFavorites.count, privacy: .public)"
        )
    }

    func clearPasteboard() {
        worker.clearPasteboard()
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        worker.copyToPasteboard(item)
    }

    func delete(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)
        imageHashes[removed.id] = nil

        // 按要求同步删除图片文件。
        if let fileName = removed.imageFileName {
            let url = AppPaths.clipboardStore.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
            ClipboardThumbnailCache.shared.remove(fileName: fileName)
        }

        if currentItem?.id == removed.id {
            currentItem = nil
            currentText = nil
        }

        persistHistory()
        Log.clipboard.info("Deleted clipboard history item \(removed.id.uuidString, privacy: .public)")
    }

    func toggleFavorite(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].isFavorite.toggle()
            items[index].favoritedAt = items[index].isFavorite ? Date() : nil
        } else {
            // 快捷选择窗口会把「当前剪贴板」补成一条临时条目；它可能还没进历史，
            // 此时收藏应当把它正式写入历史，而不是静默失败。
            var favorite = item
            favorite.isFavorite = true
            favorite.favoritedAt = Date()
            items.insert(favorite, at: 0)
        }
        let isFavorite = items.first(where: { $0.id == item.id })?.isFavorite ?? false
        // 只改标记，不动实时列表的先后顺序；「收藏」分区自己按收藏时间排序。
        persistHistory()
        Log.clipboard.info(
            "Clipboard item \(item.id.uuidString, privacy: .public) favorite=\(isFavorite, privacy: .public)"
        )
    }

    // MARK: - 分区

    /// 指定分区要展示的条目。
    ///
    /// - 实时：全部历史，按复制时间倒序（收藏项也在其中，靠星标区分）。
    /// - 收藏：仅收藏项，按收藏时间倒序（老数据没有收藏时间时退回复制时间）。
    func entries(in scope: ClipboardScope) -> [ClipboardItem] {
        switch scope {
        case .live:
            return items
        case .favorites:
            return items.filter(\.isFavorite).sorted { lhs, rhs in
                let lhsDate = lhs.favoritedAt ?? lhs.createdAt
                let rhsDate = rhs.favoritedAt ?? rhs.createdAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    func count(in scope: ClipboardScope) -> Int {
        switch scope {
        case .live: return items.count
        case .favorites: return items.lazy.filter(\.isFavorite).count
        }
    }

    /// 会被「清空实时历史」删掉、也可能被条数上限淘汰的条目数（即非收藏项）。
    var removableHistoryCount: Int {
        items.lazy.filter { !$0.isFavorite }.count
    }

    // MARK: - 事件处理

    private func handle(_ event: ClipboardWorkerEvent) {
        guard started else { return }

        switch event {
        case .snapshot(let snapshot, let reason):
            if let snapshot {
                ingest(snapshot)
                if reason == .manual {
                    AppState.shared.flash("已刷新剪贴板", kind: .success)
                }
            } else {
                currentItem = nil
                currentText = nil
                if reason == .manual {
                    AppState.shared.flash("剪贴板中没有可记录的内容", kind: .info)
                }
            }

        case .copyFinished(let itemID, let success, let failureMessage):
            if success {
                if let item = items.first(where: { $0.id == itemID }) {
                    currentItem = item
                    currentText = item.kind == .text ? item.text : nil
                }
                AppState.shared.flash("已复制到剪贴板", kind: .success)
            } else {
                AppState.shared.flash(failureMessage ?? "复制失败", kind: .error)
                Log.clipboard.error("Copy to pasteboard failed: \(failureMessage ?? "unknown", privacy: .public)")
            }

        case .pasteboardCleared:
            currentItem = nil
            currentText = nil
            AppState.shared.flash("已清空剪贴板", kind: .success)
        }
    }

    // MARK: - 历史

    private func applyLoadedHistory(_ loaded: ClipboardHistoryStore.Loaded) {
        var validItems: [ClipboardItem] = []
        var missingImageCount = 0

        for item in loaded.items {
            if item.kind == .image {
                guard let fileName = item.imageFileName else {
                    missingImageCount += 1
                    continue
                }
                let url = AppPaths.clipboardStore.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    missingImageCount += 1
                    continue
                }
            }
            validItems.append(item)
        }

        items = validItems

        var validHashes: [UUID: String] = [:]
        for item in validItems where item.kind == .image {
            if let hash = loaded.imageHashes[item.id] {
                validHashes[item.id] = hash
            }
        }
        imageHashes = validHashes
        normalizeOrder()
        historyLoaded = true

        if missingImageCount > 0 {
            Log.clipboard.error("Dropped \(missingImageCount, privacy: .public) clipboard image entries whose files were missing")
        }
        let didTrim = enforceHistoryLimit(persist: false)
        if didTrim || missingImageCount > 0 {
            persistHistory()
        }
        Log.clipboard.info("Restored clipboard history: \(self.items.count, privacy: .public) items")
    }

    private func ingest(_ snapshot: ClipboardSnapshot) {
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let duplicateIndex = duplicateIndex(for: snapshot) {
            // 图片重复时，把本次刚写出的 PNG 删掉，复用已有文件。
            if snapshot.kind == .image,
               let newFileName = snapshot.imageFileName,
               items[duplicateIndex].imageFileName != newFileName {
                removeImageFiles([newFileName])
            }

            var existing = items.remove(at: duplicateIndex)
            existing.createdAt = Date()
            if let sourceBundleID {
                existing.sourceBundleID = sourceBundleID
            }
            items.insert(existing, at: 0)
            currentItem = existing
            currentText = existing.kind == .text ? existing.text : nil
            Log.clipboard.debug("Clipboard content matched existing item; moved to top")
        } else {
            let item = ClipboardItem(
                id: UUID(),
                kind: snapshot.kind,
                text: snapshot.text,
                imageFileName: snapshot.imageFileName,
                fileURLs: snapshot.fileURLs,
                createdAt: Date(),
                isFavorite: false,
                favoritedAt: nil,
                sourceBundleID: sourceBundleID
            )
            items.insert(item, at: 0)
            if snapshot.kind == .image, let hash = snapshot.imageHash {
                imageHashes[item.id] = hash
            }
            currentItem = item
            currentText = item.kind == .text ? item.text : nil
            Log.clipboard.info(
                "Captured clipboard item kind=\(item.kind.rawValue, privacy: .public), total=\(self.items.count, privacy: .public)"
            )
        }

        normalizeOrder()
        enforceHistoryLimit(persist: false)
        persistHistory()
    }

    private func duplicateIndex(for snapshot: ClipboardSnapshot) -> Int? {
        items.firstIndex { item in
            guard item.kind == snapshot.kind else { return false }
            switch item.kind {
            case .image:
                guard let snapshotHash = snapshot.imageHash,
                      let existingHash = imageHashes[item.id] else {
                    return false
                }
                return snapshotHash == existingHash
            case .text, .richText:
                return item.text == snapshot.text
            case .fileURLs:
                let lhs = item.fileURLs.map(\.standardizedFileURL.path)
                let rhs = snapshot.fileURLs.map(\.standardizedFileURL.path)
                return lhs == rhs
            case .other:
                return false
            }
        }
    }

    /// 实时历史按复制时间倒序（最新在前）。收藏分区在 `entries(in:)` 里按收藏时间另行排序。
    private func normalizeOrder() {
        items.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 超出上限时删除最旧的**未收藏**项（当前剪贴板内容也受保护），并删掉对应图片。
    /// 收藏项不计入上限，永远不会被自动淘汰。
    @discardableResult
    private func enforceHistoryLimit(persist: Bool = true) -> Bool {
        let limit = clampedLimit
        var removableCount = items.lazy.filter { !$0.isFavorite }.count
        guard removableCount > limit else { return false }

        var removedImageNames: [String] = []
        var removedCount = 0

        while removableCount > limit {
            guard let index = items.lastIndex(where: { !$0.isFavorite && $0.id != currentItem?.id }) else {
                break
            }
            let removed = items.remove(at: index)
            imageHashes[removed.id] = nil
            if let fileName = removed.imageFileName {
                removedImageNames.append(fileName)
                ClipboardThumbnailCache.shared.remove(fileName: fileName)
            }
            removedCount += 1
            removableCount -= 1
        }

        if !removedImageNames.isEmpty {
            removeImageFiles(removedImageNames)
        }
        if removedCount > 0 {
            Log.clipboard.info("Trimmed \(removedCount, privacy: .public) old clipboard items to limit \(limit, privacy: .public)")
        }
        if persist, removedCount > 0 {
            persistHistory()
        }
        return removedCount > 0
    }

    private var clampedLimit: Int {
        min(max(settings.clipboardHistoryLimit, 10), 500)
    }

    // MARK: - 持久化

    private func persistHistory() {
        let stored = makeStoredHistory()
        ioQueue.async {
            ClipboardHistoryStore.save(stored)
        }
    }

    private func makeStoredHistory() -> ClipboardHistoryStore.StoredHistory {
        let storedItems = items.map { item in
            ClipboardHistoryStore.StoredItem(
                id: item.id,
                kind: item.kind,
                text: item.text,
                imageFileName: item.imageFileName,
                fileURLs: item.fileURLs,
                createdAt: item.createdAt,
                isFavorite: item.isFavorite,
                favoritedAt: item.favoritedAt,
                sourceBundleID: item.sourceBundleID,
                imageHash: imageHashes[item.id]
            )
        }

        let validIDs = Set(items.map(\.id))
        var storedHashes: [String: String] = [:]
        for (id, hash) in imageHashes where validIDs.contains(id) {
            storedHashes[id.uuidString] = hash
        }

        return ClipboardHistoryStore.StoredHistory(
            version: 2,
            items: storedItems,
            imageHashes: storedHashes
        )
    }

    private func removeImageFiles(_ fileNames: [String]) {
        guard !fileNames.isEmpty else { return }
        let directory = AppPaths.clipboardStore
        ioQueue.async {
            for fileName in fileNames {
                let url = directory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
