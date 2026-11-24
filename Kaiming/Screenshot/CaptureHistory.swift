import AppKit
import Foundation

/// 一张截图历史文件。
struct CaptureFile: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// `AppPaths.captures` 的读写、命名与保留策略。
///
/// 截图历史固定以 PNG 保存，自动保存目录才跟随
/// `SettingsStore.screenshotFormat`。命名与淘汰逻辑拆成纯函数，便于单独验证。
enum CaptureHistory {
    static let maxRetained = 30
    static let fileNamePrefix = "Kaiming-"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()

    // MARK: - 命名

    static func timestamp(for date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    static func preferredFileName(for date: Date, fileExtension: String) -> String {
        "\(fileNamePrefix)\(timestamp(for: date)).\(fileExtension)"
    }

    /// 同一秒内多次截图时追加序号，避免覆盖已有文件。
    static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let baseURL = directory.appendingPathComponent(preferredName, isDirectory: false)
        guard fileManager.fileExists(atPath: baseURL.path) else { return baseURL }

        let withoutExtension = (preferredName as NSString).deletingPathExtension
        let pathExtension = (preferredName as NSString).pathExtension
        var index = 2
        while index < 1000 {
            let candidateName = pathExtension.isEmpty
                ? "\(withoutExtension)-\(index)"
                : "\(withoutExtension)-\(index).\(pathExtension)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
        return directory.appendingPathComponent("\(UUID().uuidString).\(pathExtension)", isDirectory: false)
    }

    // MARK: - 保留策略（纯函数）

    /// 按时间倒序保留最新 `keep` 张，返回需要删除的文件。
    static func filesToPrune(from files: [CaptureFile], keep: Int) -> [CaptureFile] {
        guard keep >= 0, files.count > keep else { return [] }
        let sorted = files.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.name > rhs.name
            }
            return lhs.date > rhs.date
        }
        return Array(sorted.dropFirst(keep))
    }

    // MARK: - 查询

    static func recentFiles(in directory: URL = AppPaths.captures, limit: Int = 4) -> [CaptureFile] {
        let all = files(in: directory)
        guard limit > 0 else { return [] }
        return Array(all.prefix(limit))
    }

    static func files(in directory: URL = AppPaths.captures) -> [CaptureFile] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url -> CaptureFile? in
            guard url.pathExtension.lowercased() == "png" else { return nil }
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            guard values.isRegularFile == true else { return nil }
            let date = values.contentModificationDate ?? .distantPast
            return CaptureFile(url: url, date: date)
        }
        .sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.name > rhs.name
            }
            return lhs.date > rhs.date
        }
    }

    // MARK: - 编码

    static func encode(_ image: CGImage, format: ScreenshotFormat) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        let fileType: NSBitmapImageRep.FileType = format == .png ? .png : .jpeg
        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg
            ? [.compressionFactor: 0.9]
            : [:]
        guard let data = representation.representation(using: fileType, properties: properties) else {
            Log.screenshot.error("Image encoding failed for format \(format.rawValue, privacy: .public)")
            throw ScreenshotError.encodingFailed
        }
        return data
    }

    // MARK: - 写入

    /// 写入截图历史（始终 PNG），并淘汰旧文件。
    @discardableResult
    static func writeHistory(image: CGImage, date: Date = Date()) throws -> URL {
        let directory = AppPaths.captures
        try AppPaths.ensureDirectory(directory)
        let data = try encode(image, format: .png)
        let url = uniqueURL(in: directory, preferredName: preferredFileName(for: date, fileExtension: "png"))
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScreenshotError.fileWriteFailed(error.localizedDescription)
        }
        prune(directory: directory)
        return url
    }

    /// 按设置中的格式写入用户指定目录。
    @discardableResult
    static func writeFile(
        image: CGImage,
        format: ScreenshotFormat,
        directory: URL,
        date: Date = Date()
    ) throws -> URL {
        do {
            try AppPaths.ensureDirectory(directory)
        } catch {
            throw ScreenshotError.fileWriteFailed(error.localizedDescription)
        }
        let data = try encode(image, format: format)
        let url = uniqueURL(
            in: directory,
            preferredName: preferredFileName(for: date, fileExtension: format.fileExtension)
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScreenshotError.fileWriteFailed(error.localizedDescription)
        }
        return url
    }

    /// 删除超出保留数量的旧截图。失败只记录日志，不影响本次截图结果。
    static func prune(directory: URL = AppPaths.captures, keep: Int = maxRetained) {
        let all = files(in: directory)
        let stale = filesToPrune(from: all, keep: keep)
        guard !stale.isEmpty else { return }
        let fileManager = FileManager.default
        for file in stale {
            do {
                try fileManager.removeItem(at: file.url)
                Log.screenshot.info("Pruned old capture \(file.name, privacy: .public)")
            } catch {
                Log.screenshot.error(
                    "Failed to prune \(file.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
