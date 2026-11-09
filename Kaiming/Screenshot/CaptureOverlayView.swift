import AppKit

/// 截图覆盖层专用窗口：无边框、全屏、可成为 key window，且不受系统可见区域约束。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // 必须允许窗口覆盖菜单栏与 Dock，否则顶部/底部选择会少一截。
        frameRect
    }
}

/// 单块屏幕上的覆盖层视图：负责转发鼠标事件，并把绘制委托给 controller。
@MainActor
final class CaptureOverlayView: NSView {
    private weak var controller: CaptureOverlayController?
    private(set) var frozenScreen: CaptureOverlayController.FrozenScreen?
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, controller: CaptureOverlayController, frozenScreen: CaptureOverlayController.FrozenScreen) {
        self.controller = controller
        self.frozenScreen = frozenScreen
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let frozenScreen else { return }
        controller.draw(frozenScreen: frozenScreen, in: self)
    }

    // MARK: - 鼠标

    private func localPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let frozenScreen else { return }
        window?.makeFirstResponder(self)
        controller.mouseDown(at: localPoint(event), in: frozenScreen, clickCount: event.clickCount)
        updateCursor(for: localPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let frozenScreen else { return }
        controller.mouseDragged(at: localPoint(event), in: frozenScreen)
        updateCursor(for: localPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller, let frozenScreen else { return }
        controller.mouseUp(at: localPoint(event), in: frozenScreen)
        updateCursor(for: localPoint(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let controller, let frozenScreen else { return }
        let point = localPoint(event)
        controller.mouseMoved(at: point, in: frozenScreen)
        updateCursor(for: point)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else {
            super.keyDown(with: event)
            return
        }
        if controller.handleKeyDown(event) == nil {
            return
        }
        super.keyDown(with: event)
    }

    private func updateCursor(for point: CGPoint) {
        guard let controller, let frozenScreen else { return }
        controller.cursor(at: point, in: frozenScreen).set()
    }
}
