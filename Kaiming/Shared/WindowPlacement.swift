import AppKit
import SwiftUI

/// 独立窗口（Markdown 编辑器 / 剪贴板快速选择）的 scene id。
enum AppWindowScene {
    static let markdown = "markdown"
    static let clipboardPicker = "clipboard-picker"
    static let settings = "settings"
}

/// 独立窗口的统一出窗位置。
///
/// 约定（见 docs/contracts.md「27. 独立窗口出现在鼠标所在屏幕」）：
/// - 窗口出现在**鼠标所在的那块屏幕**，而不是上次所在屏幕或主屏；
/// - 居中并完整收进该屏 `visibleFrame`；恢复的旧 frame 比当前屏幕大时先收缩，
///   否则系统会在窗口出现后反复把它推回屏幕内（表现为窗口自己滚动 / 抖动）；
/// - 窗口已完整落在该屏可见区域内时保持用户摆放的位置，不每次打开都搬走它。
@MainActor
enum WindowPlacement {
    /// 鼠标所在屏幕；坐标不在任何屏幕内（例如外接屏刚拔掉）时回退主屏。
    static var mouseScreen: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// 把窗口放到鼠标所在屏幕中央。
    /// - Parameter keepIfUsable: 窗口已完整落在该屏可见区域内时保持原位。
    /// - Returns: 是否真的改动了窗口 frame。
    @discardableResult
    static func place(_ window: NSWindow, scene: String, keepIfUsable: Bool) -> Bool {
        guard let screen = mouseScreen else { return false }
        // 全屏窗口的位置由系统全屏会话管理，移动会破坏它。
        guard !window.styleMask.contains(.fullScreen) else { return false }

        let bounds = screen.visibleFrame
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let current = window.frame
        if keepIfUsable, bounds.insetBy(dx: -1, dy: -1).contains(current) {
            return false
        }

        let width = min(max(current.width, window.minSize.width), bounds.width)
        let height = min(max(current.height, window.minSize.height), bounds.height)
        let frame = CGRect(
            x: (bounds.midX - width / 2).rounded(.down),
            y: (bounds.midY - height / 2).rounded(.down),
            width: width.rounded(.down),
            height: height.rounded(.down)
        )
        guard frame != current else { return false }

        window.setFrame(frame, display: true, animate: false)
        #if DEBUG
        NSLog(
            "Kaiming debug: placed \(scene) window on screen \(screen.localizedName) "
            + "frame=\(NSStringFromRect(frame))"
        )
        #endif
        Log.app.info(
            "Placed \(scene, privacy: .public) window on mouse screen \(screen.localizedName, privacy: .public) frame=\(NSStringFromRect(frame), privacy: .public)"
        )
        return true
    }
}

/// 跟踪各独立窗口真正的 `NSWindow`：让「打开窗口」的调用点在窗口已存在时
/// （之前隐藏、被拖到别的屏幕、或者关闭后又被复用）也能先把它搬到鼠标所在屏幕。
@MainActor
final class WindowPlacementCenter {
    static let shared = WindowPlacementCenter()

    private final class WeakWindow {
        weak var window: NSWindow?

        init(_ window: NSWindow) {
            self.window = window
        }
    }

    private var windows: [String: WeakWindow] = [:]

    private init() {}

    /// 由窗口内容里的 `WindowPlacementProbe` 调用：登记窗口，并在窗口首次挂载时定位。
    func attach(_ window: NSWindow, scene: String) {
        // 快照 / 覆盖层这类「所有 Space 都可见」的窗口不是用户窗口，不参与出窗定位。
        guard !window.collectionBehavior.contains(.canJoinAllSpaces) else { return }

        // 每个独立窗口都跟随当前 Space：否则激活时 macOS 会整屏滑到窗口原来所在的桌面。
        if !window.collectionBehavior.contains(.moveToActiveSpace) {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }

        let isNewWindow = windows[scene]?.window !== window
        windows[scene] = WeakWindow(window)
        guard isNewWindow else { return }

        // 同步放一次，赶在窗口 orderFront 之前；SwiftUI 之后还可能套用 defaultSize /
        // defaultPosition / 记忆的 frame，所以在下一轮 runloop 再校验一次（已就位则不动）。
        WindowPlacement.place(window, scene: scene, keepIfUsable: true)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            WindowPlacement.place(window, scene: scene, keepIfUsable: true)
        }
    }

    /// `openWindow(id:)` 之前调用：窗口已存在就先搬到鼠标所在屏幕，新窗口等挂载后再定位。
    func willOpen(scene: String) {
        guard let window = windows[scene]?.window else { return }
        // 快捷选择窗口是一次性浮层：每次打开都居中到鼠标所在屏幕，不复用上次落点。
        let keepIfUsable = scene != AppWindowScene.clipboardPicker
        WindowPlacement.place(window, scene: scene, keepIfUsable: keepIfUsable)
    }
}

// MARK: - 窗口探测

/// 把真正的 `NSWindow` 交给 `WindowPlacementCenter`。
/// 用法：`WindowPlacementProbe(scene: AppWindowScene.markdown).frame(width: 0, height: 0)`
/// 作为窗口内容的 `.background`。
@MainActor
struct WindowPlacementProbe: NSViewRepresentable {
    let scene: String

    func makeNSView(context: Context) -> WindowPlacementProbeView {
        let view = WindowPlacementProbeView()
        view.scene = scene
        return view
    }

    func updateNSView(_ nsView: WindowPlacementProbeView, context: Context) {
        nsView.scene = scene
    }
}

final class WindowPlacementProbeView: NSView {
    var scene: String = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !scene.isEmpty else { return }
        WindowPlacementCenter.shared.attach(window, scene: scene)
    }
}
