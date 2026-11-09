import AppKit
import CoreGraphics

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

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
