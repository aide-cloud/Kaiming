import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一次从 `NSPasteboard` 读取到的内容快照。
/// 只包含值类型，可安全地从串行队列传递到主线程。
struct ClipboardSnapshot: Sendable {
    var kind: ClipboardKind
    var text: String?
    var imageFileName: String?
    var imageHash: String?
    var fileURLs: [URL]
    /// 用于去重的稳定标识（同类型同内容时相同）。
    var dedupeKey: String
}

/// 快照来源：启动读取 / 轮询检测 / 用户手动刷新。
enum ClipboardSnapshotReason: Sendable {
    case initial
    case poll
    case manual
}

/// `ClipboardPasteboardWorker` 向主线程回传的事件。
enum ClipboardWorkerEvent: Sendable {
    case snapshot(ClipboardSnapshot?, reason: ClipboardSnapshotReason)
    case copyFinished(itemID: UUID, success: Bool, failureMessage: String?)
    case pasteboardCleared
}

/// 所有 `NSPasteboard` 读写的唯一入口。
///
/// 内部持有专用串行队列 `com.kaiming.clipboard`（qos: .utility）：
/// - `DispatchSourceTimer` 在队列上轮询 `changeCount`，只有变化时才读取内容；
/// - 图片转码/落盘、文件 URL 读取也都在队列上完成；
/// - 结果通过 `Task { @MainActor in ... }` 回传，主线程永不触碰 `NSPasteboard`。
final class ClipboardPasteboardWorker: @unchecked Sendable {
    typealias EventHandler = @MainActor @Sendable (ClipboardWorkerEvent) -> Void

    private struct Configuration {
        var enabled: Bool
        var interval: TimeInterval
    }

    private struct StoredImage {
        let fileName: String
        let hash: String
    }

    /// 全局唯一剪贴板串行队列（见 Shared/PasteboardQueue.swift）。
    private let queue = PasteboardQueue.serial

    // 以下状态只在 `queue` 上读写（`queue.sync` 的 stop 除外），因此用 nonisolated 访问。
    private var timer: DispatchSourceTimer?
    private var lastChangeCount = -1
    private var configuration = Configuration(enabled: false, interval: 0.5)
    private var isStarted = false
    private var handler: EventHandler?

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    // MARK: - 生命周期

    /// 启动监控。`readCurrent` 为 true 时立即读取一次当前剪贴板内容并建立基线。
    func start(enabled: Bool, interval: TimeInterval, readCurrent: Bool, handler: @escaping EventHandler) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handler = handler
            self.isStarted = true
            self.configuration = Configuration(enabled: enabled, interval: Self.clampedInterval(interval))

            if readCurrent {
                let pasteboard = NSPasteboard.general
                let snapshot = Self.readSnapshot(from: pasteboard)
                self.lastChangeCount = pasteboard.changeCount
                self.emit(.snapshot(snapshot, reason: .initial))
            } else {
                self.lastChangeCount = NSPasteboard.general.changeCount
            }

            self.syncTimerLocked()
            Log.clipboard.info(
                "Pasteboard worker started, enabled=\(enabled, privacy: .public), interval=\(self.configuration.interval, privacy: .public)"
            )
        }
    }

    /// 停止监控并取消定时器。同步等待队列，保证退出前不会再有 tick。
    func stop() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.configuration.enabled = false
            self.cancelTimerLocked()
            self.handler = nil
            Log.clipboard.info("Pasteboard worker stopped")
        }
    }

    /// 设置变化（监控开关、轮询间隔）时调用。
    /// 从暂停切回开启时会重新建立基线并读取一次当前内容，避免漏掉关闭期间的剪贴板。
    func updateSettings(enabled: Bool, interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasEnabled = self.configuration.enabled
            self.configuration = Configuration(enabled: enabled, interval: Self.clampedInterval(interval))
            guard self.isStarted else { return }

            if enabled, !wasEnabled {
                let pasteboard = NSPasteboard.general
                let snapshot = Self.readSnapshot(from: pasteboard)
                self.lastChangeCount = pasteboard.changeCount
                self.emit(.snapshot(snapshot, reason: .initial))
            }
            self.syncTimerLocked()
        }
    }

    // MARK: - 手动操作

    /// 立即读取一次剪贴板（受监控开关影响很小：这是显式请求，总会执行）。
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            let snapshot = Self.readSnapshot(from: pasteboard)
            self.lastChangeCount = pasteboard.changeCount
            self.emit(.snapshot(snapshot, reason: .manual))
        }
    }

    /// 把历史条目写回剪贴板，并在同一队列上同步基线，避免监控把自己的写入当成外部变化。
    func copyToPasteboard(_ item: ClipboardItem) {
        queue.async { [weak self] in
            guard let self else { return }
            if let failure = Self.write(item: item) {
                self.emit(.copyFinished(itemID: item.id, success: false, failureMessage: failure))
                return
            }
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.emit(.copyFinished(itemID: item.id, success: true, failureMessage: nil))
        }
    }

    /// 清空系统剪贴板（保留历史记录），同样同步基线。
    func clearPasteboard() {
        queue.async { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            self.lastChangeCount = pasteboard.changeCount
            self.emit(.pasteboardCleared)
        }
    }

    // MARK: - 定时轮询

    private func syncTimerLocked() {
        guard isStarted, configuration.enabled else {
            cancelTimerLocked()
            return
        }
        let interval = configuration.interval
        if let timer {
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in
            self?.pollLocked()
        }
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        source.resume()
        timer = source
    }

    private func cancelTimerLocked() {
        guard let timer else { return }
        timer.setEventHandler {}
        timer.cancel()
        self.timer = nil
    }

    private func pollLocked() {
        guard isStarted, configuration.enabled else { return }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let snapshot = Self.readSnapshot(from: pasteboard)
        emit(.snapshot(snapshot, reason: .poll))
    }

    // MARK: - 事件回传

    private func emit(_ event: ClipboardWorkerEvent) {
        guard let handler else { return }
        Task { @MainActor in
            handler(event)
        }
    }

    // MARK: - 剪贴板读取

    private static func readSnapshot(from pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        // 1. 文件 URL（必须在图片/文本之前判断：Finder 复制文件时也可能带图标或路径文本）。
        if let fileURLs = readFileURLs(from: pasteboard) {
            let paths = fileURLs.map(\.standardizedFileURL.path)
            Log.clipboard.debug("Captured \(fileURLs.count, privacy: .public) file URLs from pasteboard")
            return ClipboardSnapshot(
                kind: .fileURLs,
                text: nil,
                imageFileName: nil,
                imageHash: nil,
                fileURLs: fileURLs,
                dedupeKey: "file:" + paths.joined(separator: "\u{0}")
            )
        }

        // 2. 图片：优先原始 PNG，其次把 TIFF 转成 PNG 后落盘。
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            if let stored = storeImage(from: pasteboard) {
                return ClipboardSnapshot(
                    kind: .image,
                    text: nil,
                    imageFileName: stored.fileName,
                    imageHash: stored.hash,
                    fileURLs: [],
                    dedupeKey: "image:" + stored.hash
                )
            }
            Log.clipboard.error("Pasteboard advertised image data but it could not be converted to PNG")
        }

        // 3. 富文本：RTF / HTML 统一记为 richText，保存纯文本预览。
        let isRichText = pasteboard.availableType(from: [.rtf, .html]) != nil
        let string = pasteboard.string(forType: .string)
        if isRichText {
            guard let string,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
                Log.clipboard.info("Ignoring rich text without plain-text preview, types: \(types, privacy: .public)")
                return nil
            }
            return ClipboardSnapshot(
                kind: .richText,
                text: string,
                imageFileName: nil,
                imageHash: nil,
                fileURLs: [],
                dedupeKey: "rich:" + string
            )
        }

        // 4. 纯文本。
        if let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClipboardSnapshot(
                kind: .text,
                text: string,
                imageFileName: nil,
                imageHash: nil,
                fileURLs: [],
                dedupeKey: "text:" + string
            )
        }

        // 5. 其它类型忽略（macOS 15.4 的 detectedPatterns 在 SDK 15.2 不可用，
        //    这里用 changeCount + availableType 判断；未知类型只记日志）。
        let types = (pasteboard.types ?? []).map(\.rawValue)
        if !types.isEmpty {
            Log.clipboard.info("Ignoring unsupported pasteboard types: \(types.joined(separator: ", "), privacy: .public)")
        }
        return nil
    }

    private static func readFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard pasteboard.availableType(from: [.fileURL]) != nil else { return nil }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] else {
            return nil
        }
        let urls = objects.map { $0 as URL }.filter(\.isFileURL)
        return urls.isEmpty ? nil : urls
    }

    // MARK: - 图片落盘

    private static func storeImage(from pasteboard: NSPasteboard) -> StoredImage? {
        var pngData: Data?
        if let data = pasteboard.data(forType: .png), isPNG(data) {
            pngData = data
        }
        if pngData == nil, let tiffData = pasteboard.data(forType: .tiff) {
            pngData = Self.pngData(fromImageData: tiffData)
        }
        guard let png = pngData, !png.isEmpty, isPNG(png) else { return nil }

        do {
            let directory = try AppPaths.ensureDirectory(AppPaths.clipboardStore)
            let fileName = "\(UUID().uuidString).png"
            let url = directory.appendingPathComponent(fileName)
            try png.write(to: url, options: [.atomic])
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            Log.clipboard.debug("Persisted clipboard image \(fileName, privacy: .public) (\(png.count, privacy: .public) bytes)")
            return StoredImage(fileName: fileName, hash: hash)
        } catch {
            Log.clipboard.error("Failed to persist clipboard image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }

    private static func pngData(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 写入剪贴板

    /// 返回 nil 表示成功，否则返回给用户看的中文错误文案。
    private static func write(item: ClipboardItem) -> String? {
        let pasteboard = NSPasteboard.general

        switch item.kind {
        case .text, .richText:
            guard let text = item.text, !text.isEmpty else {
                return "这条记录没有可复制的文本。"
            }
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                return "写入文本到剪贴板失败。"
            }
            return nil

        case .image:
            guard let fileName = item.imageFileName else {
                return "图片记录缺少文件名，无法复制。"
            }
            let url = AppPaths.clipboardStore.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return "图片文件已不存在，无法复制。"
            }
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else {
                return "写入图片到剪贴板失败。"
            }
            return nil

        case .fileURLs:
            guard !item.fileURLs.isEmpty else {
                return "这条记录没有可复制的文件。"
            }
            pasteboard.clearContents()
            let objects: [NSPasteboardWriting] = item.fileURLs.map { $0 as NSURL }
            guard pasteboard.writeObjects(objects) else {
                return "写入文件到剪贴板失败。"
            }
            return nil

        case .other:
            return "该类型暂不支持复制。"
        }
    }

    // MARK: - 工具

    private static func clampedInterval(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, 0.2), 5.0)
    }
}
