import Foundation

/// 应用数据目录的统一约定。
///
/// 约定：
/// - 截图历史 / 剪贴板缓存 / 壁纸都放在 Application Support/Kaiming 下，**不允许**指向临时目录；
/// - 默认截图保存目录为 ~/Pictures/Kaiming，可在设置中修改。
enum AppPaths {
    static var applicationSupport: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Kaiming", isDirectory: true)
    }

    static var wallpapers: URL { applicationSupport.appendingPathComponent("Wallpapers", isDirectory: true) }
    static var captures: URL { applicationSupport.appendingPathComponent("Captures", isDirectory: true) }
    static var clipboardStore: URL { applicationSupport.appendingPathComponent("Clipboard", isDirectory: true) }

    static var defaultScreenshots: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Kaiming", isDirectory: true)
    }

    /// 确保目录存在；返回同一 URL 便于链式调用。
    @discardableResult
    static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
