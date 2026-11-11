import SwiftUI

/// 自定义 hover tooltip：约 260ms 后显示，不依赖 `.help` 的系统延迟。
/// 用于工具栏/侧边栏/预检视窗的所有图标按钮。
struct MarkdownTooltipModifier: ViewModifier {
    let text: String
    let alignment: Alignment

    @State private var isHovering = false
    @State private var isVisible = false
    @State private var showTask: Task<Void, Never>?

    private var isForceVisible: Bool {
        #if DEBUG
        return MarkdownTooltipDebug.isForced(text)
        #else
        return false
        #endif
    }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                showTask?.cancel()
                showTask = nil
                if hovering {
                    showTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 260_000_000)
                        guard !Task.isCancelled, isHovering else { return }
                        isVisible = true
                    }
                } else {
                    isVisible = false
                }
            }
            .overlay(alignment: alignment) {
                if isVisible {
                    MarkdownTooltipBubble(text: text)
                        .offset(y: 24)
                        .zIndex(1000)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
            .onDisappear {
                showTask?.cancel()
                showTask = nil
            }
            .onAppear {
                if isForceVisible {
                    isVisible = true
                }
            }
    }
}

#if DEBUG
/// 仅调试构建：`--markdown-tooltip-demo` 让“新建”按钮强制显示 tooltip，
/// 便于无鼠标自动化时截图验证自定义气泡样式。
private enum MarkdownTooltipDebug {
    static let forcedText = "新建 Markdown（⌘N）"

    static func isForced(_ text: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains("--markdown-tooltip-demo") && text == forcedText
    }
}
#endif

struct MarkdownTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 4, y: 2)
    }
}

extension View {
    /// 260ms 延迟的自定义 tooltip；同时移除系统 `.help` 依赖。
    func markdownTooltip(_ text: String, alignment: Alignment = .bottomLeading) -> some View {
        modifier(MarkdownTooltipModifier(text: text, alignment: alignment))
    }
}
