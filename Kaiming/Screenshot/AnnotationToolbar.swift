import SwiftUI

/// 覆盖层上的标注状态。只在主线程读写，驱动 SwiftUI 工具栏与 AppKit 覆盖层重绘。
@MainActor
final class AnnotationSession: ObservableObject {
    @Published var tool: AnnotationTool = .select {
        didSet {
            // 编辑标注只在「调整选区 / 编辑标注」工具下可用，切到绘制工具时收起选中框。
            if tool != .select {
                selectedAnnotationID = nil
            }
        }
    }
    @Published var color: AnnotationColor = AnnotationColor.palette[0]
    /// 圆角半径（点），0–48；预览与最终 PNG 共用。
    @Published var cornerRadius: CGFloat = 0
    @Published private(set) var annotations: [Annotation] = []
    /// 当前选中的已有标注；`nil` 表示没有选中。
    @Published private(set) var selectedAnnotationID: UUID?

    /// 撤销快照：每次新增/编辑/删除前压入一份完整标注数组。
    private var undoStack: [[Annotation]] = []
    private static let maxUndoDepth = 50

    var hasAnnotations: Bool { !annotations.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var clampedCornerRadius: CGFloat { max(0, min(cornerRadius, 48)) }

    var selectedAnnotation: Annotation? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    var canDeleteSelectedAnnotation: Bool { selectedAnnotation != nil }

    func add(_ annotation: Annotation) {
        beginMutation()
        annotations.append(annotation)
    }

    /// 记录一次可撤销的修改。拖动/缩放应在第一次真正改变几何前调用一次，
    /// 之后连续的中间状态直接 `replace`，避免撤销栈被鼠标事件刷爆。
    func beginMutation() {
        undoStack.append(annotations)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
    }

    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoStack.popLast() else { return false }
        annotations = snapshot
        if let selectedAnnotationID,
           !annotations.contains(where: { $0.id == selectedAnnotationID }) {
            self.selectedAnnotationID = nil
        }
        return true
    }

    func select(_ id: UUID?) {
        selectedAnnotationID = id
    }

    func annotation(id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// 替换一条已存在的标注（调用方负责在编辑开始时记录撤销快照）。
    func replace(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    func delete(_ id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        beginMutation()
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id {
            selectedAnnotationID = nil
        }
    }

    func deleteSelected() {
        guard let selectedAnnotationID else { return }
        delete(selectedAnnotationID)
    }

    /// 新选择截图区域 / 进入长截图时调用：清空标注并丢弃撤销历史。
    func clear() {
        annotations.removeAll()
        undoStack.removeAll()
        selectedAnnotationID = nil
    }
}

/// 覆盖层底部/顶部的轻量标注工具栏。
struct AnnotationToolbar: View {
    static let preferredSize = CGSize(width: 790, height: 44)

    @ObservedObject var session: AnnotationSession
    /// 只有区域截图（未进入长截图流程）才显示长截图入口。
    let showsLongCapture: Bool
    let onStartLongCapture: () -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach([AnnotationTool.select, .pen, .rectangle, .arrow, .text, .mosaic]) { tool in
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
            .disabled(!session.canUndo)
            .help("撤销上一步（⌘Z）")

            Button {
                session.deleteSelected()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!session.canDeleteSelectedAnnotation)
            .help("删除选中的标注（Delete）")

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
        .help(
            tool == .select
                ? "调整选区；单击已有标注可拖动，双击文字编辑，Delete 删除"
                : tool.title
        )
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
