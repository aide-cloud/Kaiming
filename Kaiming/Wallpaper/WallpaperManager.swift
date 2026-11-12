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
    /// 可选能力：文件夹轮换。状态只存在于本次运行的内存中，不新增 UserDefaults 键。
    @Published private(set) var isRotating = false
    @Published private(set) var rotationFolder: URL?
    @Published private(set) var rotationInterval: TimeInterval = 300

    /// 动态（视频）壁纸状态：是否启用、启用的屏幕、当前视频信息、菜单栏 poster。
    @Published private(set) var isDynamicWallpaperActive = false
    @Published private(set) var dynamicWallpaperScreens: Set<String> = []
    @Published private(set) var dynamicWallpaperInfo: WallpaperVideoInfo?
    @Published private(set) var dynamicPosterURL: URL?

    private let dynamicController = DynamicWallpaperController()
    private var screenObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var rotationTask: Task<Void, Never>?
    private var rotationScreenIDs: Set<String> = []
    private var rotationTick = 0
    private var thumbnailCache: [String: Data] = [:]
    /// screenID → 启用动态壁纸前的系统壁纸；停止时恢复（多屏各自）。
    private var originalWallpapers: [String: URL] = [:]
    /// 串行化动态壁纸状态文件的写入，避免快速「停止 / 开始」时 JSON 写入乱序。
    private var dynamicStateWriteTask: Task<Void, Never>?

    private init() {
        refreshScreens()
        observeScreenChanges()
        observeTermination()
        scheduleDynamicWallpaperRestore()
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
                self.syncDynamicWallpaperScreens()
                Log.wallpaper.info("Screen parameters changed; refresh finished")
            }
        }
    }

    private func observeTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screens = self.dynamicWallpaperScreens
                self.dynamicController.stopAll()
                // 退出 App 时恢复系统壁纸，避免菜单栏/桌面停留在 poster；持久化状态保留，
                // 下次启动仍会恢复动态壁纸（原壁纸路径也在状态文件里）。
                if !screens.isEmpty {
                    let failures = self.restoreOriginalWallpapers(for: screens, removeFromMap: false)
                    if !failures.isEmpty {
                        Log.wallpaper.error("Restore original wallpapers on termination failed: \(failures.joined(separator: "; "), privacy: .public)")
                    }
                }
                Log.wallpaper.info("Dynamic wallpaper stopped for app termination")
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

    /// 统一壁纸入口：按文件类型自动路由——图片走 `setWallpaper(fileURL:screenIDs:)`，
    /// 视频走 `startDynamicWallpaper(fileURL:screenIDs:)`，其他类型直接给出错误提示。
    ///
    /// 面板「选择壁纸…」与剪贴板中的文件都经过这里；两个既有方法签名保持不变（冻结契约），
    /// 本方法只负责分派与统一校验。
    func applyWallpaper(from url: URL, screenIDs: Set<String>) {
        guard !isBusy else {
            Log.wallpaper.info("Ignore applyWallpaper(from:) while busy")
            return
        }

        // 面板返回的 URL 可能是安全作用域资源，类型判定需要读取文件属性，先获取访问权。
        let accessing = url.startAccessingSecurityScopedResource()
        let kind = WallpaperContentKind.kind(for: url)
        if accessing { url.stopAccessingSecurityScopedResource() }

        switch kind {
        case .image:
            Log.wallpaper.info("Apply wallpaper \(url.lastPathComponent, privacy: .public) as image")
            setWallpaper(fileURL: url, screenIDs: screenIDs)
        case .video:
            Log.wallpaper.info("Apply wallpaper \(url.lastPathComponent, privacy: .public) as video")
            startDynamicWallpaper(fileURL: url, screenIDs: screenIDs)
        case nil:
            Log.wallpaper.error(
                "Unsupported wallpaper file type: \(url.lastPathComponent, privacy: .public)"
            )
            AppState.shared.flash("不支持的文件类型：仅支持图片或 MP4 / MOV / M4V 视频", kind: .error)
        }
    }

    /// 从 `NSPasteboard.general` 读取图片数据或图片 / 视频文件后设为壁纸。
    /// 剪贴板访问全部串行化在 `WallpaperIO.pasteboard` 队列上；文件统一交给
    /// `applyWallpaper(from:screenIDs:)` 按类型路由。
    func setFromPasteboard(screenIDs: Set<String>) {
        guard !isBusy else {
            Log.wallpaper.info("Ignore setFromPasteboard while busy")
            return
        }
        guard let targets = resolveTargets(screenIDs) else { return }

        isBusy = true
        Task { [weak self] in
            let result = await WallpaperFileStore.readPasteboardContent()
            guard let self else { return }

            switch result {
            case .image(let data, let fileExtension):
                do {
                    let storedURL = try await WallpaperFileStore.storeImageData(data, sourceExtension: fileExtension)
                    self.finishInstall(storedURL: storedURL, screenIDs: targets, announce: true)
                } catch {
                    self.finishFailure(error)
                }

            case .file(let fileURL):
                self.isBusy = false
                self.applyWallpaper(from: fileURL, screenIDs: targets)

            case .empty:
                self.isBusy = false
                AppState.shared.flash("剪贴板中没有可用图片或视频文件，请先复制图片或视频", kind: .info)
                Log.wallpaper.info("Clipboard contains no image or video")
            }
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

    // MARK: - 动态视频壁纸

    /// 把视频设为桌面层动态壁纸（每屏一个窗口、循环静音、多屏独立）。
    /// 通常由统一入口 `applyWallpaper(from:screenIDs:)` 在判定为视频后调用。
    ///
    /// macOS 没有公开 API 把视频设为系统壁纸，这里用 `CGWindowLevelForKey(.desktopWindow) + 1`
    /// 的桌面层窗口模拟，属于实验方案；桌面图标层级更高。
    func startDynamicWallpaper(fileURL: URL, screenIDs: Set<String>) {
        guard !isBusy else {
            Log.wallpaper.info("Ignore startDynamicWallpaper while busy")
            return
        }
        guard let targets = resolveTargets(screenIDs) else { return }
        guard WallpaperVideoStore.isSupportedVideoFile(fileURL) else {
            AppState.shared.flash("仅支持 MP4 / MOV / M4V 视频文件", kind: .error)
            return
        }

        let source = fileURL
        let accessing = source.startAccessingSecurityScopedResource()
        isBusy = true
        Log.wallpaper.info("Importing dynamic wallpaper video \(source.lastPathComponent, privacy: .public)")

        Task { [weak self] in
            defer {
                if accessing { source.stopAccessingSecurityScopedResource() }
            }
            guard let self else { return }
            do {
                let sourceInfo = try await WallpaperVideoStore.inspectVideo(url: source)
                let storedURL = try await WallpaperVideoStore.storeVideoFile(source)
                let storedInfo = WallpaperVideoInfo(
                    url: storedURL,
                    duration: sourceInfo.duration,
                    pixelWidth: sourceInfo.pixelWidth,
                    pixelHeight: sourceInfo.pixelHeight,
                    thumbnailData: sourceInfo.thumbnailData
                )
                // 菜单栏毛玻璃只取系统壁纸，桌面层窗口不会出现在菜单栏背景里；
                // 用视频首帧 poster 作为系统壁纸，使菜单栏/系统半透明区域与视频匹配。
                let posterURL = try? await WallpaperVideoStore.ensurePoster(for: storedURL)
                if posterURL == nil {
                    Log.wallpaper.error("Menu bar poster generation failed for \(storedURL.lastPathComponent, privacy: .public)")
                }
                self.installDynamicWallpaper(info: storedInfo, posterURL: posterURL, screenIDs: targets)
            } catch {
                self.isBusy = false
                let message = error.localizedDescription
                Log.wallpaper.error("Dynamic wallpaper import failed: \(message, privacy: .public)")
                AppState.shared.flash("动态壁纸设置失败：\(message)", kind: .error)
            }
        }
    }

    /// 停止所有屏幕的动态壁纸：关闭桌面层窗口、恢复原系统壁纸，并清除跨启动状态。
    func stopDynamicWallpaper() {
        let wasActive = isDynamicWallpaperActive
        let screens = dynamicWallpaperScreens
        dynamicController.stopAll()
        let restoreFailures = restoreOriginalWallpapers(for: screens, removeFromMap: true)
        dynamicWallpaperScreens = []
        dynamicWallpaperInfo = nil
        dynamicPosterURL = nil
        isDynamicWallpaperActive = false
        clearDynamicPersistence()
        refreshScreens()
        if wasActive {
            if restoreFailures.isEmpty {
                Log.wallpaper.info("Dynamic wallpaper stopped; original wallpapers restored")
                AppState.shared.flash("已停止动态壁纸", kind: .success)
            } else {
                Log.wallpaper.error(
                    "Dynamic wallpaper stopped; restore failures: \(restoreFailures.joined(separator: "; "), privacy: .public)"
                )
                AppState.shared.flash(
                    "已停止动态壁纸，但部分屏幕原壁纸恢复失败：\(restoreFailures.joined(separator: "；"))",
                    kind: .error
                )
            }
        }
    }

    /// 只停止指定屏幕的动态壁纸，并恢复这些屏幕的原壁纸。
    func stopDynamicWallpaper(screenIDs: Set<String>) {
        detachDynamicWallpaper(screenIDs: screenIDs, restoreOriginals: true)
    }

    private func installDynamicWallpaper(
        info: WallpaperVideoInfo,
        posterURL: URL?,
        screenIDs: Set<String>
    ) {
        let screenMap = Self.makeScreenMap()
        let previousScreens = dynamicWallpaperScreens

        // 替换视频时，不再作为目标的屏幕先恢复原壁纸；目标屏幕已有原壁纸记录则保留，
        // 避免把上一次的 poster 当成原壁纸。
        let removedScreens = previousScreens.subtracting(screenIDs)
        if !removedScreens.isEmpty {
            let restoreFailures = restoreOriginalWallpapers(for: removedScreens, removeFromMap: true)
            if !restoreFailures.isEmpty {
                Log.wallpaper.error(
                    "Restore removed screens failed: \(restoreFailures.joined(separator: "; "), privacy: .public)"
                )
            }
        }

        dynamicController.stopAll()
        captureOriginalWallpapers(for: screenIDs)
        let posterFailures = applyPoster(posterURL, to: screenIDs)
        let started = dynamicController.start(
            videoURL: info.url,
            screenIDs: screenIDs,
            screens: screenMap
        )
        isBusy = false

        guard !started.isEmpty else {
            let restoreFailures = restoreOriginalWallpapers(for: screenIDs, removeFromMap: true)
            if !restoreFailures.isEmpty {
                Log.wallpaper.error(
                    "Restore after failed dynamic start: \(restoreFailures.joined(separator: "; "), privacy: .public)"
                )
            }
            dynamicPosterURL = nil
            clearDynamicPersistence()
            AppState.shared.flash("动态壁纸启动失败：没有可用屏幕", kind: .error)
            return
        }

        dynamicWallpaperInfo = info
        dynamicWallpaperScreens = started
        dynamicPosterURL = posterURL
        isDynamicWallpaperActive = true
        // 只保留实际启动成功屏幕的原壁纸记录。
        originalWallpapers = originalWallpapers.filter { started.contains($0.key) }
        persistDynamicWallpaperState()
        refreshScreens()

        if posterURL == nil {
            AppState.shared.flash("已启用动态壁纸，但菜单栏 poster 生成失败，菜单栏背景可能不匹配", kind: .error)
        } else if !posterFailures.isEmpty {
            AppState.shared.flash(
                "已启用动态壁纸，但部分屏幕菜单栏背景设置失败：\(posterFailures.joined(separator: "；"))",
                kind: .error
            )
        } else {
            AppState.shared.flash("已启用动态壁纸", kind: .success)
        }
        Log.wallpaper.info(
            "Dynamic wallpaper active on \(started.count, privacy: .public) screen(s): \(info.url.lastPathComponent, privacy: .public), poster=\(posterURL?.lastPathComponent ?? "nil", privacy: .public)"
        )
        schedulePlaybackStatusLog()
    }

    /// 停止指定屏幕的动态壁纸。
    /// - Parameter restoreOriginals: 用户主动停止时为 true（恢复原壁纸）；切换静态壁纸时为 false
    ///   （新静态壁纸已经生效，不能再被原壁纸覆盖）。
    private func detachDynamicWallpaper(screenIDs: Set<String>, restoreOriginals: Bool) {
        guard isDynamicWallpaperActive else { return }
        let affected = dynamicWallpaperScreens.intersection(screenIDs)
        guard !affected.isEmpty else { return }

        dynamicController.stop(screenIDs: affected)
        dynamicWallpaperScreens.subtract(affected)

        var restoreFailures: [String] = []
        if restoreOriginals {
            restoreFailures = restoreOriginalWallpapers(for: affected, removeFromMap: true)
        } else {
            for screenID in affected {
                originalWallpapers.removeValue(forKey: screenID)
            }
        }

        if dynamicWallpaperScreens.isEmpty {
            dynamicWallpaperInfo = nil
            dynamicPosterURL = nil
            isDynamicWallpaperActive = false
            clearDynamicPersistence()
            Log.wallpaper.info("Dynamic wallpaper stopped because all screens switched to static wallpaper")
        } else {
            persistDynamicWallpaperState()
        }
        refreshScreens()
        if !restoreFailures.isEmpty {
            AppState.shared.flash(
                "已停止这些屏幕的动态壁纸，但原壁纸恢复失败：\(restoreFailures.joined(separator: "；"))",
                kind: .error
            )
        }
    }

    private func syncDynamicWallpaperScreens() {
        guard isDynamicWallpaperActive else { return }
        let previousScreens = dynamicWallpaperScreens
        dynamicController.syncScreens(Self.makeScreenMap())
        let activeScreenIDs = dynamicController.activeScreenIDs
        guard activeScreenIDs != dynamicWallpaperScreens else { return }

        // 断开的屏幕无法再调用 setDesktopImageURL 恢复；清理其原壁纸记录。
        let removedScreens = previousScreens.subtracting(activeScreenIDs)
        for screenID in removedScreens {
            originalWallpapers.removeValue(forKey: screenID)
        }

        dynamicWallpaperScreens = activeScreenIDs
        if activeScreenIDs.isEmpty {
            dynamicWallpaperInfo = nil
            dynamicPosterURL = nil
            isDynamicWallpaperActive = false
            clearDynamicPersistence()
            Log.wallpaper.info("Dynamic wallpaper stopped: all target screens disconnected")
        } else {
            persistDynamicWallpaperState()
            Log.wallpaper.info("Dynamic wallpaper screens updated: \(activeScreenIDs.count, privacy: .public)")
        }
        refreshScreens()
    }

    /// 记录目标屏幕启用动态壁纸前的系统壁纸；已有记录则保留（替换视频时不覆盖）。
    private func captureOriginalWallpapers(for screenIDs: Set<String>) {
        let screenMap = Self.makeScreenMap()
        for screenID in screenIDs.sorted() {
            if originalWallpapers[screenID] != nil { continue }
            guard let screen = screenMap[screenID],
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
                Log.wallpaper.error("Cannot capture original wallpaper for \(screenID, privacy: .public)")
                continue
            }
            if let poster = dynamicPosterURL, url.standardizedFileURL == poster.standardizedFileURL {
                Log.wallpaper.error(
                    "Refuse to record current poster as original wallpaper for \(screenID, privacy: .public)"
                )
                continue
            }
            originalWallpapers[screenID] = url
            Log.wallpaper.info("Original wallpaper recorded for \(screenID, privacy: .public)")
        }
    }

    /// 把视频首帧 poster 设为这些屏幕的系统壁纸（菜单栏毛玻璃背景来源）。返回失败原因。
    @discardableResult
    private func applyPoster(_ posterURL: URL?, to screenIDs: Set<String>) -> [String] {
        guard let posterURL, FileManager.default.isReadableFile(atPath: posterURL.path) else {
            return []
        }
        let screenMap = Self.makeScreenMap()
        var failures: [String] = []

        for screenID in screenIDs.sorted() {
            guard let screen = screenMap[screenID] else {
                failures.append("有屏幕已断开连接")
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(posterURL, for: screen, options: [:])
            } catch {
                failures.append("\(screen.localizedName)：\(error.localizedDescription)")
                Log.wallpaper.error(
                    "setDesktopImageURL(poster) failed for \(screenID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if failures.isEmpty {
            Log.wallpaper.info("Menu bar poster applied to \(screenIDs.count, privacy: .public) screen(s)")
        }
        return failures
    }

    /// 恢复这些屏幕的原系统壁纸；`removeFromMap` 为 false 时保留记录（App 退出后下次启动仍能恢复）。
    @discardableResult
    private func restoreOriginalWallpapers(for screenIDs: Set<String>, removeFromMap: Bool) -> [String] {
        let screenMap = Self.makeScreenMap()
        var failures: [String] = []

        for screenID in screenIDs.sorted() {
            guard let original = originalWallpapers[screenID] else { continue }
            guard let screen = screenMap[screenID] else {
                failures.append("\(screenID)：屏幕已断开")
                if removeFromMap { originalWallpapers.removeValue(forKey: screenID) }
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: [:])
                Log.wallpaper.info("Restored original wallpaper for \(screenID, privacy: .public)")
            } catch {
                failures.append("\(screen.localizedName)：\(error.localizedDescription)")
                Log.wallpaper.error(
                    "Restore original wallpaper failed for \(screenID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            if removeFromMap {
                originalWallpapers.removeValue(forKey: screenID)
            }
        }
        return failures
    }

    private func persistDynamicWallpaperState() {
        guard !dynamicWallpaperScreens.isEmpty, let info = dynamicWallpaperInfo else {
            enqueueDynamicStateWrite { await WallpaperVideoStore.clearState() }
            return
        }
        let activeOriginals = originalWallpapers
            .filter { dynamicWallpaperScreens.contains($0.key) }
            .mapValues { $0.path }
        let state = WallpaperDynamicState(
            videoPath: info.url.path,
            screenIDs: dynamicWallpaperScreens.sorted(),
            posterPath: dynamicPosterURL?.path,
            originalWallpapers: activeOriginals.isEmpty ? nil : activeOriginals
        )
        enqueueDynamicStateWrite { await WallpaperVideoStore.saveState(state) }
    }

    private func clearDynamicPersistence() {
        enqueueDynamicStateWrite { await WallpaperVideoStore.clearState() }
    }

    private func enqueueDynamicStateWrite(_ operation: @escaping @Sendable () async -> Void) {
        let previous = dynamicStateWriteTask
        dynamicStateWriteTask = Task {
            await previous?.value
            await operation()
        }
    }

    /// 启动后延迟恢复上次启用的动态壁纸；失败只记录/提示，不阻塞启动。
    private func scheduleDynamicWallpaperRestore() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            await self?.restoreDynamicWallpaperIfNeeded()
        }
    }

    private func restoreDynamicWallpaperIfNeeded() async {
        guard !isDynamicWallpaperActive else { return }
        guard let state = await WallpaperVideoStore.loadState() else { return }

        let storedURL = URL(fileURLWithPath: state.videoPath).standardizedFileURL
        let wallpaperRoot = AppPaths.wallpapers.standardizedFileURL.path + "/"
        guard storedURL.path.hasPrefix(wallpaperRoot),
              FileManager.default.isReadableFile(atPath: storedURL.path) else {
            Log.wallpaper.error("Dynamic wallpaper restore failed: stored video is missing")
            AppState.shared.flash("动态壁纸恢复失败：视频文件已丢失", kind: .error)
            await WallpaperVideoStore.clearState()
            return
        }

        var posterAppliedScreens: Set<String> = []
        do {
            let info = try await WallpaperVideoStore.inspectVideo(url: storedURL)
            let screenMap = Self.makeScreenMap()
            let savedIDs = Set(state.screenIDs)
            let availableIDs = savedIDs.intersection(screenMap.keys)
            guard !availableIDs.isEmpty else {
                Log.wallpaper.info("Dynamic wallpaper restore postponed: saved screens are not connected")
                return
            }

            // 优先使用持久化的原壁纸；旧状态没有该字段时，当前系统壁纸就是原壁纸
            // （旧版本没有设置过 poster），但绝不能把已知的旧 poster 记成原壁纸。
            var originals: [String: URL] = [:]
            if let savedOriginals = state.originalWallpapers {
                for (screenID, path) in savedOriginals where availableIDs.contains(screenID) {
                    guard !path.isEmpty else { continue }
                    originals[screenID] = URL(fileURLWithPath: path).standardizedFileURL
                }
            }
            let savedPoster = state.posterPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            var missingOriginals: [String] = []
            for screenID in availableIDs where originals[screenID] == nil {
                guard let screen = screenMap[screenID],
                      let current = NSWorkspace.shared.desktopImageURL(for: screen) else {
                    missingOriginals.append(screenID)
                    continue
                }
                if let savedPoster, current.standardizedFileURL == savedPoster {
                    missingOriginals.append(screenID)
                    Log.wallpaper.error(
                        "Cannot recover original wallpaper for \(screenID, privacy: .public): current wallpaper is an old poster"
                    )
                    continue
                }
                originals[screenID] = current
            }
            originalWallpapers = originals

            let posterURL = try? await WallpaperVideoStore.ensurePoster(for: storedURL)
            if posterURL == nil {
                Log.wallpaper.error("Menu bar poster generation failed during restore")
            }
            let posterFailures = applyPoster(posterURL, to: availableIDs)
            posterAppliedScreens = availableIDs

            let started = dynamicController.start(
                videoURL: storedURL,
                screenIDs: availableIDs,
                screens: screenMap
            )
            guard !started.isEmpty else {
                throw WallpaperVideoError.unplayable(storedURL.lastPathComponent)
            }

            dynamicWallpaperInfo = info
            dynamicWallpaperScreens = started
            dynamicPosterURL = posterURL
            isDynamicWallpaperActive = true
            originalWallpapers = originalWallpapers.filter { started.contains($0.key) }
            persistDynamicWallpaperState()
            refreshScreens()

            if posterURL == nil {
                AppState.shared.flash("动态壁纸已恢复，但菜单栏 poster 生成失败，菜单栏背景可能不匹配", kind: .error)
            } else if !posterFailures.isEmpty {
                AppState.shared.flash(
                    "动态壁纸已恢复，但部分屏幕菜单栏背景设置失败：\(posterFailures.joined(separator: "；"))",
                    kind: .error
                )
            } else if !missingOriginals.isEmpty {
                AppState.shared.flash("动态壁纸已恢复，但部分屏幕缺少原壁纸记录，停止时可能无法恢复", kind: .error)
            }

            Log.wallpaper.info(
                "Dynamic wallpaper restored on \(started.count, privacy: .public) screen(s) from \(storedURL.lastPathComponent, privacy: .public)"
            )
            #if DEBUG
            NSLog(
                "Kaiming debug: dynamic wallpaper restored screens=\(started.count) video=\(storedURL.lastPathComponent) poster=\(posterURL?.lastPathComponent ?? "nil")"
            )
            #endif
            schedulePlaybackStatusLog()
        } catch {
            let message = error.localizedDescription
            if !posterAppliedScreens.isEmpty {
                let restoreFailures = restoreOriginalWallpapers(for: posterAppliedScreens, removeFromMap: true)
                if !restoreFailures.isEmpty {
                    Log.wallpaper.error(
                        "Restore original wallpapers after failed restore failed: \(restoreFailures.joined(separator: "; "), privacy: .public)"
                    )
                }
            }
            originalWallpapers.removeAll()
            dynamicWallpaperScreens = []
            dynamicWallpaperInfo = nil
            dynamicPosterURL = nil
            isDynamicWallpaperActive = false
            Log.wallpaper.error("Dynamic wallpaper restore failed: \(message, privacy: .public)")
            AppState.shared.flash("动态壁纸恢复失败：\(message)", kind: .error)
            await WallpaperVideoStore.clearState()
        }
    }

    private func schedulePlaybackStatusLog() {
        guard !dynamicWallpaperScreens.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            for screenID in self.dynamicWallpaperScreens.sorted() {
                let status = self.dynamicController.playbackStatus(for: screenID)
                Log.wallpaper.info("Dynamic wallpaper playback \(screenID, privacy: .public): \(status, privacy: .public)")
                #if DEBUG
                NSLog("Kaiming debug: dynamic wallpaper playback \(screenID) \(status)")
                #endif
            }
        }
    }

    // MARK: - 文件夹轮换（可选能力）

    /// 记录用户选择的轮换文件夹。选择面板会让菜单栏 popover 关闭，状态保存在 Manager 中，
    /// 重新打开面板后仍可继续使用该文件夹。
    func selectRotationFolder(_ folder: URL) {
        rotationFolder = folder
        Log.wallpaper.info("Rotation folder selected: \(folder.lastPathComponent, privacy: .public)")
    }

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
                let result = applyWallpaper(storedURL, to: [screenID])
                if !result.applied.isEmpty {
                    detachDynamicWallpaper(screenIDs: result.applied, restoreOriginals: false)
                }
                if !result.failures.isEmpty {
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
        let result = applyWallpaper(storedURL, to: screenIDs)
        if !result.applied.isEmpty {
            detachDynamicWallpaper(screenIDs: result.applied, restoreOriginals: false)
        }
        isBusy = false
        refreshScreens()
        scheduleCleanup()

        guard announce else { return }
        if result.failures.isEmpty {
            AppState.shared.flash("已设为壁纸", kind: .success)
        } else if result.failures.count >= screenIDs.count {
            AppState.shared.flash("设置壁纸失败：\(result.failures[0])", kind: .error)
        } else {
            AppState.shared.flash("部分屏幕设置失败：\(result.failures.joined(separator: "；"))", kind: .error)
        }
    }

    private func finishFailure(_ error: Error) {
        isBusy = false
        let message = error.localizedDescription
        Log.wallpaper.error("Wallpaper setting failed: \(message, privacy: .public)")
        AppState.shared.flash("设置壁纸失败：\(message)", kind: .error)
    }

    /// 在主线程调用 `NSWorkspace.setDesktopImageURL`；返回成功应用的屏幕 id 与失败原因列表。
    @discardableResult
    private func applyWallpaper(_ url: URL, to screenIDs: Set<String>) -> (applied: Set<String>, failures: [String]) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            Log.wallpaper.error("Wallpaper file is not readable: \(url.lastPathComponent, privacy: .public)")
            return ([], ["壁纸文件暂不可读，请重试"])
        }

        let screenMap = Self.makeScreenMap()
        var applied: Set<String> = []
        var failures: [String] = []

        for screenID in screenIDs.sorted() {
            guard let screen = screenMap[screenID] else {
                failures.append("有屏幕已断开连接")
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                applied.insert(screenID)
            } catch {
                failures.append("\(screen.localizedName)：\(error.localizedDescription)")
                Log.wallpaper.error(
                    "setDesktopImageURL failed for \(screenID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        Log.wallpaper.info(
            "Applied \(url.lastPathComponent, privacy: .public) to \(applied.count, privacy: .public) of \(screenIDs.count, privacy: .public) screen(s)"
        )
        return (applied, failures)
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
        if let dynamicURL = dynamicWallpaperInfo?.url {
            paths.insert(dynamicURL.standardizedFileURL.path)
        }
        if let posterURL = dynamicPosterURL {
            paths.insert(posterURL.standardizedFileURL.path)
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
