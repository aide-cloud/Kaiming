import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 截图流程中会遇到的用户可见错误。
enum ScreenshotError: LocalizedError {
    case permissionDenied
    case noContent
    case noDisplay
    case displayCaptureFailed(displayID: CGDirectDisplayID, message: String)
    case noWindows
    case windowUnavailable
    case windowCaptureFailed(String)
    case encodingFailed
    case pasteboardWriteFailed
    case fileWriteFailed(String)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "需要屏幕录制权限。请打开「设置 → 权限」检测并申请授权；若系统设置中已勾选仍失败，请在同一页面重置授权记录并重启应用。"
        case .noContent:
            "没有获取到屏幕画面。若系统设置已显示已授权，请打开「设置 → 权限」重新检测；仍失败时在同一页面重置屏幕录制授权记录并重启应用。"
        case .noDisplay:
            "没有找到可截取的显示器。请确认显示器已连接并处于唤醒状态。"
        case let .displayCaptureFailed(_, message):
            "截取屏幕失败：\(message)"
        case .noWindows:
            "没有找到可截取的窗口。请确认目标窗口没有最小化，或改试区域截图。"
        case .windowUnavailable:
            "所选窗口已关闭或不可见，请重新选择。"
        case let .windowCaptureFailed(message):
            "截取窗口失败：\(message)"
        case .encodingFailed:
            "图片编码失败，请重试。"
        case .pasteboardWriteFailed:
            "写入剪贴板失败，请检查系统剪贴板是否被其他应用占用。"
        case let .fileWriteFailed(message):
            "写入文件失败：\(message)"
        case .renderFailed:
            "生成标注图像失败，请重试。"
        }
    }

    /// 是否属于「权限未生效」这一类，需要在提示后引导用户去系统设置。
    var isPermissionRelated: Bool {
        switch self {
        case .permissionDenied, .noContent:
            true
        default:
            false
        }
    }
}

/// ScreenCaptureKit 采集层。
///
/// 所有 ScreenCaptureKit 调用都放在 `nonisolated` 的异步函数中完成，只把
/// `Sendable` 的位图 / 结构体交回主线程，避免 Swift 6 下非 Sendable 的 SCK 对象跨 actor。
enum ScreenCaptureService {
    struct DisplayCapture: Sendable {
        let displayID: CGDirectDisplayID
        let image: CGImage
    }

    struct WindowDescriptor: Sendable, Identifiable {
        let id: CGWindowID
        let frame: CGRect
        let title: String
        let ownerName: String
        let ownerBundleID: String
        let layer: Int
    }

    struct PreparedContent: Sendable {
        let displays: [DisplayCapture]
        let windows: [WindowDescriptor]
    }

    /// 菜单栏、Dock、控制中心等系统 UI 的 bundle id；即使 windowLayer 为 0 也一并排除。
    private static let systemWindowBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.CoreServicesUIAgent",
        "com.apple.wallpaper.agent",
    ]

    private static let systemWindowOwnerNames: Set<String> = [
        "Window Server",
        "Dock",
        "Control Center",
        "Notification Center",
        "SystemUIServer",
        "Spotlight",
    ]

    // MARK: - 准备阶段

    private static func loadShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.screenshot.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotError.permissionDenied
        }
    }

    private static func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        // 排除本应用全部窗口：长截图的 border-only 覆盖窗口与 HUD 也属于本应用，
        // 因此不会进入逐帧截图；普通截图同样不会截到本应用窗口。
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.applications.filter { application in
            if application.processID == ownPID { return true }
            if let ownBundleID, application.bundleIdentifier == ownBundleID { return true }
            return false
        }
    }

    // MARK: - 像素尺寸

    struct DisplayPixelMetrics {
        let pointSize: CGSize
        let nativePixelSize: CGSize
        let computedPixelSize: CGSize
        let targetPixelSize: CGSize
        let pointPixelScale: CGFloat
    }

    /// SCDisplay.width/height 是「点」，SCContentFilter.pointPixelScale 是像素/点；
    /// 同时参考 CGDisplayMode.pixelWidth/Height 的真实物理像素（CGDisplayPixelsWide/High
    /// 在 HiDPI 缩放模式下可能返回点尺寸），避免错失 4K/Retina 的物理像素。
    private static func displayPixelMetrics(
        for display: SCDisplay,
        filter: SCContentFilter
    ) -> DisplayPixelMetrics {
        let pointSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        let pointPixelScale = max(CGFloat(filter.pointPixelScale), 1)
        let computed = CGSize(
            width: (pointSize.width * pointPixelScale).rounded(),
            height: (pointSize.height * pointPixelScale).rounded()
        )
        // CGDisplayPixelsWide/High 在 HiDPI 缩放模式下可能返回点尺寸（本机 4K 返回 1920），
        // 用 CGDisplayMode 的 pixelWidth/pixelHeight 才能拿到真实物理像素（3840×2160）。
        let native: CGSize
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            let pixelWidth = mode.pixelWidth
            let pixelHeight = mode.pixelHeight
            if pixelWidth > 0, pixelHeight > 0 {
                native = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
            } else {
                native = CGSize(
                    width: CGFloat(CGDisplayPixelsWide(display.displayID)),
                    height: CGFloat(CGDisplayPixelsHigh(display.displayID))
                )
            }
        } else {
            native = CGSize(
                width: CGFloat(CGDisplayPixelsWide(display.displayID)),
                height: CGFloat(CGDisplayPixelsHigh(display.displayID))
            )
        }
        let target = CGSize(
            width: max(computed.width, native.width, 1),
            height: max(computed.height, native.height, 1)
        )
        return DisplayPixelMetrics(
            pointSize: pointSize,
            nativePixelSize: native,
            computedPixelSize: computed,
            targetPixelSize: target,
            pointPixelScale: pointPixelScale
        )
    }

    /// 按屏幕最高像素分辨率创建采集配置；不缩放、尽量使用 best 捕获分辨率。
    private static func makeDisplayConfiguration(
        display: SCDisplay,
        filter: SCContentFilter,
        showsCursor: Bool
    ) -> (configuration: SCStreamConfiguration, metrics: DisplayPixelMetrics) {
        let metrics = displayPixelMetrics(for: display, filter: filter)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(metrics.targetPixelSize.width))
        configuration.height = max(1, Int(metrics.targetPixelSize.height))
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        return (configuration, metrics)
    }

    private static func logDisplayCapture(
        display: SCDisplay,
        filter: SCContentFilter,
        metrics: DisplayPixelMetrics,
        configuration: SCStreamConfiguration,
        output: CGImage
    ) {
        Log.screenshot.info(
            "Display \(display.displayID, privacy: .public) frame=\(display.frame.width, privacy: .public)x\(display.frame.height, privacy: .public)pt SCDisplay=\(display.width, privacy: .public)x\(display.height, privacy: .public)pt pointPixelScale=\(filter.pointPixelScale, privacy: .public) computed=\(metrics.computedPixelSize.width, privacy: .public)x\(metrics.computedPixelSize.height, privacy: .public) native=\(metrics.nativePixelSize.width, privacy: .public)x\(metrics.nativePixelSize.height, privacy: .public) config=\(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) output=\(output.width, privacy: .public)x\(output.height, privacy: .public)"
        )
        #if DEBUG
        NSLog(
            "Kaiming debug: Display \(display.displayID) frame=\(display.frame.width)x\(display.frame.height)pt SCDisplay=\(display.width)x\(display.height)pt pointPixelScale=\(filter.pointPixelScale) computed=\(metrics.computedPixelSize.width)x\(metrics.computedPixelSize.height) native=\(metrics.nativePixelSize.width)x\(metrics.nativePixelSize.height) config=\(configuration.width)x\(configuration.height) output=\(output.width)x\(output.height)"
        )
        #endif
    }

    /// 一次性获取屏幕内容、冻结所有目标显示器，并（窗口模式时）列出候选窗口。
    ///
    /// - Parameter displayIDs: 需要冻结的显示器；传空数组表示全部。
    static func prepare(
        displayIDs: [CGDirectDisplayID],
        includeWindows: Bool,
        showsCursor: Bool
    ) async throws -> PreparedContent {
        let content = try await loadShareableContent()

        guard !content.displays.isEmpty else {
            Log.screenshot.error("SCShareableContent returned no displays")
            throw ScreenshotError.noContent
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = ownApplications(in: content)

        var captures: [DisplayCapture] = []
        for display in content.displays {
            guard displayIDs.isEmpty || displayIDs.contains(display.displayID) else { continue }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let (configuration, metrics) = makeDisplayConfiguration(
                display: display,
                filter: filter,
                showsCursor: showsCursor
            )
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                captures.append(DisplayCapture(displayID: display.displayID, image: image))
                logDisplayCapture(
                    display: display,
                    filter: filter,
                    metrics: metrics,
                    configuration: configuration,
                    output: image
                )
            } catch {
                Log.screenshot.error(
                    "Display \(display.displayID, privacy: .public) capture failed: \(error.localizedDescription, privacy: .public)"
                )
                throw ScreenshotError.displayCaptureFailed(
                    displayID: display.displayID,
                    message: error.localizedDescription
                )
            }
        }

        guard !captures.isEmpty else {
            throw ScreenshotError.noDisplay
        }

        var windowDescriptors: [WindowDescriptor] = []
        if includeWindows {
            windowDescriptors = content.windows.compactMap { window in
                makeWindowDescriptor(for: window, ownPID: ownPID, ownBundleID: ownBundleID)
            }
        }

        Log.screenshot.info(
            "Prepared \(captures.count, privacy: .public) displays, \(windowDescriptors.count, privacy: .public) windows"
        )
        return PreparedContent(displays: captures, windows: windowDescriptors)
    }

    // MARK: - 长截图逐帧采集

    /// 重新截取当前屏幕上的指定选区（不使用冻结图）。
    ///
    /// 先捕获整块显示器（排除本应用窗口），再按该屏实际像素比例裁剪；
    /// 长截图的覆盖层在采集期间会 orderOut，因此拿到的是页面当前的真实内容。
    static func captureRegion(
        displayID: CGDirectDisplayID,
        selectionInScreen: CGRect,
        screenPointSize: CGSize,
        showsCursor: Bool
    ) async throws -> CGImage {
        let content = try await loadShareableContent()
        guard !content.displays.isEmpty else {
            throw ScreenshotError.noContent
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications(in: content),
            exceptingWindows: []
        )
        let (configuration, metrics) = makeDisplayConfiguration(
            display: display,
            filter: filter,
            showsCursor: showsCursor
        )

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            Log.screenshot.debug(
                "Region frame display \(display.displayID, privacy: .public) config=\(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) output=\(image.width, privacy: .public)x\(image.height, privacy: .public) scale=\(metrics.pointPixelScale, privacy: .public)"
            )
        } catch {
            Log.screenshot.error(
                "Long capture frame failed on display \(displayID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw ScreenshotError.displayCaptureFailed(
                displayID: displayID,
                message: error.localizedDescription
            )
        }

        let cropRect = ScreenGeometry.pixelCropRect(
            selection: selectionInScreen,
            screenBounds: CGRect(origin: .zero, size: screenPointSize),
            imageSize: CGSize(width: image.width, height: image.height)
        )
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = image.cropping(to: cropRect) else {
            throw ScreenshotError.displayCaptureFailed(
                displayID: displayID,
                message: "所选区域超出了屏幕可截取范围"
            )
        }
        return cropped
    }

    // MARK: - 窗口截图

    /// 用 `SCContentFilter(desktopIndependentWindow:)` 单独截取一个窗口。
    static func captureWindow(
        windowID: CGWindowID,
        backingScale: CGFloat,
        showsCursor: Bool
    ) async throws -> CGImage {
        let content = try await loadShareableContent()

        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenshotError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        // 窗口截图同样优先使用 filter 的 pointPixelScale，backingScale 仅作兜底。
        let filterScale = CGFloat(filter.pointPixelScale)
        // pointPixelScale 是首选；backingScale 作为兜底，避免某些窗口 filter 返回 1 时丢掉 Retina 像素。
        let scale = max(filterScale, CGFloat(backingScale), 1)
        let windowPointSize = window.frame.size
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((windowPointSize.width * scale).rounded()))
        configuration.height = max(1, Int((windowPointSize.height * scale).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        // 单独窗口截图默认会带上窗口阴影的留白，导致图片尺寸与窗口 frame 不一致；
        // 关掉后输出与窗口点尺寸严格对应，标注坐标才能对齐。
        configuration.ignoreShadowsSingleWindow = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            Log.screenshot.info(
                "Window \(windowID, privacy: .public) frame=\(windowPointSize.width, privacy: .public)x\(windowPointSize.height, privacy: .public)pt filterScale=\(filter.pointPixelScale, privacy: .public) usedScale=\(scale, privacy: .public) config=\(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) output=\(image.width, privacy: .public)x\(image.height, privacy: .public)"
            )
            return image
        } catch {
            Log.screenshot.error(
                "Window \(windowID, privacy: .public) capture failed: \(error.localizedDescription, privacy: .public)"
            )
            throw ScreenshotError.windowCaptureFailed(error.localizedDescription)
        }
    }

    // MARK: - 窗口过滤

    private static func makeWindowDescriptor(
        for window: SCWindow,
        ownPID: pid_t,
        ownBundleID: String?
    ) -> WindowDescriptor? {
        // 只保留普通应用窗口：layer 0 已经排除菜单栏(25)、Dock(20) 等系统层。
        guard window.windowLayer == 0 else { return nil }
        guard window.isOnScreen else { return nil }
        guard window.frame.width >= 40, window.frame.height >= 40 else { return nil }
        guard let owner = window.owningApplication else { return nil }
        guard owner.processID != ownPID else { return nil }
        if let ownBundleID, owner.bundleIdentifier == ownBundleID { return nil }
        guard !systemWindowBundleIDs.contains(owner.bundleIdentifier) else { return nil }
        guard !systemWindowOwnerNames.contains(owner.applicationName) else { return nil }

        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WindowDescriptor(
            id: window.windowID,
            frame: window.frame,
            title: title.isEmpty ? owner.applicationName : title,
            ownerName: owner.applicationName,
            ownerBundleID: owner.bundleIdentifier,
            layer: window.windowLayer
        )
    }
}
