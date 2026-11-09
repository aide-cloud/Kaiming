import AppKit
import SwiftUI

/// 菜单栏面板中的剪贴板页。宽度由父容器（372pt 内容宽）决定。
/// 所有剪贴板操作都通过 `ClipboardManager`，这里不直接访问 `NSPasteboard`。
struct ClipboardPanelView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @EnvironmentObject private var settings: SettingsStore
    @State private var showClearHistoryConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            currentSection
            historySection
            clearSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "清空全部剪贴板历史？",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空历史", role: .destructive) {
                manager.clearHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部历史记录（包括置顶项）及其保存的图片文件，此操作不可撤销。")
        }
    }

    // MARK: - 当前剪贴板

    private var currentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("当前剪贴板")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                monitoringBadge
            }

            if let item = manager.currentItem {
                currentPreview(item)

                HStack(spacing: 8) {
                    Button {
                        manager.copyToPasteboard(item)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("再次复制到剪贴板")

                    Button(role: .destructive) {
                        manager.clearPasteboard()
                    } label: {
                        Label("清空", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .help("清空系统剪贴板，历史记录保留")

                    Spacer(minLength: 0)

                    Text("\(item.kind.title) · \(relativeTime(for: item))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(emptyCurrentText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("刷新") {
                        manager.refreshNow()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14))
        )
    }

    private var monitoringBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(manager.isMonitoring ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(manager.isMonitoring ? "监控中" : "已暂停")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .help(manager.isMonitoring ? "正在按设置轮询剪贴板变化" : "剪贴板监控已暂停，可在设置中开启")
    }

    private var emptyCurrentText: String {
        if !settings.clipboardMonitoringEnabled {
            return "剪贴板监控已关闭，点击「刷新」可手动读取一次。"
        }
        return "暂无可记录的剪贴板内容，或当前类型暂不支持。"
    }

    @ViewBuilder
    private func currentPreview(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            Text(Self.preview(item.text, limit: 2_000))
                .font(.system(size: 11))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .richText:
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.preview(item.text, limit: 1_500))
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("富文本 · 复制时以纯文本写入")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

        case .image:
            if let image = ClipboardThumbnailCache.shared.thumbnail(for: item, maxPixelSize: 600) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.15))
                    )
            } else {
                Label("图片预览不可用", systemImage: "photo.badge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

        case .fileURLs:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(item.fileURLs.prefix(3)), id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .help(url.path)
                }
                if item.fileURLs.count > 3 {
                    Text("等 \(item.fileURLs.count) 个文件")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

        case .other:
            Text("暂不支持的内容类型")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 历史记录

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("历史记录")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(manager.items.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )

                Spacer(minLength: 4)

                Button {
                    manager.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("立即刷新剪贴板")
                .accessibilityLabel("刷新剪贴板")
            }

            if manager.items.isEmpty {
                emptyHistory
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(manager.items) { item in
                        ClipboardHistoryRow(item: item)
                    }
                }
            }

            Text("最多保留 \(settings.clipboardHistoryLimit) 条；置顶项固定在最上方，且不会被自动淘汰。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 5) {
            Image(systemName: "tray")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
            Text("暂无历史记录")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("复制文本、图片或文件后会自动出现在这里。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - 清空历史

    private var clearSection: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.bottom, 10)
            Button(role: .destructive) {
                showClearHistoryConfirmation = true
            } label: {
                Label("清空历史", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(manager.items.isEmpty)
            .help("删除全部历史记录（包括置顶项）")
        }
    }

    // MARK: - 工具

    private func relativeTime(for item: ClipboardItem) -> String {
        Self.relativeString(since: item.createdAt)
    }

    static func relativeString(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400)) 天前" }
        return shortDateFormatter.string(from: date)
    }

    static func preview(_ text: String?, limit: Int) -> String {
        guard let text else { return "（无纯文本预览）" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "（空白内容）" }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

// MARK: - 历史行

private struct ClipboardHistoryRow: View {
    let item: ClipboardItem

    @ObservedObject private var manager = ClipboardManager.shared
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            leadingVisual
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(previewText)
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)

                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("已置顶，不会被自动淘汰")
                    }
                }

                Text(ClipboardPanelView.relativeString(since: item.createdAt))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 3)

            if isHovering {
                actionButtons
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.accentColor.opacity(0.09) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            manager.copyToPasteboard(item)
        }
        .help(tapHelp)
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if item.kind == .image,
           let image = ClipboardThumbnailCache.shared.thumbnail(for: item, maxPixelSize: 96) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18))
                )
        } else {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.kind.tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(item.kind.tint.opacity(0.13))
                )
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            Button {
                manager.copyToPasteboard(item)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("复制")
            .accessibilityLabel("复制")

            Button {
                manager.togglePin(item)
            } label: {
                Image(systemName: item.isPinned ? "pin.slash" : "pin")
                    .font(.system(size: 10))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(item.isPinned ? "取消置顶" : "置顶")
            .accessibilityLabel(item.isPinned ? "取消置顶" : "置顶")

            Button(role: .destructive) {
                manager.delete(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("从历史中删除")
            .accessibilityLabel("删除")
        }
    }

    private var previewText: String {
        switch item.kind {
        case .text, .richText:
            return ClipboardPanelView.preview(item.text, limit: 300)
        case .image:
            return "图片"
        case .fileURLs:
            let names = item.fileURLs.map(\.lastPathComponent)
            guard let first = names.first else { return "文件" }
            return names.count > 1 ? "\(first) 等 \(names.count) 个文件" : first
        case .other:
            return "其他内容"
        }
    }

    private var tapHelp: String {
        switch item.kind {
        case .image: return "单击复制图片"
        case .fileURLs: return "单击复制文件"
        case .richText: return "单击以纯文本复制富文本"
        case .text, .other: return "单击复制"
        }
    }
}

// MARK: - 类型展示

extension ClipboardKind {
    var title: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .fileURLs: return "文件"
        case .richText: return "富文本"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .fileURLs: return "folder"
        case .richText: return "doc.richtext"
        case .other: return "questionmark.square.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .text: return .blue
        case .image: return .green
        case .fileURLs: return .orange
        case .richText: return .purple
        case .other: return .gray
        }
    }
}
