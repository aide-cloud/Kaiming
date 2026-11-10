import AppKit
import SwiftUI

/// Markdown 窗口左侧目录树。宽度固定 260pt（需求区间 240–280pt）。
struct MarkdownSidebarView: View {
    @ObservedObject var tree: MarkdownFolderTree

    let currentFileURL: URL?
    let onOpenFolder: () -> Void
    let onSelectFile: (URL) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let message = tree.errorMessage {
                errorBanner(message)
            }

            content
        }
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(tree.rootURL?.lastPathComponent ?? "目录")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            headerButton("arrow.clockwise", help: "刷新目录") {
                tree.refresh()
            }
            .disabled(tree.rootURL == nil)

            headerButton("folder.badge.plus", help: "打开文件夹…", action: onOpenFolder)

            headerButton("sidebar.left", help: "隐藏目录树", action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private func headerButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if tree.rootURL == nil {
            emptyState
        } else if tree.isLoadingRoot && tree.rootChildren.isEmpty {
            loadingState
        } else if tree.rootChildren.isEmpty {
            if tree.errorMessage != nil {
                readErrorState
            } else {
                emptyFolderState
            }
        } else {
            treeScroll
        }
    }

    private var treeScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(tree.rootChildren) { node in
                    MarkdownTreeRow(
                        node: node,
                        depth: 0,
                        tree: tree,
                        currentFileURL: currentFileURL,
                        onSelectFile: onSelectFile
                    )
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)

            Text("尚未打开文件夹")
                .font(.system(size: 12, weight: .medium))

            Text("打开一个目录，即可在这里浏览其中的 Markdown 文件。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("打开文件夹…", action: onOpenFolder)
                .controlSize(.small)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取目录…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFolderState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)

            Text("此文件夹中没有 Markdown 文件")
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)

            Text("只显示文件夹与 .md / .markdown 文件。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button("重新读取") {
                tree.refresh()
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readErrorState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.orange)

            Text("目录读取失败")
                .font(.system(size: 11, weight: .medium))

            Text("请检查该文件夹的访问权限后重试。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("重新读取") {
                tree.refresh()
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                tree.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("忽略提示")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

// MARK: - 单行

private struct MarkdownTreeRow: View {
    let node: MarkdownTreeNode
    let depth: Int
    @ObservedObject var tree: MarkdownFolderTree
    let currentFileURL: URL?
    let onSelectFile: (URL) -> Void

    private var leadingPadding: CGFloat {
        CGFloat(depth) * 12 + 8
    }

    private var isExpanded: Bool {
        tree.isExpanded(node.url)
    }

    private var isCurrent: Bool {
        guard !node.isDirectory, let currentFileURL else { return false }
        return node.url.standardizedFileURL == currentFileURL.standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rowContent

            if node.isDirectory, isExpanded {
                if let children = tree.children(of: node.url) {
                    if children.isEmpty {
                        Text("空文件夹")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, leadingPadding + 26)
                            .padding(.vertical, 2)
                    } else {
                        ForEach(children) { child in
                            MarkdownTreeRow(
                                node: child,
                                depth: depth + 1,
                                tree: tree,
                                currentFileURL: currentFileURL,
                                onSelectFile: onSelectFile
                            )
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("载入中…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, leadingPadding + 26)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var rowContent: some View {
        Button {
            if node.isDirectory {
                tree.toggleDirectory(node.url)
            } else {
                onSelectFile(node.url)
            }
        } label: {
            HStack(spacing: 4) {
                disclosureIcon

                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: 11))
                    .frame(width: 14)
                    .foregroundStyle(
                        node.isDirectory || !isCurrent ? Color.secondary : Color.accentColor
                    )

                Text(node.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.16) : Color.clear)
                    .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .help(node.url.path)
    }

    private var disclosureIcon: some View {
        Group {
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.12), value: isExpanded)
            } else {
                Color.clear
            }
        }
        .frame(width: 10)
    }
}
