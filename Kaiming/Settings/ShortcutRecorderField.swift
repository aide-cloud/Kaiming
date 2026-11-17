import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 快捷键录制控件：点击后进入录制态，按下组合键即自动录入并显示。
///
/// 录制期间由父视图暂停全局热键（`HotKeyManager.suspend()`），
/// 否则按下已有组合键会先触发原来的全局动作，录不到按键本身。
@MainActor
struct ShortcutRecorderField: View {
    let binding: HotKeyBinding
    let isRecording: Bool
    let onToggle: () -> Void
    let onCapture: (HotKeyBinding) -> Void
    let onCancel: () -> Void

    @State private var monitor = ShortcutRecorderKeyMonitor()
    @State private var warning: String?

    var body: some View {
        Button(action: onToggle) {
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .frame(minWidth: 74)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(isRecording ? 0.14 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18),
                            lineWidth: isRecording ? 1.4 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("快捷键 \(binding.displayString)")
        .onChange(of: isRecording) { _, recording in
            if recording {
                installMonitor()
            } else {
                monitor.remove()
                warning = nil
            }
        }
        .onDisappear {
            monitor.remove()
        }
    }

    private var text: String {
        guard isRecording else { return binding.displayString }
        return warning == nil ? "按下组合键…" : "需含 ⌘/⌥/⌃"
    }

    private var helpText: String {
        guard isRecording else { return "点击后按下新的组合键（⌘ / ⌥ / ⌃ 至少一个，或 F1–F20）" }
        return warning ?? "按下组合键完成录制，Esc 取消"
    }

    private func installMonitor() {
        monitor.install { keyCode, flags in
            if Int(keyCode) == kVK_Escape {
                monitor.remove()
                onCancel()
                return true
            }

            let modifiers = HotKeyFormatter.carbonModifiers(from: flags)
            let proposed = HotKeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers)
            if let error = proposed.validationError {
                warning = error
                return true
            }
            // 先摘掉监听再回传，避免恢复全局热键后又被同一路径重复录入。
            monitor.remove()
            warning = nil
            onCapture(proposed)
            return true
        }
    }
}

/// 录制期间只消费设置窗口内的按键，避免影响其他窗口。
@MainActor
private final class ShortcutRecorderKeyMonitor {
    private var token: Any?
    private var handler: ((UInt16, NSEvent.ModifierFlags) -> Bool)?

    func install(handler: @escaping (UInt16, NSEvent.ModifierFlags) -> Bool) {
        remove()
        self.handler = handler
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self.handler?(keyCode, flags) ?? false
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
        handler = nil
    }
}
