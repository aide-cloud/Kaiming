import Foundation
import UniformTypeIdentifiers

/// 壁纸内容类型：统一入口只区分「图片」与「视频」两类，不再要求用户先选媒体类型。
///
/// 判定顺序：
/// 1. 优先读取文件系统给出的 `UTType`（`contentTypeKey`），按 `conforms(to: .image)` 与
///    `.movie` / `.video` 分类；
/// 2. `UTType` 缺失或无法解析时用扩展名兜底：视频看
///    `WallpaperVideoStore.supportedVideoExtensions`（mp4 / mov / m4v 等），图片再看一次 `UTType`。
enum WallpaperContentKind: Sendable {
    case image
    case video

    /// 统一入口与剪贴板共用的类型判定；既不是图片也不是视频时返回 `nil`。
    static func kind(for url: URL) -> WallpaperContentKind? {
        if let type = contentType(for: url) {
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return .video
            }
        }

        let fileExtension = url.pathExtension.lowercased()
        if WallpaperVideoStore.supportedVideoExtensions.contains(fileExtension) {
            return .video
        }
        if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .image) {
            return .image
        }
        return nil
    }

    private static func contentType(for url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }
}
