import AppKit
import Foundation

/// 剪贴板图片缩略图缓存。
///
/// 只在主线程使用；第一次访问时用 `NSImage(contentsOf:)` 读盘并缩放到目标尺寸，
/// 之后直接命中内存缓存，避免 SwiftUI 每次刷新都读盘解码。
@MainActor
final class ClipboardThumbnailCache {
    static let shared = ClipboardThumbnailCache()

    private var cache: [String: NSImage] = [:]
    private var insertionOrder: [String] = []
    private let maxEntryCount = 120

    private init() {}

    func thumbnail(for item: ClipboardItem, maxPixelSize: CGFloat = 160) -> NSImage? {
        guard item.kind == .image, let fileName = item.imageFileName else { return nil }
        let key = "\(fileName)|\(Int(maxPixelSize))"
        if let cached = cache[key] {
            return cached
        }

        let url = AppPaths.clipboardStore.appendingPathComponent(fileName)
        guard let source = NSImage(contentsOf: url) else {
            Log.clipboard.error("Thumbnail source missing: \(fileName, privacy: .public)")
            return nil
        }

        let thumbnail = Self.downscaled(source, maxPixelSize: maxPixelSize)
        cache[key] = thumbnail
        insertionOrder.append(key)
        trimIfNeeded()
        return thumbnail
    }

    func remove(fileName: String) {
        let prefix = "\(fileName)|"
        let removedKeys = cache.keys.filter { $0.hasPrefix(prefix) }
        for key in removedKeys {
            cache[key] = nil
        }
        insertionOrder.removeAll { $0.hasPrefix(prefix) }
    }

    func removeAll() {
        cache.removeAll()
        insertionOrder.removeAll()
    }

    private func trimIfNeeded() {
        guard insertionOrder.count > maxEntryCount else { return }
        let overflow = insertionOrder.count - maxEntryCount
        let evicted = insertionOrder.prefix(overflow)
        for key in evicted {
            cache[key] = nil
        }
        insertionOrder.removeFirst(overflow)
    }

    private static func downscaled(_ image: NSImage, maxPixelSize: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let scale = min(1, maxPixelSize / max(size.width, size.height))
        let target = NSSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )
        return NSImage(size: target, flipped: false) { rect in
            image.draw(
                in: rect,
                from: NSRect(origin: .zero, size: size),
                operation: .copy,
                fraction: 1
            )
            return true
        }
    }
}
