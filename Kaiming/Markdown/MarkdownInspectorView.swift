import AppKit
import SwiftUI

/// 右侧可切换 inspector：外部链接预览卡片 + HTML 块原生渲染。
///
/// 位置：Markdown 窗口编辑区右上角覆盖层（不改变窗口/侧边栏宽度，不打断编辑）。
/// HTML 使用 `NSAttributedString(html:)` 在本地解析，不加载 WebView；脚本、CSS、
/// 远程图片和 `<details>` 交互等能力受限，界面上有明确说明。
struct MarkdownInspectorView: View {
    @ObservedObject var linkStore: MarkdownLinkPreviewStore
    let htmlPreviews: [MarkdownHTMLPreview]
    let onRefresh: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if linkStore.cards.isEmpty && htmlPreviews.isEmpty {
                        emptyState
                    } else {
                        if !linkStore.cards.isEmpty {
                            linkSection
                        }
                        if !htmlPreviews.isEmpty {
                            htmlSection
                        }
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

            Text("富内容")
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("重新解析链接与 HTML")
            .accessibilityLabel("重新解析富内容")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("关闭富内容 inspector")
            .accessibilityLabel("关闭富内容 inspector")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    // MARK: - 链接

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("链接预览", symbol: "link")

            ForEach(linkStore.cards) { card in
                linkCard(card)
            }
        }
    }

    private func linkCard(_ card: MarkdownLinkCard) -> some View {
        Button {
            NSWorkspace.shared.open(card.url)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if let icon = card.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(.top, 1)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title ?? card.domain)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(card.domain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if let description = card.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }

                    if card.isLoading {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("正在获取预览…")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    } else if let error = card.errorMessage {
                        Text("预览不可用：\(error)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在默认浏览器中打开 \(card.url.absoluteString)")
    }

    // MARK: - HTML

    private var htmlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("HTML 块", symbol: "chevron.left.forwardslash.chevron.right")

            ForEach(htmlPreviews) { preview in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("<\(preview.tagName)>")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(preview.sourceLength) 字符")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    if let attributedText = preview.attributedText {
                        MarkdownAttributedTextView(attributedText: attributedText)
                            .frame(height: preview.displayHeight)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(preview.errorMessage ?? "无法渲染此 HTML 块。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.orange.opacity(0.10))
                        )
                    }
                }
            }

            Text("原生 NSAttributedString(HTML) 解析，不使用 WebView；脚本/CSS、远程图片与 details 交互等能力受限。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有可预览的富内容")
                .font(.system(size: 11, weight: .medium))
            Text("文档中的 http(s) 链接会显示为预览卡片；HTML 块会在这里原生渲染。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
    }
}
