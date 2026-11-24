import AppKit
import SwiftUI

/// 菜单栏图标。label 在应用启动时即被创建，因此在这里注册 AppRouter 的处理器，
/// 保证菜单栏面板还没打开过时，全局快捷键也能拿到 openWindow 等环境能力。
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .accessibilityLabel("Kaiming")
            .task {
                registerRouter()
                #if DEBUG
                // 仅调试构建：方便自动化冒烟与截图验收。
                if ProcessInfo.processInfo.arguments.contains("--open-markdown") {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    WindowPlacementCenter.shared.willOpen(scene: AppWindowScene.markdown)
                    openWindow(id: AppWindowScene.markdown)
                    NSApp.activate(ignoringOtherApps: true)
                }
                #endif
            }
    }

    private func registerRouter() {
        #if DEBUG
        NSLog("Kaiming debug: registering AppRouter handlers")
        #endif
        AppRouter.shared.register(
            capture: { mode in
                ScreenshotCoordinator.shared.start(mode: mode)
            },
            markdown: {
                // 独立窗口统一出现在鼠标所在屏幕（见 WindowPlacement）。
                WindowPlacementCenter.shared.willOpen(scene: AppWindowScene.markdown)
                openWindow(id: AppWindowScene.markdown)
                NSApp.activate(ignoringOtherApps: true)
            }
        )
        AppRouter.shared.registerSettings {
            openWindow(id: AppWindowScene.settings)
            NSApp.activate(ignoringOtherApps: true)
        }
        AppRouter.shared.registerClipboardPicker {
            WindowPlacementCenter.shared.willOpen(scene: AppWindowScene.clipboardPicker)
            openWindow(id: AppWindowScene.clipboardPicker)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
