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
        handlePickerKeyTest()
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
        handleRenderTestArguments()

        #endif
    }


    #if DEBUG
    /// 快照用分区：`--snapshot-clipboard-scope favorites` 渲染「收藏」页，默认「实时」。
    private static func snapshotClipboardScope(_ args: [String]) -> ClipboardScope {
        guard let index = args.firstIndex(of: "--snapshot-clipboard-scope"),
              index + 1 < args.count,
              let scope = ClipboardScope(rawValue: args[index + 1]) else {
            return .live
        }
        return scope
    }

    /// 快照用系统页分区：`--snapshot-system-section features` 渲染「系统功能」。
    private static func snapshotSystemSection(_ args: [String]) -> SystemSection {
        guard let index = args.firstIndex(of: "--snapshot-system-section"),
              index + 1 < args.count,
              let section = SystemSection(rawValue: args[index + 1]) else {
            return .clean
        }
        return section
    }

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
                case "system": AppState.shared.selectedTab = .system
                default: AppState.shared.selectedTab = .screenshot
                }
            }
            let root = AnyView(
                MenuBarPanel(
                    clipboardScope: Self.snapshotClipboardScope(args),
                    systemSection: Self.snapshotSystemSection(args)
                )
                .environmentObject(AppState.shared)
                .environmentObject(SettingsStore.shared)
            )
            snapshotViaWindow(root: root, size: CGSize(width: 400, height: 580), path: path)
            return
        }

        if let index = args.firstIndex(of: "--snapshot-menubar-label"), index + 1 < args.count {
            let path = args[index + 1]
            snapshotViaWindow(
                root: AnyView(MenuBarLabel()),
                size: CGSize(width: 520, height: 34),
                path: path
            )
            return
        }

        if let index = args.firstIndex(of: "--snapshot-clipboard-picker"), index + 1 < args.count {
            let path = args[index + 1]
            let root = AnyView(
                ClipboardPickerView(initialScope: Self.snapshotClipboardScope(args))
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

        if let index = args.firstIndex(of: "--snapshot-annotation-toolbar"), index + 1 < args.count {
            let path = args[index + 1]
            let session = AnnotationSession()
            session.cornerRadius = 20
            session.add(
                Annotation(
                    kind: .rectangle,
                    start: CGPoint(x: 20, y: 20),
                    end: CGPoint(x: 120, y: 80),
                    color: AnnotationColor.palette[0]
                )
            )
            session.select(session.annotations[0].id)
            let root = AnyView(
                AnnotationToolbar(
                    session: session,
                    showsLongCapture: true,
                    onStartLongCapture: {},
                    onComplete: {},
                    onCancel: {}
                )
            )
            snapshotViaWindow(root: root, size: AnnotationToolbar.preferredSize, path: path)
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

    /// 键盘回归验证：打开剪贴板快捷选择后，把合成的 ↓/↑ 事件投递到应用事件队列，
    /// 走正常的事件分发（字段编辑器 → delegate），并逐步截图窗口，便于人工核对高亮移动。
    private func handlePickerKeyTest() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--picker-key-test") else { return }
        let directory = ProcessInfo.processInfo.environment["KAIMING_PICKER_TEST_DIR"]
            ?? NSTemporaryDirectory()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            AppRouter.shared.openClipboardPicker()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self else { return }
            guard let window = NSApp.windows.first(where: {
                $0.title.contains("剪贴板") && $0.isVisible
            }) else {
                NSLog("Kaiming debug: picker key test could not find picker window")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if let field = Self.firstTextField(in: window.contentView) {
                window.makeFirstResponder(field)
            }
            NSLog("Kaiming debug: picker key test window=#\(window.windowNumber)")

            self.captureWindowSnapshot(window, to: directory + "/picker-key-0-initial.png")
            self.postKey(125, to: window) // ↓
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.captureWindowSnapshot(window, to: directory + "/picker-key-1-down.png")
                self.postKey(125, to: window) // ↓
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.captureWindowSnapshot(window, to: directory + "/picker-key-2-down.png")
                    self.postKey(126, to: window) // ↑
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        self.captureWindowSnapshot(window, to: directory + "/picker-key-3-up.png")
                        NSLog("Kaiming debug: picker key test finished")
                    }
                }
            }
        }
    }

    /// 投递到应用自己的事件队列，走与真实按键相同的分发路径（不需要辅助功能权限）。
    private func postKey(_ keyCode: UInt16, to window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            NSLog("Kaiming debug: failed to create key event \(keyCode)")
            return
        }
        NSApp.postEvent(event, atStart: false)
    }

    static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    /// 读取窗口自带的可见位图（不依赖屏幕录制权限）。
    private func captureWindowSnapshot(_ window: NSWindow, to path: String) {
        guard let content = window.contentView else { return }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            NSLog("Kaiming debug: cannot allocate snapshot rep")
            return
        }
        content.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("Kaiming debug: cannot encode snapshot")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            NSLog("Kaiming debug: wrote window snapshot \(path)")
        } catch {
            NSLog("Kaiming debug: snapshot write failed \(error.localizedDescription)")
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
        let light = ProcessInfo.processInfo.environment["KAIMING_SNAPSHOT_LIGHT"] == "1"
        if light {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        let content = light ? AnyView(root.environment(\.colorScheme, .light)) : root
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = (light ? NSColor.white : NSColor.windowBackgroundColor).cgColor
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kaiming Snapshot"
        window.contentView = hosting
        window.backgroundColor = light ? .white : .windowBackgroundColor
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if light {
            window.appearance = NSAppearance(named: .aqua)
        }
        window.orderFrontRegardless()
        window.makeKey()
        debugSnapshotWindow = window

        Task { @MainActor in
            let delay = ProcessInfo.processInfo.environment["KAIMING_SNAPSHOT_DELAY"]
                .flatMap(Double.init) ?? 2
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.2) * 1_000_000_000))
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

    /// 圆角透明回归：合成底图 + 标注拍平后，验证四个圆角 alpha=0，
    /// 并做一次 PNG 编码/解码往返校验，确保写出的文件同样保留透明角。
    /// 用法：`Kaiming --render-test-rounded /tmp/rounded.png`（DEBUG）。
    private func handleRenderTestArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--logic-test-annotations") {
            AnnotationEditingTest.run()
            return
        }
        if args.contains("--logic-test-overlay-interactions") {
            CaptureOverlayRenderTest.runInteractionTest()
            return
        }
        if args.contains("--logic-test-overlay-view") {
            CaptureOverlayRenderTest.runViewPathTest()
            return
        }
        if args.contains("--logic-test-system") {
            SystemSelfTest.run()
            return
        }
        if args.contains("--logic-test-uninstall") {
            let path: String? = {
                guard let index = args.firstIndex(of: "--logic-test-uninstall"),
                      index + 1 < args.count else { return nil }
                return args[index + 1]
            }()
            AppUninstallerSelfTest.run(reportPath: path)
            return
        }
        if let index = args.firstIndex(of: "--render-test-overlay-corners"),
           index + 1 < args.count {
            CaptureOverlayRenderTest.run(outputPath: args[index + 1])
            return
        }
        guard let index = args.firstIndex(of: "--render-test-rounded"),
              index + 1 < args.count else { return }
        let path = args[index + 1]

        let width = 640
        let height = 400
        guard let base = Self.makeRenderTestBaseImage(width: width, height: height) else {
            NSLog("Kaiming debug: rounded render test FAIL: cannot create base image")
            NSApp.terminate(nil)
            return
        }

        let penPoints = stride(from: 0, through: 16, by: 1).map { step in
            CGPoint(x: 260 + CGFloat(step) * 9, y: 260 + CGFloat((step * 7) % 40))
        }
        let annotations: [Annotation] = [
            Annotation(
                kind: .rectangle,
                start: CGPoint(x: 40, y: 40),
                end: CGPoint(x: 190, y: 150),
                color: AnnotationColor.palette[0]
            ),
            Annotation(
                kind: .arrow,
                start: CGPoint(x: 250, y: 60),
                end: CGPoint(x: 400, y: 190),
                color: AnnotationColor.palette[4]
            ),
            Annotation(
                kind: .text,
                start: CGPoint(x: 50, y: 230),
                color: AnnotationColor.palette[3],
                text: "圆角透明测试"
            ),
            Annotation(
                kind: .pen,
                start: penPoints[0],
                end: penPoints[penPoints.count - 1],
                color: AnnotationColor.palette[1],
                lineWidth: AnnotationGeometry.penLineWidth,
                points: penPoints
            ),
            Annotation(
                kind: .mosaic,
                start: CGPoint(x: 380, y: 200),
                end: CGPoint(x: 600, y: 355),
                color: AnnotationColor.palette[0]
            ),
        ]

        guard let rendered = AnnotationDrawing.render(
            baseImage: base,
            annotations: annotations,
            boundsInPoints: CGSize(width: width, height: height),
            cornerRadius: 28,
            addsWindowHeader: true
        ) else {
            NSLog("Kaiming debug: rounded render test FAIL: render returned nil")
            NSApp.terminate(nil)
            return
        }

        var failures: [String] = Self.verifyTransparentCorners(rendered, label: "rendered")
        var pngWritten = false
        do {
            let data = try CaptureHistory.encode(rendered, format: .png)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            pngWritten = true
            if let image = NSImage(data: data) {
                var rect = CGRect(origin: .zero, size: image.size)
                if let decoded = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    failures += Self.verifyTransparentCorners(decoded, label: "png-roundtrip")
                } else {
                    failures.append("png-roundtrip: decode failed")
                }
            } else {
                failures.append("png-roundtrip: NSImage decode failed")
            }
        } catch {
            failures.append("png-encode: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            NSLog(
                "Kaiming debug: rounded render test PASS size=\(rendered.width)x\(rendered.height) "
                    + "png=\(pngWritten ? path : "-")"
            )
        } else {
            NSLog("Kaiming debug: rounded render test FAIL \(failures.joined(separator: "; "))")
        }
        NSApp.terminate(nil)
    }

    /// 四角 alpha 必须为 0，中心必须不透明；返回失败描述。
    private static func verifyTransparentCorners(_ image: CGImage, label: String) -> [String] {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return ["\(label): image too small"] }

        var failures: [String] = []
        let corners = [
            ("topLeft", 0, 0),
            ("topRight", width - 1, 0),
            ("bottomLeft", 0, height - 1),
            ("bottomRight", width - 1, height - 1),
        ]
        for (name, x, y) in corners {
            guard let alpha = alphaValue(of: image, x: x, y: y) else {
                failures.append("\(label).\(name): alpha read failed")
                continue
            }
            if alpha != 0 {
                failures.append("\(label).\(name): alpha=\(alpha) (expected 0)")
            }
        }
        if let centerAlpha = alphaValue(of: image, x: width / 2, y: height / 2),
           centerAlpha != 255 {
            failures.append("\(label).center: alpha=\(centerAlpha) (expected 255)")
        }
        return failures
    }

    /// 取样单像素 alpha（x/y 以图像左上角为原点）。
    private static func alphaValue(of image: CGImage, x: Int, y: Int) -> UInt8? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(
            image,
            in: CGRect(
                x: CGFloat(-x),
                y: CGFloat(-(image.height - 1 - y)),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        guard let data = context.data else { return nil }
        return data.assumingMemoryBound(to: UInt8.self)[3]
    }

    private static func makeRenderTestBaseImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)

        let colors: [NSColor] = [
            NSColor(srgbRed: 0.16, green: 0.45, blue: 0.86, alpha: 1),
            NSColor(srgbRed: 0.94, green: 0.58, blue: 0.12, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.72, blue: 0.42, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(
                CGRect(
                    x: 380,
                    y: 200 + CGFloat(index) * 55,
                    width: 220,
                    height: 45
                )
            )
        }
        return context.makeImage()
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
