import AppKit
import SwiftUI

/// 剪贴板快捷选择窗口的搜索框。
///
/// 用 `NSTextField` 而不是 SwiftUI `TextField`：方向键在字段编辑器里会以
/// `moveUp:` / `moveDown:` 命令下发，直接在 delegate 里接管即可稳定工作，
/// 不依赖「窗口必须成为 key window + 事件监听器」这套容易失效的组合。
struct ClipboardPickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// 每次自增表示「请把焦点放回搜索框」。
    let focusToken: Int
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 14)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self

        let attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: NSFont.systemFont(ofSize: 14),
            ]
        )
        if nsView.placeholderAttributedString != attributedPlaceholder {
            nsView.placeholderAttributedString = attributedPlaceholder
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if context.coordinator.appliedFocusToken != focusToken {
            context.coordinator.appliedFocusToken = focusToken
            DispatchQueue.main.async {
                Self.focus(nsView)
            }
        }
    }

    static func focus(_ field: NSTextField) {
        guard let window = field.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        guard window.firstResponder !== field.currentEditor() else { return }
        window.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let length = field.stringValue.utf16.count
            editor.selectedRange = NSRange(location: length, length: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ClipboardPickerSearchField
        var appliedFocusToken = -1

        init(parent: ClipboardPickerSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            guard parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // 中文输入法组合中不抢方向键 / Return，交给输入法处理。
            guard !textView.hasMarkedText() else { return false }

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
