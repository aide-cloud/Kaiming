import AppKit
import ApplicationServices

/// 辅助功能（Accessibility）权限：仅「长截图自动滚动」需要。
/// 普通区域/窗口/全屏截图不需要该权限。
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统引导（系统只会在首次/必要时弹出），返回当前状态。
    @discardableResult
    static func prompt() -> Bool {
        // 避免引用非 Sendable 的全局常量；该键名是 AX API 的稳定字符串。
        let granted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        Log.app.info("Accessibility permission prompted, trusted=\(granted, privacy: .public)")
        return granted
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
