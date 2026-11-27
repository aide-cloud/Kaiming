#if DEBUG
import AppKit
import Foundation

/// 调试自检：`Kaiming --logic-test-uninstall`。
/// 在 `~/Applications` 与 `~/Library` 下创建带测试前缀的假应用和关联文件，
/// 验证扫描、按 bundle id/应用名匹配、安全删除与诱饵保留，结束后全部清理。
enum AppUninstallerSelfTest {
    @MainActor
    static func run(reportPath: String?) {
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                runFixture()
            }.value
            print(report)
            if let reportPath {
                try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }

    nonisolated static func runFixture() -> String {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let appsDirectory = home.appendingPathComponent("Applications", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let testID = "com.kaiming.uninstall-test"
        let testName = "KaimingUninstallTest"
        let appURL = appsDirectory.appendingPathComponent("\(testName).app", isDirectory: true)
        let decoyID = "\(testID)2"
        let decoyName = "\(testName)2"
        var expected: [URL] = [appURL]
        var decoys: [URL] = []
        var setupErrors: [String] = []

        @discardableResult
        func write(_ url: URL, bytes: Int = 128) -> Bool {
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: bytes).write(to: url)
                return true
            } catch {
                setupErrors.append("\(url.path): \(error.localizedDescription)")
                return false
            }
        }

        func removeTree(_ url: URL) {
            try? fileManager.removeItem(at: url)
        }

        removeTree(appURL)
        defer {
            removeTree(appURL)
            for url in expected { removeTree(url) }
            for url in decoys { removeTree(url) }
        }

        // 假应用 bundle。
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        do {
            try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        } catch {
            setupErrors.append("\(contents.path): \(error.localizedDescription)")
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": testID,
            "CFBundleName": testName,
            "CFBundleDisplayName": "Kaiming Uninstall Test",
            "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "APPL",
        ]
        do {
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        } catch {
            setupErrors.append("Info.plist: \(error.localizedDescription)")
        }

        // 关联文件（bundle id + 应用名两条路径）。
        let supportByID = library.appendingPathComponent("Application Support/\(testID)", isDirectory: true)
        let supportName = library.appendingPathComponent("Application Support/\(testName)", isDirectory: true)
        let cacheByID = library.appendingPathComponent("Caches/\(testID)", isDirectory: true)
        let cacheName = library.appendingPathComponent("Caches/\(testName)", isDirectory: true)
        let preferences = library.appendingPathComponent("Preferences/\(testID).plist")
        let byHost = library.appendingPathComponent("Preferences/ByHost/\(testID).ABC.plist")
        let logsByID = library.appendingPathComponent("Logs/\(testID)", isDirectory: true)
        let logsName = library.appendingPathComponent("Logs/\(testName)", isDirectory: true)
        let savedState = library.appendingPathComponent("Saved Application State/\(testID).savedState", isDirectory: true)
        let webKit = library.appendingPathComponent("WebKit/\(testID)", isDirectory: true)
        let httpStorage = library.appendingPathComponent("HTTPStorages/\(testID)", isDirectory: true)
        let cookies = library.appendingPathComponent("Cookies/\(testID).binarycookies")
        let scripts = library.appendingPathComponent("Application Scripts/\(testID)", isDirectory: true)
        let launchAgent = library.appendingPathComponent("LaunchAgents/\(testID).plist")

        // 部分受 TCC 保护的目录（例如 Cookies）在未授权完全磁盘访问时会写失败；
        // 只有创建成功的路径才纳入断言，避免把环境限制误判成扫描/删除失败。
        var createdRelated: [URL] = []
        if write(supportByID.appendingPathComponent("old.bin"), bytes: 1_000_000) { createdRelated.append(supportByID) }
        if write(supportName.appendingPathComponent("name.bin"), bytes: 256_000) { createdRelated.append(supportName) }
        if write(cacheByID.appendingPathComponent("cache.bin"), bytes: 512_000) { createdRelated.append(cacheByID) }
        if write(cacheName.appendingPathComponent("name.bin"), bytes: 128_000) { createdRelated.append(cacheName) }
        if write(preferences, bytes: 4096) { createdRelated.append(preferences) }
        if write(byHost, bytes: 4096) { createdRelated.append(byHost) }
        if write(logsByID.appendingPathComponent("old.log"), bytes: 64_000) { createdRelated.append(logsByID) }
        if write(logsName.appendingPathComponent("old.log"), bytes: 32_000) { createdRelated.append(logsName) }
        if write(savedState.appendingPathComponent("data.bin"), bytes: 16_000) { createdRelated.append(savedState) }
        if write(webKit.appendingPathComponent("data.bin"), bytes: 8192) { createdRelated.append(webKit) }
        if write(httpStorage.appendingPathComponent("data.bin"), bytes: 8192) { createdRelated.append(httpStorage) }
        if write(cookies, bytes: 1024) { createdRelated.append(cookies) }
        if write(scripts.appendingPathComponent("script.scpt"), bytes: 1024) { createdRelated.append(scripts) }
        if write(launchAgent, bytes: 1024) { createdRelated.append(launchAgent) }
        expected.append(contentsOf: createdRelated)

        // 用户目录同名项：应被扫描并允许删除，但诱饵不能误伤。
        let userFolder = home.appendingPathComponent("Documents/\(testName)", isDirectory: true)
        if write(userFolder.appendingPathComponent("save.bin"), bytes: 64_000) { expected.append(userFolder) }

        // 诱饵：相似但不同的 bundle id / 应用名，必须保留。
        let decoyCache = library.appendingPathComponent("Caches/\(decoyID)", isDirectory: true)
        let decoySupport = library.appendingPathComponent("Application Support/\(decoyName)", isDirectory: true)
        let decoyUser = home.appendingPathComponent("Documents/\(decoyName)", isDirectory: true)
        if write(decoyCache.appendingPathComponent("keep.bin"), bytes: 32_000) { decoys.append(decoyCache) }
        if write(decoySupport.appendingPathComponent("keep.bin"), bytes: 32_000) { decoys.append(decoySupport) }
        if write(decoyUser.appendingPathComponent("keep.bin"), bytes: 32_000) { decoys.append(decoyUser) }

        let app = InstalledApp(
            url: appURL.standardizedFileURL,
            bundleID: testID,
            name: testName,
            version: "1.0"
        )

        let appExists = fileManager.fileExists(atPath: appURL.path)
        let readBundleID = Bundle(url: appURL)?.bundleIdentifier
        let inventory = AppInventory.scan()
        let inventoryFound = inventory.contains { $0.bundleID == testID }
        let items = AppResidueScanner.scan(app)
        let paths = Set(items.map(\.url.path))
        let expectedPaths = expected.map { $0.standardizedFileURL.path }
        let missing = expectedPaths.filter { !paths.contains($0) }
        let decoyLeaked = decoys.contains { paths.contains($0.standardizedFileURL.path) }
        let totalBytes = items.reduce(UInt64(0)) { $0 + $1.bytes }

        let outcome = AppResidueScanner.remove(items: items, app: app)
        let remaining = expectedPaths.filter { fileManager.fileExists(atPath: $0) }
        let decoysKept = decoys.allSatisfy { fileManager.fileExists(atPath: $0.path) }

        // 额外验证安全护栏：不允许删除 ~/Library。
        let guardLibrary = library.standardizedFileURL
        let unsafeItem = UninstallItem(url: guardLibrary, category: .support, bytes: 0, itemCount: 0)
        let guardOutcome = AppResidueScanner.remove(items: [unsafeItem], app: app)
        let guardOK = guardOutcome.failures.count == 1 && fileManager.fileExists(atPath: guardLibrary.path)

        let pass = inventoryFound
            && missing.isEmpty
            && !decoyLeaked
            && totalBytes > 0
            && outcome.failures.isEmpty
            && remaining.isEmpty
            && decoysKept
            && guardOK

        return "[uninstall-test] PASS=\(pass) appExists=\(appExists) readBundleID=\(readBundleID ?? "-") "
            + "inventory=\(inventoryFound) items=\(items.count) bytes=\(totalBytes) "
            + "removed=\(outcome.removedCount) failures=\(outcome.failures.count) missing=\(missing) "
            + "decoyLeaked=\(decoyLeaked) decoysKept=\(decoysKept) guard=\(guardOK) setupErrors=\(setupErrors)"
    }
}
#endif
