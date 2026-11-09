import Foundation

/// App 层向各模块分派「用户意图」的桥。仅承载命令，不承载模块间数据。
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    private var captureHandler: ((CaptureMode) -> Void)?
    private var markdownHandler: (() -> Void)?
    private var settingsHandler: (() -> Void)?

    private init() {}

    /// 由应用根部（MenuBarExtra label）在启动时注册，保证未打开面板时全局快捷键也能工作。
    func register(capture: @escaping (CaptureMode) -> Void, markdown: @escaping () -> Void) {
        captureHandler = capture
        markdownHandler = markdown
        Log.app.info("AppRouter handlers registered")
    }

    /// 设置窗口使用独立 Window scene；macOS 14 + LSUIElement 下 Settings scene 无法可靠唤起。
    func registerSettings(_ handler: @escaping () -> Void) {
        settingsHandler = handler
    }

    func openSettings() {
        guard let settingsHandler else {
            Log.app.error("Settings handler not registered yet; ignoring")
            return
        }
        settingsHandler()
    }

    func capture(_ mode: CaptureMode) {
        guard let captureHandler else {
            Log.app.error("Capture handler not registered yet; ignoring \(mode.rawValue, privacy: .public)")
            return
        }
        captureHandler(mode)
    }

    func openMarkdown() {
        guard let markdownHandler else {
            Log.app.error("Markdown handler not registered yet; ignoring shortcut")
            return
        }
        markdownHandler()
    }
}
