import AppKit
#if DEBUG
import SwiftUI
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var debugSnapshotWindow: NSWindow?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        // LSUIElement 之外再显式设为 accessory，确保双击启动时也不会短暂出现 Dock 图标。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppState.shared.refreshPermission()
        SettingsStore.shared.refreshLaunchAtLogin()

        // 全局快捷键：注册失败（被占用）时会记录到 HotKeyManager.failures，设置页可见。
        HotKeyManager.shared.install()

        // 剪贴板模块自己负责串行队列与轮询，这里只启动。
        ClipboardManager.shared.startMonitoring()

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

        if let index = args.firstIndex(of: "--snapshot-settings"), index + 1 < args.count {
            let path = args[index + 1]
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardManager.shared.stopMonitoring()
        HotKeyManager.shared.uninstall()
        Log.app.info("Kaiming terminating")
    }
}
