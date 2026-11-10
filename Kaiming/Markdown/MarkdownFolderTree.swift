import Foundation

/// 侧边栏目录树中的一个条目（文件夹或 Markdown 文件）。
struct MarkdownTreeNode: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool

    var id: URL { url }
}

/// 目录读取的后台结果。`Result` 的 Failure 必须是 `Error`，这里用专用枚举更直白。
private enum MarkdownDirectoryReadResult: Sendable {
    case entries([MarkdownTreeNode])
    case failure(String)
}

/// 侧边栏目录树的数据源。
///
/// - 只读取目录与 `.md` / `.markdown` 文件，文件夹优先排序；
/// - 根目录打开后自动展开，子目录在第一次展开时才读取（懒加载）；
/// - 目录读取在后台队列完成，主线程只更新 `@Published` 状态；
/// - 最近打开的目录保存在模块自己的 `UserDefaults` 键里。
@MainActor
final class MarkdownFolderTree: ObservableObject {
    /// 全 App 共享的目录树状态：外部打开请求可能先被另一个 Markdown 窗口视图消费，
    /// 共享同一棵树可以让所有存活的窗口（包括调试快照窗口）都看到同一个目录。
    static let shared = MarkdownFolderTree()

    @Published private(set) var rootURL: URL?
    @Published private(set) var childrenByDirectory: [URL: [MarkdownTreeNode]] = [:]
    @Published private(set) var expandedDirectories: Set<URL> = []
    @Published private(set) var loadingDirectories: Set<URL> = []
    @Published private(set) var errorMessage: String?

    private static let recentFolderKey = "kaiming.markdown.sidebar.recentFolderPath"

    private var loadTokens: [URL: UUID] = [:]
    private var scopedRootURL: URL?

    // MARK: - 派生状态

    var rootChildren: [MarkdownTreeNode] {
        guard let rootURL else { return [] }
        return childrenByDirectory[rootURL] ?? []
    }

    var isLoadingRoot: Bool {
        guard let rootURL else { return false }
        return loadingDirectories.contains(rootURL)
    }

    func children(of directory: URL) -> [MarkdownTreeNode]? {
        childrenByDirectory[directory]
    }

    func isExpanded(_ directory: URL) -> Bool {
        expandedDirectories.contains(directory)
    }

    func isLoading(_ directory: URL) -> Bool {
        loadingDirectories.contains(directory)
    }

    // MARK: - 打开 / 刷新

    func open(folder: URL, remember: Bool = true) {
        let standardized = folder.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            setError("无法打开文件夹：路径不存在或不是文件夹（\(folder.path)）")
            return
        }

        if standardized == rootURL {
            refresh()
            return
        }

        releaseScopedAccess()
        if standardized.startAccessingSecurityScopedResource() {
            scopedRootURL = standardized
        }

        rootURL = standardized
        childrenByDirectory = [:]
        expandedDirectories = [standardized]
        loadingDirectories = []
        errorMessage = nil
        loadTokens = [:]

        if remember {
            UserDefaults.standard.set(standardized.path, forKey: Self.recentFolderKey)
        }

        loadChildren(of: standardized, force: true)
        Log.markdown.info("Opened Markdown folder \(standardized.path, privacy: .public)")
    }

    /// 重新读取根目录以及所有已经加载过的子目录，展开状态保持不变。
    func refresh() {
        guard let rootURL else { return }
        errorMessage = nil
        let directories = Set(childrenByDirectory.keys).union([rootURL])
        for directory in directories {
            loadChildren(of: directory, force: true)
        }
        Log.markdown.info("Refreshed Markdown folder tree at \(rootURL.path, privacy: .public)")
    }

    func toggleDirectory(_ url: URL) {
        if expandedDirectories.contains(url) {
            expandedDirectories.remove(url)
        } else {
            expandedDirectories.insert(url)
            if childrenByDirectory[url] == nil {
                loadChildren(of: url, force: false)
            }
        }
    }

    // MARK: - 最近目录

    @discardableResult
    func restoreRecentFolder() -> Bool {
        guard rootURL == nil else { return true }
        guard let path = UserDefaults.standard.string(forKey: Self.recentFolderKey), !path.isEmpty else {
            return false
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            UserDefaults.standard.removeObject(forKey: Self.recentFolderKey)
            return false
        }

        open(folder: url, remember: false)
        return rootURL != nil
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 目录读取

    private func loadChildren(of directory: URL, force: Bool) {
        if !force, childrenByDirectory[directory] != nil {
            return
        }

        let token = UUID()
        loadTokens[directory] = token
        loadingDirectories.insert(directory)

        Task { @MainActor [weak self] in
            let result = await Self.readEntries(in: directory)
            guard let self, self.loadTokens[directory] == token else { return }
            self.loadTokens[directory] = nil
            self.loadingDirectories.remove(directory)

            switch result {
            case .entries(let nodes):
                self.childrenByDirectory[directory] = nodes
            case .failure(let message):
                self.childrenByDirectory[directory] = []
                self.setError(message)
            }
        }
    }

    private nonisolated static func readEntries(
        in directory: URL
    ) async -> MarkdownDirectoryReadResult {
        await Task.detached(priority: .userInitiated) { () -> MarkdownDirectoryReadResult in
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey
            ]
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )

                var nodes: [MarkdownTreeNode] = []
                nodes.reserveCapacity(urls.count)

                for url in urls {
                    let values = try? url.resourceValues(forKeys: keys)
                    // 跳过符号链接，避免目录环。
                    if values?.isSymbolicLink == true { continue }
                    if values?.isDirectory == true {
                        nodes.append(
                            MarkdownTreeNode(
                                url: url.standardizedFileURL,
                                name: url.lastPathComponent,
                                isDirectory: true
                            )
                        )
                    } else if MarkdownFileTypes.isMarkdownFile(url) {
                        nodes.append(
                            MarkdownTreeNode(
                                url: url.standardizedFileURL,
                                name: url.lastPathComponent,
                                isDirectory: false
                            )
                        )
                    }
                }

                nodes.sort { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return .entries(nodes)
            } catch {
                return .failure("无法读取目录“\(directory.lastPathComponent)”：\(error.localizedDescription)")
            }
        }.value
    }

    // MARK: - 私有

    private func setError(_ message: String) {
        errorMessage = message
        Log.markdown.error("\(message, privacy: .public)")
        AppState.shared.flash(message, kind: .error)
    }

    private func releaseScopedAccess() {
        if let scopedRootURL {
            scopedRootURL.stopAccessingSecurityScopedResource()
        }
        scopedRootURL = nil
    }
}
