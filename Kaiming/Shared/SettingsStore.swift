import AppKit
import Combine
import ServiceManagement

/// 截图文件格式。
enum ScreenshotFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG（无损）" : "JPEG（体积小）" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// 全部偏好设置的单一来源。模块内部只读取这里，不各自建 UserDefaults 键。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let copyScreenshotToClipboard = "kaiming.screenshot.copyToClipboard"
        static let playCaptureSound = "kaiming.screenshot.playSound"
        static let captureCursor = "kaiming.screenshot.captureCursor"
        static let screenshotFormat = "kaiming.screenshot.format"
        static let autoSaveScreenshots = "kaiming.screenshot.autoSave"
        static let screenshotSaveDirectory = "kaiming.screenshot.saveDirectory"
        static let screenshotImageWindowHeader = "kaiming.screenshot.imageWindowHeader"
        static let screenshotHideOwnWindows = "kaiming.screenshot.hideOwnWindows"
        static let clipboardMonitoring = "kaiming.clipboard.monitoring"
        static let clipboardHistoryLimit = "kaiming.clipboard.historyLimit"
        static let clipboardPollInterval = "kaiming.clipboard.pollInterval"
        static let hotkeysEnabled = "kaiming.hotkeys.enabled"
        static let markdownFontSize = "kaiming.markdown.fontSize"
        static let markdownLivePreview = "kaiming.markdown.livePreview"
        static let markdownPageWidth = "kaiming.markdown.pageWidth"
    }

    private let defaults: UserDefaults

    // MARK: - 截图

    @Published var copyScreenshotToClipboard: Bool {
        didSet { defaults.set(copyScreenshotToClipboard, forKey: Keys.copyScreenshotToClipboard) }
    }

    @Published var playCaptureSound: Bool {
        didSet { defaults.set(playCaptureSound, forKey: Keys.playCaptureSound) }
    }

    @Published var captureCursor: Bool {
        didSet { defaults.set(captureCursor, forKey: Keys.captureCursor) }
    }

    @Published var screenshotFormat: ScreenshotFormat {
        didSet { defaults.set(screenshotFormat.rawValue, forKey: Keys.screenshotFormat) }
    }

    @Published var autoSaveScreenshots: Bool {
        didSet { defaults.set(autoSaveScreenshots, forKey: Keys.autoSaveScreenshots) }
    }

    /// 空字符串表示使用默认目录 ~/Pictures/Kaiming。
    @Published var screenshotSaveDirectoryPath: String {
        didSet { defaults.set(screenshotSaveDirectoryPath, forKey: Keys.screenshotSaveDirectory) }
    }

    var screenshotSaveDirectory: URL {
        if screenshotSaveDirectoryPath.isEmpty {
            return AppPaths.defaultScreenshots
        }
        return URL(fileURLWithPath: screenshotSaveDirectoryPath, isDirectory: true)
    }

    /// 是否在截图成品顶部合成 macOS 标准窗口头部（红黄绿三个圆点）。
    /// 区域 / 全屏 / 长截图生效；窗口截图本身已含标题栏，不重复叠加。
    @Published var screenshotImageWindowHeader: Bool {
        didSet { defaults.set(screenshotImageWindowHeader, forKey: Keys.screenshotImageWindowHeader) }
    }

    /// 截图时是否隐藏 Kaiming 自己的窗口（含 Markdown 编辑/预览窗口）。
    /// 默认 `false`：截图内容保留 Markdown 等本应用窗口，方便直接把文档截进图里。
    /// 长截图逐帧采集仍会排除覆盖层边框/HUD，避免把截图辅助 UI 拼进结果。
    @Published var screenshotHideOwnWindows: Bool {
        didSet { defaults.set(screenshotHideOwnWindows, forKey: Keys.screenshotHideOwnWindows) }
    }

    // MARK: - 剪贴板

    @Published var clipboardMonitoringEnabled: Bool {
        didSet { defaults.set(clipboardMonitoringEnabled, forKey: Keys.clipboardMonitoring) }
    }

    /// 历史记录上限，读取端会 clamp 到 10...500。
    @Published var clipboardHistoryLimit: Int {
        didSet { defaults.set(clipboardHistoryLimit, forKey: Keys.clipboardHistoryLimit) }
    }

    @Published var clipboardPollInterval: Double {
        didSet { defaults.set(clipboardPollInterval, forKey: Keys.clipboardPollInterval) }
    }

    // MARK: - 快捷键 / Markdown

    @Published var hotkeysEnabled: Bool {
        didSet { defaults.set(hotkeysEnabled, forKey: Keys.hotkeysEnabled) }
    }

    @Published var markdownFontSize: Double {
        didSet { defaults.set(markdownFontSize, forKey: Keys.markdownFontSize) }
    }

    @Published var markdownLivePreview: Bool {
        didSet { defaults.set(markdownLivePreview, forKey: Keys.markdownLivePreview) }
    }

    @Published var markdownPageWidth: MarkdownPageWidth {
        didSet { defaults.set(markdownPageWidth.rawValue, forKey: Keys.markdownPageWidth) }
    }

    // MARK: - 开机启动（由 SMAppService 真实状态驱动）

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func bool(_ key: String, default fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }

        copyScreenshotToClipboard = bool(Keys.copyScreenshotToClipboard, default: true)
        playCaptureSound = bool(Keys.playCaptureSound, default: true)
        captureCursor = bool(Keys.captureCursor, default: false)

        let formatRaw = defaults.string(forKey: Keys.screenshotFormat) ?? ScreenshotFormat.png.rawValue
        screenshotFormat = ScreenshotFormat(rawValue: formatRaw) ?? .png
        autoSaveScreenshots = bool(Keys.autoSaveScreenshots, default: false)
        screenshotSaveDirectoryPath = defaults.string(forKey: Keys.screenshotSaveDirectory) ?? ""
        screenshotImageWindowHeader = bool(Keys.screenshotImageWindowHeader, default: true)
        screenshotHideOwnWindows = bool(Keys.screenshotHideOwnWindows, default: false)

        clipboardMonitoringEnabled = bool(Keys.clipboardMonitoring, default: true)
        clipboardHistoryLimit = defaults.object(forKey: Keys.clipboardHistoryLimit) as? Int ?? 50
        clipboardPollInterval = defaults.object(forKey: Keys.clipboardPollInterval) as? Double ?? 0.5

        hotkeysEnabled = bool(Keys.hotkeysEnabled, default: true)
        markdownFontSize = defaults.object(forKey: Keys.markdownFontSize) as? Double ?? 15
        markdownLivePreview = bool(Keys.markdownLivePreview, default: true)
        let pageWidthRaw = defaults.string(forKey: Keys.markdownPageWidth) ?? MarkdownPageWidth.standard.rawValue
        markdownPageWidth = MarkdownPageWidth(rawValue: pageWidthRaw) ?? .standard

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - 开机启动

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
            Log.app.info("Login item updated: \(enabled, privacy: .public)")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
            Log.app.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - 重置

    func resetToDefaults() {
        copyScreenshotToClipboard = true
        playCaptureSound = true
        captureCursor = false
        screenshotFormat = .png
        autoSaveScreenshots = false
        screenshotSaveDirectoryPath = ""
        screenshotImageWindowHeader = true
        screenshotHideOwnWindows = false
        clipboardMonitoringEnabled = true
        clipboardHistoryLimit = 50
        clipboardPollInterval = 0.5
        hotkeysEnabled = true
        markdownFontSize = 15
        markdownLivePreview = true
        markdownPageWidth = .standard
        Log.app.info("Settings reset to defaults")
    }
}
