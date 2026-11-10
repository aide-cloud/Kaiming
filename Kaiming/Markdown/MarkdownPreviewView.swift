import AppKit
import SwiftUI

/// 非 Markdown 文件的只读预览面板。
///
/// 预览期间 Markdown 编辑器仍然保留在视图层级里（见 `MarkdownWindowView` 的 ZStack），
/// 因此未保存内容与撤销栈不会被预览替换；预览只读取文件，不触发 Markdown 渲染。
struct MarkdownPreviewView: View {
    let preview: MarkdownPreview
    let markdownIsDirty: Bool
    let onClose: () -> Void
    let onOpenExternal: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if markdownIsDirty {
                dirtyNotice
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: preview.kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(preview.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("只读预览")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )

            Spacer(minLength: 8)

            if markdownIsDirty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                    Text("Markdown 未保存")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                .help("预览不会修改未保存的 Markdown；关闭预览即可返回编辑器")
            }

            Text(preview.isLoading ? "读取中…" : preview.formattedSize)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            iconButton("arrow.up.forward.app", help: "用默认应用打开", action: onOpenExternal)
            iconButton("folder", help: "在 Finder 中显示", action: onReveal)
            iconButton("xmark", help: "关闭预览，返回 Markdown", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var dirtyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
            Text("当前 Markdown 有未保存修改。预览不会改动它；关闭预览即可返回编辑器。")
                .font(.system(size: 10))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if preview.isLoading {
            loadingState
        } else if let content = preview.content {
            switch content {
            case .text(let text, let isTruncated):
                textContent(text, isTruncated: isTruncated)
            case .image(let image):
                imageContent(image)
            case .binary:
                binaryContent
            }
        } else {
            loadingState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取 \(preview.displayName)…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func textContent(_ text: String, isTruncated: Bool) -> some View {
        VStack(spacing: 0) {
            MarkdownPlainTextView(text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isTruncated {
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                    Text("文件较大，仅显示前 1 MB 内容。")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
            }
        }
    }

    private func imageContent(_ image: NSImage?) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }

                Text(preview.errorMessage ?? "\(preview.displayName) · \(preview.formattedSize)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                HStack(spacing: 8) {
                    Button("用默认应用打开", action: onOpenExternal)
                    Button("在 Finder 中显示", action: onReveal)
                }
                .controlSize(.small)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var binaryContent: some View {
        VStack(spacing: 12) {
            Image(systemName: preview.kind == .image ? "photo.on.rectangle.angled" : "doc.zipper")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)

            Text(preview.errorMessage ?? "此文件为二进制格式，暂不支持内嵌预览。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(preview.displayName)\(preview.fileSize > 0 ? " · \(preview.formattedSize)" : "")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button("用默认应用打开", action: onOpenExternal)
                Button("在 Finder 中显示", action: onReveal)
            }
            .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 纯文本视图

/// 只读、可选择、等宽字体的纯文本视图（不经过 Markdown 引擎）。
struct MarkdownPlainTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 18, height: 14)
            textView.font = Self.monospaceFont
            textView.textColor = .labelColor
            textView.insertionPointColor = .labelColor
            textView.string = text
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = Self.monospaceFont
    }

    private static let monospaceFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}
