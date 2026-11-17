import AppKit
import Carbon.HIToolbox

/// 一组可自定义的全局快捷键：Carbon 虚拟键码 + 修饰键掩码。
///
/// 只保存键码与修饰键，显示文案由 `HotKeyFormatter` 按当前键盘布局实时推导，
/// 因此切换输入法/键盘布局后设置页与面板提示会同步更新，不会留下过期字符串。
struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {
    /// Carbon 虚拟键码（`kVK_*`）。
    var keyCode: UInt32
    /// Carbon 修饰键掩码（`cmdKey` / `optionKey` / `controlKey` / `shiftKey`）。
    var modifiers: UInt32

    var displayString: String { HotKeyFormatter.displayString(for: self) }

    /// 至少要有一个「主修饰键」，否则会把普通打字抢成全局热键。
    var hasPrimaryModifier: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// 功能键（F1–F20）允许不带修饰键单独注册。
    var isFunctionKey: Bool {
        Self.functionKeyCodes.contains(keyCode)
    }

    /// 绑定是否可注册：必须有主修饰键（或单独的 F1–F20），不能只有 Shift。
    var validationError: String? {
        if !hasPrimaryModifier && !isFunctionKey {
            return "组合键至少需要包含 ⌘、⌥ 或 ⌃ 之一（或使用 F1–F20）"
        }
        return nil
    }

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5),
        UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10),
        UInt32(kVK_F11), UInt32(kVK_F12), UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15),
        UInt32(kVK_F16), UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]
}

/// 快捷键的修饰键换算与显示格式化。
enum HotKeyFormatter {
    /// 显示顺序遵循 macOS 习惯：⌃⌥⇧⌘ + 键。
    static func displayString(for binding: HotKeyBinding) -> String {
        var text = ""
        if binding.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if binding.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if binding.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if binding.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel(for: binding.keyCode)
    }

    /// 把 AppKit 修饰键换算成 Carbon 掩码。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let deviceFlags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if deviceFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if deviceFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if deviceFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if deviceFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    // MARK: - 键名

    private static let specialKeyLabels: [UInt32: String] = [
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_ANSI_KeypadClear): "⌧",
        UInt32(kVK_ANSI_KeypadDecimal): ".",
        UInt32(kVK_ANSI_KeypadMultiply): "*",
        UInt32(kVK_ANSI_KeypadPlus): "+",
        UInt32(kVK_ANSI_KeypadMinus): "-",
        UInt32(kVK_ANSI_KeypadDivide): "/",
        UInt32(kVK_ANSI_KeypadEquals): "=",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
    ]

    static func keyLabel(for keyCode: UInt32) -> String {
        if let label = specialKeyLabels[keyCode] {
            return label
        }
        if let character = character(for: keyCode) {
            return character
        }
        return "键码 \(keyCode)"
    }

    /// 用当前键盘布局把键码换成可见字符（不需要任何系统权限，也不发送事件）。
    private static func character(for keyCode: UInt32) -> String? {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        ) else {
            return nil
        }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: buffer, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.uppercased()
    }
}
