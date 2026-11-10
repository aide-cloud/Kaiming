import AppKit
import Combine
import Foundation

/// 应用中心的数据模型：已安装应用 + 最近打开过的目录。
@MainActor
final class AppCenterModel: ObservableObject {
    struct InstalledApp: Identifiable, Equatable {
        let id: String
        let url: URL
        let name: String
        var icon: NSImage?
    }

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var recentFolders: [URL] = []
    @Published private(set) var isLoading = false

    private let defaults: UserDefaults
    private static let recentFoldersKey = "kaiming.appcenter.recentFolders"
    private static let maxRecentFolders = 6

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentFolders = (defaults.stringArray(forKey: Self.recentFoldersKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 加载

    func reload() {
        guard !isLoading else { return }
        isLoading = true

        Task { @MainActor [weak self] in
            let urls = await Task.detached(priority: .utility) {
                Self.scanApplications()
            }.value

            guard let self else { return }
            let icons = urls.map { url -> NSImage? in
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 40, height: 40)
                return icon
            }
            apps = zip(urls, icons).map { url, icon in
                InstalledApp(
                    id: url.path,
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    icon: icon
                )
            }
            isLoading = false
            Log.app.info("App center loaded \(self.apps.count, privacy: .public) applications")
        }
    }

    private nonisolated static func scanApplications() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]

        var seen = Set<String>()
        var result: [URL] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                let relativeDepth = url.pathComponents.count - root.pathComponents.count
                guard relativeDepth <= 2 else { continue }

                // 跳过应用包内部的辅助 app
                if url.pathComponents.contains(where: { $0.hasSuffix(".app") && $0 != url.lastPathComponent }) {
                    continue
                }

                let standardized = url.standardizedFileURL.path
                guard seen.insert(standardized).inserted else { continue }
                result.append(url)
                if result.count >= 160 { break }
            }
            if result.count >= 160 { break }
        }

        return result.sorted {
            $0.deletingPathExtension().lastPathComponent
                .localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - 动作

    func launch(_ app: InstalledApp) {
        guard NSWorkspace.shared.open(app.url) else {
            AppState.shared.flash("无法启动 \(app.name)。", kind: .error)
            return
        }
        Log.app.info("Launched application \(app.name, privacy: .public)")
    }

    func reveal(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    /// 在 Markdown 窗口中打开目录（并记住最近目录）。
    func openInMarkdown(folder: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            AppState.shared.flash("目录不存在：\(folder.lastPathComponent)", kind: .error)
            return
        }

        remember(folder: folder)
        MarkdownOpenRequest.shared.open(folder: folder)
        AppRouter.shared.openMarkdown()
        Log.app.info("Opening folder in Markdown: \(folder.path, privacy: .public)")
    }

    func forgetRecentFolders() {
        recentFolders = []
        defaults.removeObject(forKey: Self.recentFoldersKey)
    }

    private func remember(folder: URL) {
        let path = folder.standardizedFileURL.path
        var paths = recentFolders.map(\.path)
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.maxRecentFolders {
            paths = Array(paths.prefix(Self.maxRecentFolders))
        }
        recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        defaults.set(paths, forKey: Self.recentFoldersKey)
    }
}
