import AppKit
import SwiftUI

@main
struct KaimingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appState)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // Markdown 是持续编辑型功能，独立窗口承载；绝不嵌入菜单栏面板。
        Window("Markdown — Kaiming", id: "markdown") {
            MarkdownWindowView()
                .environmentObject(settings)
                .environmentObject(appState)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)

        // 剪贴板快捷选择（⌥⇧C）：独立小窗口，支持键盘上下选择 + Enter 复制。
        Window("剪贴板 — Kaiming", id: "clipboard-picker") {
            ClipboardPickerView()
                .environmentObject(settings)
                .environmentObject(appState)
        }
        .defaultSize(width: 520, height: 460)
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        // macOS 14 + LSUIElement 下 SwiftUI `Settings` scene 无法可靠唤起
        // （实测 showSettingsWindow: 返回 handled 但不创建窗口），因此使用独立 Window scene。
        Window("设置 — Kaiming", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(appState)
        }
        .defaultSize(width: 580, height: 560)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    AppRouter.shared.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
