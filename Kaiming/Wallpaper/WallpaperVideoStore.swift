import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

/// 视频壁纸相关的错误；`errorDescription` 直接用于用户提示。
enum WallpaperVideoError: LocalizedError {
    case unsupportedFormat
    case unplayable(String)
    case noVideoTrack
    case invalidDuration
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "仅支持 MP4 / MOV / M4V 视频"
        case .unplayable(let name):
            "视频无法播放：\(name)"
        case .noVideoTrack:
            "视频中没有可用的视频轨道"
        case .invalidDuration:
            "视频时长无效"
        case .copyFailed(let reason):
            "复制视频失败：\(reason)"
        }
    }
}

/// 一段可播放的视频信息（首帧缩略图、时长、像素尺寸）。全部为 `Sendable` 数据，可安全回传主线程。
struct WallpaperVideoInfo: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnailData: Data?
}

/// 动态壁纸的持久化状态：视频绝对路径 + 启用的屏幕 id。
struct WallpaperDynamicState: Codable, Sendable {
    let videoPath: String
    let screenIDs: [String]
}

/// 动态壁纸的视频仓库：校验、持久化复制、首帧缩略图与跨启动状态文件。
///
/// macOS 没有公开 API 把视频设为系统壁纸，本模块通过桌面层窗口播放（见 DynamicWallpaperController）。
enum WallpaperVideoStore {
    static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let stateFileName = "dynamic-wallpaper.json"

    // MARK: - 校验

    static func isSupportedVideoFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return false
        }
        let fileExtension = url.pathExtension.lowercased()
        guard supportedVideoExtensions.contains(fileExtension),
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// 用 AVFoundation 校验可播放性，并生成首帧缩略图。任何失败都会抛出中文错误。
    static func inspectVideo(url: URL) async throws -> WallpaperVideoInfo {
        guard isSupportedVideoFile(url) else {
            throw WallpaperVideoError.unsupportedFormat
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw WallpaperVideoError.unplayable(url.lastPathComponent)
        }

        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw WallpaperVideoError.invalidDuration
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw WallpaperVideoError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        let width = max(1, Int(abs(transformedSize.width).rounded()))
        let height = max(1, Int(abs(transformedSize.height).rounded()))
        let thumbnail = await thumbnailPNGData(for: asset, duration: seconds)

        return WallpaperVideoInfo(
            url: url,
            duration: seconds,
            pixelWidth: width,
            pixelHeight: height,
            thumbnailData: thumbnail
        )
    }

    // MARK: - 持久化复制

    /// 把视频原样复制到 `AppPaths.wallpapers/<UUID>.<ext>`，绝不引用用户选择的原始位置。
    static func storeVideoFile(_ source: URL) async throws -> URL {
        try await WallpaperFileStore.perform {
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw WallpaperVideoError.unplayable(source.lastPathComponent)
            }
            let fileExtension = source.pathExtension.lowercased()
            guard supportedVideoExtensions.contains(fileExtension) else {
                throw WallpaperVideoError.unsupportedFormat
            }

            let directory = try AppPaths.ensureDirectory(AppPaths.wallpapers)
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString).\(fileExtension)",
                isDirectory: false
            )

            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw WallpaperVideoError.copyFailed(error.localizedDescription)
            }

            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard FileManager.default.isReadableFile(atPath: destination.path), size > 0 else {
                try? FileManager.default.removeItem(at: destination)
                throw WallpaperVideoError.unplayable(destination.lastPathComponent)
            }
            return destination
        }
    }

    // MARK: - 跨启动状态

    /// `AppPaths.applicationSupport/dynamic-wallpaper.json`；文件不存在时返回 nil。
    static func loadState() async -> WallpaperDynamicState? {
        do {
            return try await WallpaperFileStore.perform {
                let url = stateFileURL
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(WallpaperDynamicState.self, from: data)
            }
        } catch {
            Log.wallpaper.error("Load dynamic wallpaper state failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func saveState(_ state: WallpaperDynamicState) async {
        do {
            try await WallpaperFileStore.perform {
                let directory = try AppPaths.ensureDirectory(AppPaths.applicationSupport)
                let data = try JSONEncoder().encode(state)
                try data.write(
                    to: directory.appendingPathComponent(stateFileName, isDirectory: false),
                    options: .atomic
                )
            }
            Log.wallpaper.info("Dynamic wallpaper state saved for \(state.screenIDs.count, privacy: .public) screen(s)")
        } catch {
            Log.wallpaper.error("Save dynamic wallpaper state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clearState() async {
        do {
            try await WallpaperFileStore.perform {
                let url = stateFileURL
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            Log.wallpaper.info("Dynamic wallpaper state cleared")
        } catch {
            Log.wallpaper.error("Clear dynamic wallpaper state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var stateFileURL: URL {
        AppPaths.applicationSupport.appendingPathComponent(stateFileName, isDirectory: false)
    }

    // MARK: - 缩略图

    /// 首帧缩略图；部分视频首帧不可解码时回退到 0.1~0.3 秒处。
    private static func thumbnailPNGData(for asset: AVAsset, duration: TimeInterval) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        let fallbackSeconds = min(0.3, max(0.05, duration * 0.1))
        let candidates: [CMTime] = [
            .zero,
            CMTime(seconds: fallbackSeconds, preferredTimescale: 600)
        ]
        for time in candidates {
            if let result = try? await generator.image(at: time) {
                return WallpaperFileStore.pngData(from: result.image)
            }
        }
        return nil
    }
}
