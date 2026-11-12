import AppKit
#if DEBUG
import SwiftUI
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var debugSnapshotWindow: NSWindow?
    #endif

    private var permissionWatchdog: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // LSUIElement 之外再显式设为 accessory，确保双击启动时也不会短暂出现 Dock 图标。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppState.shared.refreshPermission()
        SettingsStore.shared.refreshLaunchAtLogin()
        attemptAutomaticPermissionRecovery()
        startPermissionWatchdogIfNeeded()

        // 全局快捷键：注册失败（被占用）时会记录到 HotKeyManager.failures，设置页可见。
        HotKeyManager.shared.install()

        // 剪贴板模块自己负责串行队列与轮询，这里只启动。
        ClipboardManager.shared.startMonitoring()

        // 触发壁纸模块初始化：若上次启用了动态壁纸，由它在 init 中恢复播放。
        _ = WallpaperManager.shared

        Log.app.info("Kaiming launched, screenRecording=\(AppState.shared.screenRecordingGranted, privacy: .public)")

        #if DEBUG
        NSLog(
            "Kaiming debug: launched, screenRecording=\(AppState.shared.screenRecordingGranted), "
                + "hotkeyFailures=\(HotKeyManager.shared.failures.count)"
        )
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AppRouter.shared.openSettings()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--probe-permission") {
            Task { @MainActor in
                let preflight = ScreenCapturePermission.isGranted
                let actual = await ScreenCapturePermission.verifyAccess()
                NSLog("Kaiming debug: permission preflight=\(preflight) actualSCK=\(actual)")
            }
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--probe-permission-file"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            Task { @MainActor in
                let preflight = ScreenCapturePermission.isGranted
                let actual = await ScreenCapturePermission.verifyAccess()
                let text = "preflight=\(preflight) actualSCK=\(actual) bundle=\(Bundle.main.bundleIdentifier ?? "-")\n"
                try? text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-clipboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AppRouter.shared.openClipboardPicker()
            }
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--capture-test"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let modeName = ProcessInfo.processInfo.arguments[index + 1]
            let mode: CaptureMode = switch modeName {
            case "window": .window
            case "region": .region
            default: .fullScreen
            }
            // 测试只覆盖本次采集行为，绝不修改 SettingsStore/UserDefaults。
            // 默认不写剪贴板；加 --capture-test-copy 可显式验证“截图进剪贴板”链路。
            let copyToClipboard = ProcessInfo.processInfo.arguments.contains("--capture-test-copy")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                ScreenshotCoordinator.shared.startForTesting(
                    mode: mode,
                    copyToClipboard: copyToClipboard,
                    playSound: false,
                    addsWindowHeader: ProcessInfo.processInfo.arguments
                        .contains("--capture-test-decorate")
                )
            }
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--open-folder"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MarkdownOpenRequest.shared.open(folder: URL(fileURLWithPath: path))
                AppRouter.shared.openMarkdown()
            }
        }
        handleSnapshotArguments()

        #endif
    }


    #if DEBUG
    /// 调试快照：不依赖屏幕录制权限，把 SwiftUI 面板 / Markdown 窗口渲染成 PNG 后退出。
    private func handleSnapshotArguments() {
        let args = ProcessInfo.processInfo.arguments

        if let index = args.firstIndex(of: "--snapshot-panel"), index + 1 < args.count {
            let path = args[index + 1]
            if args.contains("--snapshot-fake-capture") {
                AppState.shared.recordCapture(Self.debugSampleImage())
            }
            if let tabIndex = args.firstIndex(of: "--snapshot-tab"), tabIndex + 1 < args.count {
                switch args[tabIndex + 1] {
                case "clipboard": AppState.shared.selectedTab = .clipboard
                case "wallpaper": AppState.shared.selectedTab = .wallpaper
                case "apps": AppState.shared.selectedTab = .apps
                default: AppState.shared.selectedTab = .screenshot
                }
            }
            let root = AnyView(
                MenuBarPanel()
                    .environmentObject(AppState.shared)
                    .environmentObject(SettingsStore.shared)
            )
            snapshotViaWindow(root: root, size: CGSize(width: 400, height: 580), path: path)
            return
        }

        if let index = args.firstIndex(of: "--snapshot-clipboard-picker"), index + 1 < args.count {
            let path = args[index + 1]
            let root = AnyView(
                ClipboardPickerView()
                    .environmentObject(SettingsStore.shared)
                    .environmentObject(AppState.shared)
            )
            snapshotViaWindow(root: root, size: CGSize(width: 520, height: 460), path: path)
            return
        }

        if let index = args.firstIndex(of: "--snapshot-settings"), index + 1 < args.count {
            let path = args[index + 1]
            if let tabIndex = args.firstIndex(of: "--snapshot-settings-tab"),
               tabIndex + 1 < args.count,
               let tab = SettingsTab(rawValue: args[tabIndex + 1]) {
                SettingsRoute.shared.request(tab)
            }
            let root = AnyView(
                SettingsView()
                    .environmentObject(SettingsStore.shared)
                    .environmentObject(AppState.shared)
            )
            snapshotViaWindow(root: root, size: CGSize(width: 580, height: 560), path: path)
            return
        }

        if let index = args.firstIndex(of: "--snapshot-markdown"), index + 1 < args.count {
            let path = args[index + 1]
            let root = AnyView(
                MarkdownWindowView()
                    .environmentObject(SettingsStore.shared)
                    .environmentObject(AppState.shared)
            )
            snapshotViaWindow(root: root, size: CGSize(width: 900, height: 700), path: path)
        }
    }

    /// 调试快照用的合成截图（避免依赖真实屏幕录制权限）。
    private static func debugSampleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 200)
        NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.32, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedRed: 0.95, green: 0.74, blue: 0.36, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 120, y: 60, width: 80, height: 80)).fill()
        image.unlockFocus()
        return image
    }

    /// 用真实 NSWindow + NSHostingView 渲染，避免 ImageRenderer 对控件/AppKit 内容支持不全。
    private func snapshotViaWindow(root: AnyView, size: CGSize, path: String) {
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kaiming Snapshot"
        window.contentView = hosting
        window.backgroundColor = .windowBackgroundColor
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        window.makeKey()
        debugSnapshotWindow = window

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    NSLog("Kaiming debug: wrote snapshot to \(path)")
                }
            } else {
                NSLog("Kaiming debug: snapshot failed")
            }
            NSApp.terminate(nil)
        }
    }
    #endif


    func applicationDidBecomeActive(_ notification: Notification) {
        // 用户可能刚从系统设置授权返回，实时刷新权限状态。
        AppState.shared.refreshPermission()
    }

    /// TCC 授权通常只对新进程生效。若系统认为已授权但当前进程 preflight 仍为 false，
    /// 自动重启一次让授权生效；每个安装只尝试一次，失败后交给 UI 的“重启/重置”流程。
    /// 用户可能正在系统设置里勾选权限；TCC 通常只对新进程生效。
    /// 监视前台应用：一旦用户从系统设置/授权弹窗返回 Kaiming，自动重启一次让授权生效。
    private func startPermissionWatchdogIfNeeded() {
        guard !ScreenCapturePermission.isGranted else { return }
        permissionWatchdog?.cancel()
        permissionWatchdog = Task { @MainActor in
            let settingsBundleIDs: Set<String> = [
                "com.apple.systempreferences",
                "com.apple.SystemSettings",
                "com.apple.SecurityAgent",
            ]
            var visitedSystemSettings = false

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)

                if ScreenCapturePermission.isGranted {
                    UserDefaults.standard.set(false, forKey: "kaiming.permission.autoRelaunchAttempted")
                    Log.app.info("Screen recording permission became effective; relaunching to apply")
                    AppRelauncher.relaunch()
                    return
                }

                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if let frontmost, settingsBundleIDs.contains(frontmost) {
                    visitedSystemSettings = true
                } else if visitedSystemSettings, frontmost == Bundle.main.bundleIdentifier {
                    UserDefaults.standard.set(false, forKey: "kaiming.permission.autoRelaunchAttempted")
                    Log.app.info("Returned from system settings with permission denied; relaunching to apply TCC")
                    AppRelauncher.relaunch()
                    return
                }
            }
        }
    }

    private func attemptAutomaticPermissionRecovery() {
        guard !ScreenCapturePermission.isGranted else {
            UserDefaults.standard.set(false, forKey: "kaiming.permission.autoRelaunchAttempted")
            return
        }

        let defaults = UserDefaults.standard
        let key = "kaiming.permission.autoRelaunchAttempted"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        let granted = PermissionCenter.shared.request(.screenRecording)
        #if DEBUG
        NSLog("Kaiming debug: automatic permission request granted=\(granted)")
        #endif
        if granted {
            // 系统已有授权记录，但当前进程未生效：重启一次使 TCC 重新绑定。
            AppRelauncher.relaunch()
        }
    }

    /// 处理 `kaiming://open-folder?path=<base64url>`（CLI `kaiming ./docs` 使用）。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleExternalOpen(url)
        }
    }

    private func handleExternalOpen(_ url: URL) {
        guard url.scheme == "kaiming" else { return }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let encoded = components.queryItems?.first(where: { $0.name == "path" })?.value,
            let decoded = Self.decodeBase64URL(encoded)
        else {
            AppState.shared.flash("目录快捷方式无效，请重新复制路径。", kind: .error)
            return
        }

        let target = URL(fileURLWithPath: decoded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            AppState.shared.flash("路径不存在：\(target.path)", kind: .error)
            return
        }

        let folder = isDirectory.boolValue ? target : target.deletingLastPathComponent()
        let file = isDirectory.boolValue ? nil : target
        #if DEBUG
        NSLog("Kaiming debug: external open folder=\(folder.path) file=\(file?.path ?? "-")")
        #endif
        MarkdownOpenRequest.shared.open(folder: folder, file: file)

        // MenuBarLabel 的 task 通常已注册 handler；若 URL 在冷启动时到达，稍等再打开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            AppRouter.shared.openMarkdown()
        }
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionWatchdog?.cancel()
        ClipboardManager.shared.stopMonitoring()
        HotKeyManager.shared.uninstall()
        Log.app.info("Kaiming terminating")
    }
}
