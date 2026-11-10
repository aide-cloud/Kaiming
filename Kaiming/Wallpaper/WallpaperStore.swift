import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 壁纸模块内部使用的串行队列。
///
/// 约束（docs/contracts.md 第 3 节）：
/// - 所有 `NSPasteboard` 读写只在 `pasteboard` 队列上执行，禁止并发；
/// - 壁纸文件的复制、缩略图生成与清理只在 `disk` 队列上执行，避免阻塞主线程。
enum WallpaperIO {
    /// 全局唯一剪贴板串行队列（见 Shared/PasteboardQueue.swift）。
    static let pasteboard = PasteboardQueue.serial
    static let disk = DispatchQueue(label: "com.kaiming.wallpaper.disk", qos: .userInitiated)
}

/// 壁纸文件读写错误，`errorDescription` 直接用于用户提示。
enum WallpaperStoreError: LocalizedError {
    case unreadableFile(String)
    case copyFailed(String)
    case unsupportedImage
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let name):
            "文件不可读：\(name)"
        case .copyFailed(let reason):
            "复制图片失败：\(reason)"
        case .unsupportedImage:
            "不是受支持的图片格式"
        case .writeFailed(let reason):
            "保存壁纸失败：\(reason)"
        }
    }
}

/// 剪贴板读取结果。只携带 `Sendable` 的 `Data` / `URL`，由主线程再解码成 `NSImage`。
enum WallpaperPasteboardResult: Sendable {
    case image(data: Data, fileExtension: String)
    case file(URL)
    case empty
}

/// 壁纸模块的文件仓库：负责持久化复制、缩略图与保留策略。
///
/// 所有成员都是非隔离的静态方法，内部通过 `WallpaperIO.disk` 串行执行；
/// 只把 `Sendable` 数据（`Data` / `URL` / 值类型）带出队列。
enum WallpaperFileStore {
    /// `AppPaths.wallpapers` 中保留的最大壁纸数量（当前正在使用的文件不受限制）。
    static let retentionLimit = 50
    /// 轮换文件夹一次最多扫描的图片数量，避免超大目录拖慢主线程交互。
    static let rotationFolderLimit = 2000

    // MARK: - 异步桥

    /// 在 `disk` 串行队列上执行同步工作，并把结果带回调用方。
    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            WallpaperIO.disk.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 剪贴板

    /// 从 `NSPasteboard.general` 读取图片，全部访问都发生在 `WallpaperIO.pasteboard` 队列上。
    static func readPasteboardImage() async -> WallpaperPasteboardResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<WallpaperPasteboardResult, Never>) in
            WallpaperIO.pasteboard.async {
                continuation.resume(returning: readPasteboardImageSync())
            }
        }
    }

    private static func readPasteboardImageSync() -> WallpaperPasteboardResult {
        let pasteboard = NSPasteboard.general

        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
           let imageURL = urls.first(where: isReadableImageFile) {
            return .file(imageURL)
        }

        if let pngData = pasteboard.data(forType: .png), imageSource(from: pngData) != nil {
            return .image(data: pngData, fileExtension: "png")
        }

        if let tiffData = pasteboard.data(forType: .tiff), imageSource(from: tiffData) != nil {
            return .image(data: tiffData, fileExtension: "tiff")
        }

        return .empty
    }

    // MARK: - 持久化

    /// 把内存中的图片数据（PNG / TIFF）写入 `AppPaths.wallpapers`，统一转成 PNG，文件名 UUID。
    static func storeImageData(_ data: Data, sourceExtension: String) async throws -> URL {
        try await perform {
            let directory = try ensureWallpaperDirectory()
            let fileExtension = sourceExtension.lowercased()
            let destination = directory.appendingPathComponent("\(UUID().uuidString).png", isDirectory: false)

            do {
                if fileExtension == "png", imageSource(from: data) != nil {
                    // 已经是 PNG，保留原始字节，避免无谓重编码。
                    try data.write(to: destination, options: .atomic)
                } else {
                    guard let pngData = pngData(from: data) else {
                        throw WallpaperStoreError.unsupportedImage
                    }
                    try pngData.write(to: destination, options: .atomic)
                }
            } catch let error as WallpaperStoreError {
                throw error
            } catch {
                throw WallpaperStoreError.writeFailed(error.localizedDescription)
            }

            try verifyStoredFile(destination)
            return destination
        }
    }

    /// 把磁盘上的图片原样复制到 `AppPaths.wallpapers`，保留原扩展名（缺失时按图片类型补全）。
    static func storeImageFile(_ source: URL) async throws -> URL {
        try await perform {
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw WallpaperStoreError.unreadableFile(source.lastPathComponent)
            }
            guard imageSource(from: source) != nil else {
                throw WallpaperStoreError.unsupportedImage
            }

            let directory = try ensureWallpaperDirectory()
            let fileExtension = imageFileExtension(for: source)
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString).\(fileExtension)",
                isDirectory: false
            )

            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw WallpaperStoreError.copyFailed(error.localizedDescription)
            }

            do {
                try verifyStoredFile(destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return destination
        }
    }

    // MARK: - 缩略图

    /// 为指定图片生成 PNG 缩略图数据（用于屏幕行里的“当前壁纸”预览）。
    static func thumbnailData(for url: URL, maxPixel: Int = 480) async -> Data? {
        do {
            return try await perform { thumbnailPNGData(for: url, maxPixel: maxPixel) }
        } catch {
            Log.wallpaper.error("Thumbnail failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 文件夹轮换

    /// 扫描轮换文件夹中的图片（按文件名排序，结果稳定）。
    static func rotationFiles(in folder: URL) async -> [URL] {
        do {
            return try await perform { rotationFilesSync(in: folder) }
        } catch {
            Log.wallpaper.error("Scan rotation folder failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func rotationFilesSync(in folder: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: folder.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return urls
            .filter { isReadableImageFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(rotationFolderLimit)
            .map { $0 }
    }

    // MARK: - 清理

    /// 只保留最近 `limit` 张壁纸；`protectedPaths`（当前所有屏幕正在使用的文件）永不删除。
    /// 仅在成功设置壁纸后调用，启动时不做任何清理。
    static func cleanStore(keeping limit: Int, protectedPaths: Set<String>) async {
        do {
            try await perform {
                cleanStoreSync(keeping: limit, protectedPaths: protectedPaths)
            }
        } catch {
            Log.wallpaper.error("Clean wallpaper store failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func cleanStoreSync(keeping limit: Int, protectedPaths: Set<String>) {
        let directory = AppPaths.wallpapers
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let protected = Set(protectedPaths.map { normalizedPath($0) })
        let images = urls
            .filter { isRegularFile($0) && isImageFile($0) }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }

        var keptCount = 0
        var removedCount = 0
        for file in images {
            if protected.contains(normalizedPath(file.path)) {
                // 正在被系统使用的文件无论多旧都保留。
                continue
            }
            if keptCount < limit {
                keptCount += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: file)
                removedCount += 1
            } catch {
                Log.wallpaper.error("Remove old wallpaper failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if removedCount > 0 {
            Log.wallpaper.info("Wallpaper cleanup removed \(removedCount, privacy: .public) file(s), kept \(keptCount, privacy: .public)")
        }
    }

    // MARK: - 图片工具

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    static func isReadableImageFile(_ url: URL) -> Bool {
        guard isRegularFile(url), FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return isImageFile(url)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func ensureWallpaperDirectory() throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.wallpapers)
    }

    private static func verifyStoredFile(_ url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.isReadableFile(atPath: url.path), size > 0 else {
            throw WallpaperStoreError.unreadableFile(url.lastPathComponent)
        }
    }

    private static func imageFileExtension(for source: URL) -> String {
        let original = source.pathExtension.lowercased()
        if !original.isEmpty, isImageFile(source) {
            return original
        }
        if let imageSource = imageSource(from: source),
           let typeIdentifier = CGImageSourceGetType(imageSource),
           let type = UTType(typeIdentifier as String),
           let preferred = type.preferredFilenameExtension {
            return preferred
        }
        return "png"
    }

    private static func imageSource(from data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func imageSource(from url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func pngData(from data: Data) -> Data? {
        guard let source = imageSource(from: data),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return pngData(from: image)
    }

    static func pngData(from image: CGImage) -> Data? {
        guard let output = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
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

    private static func thumbnailPNGData(for url: URL, maxPixel: Int) -> Data? {
        guard let source = imageSource(from: url) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return pngData(from: thumbnail)
    }
}
