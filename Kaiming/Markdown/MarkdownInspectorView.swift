import SwiftUI

/// 右侧「内容导航」inspector：只显示当前文档的标题大纲。
///
/// 位置：Markdown 窗口编辑区右上角覆盖层（不改变窗口/侧边栏宽度，不打断编辑）。
/// 链接预览、HTML 块原生渲染等预览信息已移除，inspector 专注纯导航；
/// 整篇 Markdown/HTML 的只读渲染由独立的渲染预览模式承担。
struct MarkdownInspectorView: View {
    let headings: [MarkdownHeading]
    let onSelectHeading: (MarkdownHeading) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if headings.isEmpty {
                        emptyState
                    } else {
                        outlineSection
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 330)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Divider()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.righthalf.inset.filled")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("内容导航")
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .markdownTooltip("关闭内容导航", alignment: .bottomTrailing)
            .accessibilityLabel("关闭内容导航")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .zIndex(20)
    }

    // MARK: - 大纲

    private var outlineSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("标题大纲", symbol: "list.bullet.indent")

            ForEach(headings) { heading in
                Button {
                    onSelectHeading(heading)
                } label: {
                    HStack(spacing: 5) {
                        Text(heading.title)
                            .font(.system(
                                size: 11,
                                weight: heading.level <= 2 ? .semibold : .regular
                            ))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        Text("H\(heading.level)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 9)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("跳转到标题 \(heading.title)")
            }
        }
    }

    // MARK: - 其它

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("暂无标题")
                .font(.system(size: 11, weight: .medium))
            Text("当前文档没有标题。添加以 # 开头的标题后，这里会显示可点击的大纲。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
    }
}
