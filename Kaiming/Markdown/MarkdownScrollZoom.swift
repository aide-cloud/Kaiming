import AppKit
import SwiftUI

/// 内容区「按住 ⌘ + 滚轮」缩放正文字号。
///
/// 实现方式：在窗口挂一个本地滚动事件监视器，只在当前窗口且按下 ⌘ 时消费事件，
/// 其余滚动原样放行（不影响编辑区与预览区正常滚动）。触控板产生的是高频小增量，
/// 这里按累计阈值折算成 ±1pt 的台阶，手感接近浏览器缩放。
struct MarkdownScrollZoomMonitor: NSViewRepresentable {
    /// 每次缩放回调的台阶：+1 放大，-1 缩小。
    let onStep: (CGFloat) -> Void

    func makeNSView(context: Context) -> ZoomMonitorView {
        let view = ZoomMonitorView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ nsView: ZoomMonitorView, context: Context) {
        nsView.onStep = onStep
    }

    static func dismantleNSView(_ nsView: ZoomMonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

final class ZoomMonitorView: NSView {
    var onStep: ((CGFloat) -> Void)?

    private var monitor: Any?
    private var accumulatedDelta: CGFloat = 0
    private static let preciseStep: CGFloat = 20
    private static let wheelStep: CGFloat = 1

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              event.modifierFlags.contains(.command) else {
            accumulatedDelta = 0
            return event
        }
        // 预览页里的 WebView 自己会处理 ⌘+滚轮（页面缩放），不在这里抢事件。
        if isInsideWebView(event) {
            return event
        }

        let step: CGFloat = event.hasPreciseScrollingDeltas ? Self.preciseStep : Self.wheelStep
        accumulatedDelta += event.scrollingDeltaY

        while abs(accumulatedDelta) >= step {
            let direction: CGFloat = accumulatedDelta > 0 ? 1 : -1
            accumulatedDelta -= direction * step
            onStep?(direction)
        }
        return nil
    }

    private func isInsideWebView(_ event: NSEvent) -> Bool {
        guard let contentView = window?.contentView else { return false }
        let location = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(location) else { return false }
        var candidate: NSView? = hit
        while let view = candidate {
            if NSStringFromClass(type(of: view)).contains("WKWebView") {
                return true
            }
            candidate = view.superview
        }
        return false
    }
}
