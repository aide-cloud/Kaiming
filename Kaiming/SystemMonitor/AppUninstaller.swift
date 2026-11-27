import AppKit
import Foundation
import Security

// MARK: - 数据模型

struct InstalledApp: Sendable, Equatable {
    let url: URL
    let bundleID: String
    let name: String
    let version: String?

    var id: String { url.standardizedFileURL.path }
}

enum UninstallCategory: Int, CaseIterable, Sendable {
    case app
    case userData
    case support
    case groupContainers
    case containers
    case caches
    case preferences
    case state
    case logs
    case web
    case scripts
    case plugins
    case launchAgents

    var title: String {
        switch self {
        case .app: "应用本体"
        case .userData: "用户目录"
        case .support: "支持文件"
        case .groupContainers: "共享容器"
        case .containers: "沙盒容器"
        case .caches: "缓存"
        case .preferences: "偏好设置"
        case .state: "窗口状态"
        case .logs: "日志"
        case .web: "网络数据"
        case .scripts: "应用脚本"
        case .plugins: "插件 / 扩展"
        case .launchAgents: "启动项"
        }
    }

    var symbolName: String {
        switch self {
        case .app: "app"
        case .userData: "folder"
        case .support: "folder"
        case .groupContainers: "square.stack.3d.up"
        case .containers: "shippingbox"
        case .caches: "archivebox"
        case .preferences: "slider.horizontal.3"
        case .state: "macwindow"
        case .logs: "doc.text"
        case .web: "globe"
        case .scripts: "applescript"
        case .plugins: "puzzlepiece.extension"
        case .launchAgents: "bolt"
        }
    }
}

struct UninstallItem: Identifiable, Sendable, Equatable {
    let url: URL
    let category: UninstallCategory
    let bytes: UInt64
    let itemCount: Int

    var id: String { url.standardizedFileURL.path }
}

struct UninstallOutcome: Sendable, Equatable {
    var freedBytes: UInt64 = 0
    var removedCount: Int = 0
    var failures: [String] = []

    static let empty = UninstallOutcome()
}

// MARK: - 已安装应用

enum AppInventory {
    /// 扫描 `/Applications` 与 `~/Applications`。
    /// 隐藏 Apple 系统应用与开明自身，避免误删系统应用或自我删除。
    static func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.kaiming.app"
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                let standardized = url.standardizedFileURL
                guard seen.insert(standardized.path).inserted else { continue }
                if (try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    continue
                }
                guard let bundle = Bundle(url: standardized),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.contains("/"),
                      !bundleID.contains(".."),
                      bundleID != ownBundleID,
                      !bundleID.hasPrefix("com.apple.") else {
                    continue
                }
                let name = displayName(for: standardized, bundle: bundle)
                let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
                apps.append(
                    InstalledApp(
                        url: standardized,
                        bundleID: bundleID,
                        name: name,
                        version: version
                    )
                )
            }
        }

        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func displayName(for url: URL, bundle: Bundle) -> String {
        let localized = bundle.localizedInfoDictionary
        let info = bundle.infoDictionary
        return (localized?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? (localized?["CFBundleName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - 关联文件扫描 / 删除

enum AppResidueScanner {
    private static let measurementCap = 300_000

    /// 按 bundle id + 文件系统应用名扫描用户目录下的已知位置。
    /// 只读：不修改任何文件。
    static func scan(_ app: InstalledApp) -> [UninstallItem] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let systemName = app.url.deletingPathExtension().lastPathComponent
        let bundleID = sanitizedBundleID(app.bundleID)

        var candidates: [(URL, UninstallCategory)] = []

        func add(_ url: URL, _ category: UninstallCategory) {
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            candidates.append((standardized, category))
        }

        add(app.url, .app)

        func addMatching(in directory: URL, prefix: String, category: UninstallCategory) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                guard matchesBundleIDEntry(name, prefix: prefix) else { continue }
                candidates.append((entry.standardizedFileURL, category))
            }
        }

        func addGroupContainerMatches(in directory: URL, bundleID: String, name: String) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }
            for entry in entries {
                let entryName = entry.lastPathComponent
                let matchesID = entryName == bundleID || entryName.hasSuffix("." + bundleID)
                let matchesName = name.count >= 4 && entryName.localizedCaseInsensitiveContains(name)
                guard matchesID || matchesName else { continue }
                candidates.append((entry.standardizedFileURL, .groupContainers))
            }
        }

        func addPluginComponents(in directory: URL, bundleID: String, name: String) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }
            for entry in entries {
                let entryName = entry.lastPathComponent
                let matchesID = entryName.localizedCaseInsensitiveContains(bundleID)
                let matchesName = name.count >= 4 && entryName.localizedCaseInsensitiveContains(name)
                guard matchesID || matchesName else { continue }
                candidates.append((entry.standardizedFileURL, .plugins))
            }
        }

        func addPreferenceFiles(in directory: URL, bundleID: String) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                let matchesID = name == bundleID + ".plist"
                    || (name.hasPrefix(bundleID + ".") && name.hasSuffix(".plist"))
                guard matchesID else { continue }
                candidates.append((entry.standardizedFileURL, .preferences))
            }
        }

        func addByHostPreferenceFiles(in directory: URL, bundleID: String) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasPrefix(bundleID + "."), name.hasSuffix(".plist") else { continue }
                candidates.append((entry.standardizedFileURL, .preferences))
            }
        }

        if let bundleID {
            addMatching(in: library.appendingPathComponent("Application Support"), prefix: bundleID, category: .support)
            addMatching(in: library.appendingPathComponent("Caches"), prefix: bundleID, category: .caches)
            addMatching(in: library.appendingPathComponent("Containers"), prefix: bundleID, category: .containers)
            addMatching(in: library.appendingPathComponent("Logs"), prefix: bundleID, category: .logs)
            addMatching(in: library.appendingPathComponent("LaunchAgents"), prefix: bundleID, category: .launchAgents)
            add(library.appendingPathComponent("Saved Application State/\(bundleID).savedState"), .state)
            add(library.appendingPathComponent("WebKit/\(bundleID)"), .web)
            add(library.appendingPathComponent("HTTPStorages/\(bundleID)"), .web)
            add(library.appendingPathComponent("Cookies/\(bundleID).binarycookies"), .web)
            add(library.appendingPathComponent("Application Scripts/\(bundleID)"), .scripts)

            addPreferenceFiles(in: library.appendingPathComponent("Preferences"), bundleID: bundleID)
            addByHostPreferenceFiles(in: library.appendingPathComponent("Preferences/ByHost"), bundleID: bundleID)
            addGroupContainerMatches(in: library.appendingPathComponent("Group Containers"), bundleID: bundleID, name: systemName)
            for group in applicationGroups(for: app.url) {
                add(library.appendingPathComponent("Group Containers/\(group)"), .groupContainers)
            }
            for root in [
                "QuickLook", "Spotlight", "Services", "PreferencePanes",
                "Internet Plug-Ins", "Input Methods", "Screen Savers", "Audio/Plug-Ins", "Workflow",
            ] {
                addPluginComponents(
                    in: library.appendingPathComponent(root),
                    bundleID: bundleID,
                    name: systemName
                )
            }
        }

        if !systemName.isEmpty, systemName != ".", systemName != ".." {
            add(library.appendingPathComponent("Application Support/\(systemName)"), .support)
            add(library.appendingPathComponent("Caches/\(systemName)"), .caches)
            add(library.appendingPathComponent("Logs/\(systemName)"), .logs)
        }

        for url in userDirectoryMatches(
            home: home,
            systemName: systemName,
            displayName: app.name,
            bundleID: bundleID
        ) {
            candidates.append((url, .userData))
        }

        // 去重后按父目录剪枝：父目录已删除时，不再单独列出子项。
        var unique: [String: (URL, UninstallCategory)] = [:]
        for (url, category) in candidates {
            let key = url.path
            if unique[key] == nil { unique[key] = (url, category) }
        }
        let measured = unique.values.map { url, category -> UninstallItem in
            let size = measure(url)
            return UninstallItem(
                url: url,
                category: category,
                bytes: size.bytes,
                itemCount: size.items
            )
        }
        let sorted = measured.sorted { $0.url.path.count < $1.url.path.count }
        var pruned: [UninstallItem] = []
        for item in sorted {
            if pruned.contains(where: { item.url.path.hasPrefix($0.url.path + "/") }) { continue }
            pruned.append(item)
        }
        return pruned.sorted { lhs, rhs in
            if lhs.category.rawValue != rhs.category.rawValue {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
    }

    /// 删除扫描结果。`app` 用于校验：只有该应用的 `.app` 本体允许被删除。
    ///
    /// 先删应用本体；本体删除失败时立即中止，避免留下一个被清掉缓存的坏应用。
    static func remove(items: [UninstallItem], app: InstalledApp) -> UninstallOutcome {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let appPath = app.url.standardizedFileURL.path
        let ownBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        var outcome = UninstallOutcome()

        guard let appItem = items.first(where: { $0.category == .app }) else {
            outcome.failures.append("未包含应用本体，已取消卸载。")
            return outcome
        }

        for item in [appItem] + items.filter({ $0.id != appItem.id }) {
            let path = item.url.standardizedFileURL.path
            guard isDeletable(
                path: path,
                appPath: appPath,
                category: item.category,
                home: home,
                ownBundlePath: ownBundlePath
            ) else {
                outcome.failures.append("跳过不安全路径：\(path)")
                if item.category == .app { return outcome }
                continue
            }
            do {
                try fileManager.removeItem(at: item.url)
                outcome.freedBytes += item.bytes
                outcome.removedCount += 1
            } catch {
                outcome.failures.append("\(path)：\(error.localizedDescription)")
                if item.category == .app { return outcome }
            }
        }
        return outcome
    }

    private static func isDeletable(
        path: String,
        appPath: String,
        category: UninstallCategory,
        home: String,
        ownBundlePath: String
    ) -> Bool {
        if path == ownBundlePath || path.hasPrefix(ownBundlePath + "/") { return false }
        if category == .userData {
            return isDeletableUserData(path: path, home: home)
        }
        if category == .app {
            guard path == appPath, path.hasSuffix(".app") else { return false }
            return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
        }
        guard path.hasPrefix(home + "/Library/"), path != home + "/Library" else { return false }
        return true
    }

    /// 目录名是否属于该 bundle id。
    ///
    /// 允许 `com.foo.Bar`、`com.foo.Bar.helper`、`com.foo.BarHelper`，
    /// 但拒绝 `com.foo.Bar2` 这类仅数字后缀的相似 bundle id，避免误伤其他应用。
    private static func matchesBundleIDEntry(_ name: String, prefix: String) -> Bool {
        if name == prefix || name.hasPrefix(prefix + ".") { return true }
        guard name.hasPrefix(prefix), name.count > prefix.count else { return false }
        let nextIndex = name.index(name.startIndex, offsetBy: prefix.count)
        let next = name[nextIndex]
        return next.isLetter || next == "_" || next == "-"
    }

    /// 用户目录同名项只允许删除「常用目录的直接子项」，拒绝目录根与受保护的系统文件夹。
    private static func isDeletableUserData(path: String, home: String) -> Bool {
        let protected: Set<String> = [
            "Library", "Applications", "Documents", "Downloads", "Desktop",
            "Pictures", "Movies", "Music", "Public", "Sites",
        ]
        let roots = [
            home,
            home + "/Documents",
            home + "/Downloads",
            home + "/Desktop",
            home + "/Pictures",
            home + "/Movies",
            home + "/Music",
            home + "/Public",
        ]
        for root in roots {
            let prefix = root + "/"
            guard path.hasPrefix(prefix) else { continue }
            let remainder = String(path.dropFirst(prefix.count))
            guard !remainder.isEmpty, !remainder.contains("/") else { continue }
            if root == home, protected.contains(remainder) { return false }
            return true
        }
        return false
    }

    /// 扫描用户常用目录中与 App 同名/同 bundle id 的顶层文件与文件夹。
    /// 这是启发式匹配：默认随卸载勾选，但界面会明确标注“可能包含个人文件”，可取消。
    private static func userDirectoryMatches(
        home: URL,
        systemName: String,
        displayName: String,
        bundleID: String?
    ) -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []
        let protected: Set<String> = [
            "Library", "Applications", "Documents", "Downloads", "Desktop",
            "Pictures", "Movies", "Music", "Public", "Pictures", "Sites", "Library",
        ]
        let safeDisplayName = displayName == "." || displayName == ".." || displayName.contains("/")
            ? nil
            : displayName
        let directories = [
            home,
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Music", isDirectory: true),
            home.appendingPathComponent("Public", isDirectory: true),
        ]
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            let isHome = directory.standardizedFileURL == home.standardizedFileURL
            for entry in entries {
                let name = entry.lastPathComponent
                if isHome && protected.contains(name) { continue }
                var matches = name.localizedCaseInsensitiveCompare(systemName) == .orderedSame
                if let safeDisplayName, !safeDisplayName.isEmpty {
                    matches = matches || name.localizedCaseInsensitiveCompare(safeDisplayName) == .orderedSame
                }
                if let bundleID {
                    matches = matches || name.localizedCaseInsensitiveCompare(bundleID) == .orderedSame
                }
                guard matches else { continue }
                result.append(entry.standardizedFileURL)
            }
        }
        return result
    }

    /// 从代码签名 entitlements 读取 App Group，精确定位 Group Containers。
    /// 未签名 / 无权限时返回空数组，后续仍会用 bundle id 后缀做启发式匹配。
    private static func applicationGroups(for appURL: URL) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return []
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return []
        }
        let raw = dictionary[kSecCodeInfoEntitlements as String]
        var entitlements: [String: Any]?
        if let rawDictionary = raw as? [String: Any] {
            entitlements = rawDictionary
        } else if let data = raw as? Data {
            entitlements = (try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )) as? [String: Any]
        }
        return entitlements?["com.apple.security.application-groups"] as? [String] ?? []
    }

    private static func sanitizedBundleID(_ id: String) -> String? {
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { return nil }
        return id
    }

    private static func measure(_ url: URL) -> (bytes: UInt64, items: Int) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        let keySet = Set(keys)

        if let values = try? url.resourceValues(forKeys: keySet) {
            if values.isSymbolicLink == true { return (0, 1) }
            if values.isRegularFile == true {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
                return (UInt64(max(size, 0)), 1)
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }

        var bytes: UInt64 = 0
        var items = 0
        for case let fileURL as URL in enumerator {
            if items >= measurementCap { break }
            let values = try? fileURL.resourceValues(forKeys: keySet)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0
            bytes += UInt64(max(size, 0))
            items += 1
        }
        return (bytes, items)
    }
}

// MARK: - 面板模型

struct AppUninstallRow: Identifiable {
    let app: InstalledApp
    let icon: NSImage?
    let isRunning: Bool

    var id: String { app.id }
}

@MainActor
final class AppUninstallModel: ObservableObject {
    @Published private(set) var apps: [AppUninstallRow] = []
    @Published var query = ""
    @Published private(set) var selected: AppUninstallRow?
    @Published private(set) var items: [UninstallItem] = []
    @Published private(set) var checkedIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var errorMessage: String?

    private var iconCache: [String: NSImage] = [:]
    private var didLoad = false

    var filteredApps: [AppUninstallRow] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return apps }
        return apps.filter {
            $0.app.name.lowercased().contains(keyword)
                || $0.app.bundleID.lowercased().contains(keyword)
        }
    }

    var checkedItems: [UninstallItem] {
        items.filter { checkedIDs.contains($0.id) }
    }

    var checkedBytes: UInt64 {
        checkedItems.reduce(0) { $0 + $1.bytes }
    }

    var totalBytes: UInt64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    func isChecked(_ item: UninstallItem) -> Bool {
        checkedIDs.contains(item.id)
    }

    func loadAppsIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        reloadApps()
    }

    func reloadApps() {
        guard !isLoading else { return }
        isLoading = true
        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                AppInventory.scan()
            }.value
            guard let self else { return }
            self.apps = self.makeRows(scanned)
            self.isLoading = false
        }
    }

    func select(_ row: AppUninstallRow) {
        selected = row
        items = []
        checkedIDs = []
        errorMessage = nil
        isScanning = true
        let app = row.app
        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                AppResidueScanner.scan(app)
            }.value
            guard let self, self.selected?.app.id == app.id else { return }
            self.items = scanned
            // 默认全选；用户目录项在 UI 中带橙色警告，可在确认前取消。
            self.checkedIDs = Set(scanned.map(\.id))
            self.isScanning = false
        }
    }

    func clearSelection() {
        selected = nil
        items = []
        checkedIDs = []
        errorMessage = nil
    }

    func rescan() {
        guard let selected else { return }
        select(selected)
    }

    func toggle(_ item: UninstallItem) {
        guard item.category != .app else { return }
        if checkedIDs.contains(item.id) {
            checkedIDs.remove(item.id)
        } else {
            checkedIDs.insert(item.id)
        }
    }

    func setAllChecked(_ checked: Bool) {
        if checked {
            checkedIDs = Set(items.map(\.id))
        } else {
            checkedIDs = Set(items.filter { $0.category == .app }.map(\.id))
        }
    }

    func uninstall() async -> UninstallOutcome? {
        guard let selected, !isScanning, !isRemoving else { return nil }
        let targets = checkedItems
        guard targets.contains(where: { $0.category == .app }) else {
            errorMessage = "应用本体未被选中，无法卸载。"
            return nil
        }
        guard FileManager.default.fileExists(atPath: selected.app.url.path) else {
            errorMessage = "应用已不存在，正在刷新列表。"
            reloadApps()
            clearSelection()
            return nil
        }
        isRemoving = true
        defer { isRemoving = false }
        errorMessage = nil

        guard await quitIfNeeded(selected.app) else {
            errorMessage = "未能退出该应用，请手动退出后重试。"
            return nil
        }

        let app = selected.app
        let outcome = await Task.detached(priority: .userInitiated) {
            AppResidueScanner.remove(items: targets, app: app)
        }.value
        Log.system.info(
            "Uninstall \(app.bundleID, privacy: .public): removed=\(outcome.removedCount, privacy: .public) freed=\(outcome.freedBytes, privacy: .public) failures=\(outcome.failures.count, privacy: .public)"
        )

        let appStillExists = FileManager.default.fileExists(atPath: app.url.path)
        if appStillExists {
            // 应用本体没有删掉：保留详情页，直接展示失败原因。
            errorMessage = outcome.failures.first ?? "删除失败，请检查权限。"
            reloadApps()
        } else if !outcome.failures.isEmpty {
            // 应用已删除但部分关联文件失败：保留详情页，让用户看到失败摘要。
            errorMessage = "应用已删除；\(outcome.failures.count) 项关联文件删除失败。可返回列表后重试清理。"
            reloadApps()
        } else {
            reloadApps()
            clearSelection()
        }
        return outcome
    }

    private func quitIfNeeded(_ app: InstalledApp) async -> Bool {
        let appPath = app.url.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter { run in
            guard let path = run.bundleURL?.standardizedFileURL.path else { return false }
            return path == appPath || path.hasPrefix(appPath + "/")
        }
        guard !running.isEmpty else { return true }
        for run in running { _ = run.terminate() }
        for _ in 0..<30 {
            if running.allSatisfy({ $0.isTerminated }) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return running.allSatisfy({ $0.isTerminated })
    }

    private func makeRows(_ scanned: [InstalledApp]) -> [AppUninstallRow] {
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
        return scanned.map { app in
            AppUninstallRow(
                app: app,
                icon: icon(for: app.url),
                isRunning: runningIDs.contains(app.bundleID) || runningPaths.contains(app.url.path)
            )
        }
    }

    private func icon(for url: URL) -> NSImage? {
        let key = url.path
        if let cached = iconCache[key] { return cached }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let icon = source.copy() as? NSImage ?? source
        icon.size = NSSize(width: 20, height: 20)
        iconCache[key] = icon
        return icon
    }
}
