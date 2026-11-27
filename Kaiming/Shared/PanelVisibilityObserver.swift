import AppKit
import SwiftUI

/// 监听承载视图的菜单栏面板窗口的可见状态。
///
/// 菜单栏面板收起后 SwiftUI 只是把窗口移出屏幕，视图树与 `@State` 都还活着，
/// 仅靠 `onAppear` / `onDisappear` 不足以启动/停止后台采样或复位临时 UI。
/// 这里监听窗口 becomeKey / resignKey / close 与应用失活，给面板级状态一个可靠的生命周期。
struct PanelVisibilityObserver: NSViewRepresentable {
    var onVisible: () -> Void = {}
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onVisible = onVisible
        context.coordinator.onDismiss = onDismiss
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisible: onVisible, onDismiss: onDismiss)
    }

    @MainActor
    final class Coordinator {
        var onVisible: () -> Void
        var onDismiss: () -> Void

        private var tokens: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        init(onVisible: @escaping () -> Void, onDismiss: @escaping () -> Void) {
            self.onVisible = onVisible
            self.onDismiss = onDismiss
        }

        /// 视图刚进入层级时 `window` 可能还是 nil；每次更新再试一次，直到绑定到真实窗口。
        func attach(to view: NSView) {
            guard observedWindow == nil else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                self.observe(window)
            }
        }

        private func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            detach()
            observedWindow = window

            let center = NotificationCenter.default
            tokens = [
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.onVisible() }
                },
                center.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.onDismiss() }
                },
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.onDismiss() }
                },
                // 点击其他应用时菜单栏面板也会收起，但窗口不一定先失 key；应用失活一并兜底。
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.onDismiss() }
                },
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        if self.observedWindow?.isKeyWindow == true {
                            self.onVisible()
                        }
                    }
                },
            ]

            if window.isKeyWindow {
                Task { @MainActor in self.onVisible() }
            }
        }

        func detach() {
            let center = NotificationCenter.default
            for token in tokens {
                center.removeObserver(token)
            }
            tokens.removeAll()
            observedWindow = nil
        }
    }
}
