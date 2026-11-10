import SwiftUI

/// 覆盖层上的标注状态。只在主线程读写，驱动 SwiftUI 工具栏与 AppKit 覆盖层重绘。
@MainActor
final class AnnotationSession: ObservableObject {
    @Published var tool: AnnotationTool = .select
    @Published var color: AnnotationColor = AnnotationColor.palette[0]
    /// 圆角半径（点），0–48；预览与最终 PNG 共用。
    @Published var cornerRadius: CGFloat = 0
    @Published private(set) var annotations: [Annotation] = []

    var hasAnnotations: Bool { !annotations.isEmpty }
    var clampedCornerRadius: CGFloat { max(0, min(cornerRadius, 48)) }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        annotations.removeAll()
    }
}

/// 覆盖层底部/顶部的轻量标注工具栏。
struct AnnotationToolbar: View {
    static let preferredSize = CGSize(width: 660, height: 44)

    @ObservedObject var session: AnnotationSession
    /// 只有区域截图（未进入长截图流程）才显示长截图入口。
    let showsLongCapture: Bool
    let onStartLongCapture: () -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach([AnnotationTool.select, .rectangle, .arrow, .text]) { tool in
                toolButton(tool)
            }

            divider

            ForEach(Array(AnnotationColor.palette.enumerated()), id: \.offset) { _, color in
                colorButton(color)
            }

            divider

            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!session.hasAnnotations)
            .help("撤销上一条标注")

            divider

            cornerRadiusControl

            if showsLongCapture {
                Button {
                    onStartLongCapture()
                } label: {
                    Label("长截图", systemImage: "rectangle.expand.vertical")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("滚动拼接长网页或长列表（仅区域截图）")
            }

            Spacer(minLength: 4)

            Button("完成") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("确认截图并保存（Return）")

            Button("取消") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("放弃本次截图（Esc）")
        }
        .padding(.horizontal, 8)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 8, y: 2)
    }

    private var cornerRadiusControl: some View {
        HStack(spacing: 4) {
            Text("圆角")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(value: $session.cornerRadius, in: 0...48, step: 1)
                .frame(width: 72)
                .controlSize(.mini)
                .help("圆角半径 0–48 点；最终 PNG 圆角外透明")
            Text("\(Int(session.clampedCornerRadius.rounded()))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
        }
    }

    private var divider: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 1)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            session.tool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(session.tool == tool ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .foregroundStyle(session.tool == tool ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(tool.title)
    }

    private func colorButton(_ color: AnnotationColor) -> some View {
        Button {
            session.color = color
        } label: {
            Circle()
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 14, height: 14)
                .overlay(
                    Circle()
                        .strokeBorder(
                            session.color == color ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: session.color == color ? 2 : 1
                        )
                )
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("标注颜色")
    }
}
