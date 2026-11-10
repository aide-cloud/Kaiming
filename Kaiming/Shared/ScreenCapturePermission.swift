import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕录制（Screen Recording）TCC 权限的唯一入口。
///
/// 关键陷阱：未授权时 ScreenCaptureKit 的 `SCShareableContent` 会返回空列表且不抛错，
/// 因此截图前必须显式调用 `isGranted` / `request()` 并给出可操作提示，绝不允许静默失败。
enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗；返回调用后的即时状态（用户通常需要到系统设置里勾选并重启应用）。
    @discardableResult
    static func request() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Log.app.info("Screen capture access requested, granted=\(granted, privacy: .public)")
        return granted
    }

    /// 真实能力探测：直接询问 ScreenCaptureKit，而不是只看可能过期的 preflight。
    ///
    /// 背景：TCC 授权与构建的代码签名/CDHash 绑定。重新构建后系统设置可能仍显示
    /// “已授权”，但 `CGPreflightScreenCaptureAccess()` 变为 false。若此时直接用
    /// preflight 拦截，用户会看到“需要授权”的假阴性。以实际 SCK 结果为准。
    static func verifyAccess() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let granted = !content.displays.isEmpty
            Log.app.info("ScreenCaptureKit access probe: \(granted, privacy: .public)")
            return granted
        } catch {
            Log.app.error("ScreenCaptureKit access probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 重置 Kaiming 的屏幕录制 TCC 记录（用于旧构建签名残留导致的状态错乱）。
    /// 重置后系统会要求重新授权；调用方必须提示用户并重启应用。
    @discardableResult
    static func resetTCCEntry() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            Log.app.info("tccutil reset ScreenCapture \(bundleID, privacy: .public) exit=\(process.terminationStatus, privacy: .public)")
            return process.terminationStatus == 0
        } catch {
            Log.app.error("tccutil reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
