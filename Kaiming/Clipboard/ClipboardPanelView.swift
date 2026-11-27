import AppKit
import SwiftUI

/// 菜单栏面板中的剪贴板页。宽度由父容器（372pt 内容宽）决定。
/// 所有剪贴板操作都通过 `ClipboardManager`，这里不直接访问 `NSPasteboard`。
///
/// 注意：本视图运行在 `MenuBarExtra(.window)` 里，**不要**使用 `.confirmationDialog` /
/// `.alert` / `.fileImporter` 等系统弹窗：它们会抢走面板的 key 状态，面板被收起，
/// 且弹窗按钮的 action 在视图销毁后不会执行（macOS 14 实测：点「清空历史」窗口关闭但没清空）。
/// 危险操作一律做成面板内的内联确认。
struct ClipboardPanelView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    /// 收藏 / 实时分区；面板收起后保留本次选择。
    @State private var scope: ClipboardScope
    /// 内联确认态：只属于本次面板显示，面板收起后必须复位，避免下次打开停在「清空历史」确认页。
    @State private var isConfirmingClearHistory = false

    init(initialScope: ClipboardScope = .live) {
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            currentCard
            historySection
            clearSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: cancelClearHistoryConfirmation)
        .onDisappear(perform: cancelClearHistoryConfirmation)
        .background(
            // 菜单栏面板收起时 SwiftUI 不会销毁视图树（@State 会保留），
            // 因此额外监听承载窗口失 key / 关闭，兜底复位内联确认态。
            PanelVisibilityObserver(onDismiss: cancelClearHistoryConfirmation)
                .frame(width: 0, height: 0)
        )
        .onChange(of: scope) { _, _ in
            cancelClearHistoryConfirmation()
        }
        .onChange(of: manager.removableHistoryCount) { _, count in
            if count == 0 {
                cancelClearHistoryConfirmation()
            }
        }
    }

    private func cancelClearHistoryConfirmation() {
        isConfirmingClearHistory = false
    }

    // MARK: - 当前剪贴板

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PanelIconBadge(symbol: "doc.on.clipboard", tint: PanelPalette.mint, size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("当前剪贴板")
                        .font(.system(size: 11, weight: .semibold))
                    Text(currentSubtitle)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                monitoringBadge
            }

            if let item = manager.currentItem {
                currentPreview(item)

                HStack(spacing: 6) {
                    Button {
                        manager.copyToPasteboard(item)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("再次复制到剪贴板")

                    Button(role: .destructive) {
                        manager.clearPasteboard()
                    } label: {
                        Label("清空", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("清空系统剪贴板，历史记录保留")

                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Text(emptyCurrentText)
                        .font(.system(size: 9))
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
        .panelCard(padding: 10)
    }

    private var currentSubtitle: String {
        guard let item = manager.currentItem else { return "系统剪贴板" }
        return "\(item.kind.title) · \(relativeTime(for: item))"
    }

    private var monitoringBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(manager.isMonitoring ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(manager.isMonitoring ? "监控中" : "已暂停")
                .font(.system(size: 8))
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
                .font(.system(size: 10.5))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .richText:
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.preview(item.text, limit: 1_500))
                    .font(.system(size: 10.5))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("富文本 · 复制时以纯文本写入")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

        case .image:
            if let image = ClipboardThumbnailCache.shared.thumbnail(for: item, maxPixelSize: 600) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10))
                    )
            } else {
                Label("图片预览不可用", systemImage: "photo.badge.exclamationmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

        case .fileURLs:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(item.fileURLs.prefix(3)), id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(PanelPalette.sky)
                        Text(url.lastPathComponent)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .help(url.path)
                }
                if item.fileURLs.count > 3 {
                    Text("等 \(item.fileURLs.count) 个文件")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }

        case .other:
            Text("暂不支持的内容类型")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 历史记录（收藏 / 实时）

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            scopeTabs
            Text(scopeFootnote)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            historyCard
        }
    }

    private var scopeTabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(ClipboardScope.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scope = item
                        }
                    } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 10.5, weight: scope == item ? .semibold : .regular))
                                    .foregroundStyle(scope == item ? Color.primary : Color.secondary)
                                Text("\(manager.count(in: item))")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            Capsule()
                                .fill(scope == item ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item == .favorites ? "收藏项永久保留" : "按复制时间排列，超出上限淘汰最旧")
                }

                Spacer(minLength: 4)

                Button {
                    openClipboardPicker()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 8, weight: .medium))
                        Text(HotKeyAction.openClipboard.displayString)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("打开剪贴板快捷选择（\(HotKeyAction.openClipboard.displayString)）")
                .accessibilityLabel("打开剪贴板快捷选择")

                Button {
                    manager.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("立即刷新剪贴板")
                .accessibilityLabel("刷新剪贴板")
            }
            Divider()
        }
    }

    @ViewBuilder
    private var historyCard: some View {
        if scopedItems.isEmpty {
            emptyHistory.panelCard()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(scopedItems.enumerated()), id: \.element.id) { index, item in
                    ClipboardHistoryRow(item: item, scope: scope)
                    if index < scopedItems.count - 1 {
                        Divider()
                            .opacity(0.22)
                            .padding(.leading, 38)
                    }
                }
            }
            .panelCard(padding: 4)
        }
    }

    private var scopedItems: [ClipboardItem] {
        manager.entries(in: scope)
    }

    private var scopeFootnote: String {
        switch scope {
        case .live:
            return "实时最多保留 \(settings.clipboardHistoryLimit) 条；收藏永久保留，不受影响。"
        case .favorites:
            return "收藏项永久保留，不计入实时历史的条数上限。"
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 6) {
            PanelIconBadge(
                symbol: scope == .favorites ? "star" : "tray",
                tint: scope == .favorites ? PanelPalette.amber : .secondary,
                size: 30
            )

            Text(scope == .favorites ? "还没有收藏" : "暂无实时历史")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(
                scope == .favorites
                    ? "在「实时」里点 ☆ 即可收藏，收藏项永久保留、可随时移除。"
                    : "复制文本、图片或文件后会自动出现在这里。"
            )
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: - 清空实时历史

    @ViewBuilder
    private var clearSection: some View {
        if isConfirmingClearHistory {
            clearHistoryConfirmation
        } else {
            Button(role: .destructive) {
                isConfirmingClearHistory = true
            } label: {
                Label("清空实时历史", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(manager.removableHistoryCount == 0)
            .help("删除全部实时历史，收藏项会保留")
        }
    }

    /// 面板内内联确认，替代会被菜单栏窗口吞掉的系统确认弹窗。
    private var clearHistoryConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("清空实时历史？")
                        .font(.system(size: 10, weight: .semibold))
                    Text(clearHistoryDetail)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("取消") {
                    isConfirmingClearHistory = false
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)

                Button("清空实时历史", role: .destructive) {
                    // 先收起确认态，再清空：即使 clearHistory 触发 notice 重绘，也不会停在确认页。
                    isConfirmingClearHistory = false
                    manager.clearHistory()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.red.opacity(0.22))
        )
    }

    private var clearHistoryDetail: String {
        let removable = manager.removableHistoryCount
        let favorites = manager.count(in: .favorites)
        if favorites == 0 {
            return "将删除 \(removable) 条实时记录及其保存的图片文件，此操作不可撤销。"
        }
        return "将删除 \(removable) 条实时记录及其保存的图片文件；\(favorites) 条收藏会保留，此操作不可撤销。"
    }

    // MARK: - 工具

    private func openClipboardPicker() {
        WindowPlacementCenter.shared.willOpen(scene: AppWindowScene.clipboardPicker)
        openWindow(id: AppWindowScene.clipboardPicker)
        NSApp.activate(ignoringOtherApps: true)
    }

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
    let scope: ClipboardScope

    @ObservedObject private var manager = ClipboardManager.shared
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            leadingVisual

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(previewText)
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)

                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("已收藏，永久保留")
                    }
                }

                Text(rowDetail)
                    .font(.system(size: 8))
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Color.accentColor.opacity(0.08) : Color.clear)
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

    /// 「收藏」分区里展示收藏时间，「实时」分区里展示复制时间，和各自排序一致。
    private var rowDetail: String {
        if scope == .favorites, let favoritedAt = item.favoritedAt {
            return "收藏于 " + ClipboardPanelView.relativeString(since: favoritedAt)
        }
        return ClipboardPanelView.relativeString(since: item.createdAt)
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if item.kind == .image,
           let image = ClipboardThumbnailCache.shared.thumbnail(for: item, maxPixelSize: 96) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10))
                )
        } else {
            PanelIconBadge(symbol: item.kind.symbolName, tint: item.kind.tint, size: 24)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            Button {
                manager.copyToPasteboard(item)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .frame(width: 17, height: 17)
            }
            .buttonStyle(.borderless)
            .help("复制")
            .accessibilityLabel("复制")

            Button {
                manager.toggleFavorite(item)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(item.isFavorite ? Color.orange : Color.primary)
                    .frame(width: 17, height: 17)
            }
            .buttonStyle(.borderless)
            .help(item.isFavorite ? "取消收藏" : "收藏（永久保留）")
            .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")

            Button(role: .destructive) {
                manager.delete(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .frame(width: 17, height: 17)
            }
            .buttonStyle(.borderless)
            .help(item.isFavorite ? "删除（收藏同时移除）" : "从实时历史中删除")
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
