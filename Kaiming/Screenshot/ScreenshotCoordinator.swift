import AppKit
import Combine
import CoreGraphics

/// 截图模块对 App 层暴露的入口（签名见 docs/contracts.md）。
///
/// 流程：权限预检 → ScreenCaptureKit 冻结屏幕 → AppKit 覆盖层交互/标注 →
/// 主线程拍平 → 编码、写剪贴板、自动保存、写历史、播放声音、更新面板状态。
@MainActor
final class ScreenshotCoordinator: ObservableObject {
    static let shared = ScreenshotCoordinator()

    /// 覆盖层可见期间为 true，菜单栏面板据此禁用三个截图按钮。
    @Published private(set) var isCapturing = false

    private var activeOverlay: CaptureOverlayController?

    /// 仅测试采集使用：本次运行覆盖剪贴板/声音/窗口头部，不写 UserDefaults。
    private var testClipboardOverride: Bool?
    private var testSoundOverride: Bool?
    private var testDecorationOverride: Bool?

    private init() {}

    // MARK: - 入口

    func start(mode: CaptureMode) {
        testClipboardOverride = nil
        testSoundOverride = nil
        testDecorationOverride = nil
        begin(mode)
    }

    /// DEBUG 测试入口：不修改 SettingsStore/UserDefaults，只覆盖本次采集行为。
    /// 默认跳过窗口头部装饰，保持输出为原生像素尺寸，便于尺寸校验。
    func startForTesting(
        mode: CaptureMode,
        copyToClipboard: Bool,
        playSound: Bool,
        addsWindowHeader: Bool? = nil
    ) {
        testClipboardOverride = copyToClipboard
        testSoundOverride = playSound
        testDecorationOverride = addsWindowHeader ?? false
        begin(mode)
    }

    private func begin(_ mode: CaptureMode) {
        guard !isCapturing else {
            AppState.shared.flash("正在截图，请先完成或取消当前截图。", kind: .info)
            return
        }
        Log.screenshot.info("Screenshot requested: \(mode.rawValue, privacy: .public)")

        // 不再用 preflight 直接拦截：TCC 记录可能仍绑定旧构建的 CDHash，
        // 系统设置显示已授权但 preflight 返回 false。以真实 SCK 采集结果为准；
        // 只有实际采集失败时才提示授权（见 report(_:)）。
        if !ScreenCapturePermission.isGranted {
            Log.screenshot.info("Preflight reports no access; attempting real ScreenCaptureKit capture")
        }
        guard !NSScreen.screens.isEmpty else {
            AppState.shared.flash("没有检测到可用的显示器，请唤醒屏幕后再试。", kind: .error)
            return
        }

        isCapturing = true
        Task { @MainActor [weak self] in
            await self?.performCapture(mode: mode)
        }
    }

    // MARK: - 采集


    private func performCapture(mode: CaptureMode) async {
        let settings = SettingsStore.shared
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            isCapturing = false
            report(ScreenshotError.noDisplay)
            return
        }

        let mouseScreen = screen(containing: NSEvent.mouseLocation, in: screens)
            ?? NSScreen.main
            ?? screens[0]

        let entries: [(screen: NSScreen, displayID: CGDirectDisplayID)] = screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            return (screen, id)
        }
        guard !entries.isEmpty else {
            isCapturing = false
            report(ScreenshotError.noDisplay)
            return
        }

        let addsWindowHeader = testDecorationOverride ?? settings.screenshotImageWindowHeader

        let requestedIDs: [CGDirectDisplayID]
        if mode == .fullScreen {
            guard let id = displayID(for: mouseScreen) else {
                isCapturing = false
                report(ScreenshotError.noDisplay)
                return
            }
            requestedIDs = [id]
        } else {
            requestedIDs = entries.map(\.displayID)
        }

        do {
            let prepared = try await ScreenCaptureService.prepare(
                displayIDs: requestedIDs,
                includeWindows: mode == .window,
                showsCursor: settings.captureCursor,
                hideOwnWindows: settings.screenshotHideOwnWindows
            )
            let images = Dictionary(uniqueKeysWithValues: prepared.displays.map { ($0.displayID, $0.image) })
            let frozenScreens: [CaptureOverlayController.FrozenScreen] = entries.compactMap { entry in
                guard let image = images[entry.displayID], image.width > 0, image.height > 0 else {
                    return nil
                }
                let scale = CGFloat(image.width) / max(entry.screen.frame.width, 1)
                return CaptureOverlayController.FrozenScreen(
                    screen: entry.screen,
                    displayID: entry.displayID,
                    image: image,
                    scale: scale
                )
            }
            guard !frozenScreens.isEmpty else {
                throw ScreenshotError.noDisplay
            }
            if mode == .window, prepared.windows.isEmpty {
                throw ScreenshotError.noWindows
            }

            switch mode {
            case .fullScreen:
                guard let frozen = frozenScreens.first(where: { $0.displayID == requestedIDs.first })
                    ?? frozenScreens.first else {
                    throw ScreenshotError.noDisplay
                }
                isCapturing = false
                Log.screenshot.info(
                    "Full screen capture from display \(frozen.displayID, privacy: .public)"
                )
                let output: CGImage
                if addsWindowHeader,
                   let decorated = WindowHeaderDecoration.decorate(
                       frozen.image,
                       scale: frozen.scale
                   ) {
                    output = decorated
                } else {
                    output = frozen.image
                }
                completeCapture(image: output, mode: mode)

            case .region, .window:
                let controller = CaptureOverlayController(
                    mode: mode == .region ? .region : .window,
                    frozenScreens: frozenScreens,
                    windows: prepared.windows,
                    initialScreen: mouseScreen,
                    addsWindowHeader: addsWindowHeader
                )
                controller.onFinish = { [weak self] image in
                    guard let self else { return }
                    self.activeOverlay = nil
                    self.isCapturing = false
                    self.completeCapture(image: image, mode: mode)
                }
                controller.onCancel = { [weak self] in
                    guard let self else { return }
                    self.activeOverlay = nil
                    self.isCapturing = false
                    Log.screenshot.info("Capture session cancelled by user")
                }
                activeOverlay = controller
                controller.present()
            }
        } catch {
            isCapturing = false
            activeOverlay = nil
            report(error)
        }
    }

    // MARK: - 完成

    private func completeCapture(image: CGImage, mode: CaptureMode) {
        let settings = SettingsStore.shared
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        var problems: [String] = []

        do {
            let historyURL = try CaptureHistory.writeHistory(image: image)
            Log.screenshot.info("Capture history saved: \(historyURL.lastPathComponent, privacy: .public)")
        } catch {
            problems.append("写入截图历史失败")
            Log.screenshot.error(
                "Failed to write capture history: \(error.localizedDescription, privacy: .public)"
            )
        }

        let copyToClipboard = testClipboardOverride ?? settings.copyScreenshotToClipboard
        let playCaptureSound = testSoundOverride ?? settings.playCaptureSound

        if copyToClipboard {
            do {
                try copyToPasteboard(image: image, format: settings.screenshotFormat)
                Log.screenshot.info("Capture copied to pasteboard")
            } catch {
                problems.append("复制到剪贴板失败")
                Log.screenshot.error(
                    "Failed to copy capture to pasteboard: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if settings.autoSaveScreenshots {
            do {
                let url = try CaptureHistory.writeFile(
                    image: image,
                    format: settings.screenshotFormat,
                    directory: settings.screenshotSaveDirectory
                )
                Log.screenshot.info("Capture saved: \(url.path, privacy: .public)")
            } catch {
                problems.append("保存到文件夹失败")
                Log.screenshot.error(
                    "Failed to save capture: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if playCaptureSound {
            NSSound(named: "Glass")?.play()
        }

        AppState.shared.recordCapture(nsImage)

        if problems.isEmpty {
            AppState.shared.flash(successMessage(settings: settings, copyToClipboard: copyToClipboard), kind: .success)
            Log.screenshot.info(
                "Capture completed mode=\(mode.rawValue, privacy: .public) clipboard=\(settings.copyScreenshotToClipboard, privacy: .public) autoSave=\(settings.autoSaveScreenshots, privacy: .public)"
            )
        } else {
            AppState.shared.flash(
                "截图已完成，但\(problems.joined(separator: "、"))。",
                kind: .error
            )
            Log.screenshot.error("Capture completed with problems: \(problems.joined(separator: ", "), privacy: .public)")
        }

        testClipboardOverride = nil
        testSoundOverride = nil
        testDecorationOverride = nil

        // 权限状态可能刚被系统更新，顺手同步权限中心（唯一状态来源）。
        AppState.shared.refreshPermission()
    }

    private func successMessage(settings: SettingsStore, copyToClipboard: Bool) -> String {
        var destinations: [String] = []
        if copyToClipboard {
            destinations.append("已复制到剪贴板")
        }
        if settings.autoSaveScreenshots {
            destinations.append("已保存到 \(settings.screenshotSaveDirectory.lastPathComponent)")
        }
        if destinations.isEmpty {
            return "截图完成，已加入截图历史。"
        }
        return "截图完成：\(destinations.joined(separator: "，"))。"
    }

    private func copyToPasteboard(image: CGImage, format: ScreenshotFormat) throws {
        let primaryData = try CaptureHistory.encode(image, format: format)
        let pngFallback: Data? = format == .png ? nil : try CaptureHistory.encode(image, format: .png)
        let primaryType: NSPasteboard.PasteboardType = format == .png
            ? .png
            : NSPasteboard.PasteboardType("public.jpeg")

        try PasteboardQueue.serial.sync {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(primaryData, forType: primaryType) else {
                throw ScreenshotError.pasteboardWriteFailed
            }
            if let pngFallback {
                _ = pasteboard.setData(pngFallback, forType: .png)
            }
        }
    }

    // MARK: - 错误 / 辅助

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        AppState.shared.flash(message, kind: .error)
        Log.screenshot.error("Capture aborted: \(error.localizedDescription, privacy: .public)")

        if let screenshotError = error as? ScreenshotError, screenshotError.isPermissionRelated {
            // 实际 SCK 失败才视为权限问题：重新探测真实能力，并引导用户到唯一的「权限」页。
            AppState.shared.probePermission()
            presentPermissionRecoveryAlert()
        }
    }

    /// SCK 实际失败时才弹出：把用户引导到设置「权限」页统一检测 / 申请 / 重置。
    /// 这里不再主动触发系统授权框，避免截图流程与设置页出现两套申请入口。
    private func presentPermissionRecoveryAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "屏幕录制权限未生效"
        alert.informativeText = "系统设置中可能已显示 Kaiming 已授权，但 TCC 授权通常只对新启动的进程生效，重新构建后也可能绑定旧签名。请到「设置 → 权限」重新检测、申请或重置屏幕录制权限。"
        alert.addButton(withTitle: "打开权限设置")
        alert.addButton(withTitle: "重启 Kaiming")
        alert.addButton(withTitle: "取消")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: nil)

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppRouter.shared.openSettings(tab: .permissions)
        case .alertSecondButtonReturn:
            AppRelauncher.relaunch()
        default:
            break
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func screen(containing point: CGPoint, in screens: [NSScreen]) -> NSScreen? {
        screens.first { $0.frame.contains(point) }
    }
}
