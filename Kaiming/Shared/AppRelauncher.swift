import AppKit

/// 权限变更后重启应用：Screen Recording 的 TCC 授权通常只对新进程生效。
enum AppRelauncher {
    /// 启动一个脱离当前进程的 helper，稍后重新打开当前 app，然后退出当前进程。
    @MainActor
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        guard !bundlePath.isEmpty else {
            Log.app.error("Cannot relaunch: bundle path is empty")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 用位置参数传递路径，避免路径中的空格/引号被注入。
        process.arguments = [
            "-c",
            "sleep 0.8; /usr/bin/open \"$1\"",
            "kaiming-relaunch",
            bundlePath,
        ]
        do {
            try process.run()
            Log.app.info("Relaunching Kaiming from \(bundlePath, privacy: .public)")
            NSApp.terminate(nil)
        } catch {
            Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            AppState.shared.flash("自动重启失败，请手动退出并重新打开 Kaiming。", kind: .error)
        }
    }
}
