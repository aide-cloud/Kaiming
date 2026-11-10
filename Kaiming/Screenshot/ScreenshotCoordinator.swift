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

    private init() {}

    // MARK: - 入口

    func start(mode: CaptureMode) {
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
                showsCursor: settings.captureCursor
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
                completeCapture(image: frozen.image, mode: mode)

            case .region, .window:
                let controller = CaptureOverlayController(
                    mode: mode == .region ? .region : .window,
                    frozenScreens: frozenScreens,
                    windows: prepared.windows,
                    initialScreen: mouseScreen
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

        if settings.copyScreenshotToClipboard {
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

        if settings.playCaptureSound {
            NSSound(named: "Glass")?.play()
        }

        AppState.shared.recordCapture(nsImage)

        if problems.isEmpty {
            AppState.shared.flash(successMessage(settings: settings), kind: .success)
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

        // 权限状态可能刚被系统更新，顺手刷新面板横幅。
        AppState.shared.refreshPermission()
    }

    private func successMessage(settings: SettingsStore) -> String {
        var destinations: [String] = []
        if settings.copyScreenshotToClipboard {
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
            // 实际 SCK 失败才视为权限问题：触发系统请求并重新探测能力。
            AppState.shared.probePermission()
            ScreenCapturePermission.request()
            presentPermissionRecoveryAlert()
        }
    }

    /// SCK 实际失败时才弹出：提供一键重启/打开设置，覆盖“系统设置已授权但当前进程未生效”的 TCC 状态。
    private func presentPermissionRecoveryAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "屏幕录制权限尚未对当前进程生效"
        alert.informativeText = """
        系统设置中可能已显示 Kaiming 已授权，但 TCC 授权通常只对新启动的进程生效，重新构建后也可能绑定到旧签名。

        建议先点“重启 Kaiming”。若仍失败，请在系统设置中移除 Kaiming 后重新添加（设置 → 屏幕录制 → 重置权限）。
        """
        alert.addButton(withTitle: "重启 Kaiming")
        alert.addButton(withTitle: "重置权限并重新授权")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: nil)

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppRelauncher.relaunch()
        case .alertSecondButtonReturn:
            resetPermissionAndRelaunch()
        case .alertThirdButtonReturn:
            ScreenCapturePermission.openSystemSettings()
        default:
            break
        }
    }

    /// 清除绑定到旧构建签名的 TCC 记录，重新请求授权，然后自动重启。
    private func resetPermissionAndRelaunch() {
        guard ScreenCapturePermission.resetTCCEntry() else {
            AppState.shared.flash(
                "自动重置权限失败。请在系统设置 → 屏幕录制中移除 Kaiming 后重新添加，再重启应用。",
                kind: .error
            )
            ScreenCapturePermission.openSystemSettings()
            return
        }

        AppState.shared.flash(
            "已清除旧授权记录。请在系统弹窗中允许屏幕录制；若未出现弹窗，请在系统设置中勾选 Kaiming。",
            kind: .info
        )
        let granted = ScreenCapturePermission.request()
        if granted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AppRelauncher.relaunch()
            }
        } else {
            ScreenCapturePermission.openSystemSettings()
            AppState.shared.flash(
                "请勾选 Kaiming 后点击菜单栏面板里的“重启应用”，或重新运行 ./Scripts/run.sh。",
                kind: .info
            )
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
