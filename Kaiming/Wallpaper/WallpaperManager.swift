import AppKit
import Combine

/// 一块屏幕（显示器）的壁纸状态。
struct ScreenInfo: Identifiable, Equatable {
    let id: String
    var name: String
    var isMain: Bool
    var currentWallpaper: URL?
    var pixelSize: CGSize
}

/// 壁纸模块入口。
///
/// 约定：
/// - `NSWorkspace.setDesktopImageURL` 只在主线程（本类为 `@MainActor`）调用；
/// - 所有输入图片先复制到 `AppPaths.wallpapers`（UUID 文件名），绝不引用临时路径；
/// - 成功时 `AppState.flash("已设为壁纸", kind: .success)`，失败时给出可操作的中文提示。
@MainActor
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    /// 当前所有显示器，随 `NSApplication.didChangeScreenParametersNotification` 自动刷新。
    @Published private(set) var screens: [ScreenInfo] = []
    /// 是否有进行中的壁纸写入 / 设置操作（UI 用于 loading 与防重复点击）。
    @Published private(set) var isBusy = false
    /// `AppPaths.captures` 中最近 12 张截图（按修改时间倒序，缩略图已生成）。
    @Published private(set) var recentCaptures: [WallpaperRecentCapture] = []
    @Published private(set) var isLoadingCaptures = false
    /// `AppPaths.captures` 存在但不可读时为 true，UI 会给出明确提示。
    @Published private(set) var capturesDirectoryUnreadable = false

    /// 可选能力：文件夹轮换。状态只存在于本次运行的内存中，不新增 UserDefaults 键。
    @Published private(set) var isRotating = false
    @Published private(set) var rotationFolder: URL?
    @Published private(set) var rotationInterval: TimeInterval = 300

    private var screenObserver: NSObjectProtocol?
    private var rotationTask: Task<Void, Never>?
    private var rotationScreenIDs: Set<String> = []
    private var rotationTick = 0
    private var thumbnailCache: [String: Data] = [:]

    private init() {
        refreshScreens()
        observeScreenChanges()
        Log.wallpaper.info("WallpaperManager ready with \(self.screens.count, privacy: .public) screen(s)")
    }

    // MARK: - 屏幕

    /// 重新枚举 `NSScreen`，更新稳定 display id、名称、主屏标记、像素尺寸与当前壁纸。
    func refreshScreens() {
        let currentScreens = NSScreen.screens
        let mainScreen = NSScreen.main
        var infos: [ScreenInfo] = []
        infos.reserveCapacity(currentScreens.count)

        for screen in currentScreens {
            guard let displayID = Self.displayID(for: screen) else {
                Log.wallpaper.error("Cannot resolve CGDirectDisplayID for \(screen.localizedName, privacy: .public)")
                continue
            }
            let scale = screen.backingScaleFactor
            infos.append(
                ScreenInfo(
                    id: Self.screenIdentifier(displayID: displayID),
                    name: screen.localizedName,
                    isMain: screen == mainScreen,
                    currentWallpaper: NSWorkspace.shared.desktopImageURL(for: screen),
                    pixelSize: CGSize(
                        width: screen.frame.width * scale,
                        height: screen.frame.height * scale
                    )
                )
            )
        }

        if infos != screens {
            screens = infos
            Log.wallpaper.info(
                "Refreshed \(infos.count, privacy: .public) screen(s): \(infos.map(\.id).joined(separator: ", "), privacy: .public)"
            )
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScreens()
                self.rotationScreenIDs.formIntersection(self.screens.map(\.id))
                Log.wallpaper.info("Screen parameters changed; refresh finished")
            }
        }
    }

    // MARK: - 设置壁纸（公开入口）

    func setWallpaper(image: NSImage, screenIDs: Set<String>) {
        guard !isBusy else {
            Log.wallpaper.info("Ignore setWallpaper(image:) while busy")
            return
        }
        guard let targets = resolveTargets(screenIDs) else { return }
        guard let tiffData = image.tiffRepresentation else {
            AppState.shared.flash("设置壁纸失败：无法读取图片数据", kind: .error)
            Log.wallpaper.error("NSImage.tiffRepresentation returned nil")
            return
        }

        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let storedURL = try await WallpaperFileStore.storeImageData(tiffData, sourceExtension: "tiff")
                self.finishInstall(storedURL: storedURL, screenIDs: targets, announce: true)
            } catch {
                self.finishFailure(error)
            }
        }
    }

    func setWallpaper(fileURL: URL, screenIDs: Set<String>) {
        guard !isBusy else {
            Log.wallpaper.info("Ignore setWallpaper(fileURL:) while busy")
            return
        }
        guard let targets = resolveTargets(screenIDs) else { return }

        let source = fileURL
        let accessing = source.startAccessingSecurityScopedResource()
        isBusy = true
        Log.wallpaper.info("Importing wallpaper from \(source.lastPathComponent, privacy: .public)")

        Task { [weak self] in
            defer {
                if accessing { source.stopAccessingSecurityScopedResource() }
            }
            guard let self else { return }
            do {
                let storedURL = try await WallpaperFileStore.storeImageFile(source)
                self.finishInstall(storedURL: storedURL, screenIDs: targets, announce: true)
            } catch {
                self.finishFailure(error)
            }
        }
    }

    /// 从 `NSPasteboard.general` 读取图片（PNG / TIFF / 图片文件路径）后设为壁纸。
    /// 剪贴板访问全部串行化在 `WallpaperIO.pasteboard` 队列上。
    func setFromPasteboard(screenIDs: Set<String>) {
        guard !isBusy else {
            Log.wallpaper.info("Ignore setFromPasteboard while busy")
            return
        }
        guard let targets = resolveTargets(screenIDs) else { return }

        isBusy = true
        Task { [weak self] in
            let result = await WallpaperFileStore.readPasteboardImage()
            guard let self else { return }

            switch result {
            case .image(let data, let fileExtension):
                do {
                    let storedURL = try await WallpaperFileStore.storeImageData(data, sourceExtension: fileExtension)
                    self.finishInstall(storedURL: storedURL, screenIDs: targets, announce: true)
                } catch {
                    self.finishFailure(error)
                }

            case .file(let imageURL):
                self.isBusy = false
                self.setWallpaper(fileURL: imageURL, screenIDs: targets)

            case .empty:
                self.isBusy = false
                AppState.shared.flash("剪贴板中没有可用图片，请先复制一张图片", kind: .info)
                Log.wallpaper.info("Clipboard contains no image")
            }
        }
    }

    // MARK: - 最近截图

    func loadRecentCaptures() {
        guard !isLoadingCaptures else { return }
        isLoadingCaptures = true
        Task { [weak self] in
            let captures = await WallpaperFileStore.listRecentCaptures()
            guard let self else { return }
            let capturesDirectory = AppPaths.captures
            let directoryExists = FileManager.default.fileExists(atPath: capturesDirectory.path)
            self.capturesDirectoryUnreadable = directoryExists
                && !FileManager.default.isReadableFile(atPath: capturesDirectory.path)
            self.recentCaptures = captures
            self.isLoadingCaptures = false
            Log.wallpaper.info("Loaded \(captures.count, privacy: .public) recent capture(s)")
        }
    }

    /// 供屏幕行显示“当前壁纸”缩略图；结果按绝对路径缓存，避免重复解码。
    func thumbnailData(for url: URL) async -> Data? {
        let key = url.standardizedFileURL.path
        if let cached = thumbnailCache[key] {
            return cached
        }
        let data = await WallpaperFileStore.thumbnailData(for: url)
        if let data {
            thumbnailCache[key] = data
        }
        return data
    }

    // MARK: - 文件夹轮换（可选能力）

    func startRotation(folder: URL, interval: TimeInterval, screenIDs: Set<String>) {
        guard !isBusy else { return }
        guard let targets = resolveTargets(screenIDs) else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: folder.path) else {
            AppState.shared.flash("无法读取轮换文件夹，请重新选择", kind: .error)
            return
        }

        stopRotation()
        isRotating = true
        rotationFolder = folder
        rotationInterval = max(30, interval)
        rotationScreenIDs = targets
        rotationTick = 0

        Log.wallpaper.info(
            "Rotation started: folder=\(folder.lastPathComponent, privacy: .public), interval=\(Int(self.rotationInterval), privacy: .public)s, screens=\(self.rotationScreenIDs.count, privacy: .public)"
        )

        let selectedIDs = rotationScreenIDs
        rotationTask = Task { [weak self] in
            guard let self else { return }

            let initialFiles = await WallpaperFileStore.rotationFiles(in: folder)
            guard !initialFiles.isEmpty else {
                self.stopRotation()
                AppState.shared.flash("该文件夹中没有可用图片，已停止轮换", kind: .error)
                return
            }

            await self.rotateOnce()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.rotationInterval * 1_000_000_000))
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await self.rotateOnce()
            }
            Log.wallpaper.info("Rotation loop ended for \(selectedIDs.count, privacy: .public) screen(s)")
        }
    }

    func stopRotation() {
        rotationTask?.cancel()
        rotationTask = nil
        if isRotating {
            Log.wallpaper.info("Rotation stopped")
        }
        isRotating = false
    }

    private func rotateOnce() async {
        guard isRotating, !isBusy else { return }
        guard let folder = rotationFolder else {
            stopRotation()
            return
        }
        guard !rotationScreenIDs.isEmpty else {
            stopRotation()
            AppState.shared.flash("轮换目标屏幕已不可用，已停止轮换", kind: .error)
            return
        }

        let files = await WallpaperFileStore.rotationFiles(in: folder)
        guard !files.isEmpty else {
            stopRotation()
            AppState.shared.flash("轮换文件夹中没有可用图片，已停止轮换", kind: .error)
            return
        }

        rotationTick += 1
        let screenMap = Self.makeScreenMap()
        var failureCount = 0

        for (offset, screenID) in rotationScreenIDs.sorted().enumerated() {
            if Task.isCancelled || !isRotating { return }
            guard screenMap[screenID] != nil else { continue }

            let file = files[(rotationTick + offset) % files.count]
            do {
                let storedURL = try await WallpaperFileStore.storeImageFile(file)
                if Task.isCancelled || !isRotating { return }
                let failures = applyWallpaper(storedURL, to: [screenID])
                if !failures.isEmpty {
                    failureCount += 1
                }
            } catch {
                failureCount += 1
                Log.wallpaper.error(
                    "Rotation failed for \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        refreshScreens()
        scheduleCleanup()
        if failureCount > 0 {
            AppState.shared.flash("部分屏幕轮换失败，请检查文件夹中的图片", kind: .error)
        }
    }

    // MARK: - 内部：目标解析与应用

    /// 返回规范化后的目标屏幕（只保留当前仍然存在的 id）。失败时给出用户提示并返回 nil。
    private func resolveTargets(_ screenIDs: Set<String>) -> Set<String>? {
        if screens.isEmpty {
            refreshScreens()
        }

        let screenMap = Self.makeScreenMap()
        guard !screenMap.isEmpty else {
            AppState.shared.flash("未检测到可用显示器，请刷新后重试", kind: .error)
            return nil
        }
        guard !screenIDs.isEmpty else {
            AppState.shared.flash("请先选择至少一块屏幕", kind: .error)
            return nil
        }

        let validIDs = screenIDs.filter { screenMap[$0] != nil }
        guard !validIDs.isEmpty else {
            AppState.shared.flash("所选屏幕已断开，请刷新后重试", kind: .error)
            return nil
        }
        return Set(validIDs)
    }

    private func finishInstall(storedURL: URL, screenIDs: Set<String>, announce: Bool) {
        let failures = applyWallpaper(storedURL, to: screenIDs)
        isBusy = false
        refreshScreens()
        scheduleCleanup()

        guard announce else { return }
        if failures.isEmpty {
            AppState.shared.flash("已设为壁纸", kind: .success)
        } else if failures.count >= screenIDs.count {
            AppState.shared.flash("设置壁纸失败：\(failures[0])", kind: .error)
        } else {
            AppState.shared.flash("部分屏幕设置失败：\(failures.joined(separator: "；"))", kind: .error)
        }
    }

    private func finishFailure(_ error: Error) {
        isBusy = false
        let message = error.localizedDescription
        Log.wallpaper.error("Wallpaper setting failed: \(message, privacy: .public)")
        AppState.shared.flash("设置壁纸失败：\(message)", kind: .error)
    }

    /// 在主线程调用 `NSWorkspace.setDesktopImageURL`；返回失败原因列表。
    @discardableResult
    private func applyWallpaper(_ url: URL, to screenIDs: Set<String>) -> [String] {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            Log.wallpaper.error("Wallpaper file is not readable: \(url.lastPathComponent, privacy: .public)")
            return ["壁纸文件暂不可读，请重试"]
        }

        let screenMap = Self.makeScreenMap()
        var failures: [String] = []
        var successCount = 0

        for screenID in screenIDs.sorted() {
            guard let screen = screenMap[screenID] else {
                failures.append("有屏幕已断开连接")
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                successCount += 1
            } catch {
                failures.append("\(screen.localizedName)：\(error.localizedDescription)")
                Log.wallpaper.error(
                    "setDesktopImageURL failed for \(screenID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        Log.wallpaper.info(
            "Applied \(url.lastPathComponent, privacy: .public) to \(successCount, privacy: .public) of \(screenIDs.count, privacy: .public) screen(s)"
        )
        return failures
    }

    private func scheduleCleanup() {
        let protectedPaths = currentWallpaperPaths()
        Task {
            await WallpaperFileStore.cleanStore(
                keeping: WallpaperFileStore.retentionLimit,
                protectedPaths: protectedPaths
            )
        }
    }

    /// 当前所有屏幕正在使用的壁纸绝对路径，清理时必须保留。
    private func currentWallpaperPaths() -> Set<String> {
        var paths: Set<String> = []
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        return paths
    }

    // MARK: - 内部：NSScreen 映射

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        if let number = screen.deviceDescription[key] as? UInt32 {
            return number
        }
        return nil
    }

    private static func screenIdentifier(displayID: CGDirectDisplayID) -> String {
        "display-\(displayID)"
    }

    private static func makeScreenMap() -> [String: NSScreen] {
        var map: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            map[screenIdentifier(displayID: displayID)] = screen
        }
        return map
    }
}
