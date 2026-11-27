import AppKit
import Combine
import SwiftUI

/// 剪贴板快捷选择窗口：搜索 + 键盘上下选择 + Return 复制。
///
/// 这是一个独立 Window scene（id: "clipboard-picker"），内容由 `ClipboardManager`
/// 驱动；本视图不直接访问 `NSPasteboard`。打开快捷键可在设置 → 快捷键自定义。
struct ClipboardPickerView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    /// 观察设置变化，让右上角快捷键提示跟随自定义值刷新。
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var hoveredID: UUID?
    @State private var pickerWindow: NSWindow?
    /// 收藏 / 实时分区；与面板一致，两个 tab 搜索与键盘选择都各自生效。
    @State private var scope: ClipboardScope
    /// 自增即请求搜索框重新获得焦点（窗口刚出现、重新成为 key window 时）。
    @State private var searchFocusToken = 0

    init(initialScope: ClipboardScope = .live) {
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            searchBar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            scopeBar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider()

            listContent

            Divider()

            footer
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(windowAccessor)
        .background(
            // 首次出现时居中到鼠标所在屏幕（见 WindowPlacement）。
            WindowPlacementProbe(scene: AppWindowScene.clipboardPicker)
                .frame(width: 0, height: 0)
        )
        .onExitCommand {
            closePicker()
        }
        .onAppear {
            selectedID = entries.first?.id
            requestSearchFocus()
            Log.clipboard.info("Clipboard picker appeared, entries=\(self.entries.count, privacy: .public)")
            #if DEBUG
            NSLog("Kaiming debug: clipboard picker appeared, entries=\(entries.count)")
            #endif
        }
        .onChange(of: pickerWindow?.windowNumber) { _, number in
            guard number != nil else { return }
            requestSearchFocus()
            #if DEBUG
            NSLog("Kaiming debug: clipboard picker window attached #\(number ?? -1)")
            #endif
        }
        .onChange(of: searchText) { _, _ in
            selectedID = entries.first?.id
        }
        .onChange(of: scope) { _, _ in
            // 切分区后回到第一条，避免高亮停在不可见的条目上。
            selectedID = entries.first?.id
            requestSearchFocus()
            Log.clipboard.info("Clipboard picker scope changed to \(scope.rawValue, privacy: .public)")
        }
        .onChange(of: visibleEntryIDs) { _, ids in
            if let selectedID, ids.contains(selectedID) {
                return
            }
            selectedID = ids.first
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === pickerWindow else {
                return
            }
            requestSearchFocus()
        }
        .onDisappear {
            Log.clipboard.info("Clipboard picker dismissed")
            #if DEBUG
            NSLog("Kaiming debug: clipboard picker disappeared")
            #endif
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            PanelIconBadge(symbol: "doc.on.clipboard", tint: PanelPalette.mint, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("剪贴板")
                    .font(.system(size: 13, weight: .semibold))
                Text(scope == .favorites
                    ? "收藏项永久保留，可随时取消"
                    : "↑↓ 选择 · ↵ 复制 · ⌘D 收藏")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            PanelChip(
                text: HotKeyAction.openClipboard.displayString,
                tint: .secondary
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            ClipboardPickerSearchField(
                text: $searchText,
                placeholder: "搜索文本、文件名或类型…",
                focusToken: searchFocusToken,
                onMoveSelection: { moveSelection(by: $0) },
                onSubmit: { activateSelected() },
                onCancel: { closePicker() }
            )
            .frame(maxWidth: .infinity, minHeight: 18)
            .layoutPriority(1)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    requestSearchFocus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
                .accessibilityLabel("清空搜索")
                .fixedSize()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    // MARK: - 分区 tab

    private var scopeBar: some View {
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
                                .font(.system(size: 11, weight: scope == item ? .semibold : .regular))
                                .foregroundStyle(scope == item ? Color.primary : Color.secondary)
                            Text("\(manager.count(in: item))")
                                .font(.system(size: 8.5))
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
                .help(item == .favorites ? "收藏项永久保留" : "按复制时间倒序")
            }

            Spacer(minLength: 4)

            Text(scope == .favorites ? "收藏永久保留" : "按复制时间倒序")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: - 列表

    private var listContent: some View {
        ScrollViewReader { proxy in
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry)
                                    .id(entry.id)
                                if index < entries.count - 1 {
                                    Divider()
                                        .opacity(0.16)
                                        .padding(.leading, 54)
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func row(_ entry: PickerEntry) -> some View {
        let item = entry.item
        let isSelected = selectedID == entry.id
        let isHovered = hoveredID == entry.id

        return HStack(spacing: 6) {
            Button {
                activate(entry)
            } label: {
                HStack(spacing: 10) {
                    leadingVisual(for: item)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(title(for: item))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if entry.isCurrent {
                                PanelChip(text: "当前", tint: .accentColor)
                            }
                        }

                        Text(rowMeta(for: item))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if isSelected {
                        Image(systemName: "return")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .help("按 Return 复制")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("单击复制\(item.kind.title)")

            favoriteButton(for: entry, isSelected: isSelected)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.14)
                        : (isHovered ? Color.secondary.opacity(0.07) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
        )
        .onHover { hovering in
            if hovering {
                hoveredID = entry.id
            } else if hoveredID == entry.id {
                hoveredID = nil
            }
        }
        .contextMenu {
            Button(item.isFavorite ? "取消收藏" : "收藏") {
                toggleFavorite(entry)
            }
            Button("复制") {
                activate(entry)
            }
        }
    }

    private func favoriteButton(for entry: PickerEntry, isSelected: Bool) -> some View {
        let item = entry.item
        return Button {
            toggleFavorite(entry)
        } label: {
            Image(systemName: item.isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.isFavorite ? Color.orange : Color.secondary.opacity(isSelected ? 0.9 : 0.55))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(item.isFavorite ? Color.orange.opacity(0.12) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(item.isFavorite ? "取消收藏" : "收藏（永久保留）")
        .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")
    }

    @ViewBuilder
    private func leadingVisual(for item: ClipboardItem) -> some View {
        if item.kind == .image,
           let thumbnail = ClipboardThumbnailCache.shared.thumbnail(for: item, maxPixelSize: 96) {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18))
                )
        } else {
            PanelIconBadge(symbol: item.kind.symbolName, tint: item.kind.tint, size: 30)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            PanelIconBadge(
                symbol: hasSearch ? "magnifyingglass" : (scope == .favorites ? "star" : "clipboard"),
                tint: hasSearch ? .secondary : (scope == .favorites ? PanelPalette.amber : .secondary),
                size: 38
            )

            Text(emptyTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(emptyHint)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyTitle: String {
        if hasSearch {
            return "没有匹配「\(trimmedSearchText)」的记录"
        }
        return scope == .favorites ? "还没有收藏" : "暂无剪贴板记录"
    }

    private var emptyHint: String {
        if hasSearch {
            return scope == .favorites
                ? "只在「收藏」里搜索；切到「实时」可搜全部历史。"
                : "可搜索文本内容、文件名，或「文本 / 图片 / 文件 / 富文本」。"
        }
        return scope == .favorites
            ? "在任意记录右侧点 ☆ 收藏；收藏项永久保留、可随时移除。"
            : "复制文本、图片或文件后，历史会显示在这里；右侧 ☆ 可收藏。"
    }

    // MARK: - 底部提示

    private var footer: some View {
        HStack(spacing: 12) {
            keyHint("↑↓", "选择")
            keyHint("↵", "复制")

            Button {
                toggleFavoriteSelected()
            } label: {
                HStack(spacing: 4) {
                    Text("⌘D")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                    Text(selectedIsFavorite ? "取消收藏" : "收藏")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(selectedEntry == nil)
            .keyboardShortcut("d", modifiers: .command)
            .help(selectedIsFavorite ? "取消收藏选中项（⌘D）" : "收藏选中项（⌘D）")

            keyHint("esc", "关闭")

            Spacer()

            Text("\(entries.count) 条")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 数据

    /// 当前分区的内容，当前剪贴板条目排第一；实时分区里当前内容若还没进历史也会补上。
    private var allEntries: [PickerEntry] {
        let currentID = manager.currentItem?.id
        var scoped = manager.entries(in: scope)

        // 当前剪贴板内容排第一（它在历史里时提上来，保持与旧版一致）。
        if let currentID, let index = scoped.firstIndex(where: { $0.id == currentID }) {
            scoped.insert(scoped.remove(at: index), at: 0)
        }

        var result: [PickerEntry] = []
        if scope == .live,
           let current = manager.currentItem,
           !scoped.contains(where: { $0.id == current.id }) {
            result.append(PickerEntry(id: current.id, item: current, isCurrent: true))
        }

        for item in scoped {
            result.append(PickerEntry(id: item.id, item: item, isCurrent: item.id == currentID))
        }
        return result
    }

    private var entries: [PickerEntry] {
        let query = trimmedSearchText
        guard !query.isEmpty else { return allEntries }
        return allEntries.filter { matches($0.item, query: query) }
    }

    private var visibleEntryIDs: [UUID] {
        entries.map(\.id)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSearch: Bool {
        !trimmedSearchText.isEmpty
    }

    private func matches(_ item: ClipboardItem, query: String) -> Bool {
        if item.kind.title.localizedCaseInsensitiveContains(query) {
            return true
        }
        if item.kind.rawValue.localizedCaseInsensitiveContains(query) {
            return true
        }

        switch item.kind {
        case .text, .richText:
            return item.text?.localizedCaseInsensitiveContains(query) ?? false
        case .image:
            return false
        case .fileURLs:
            return item.fileURLs.contains { url in
                url.lastPathComponent.localizedCaseInsensitiveContains(query)
                    || url.path.localizedCaseInsensitiveContains(query)
            }
        case .other:
            return false
        }
    }

    private func title(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text, .richText:
            return ClipboardPanelView.preview(item.text, limit: 180)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
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

    /// 副标题：收藏分区显示收藏时间（与排序一致），实时分区显示复制时间。
    private func rowMeta(for item: ClipboardItem) -> String {
        if scope == .favorites, let favoritedAt = item.favoritedAt {
            return "\(item.kind.title) · 收藏于 \(ClipboardPanelView.relativeString(since: favoritedAt))"
        }
        return "\(item.kind.title) · \(ClipboardPanelView.relativeString(since: item.createdAt))"
    }

    // MARK: - 收藏

    private var selectedEntry: PickerEntry? {
        guard let selectedID else { return nil }
        return entries.first(where: { $0.id == selectedID })
    }

    private var selectedIsFavorite: Bool {
        selectedEntry?.item.isFavorite == true
    }

    private func toggleFavoriteSelected() {
        guard let entry = selectedEntry else { return }
        toggleFavorite(entry)
    }

    private func toggleFavorite(_ entry: PickerEntry) {
        manager.toggleFavorite(entry.item)
        Log.clipboard.info(
            "Clipboard picker toggled favorite \(entry.item.id.uuidString, privacy: .public)"
        )
        #if DEBUG
        NSLog("Kaiming debug: clipboard picker favorite=\(!entry.item.isFavorite) kind=\(entry.item.kind.rawValue)")
        #endif
    }

    // MARK: - 键盘 / 操作

    private func moveSelection(by delta: Int) {
        let list = entries
        guard !list.isEmpty else { return }

        let currentIndex = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        var nextIndex = currentIndex + delta
        if nextIndex < 0 {
            nextIndex = list.count - 1
        } else if nextIndex >= list.count {
            nextIndex = 0
        }
        selectedID = list[nextIndex].id
    }

    private func activateSelected() {
        guard let selectedID,
              let entry = entries.first(where: { $0.id == selectedID }) else {
            return
        }
        activate(entry)
    }

    private func activate(_ entry: PickerEntry) {
        manager.copyToPasteboard(entry.item)
        Log.clipboard.info("Clipboard picker selected item \(entry.item.id.uuidString, privacy: .public)")
        #if DEBUG
        NSLog("Kaiming debug: clipboard picker activated kind=\(entry.item.kind.rawValue)")
        #endif
        closePicker()
    }

    private func closePicker() {
        let closedWindowNumber = pickerWindow?.windowNumber
        dismissWindow(id: AppWindowScene.clipboardPicker)

        // 没有其他用户可见窗口时隐藏应用，把焦点还给之前的应用，方便直接 ⌘V。
        // 注意：NSStatusBarWindow（level 25）始终 visible；隐藏的 TUINSWindow 也不应计入。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let hasOtherVisibleWindow = NSApp.windows.contains { window in
                window.isVisible
                    && window.level == .normal
                    && window.windowNumber != closedWindowNumber
                    && window.windowNumber > 0
            }
            if !hasOtherVisibleWindow {
                NSApp.hide(nil)
            }
        }
    }

    private func requestSearchFocus() {
        // 让窗口成为 key 并显式激活应用：从其他 App 用快捷键唤起时，
        // 只有窗口真正拿到键盘焦点，方向键/输入才会落到本窗口。
        NSApp.activate(ignoringOtherApps: true)
        pickerWindow?.makeKeyAndOrderFront(nil)
        searchFocusToken &+= 1
    }

    // MARK: - 窗口绑定

    private var windowAccessor: some View {
        ClipboardPickerWindowReader { window in
            guard let window else { return }
            DispatchQueue.main.async {
                if pickerWindow !== window {
                    pickerWindow = window
                }
            }
        }
        .frame(width: 0, height: 0)
    }
}

// MARK: - 数据模型

private struct PickerEntry: Identifiable {
    let id: UUID
    let item: ClipboardItem
    let isCurrent: Bool
}

// MARK: - 窗口读取

private struct ClipboardPickerWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClipboardPickerWindowProbeView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClipboardPickerWindowProbeView)?.onWindowChange = onWindowChange
    }
}

private final class ClipboardPickerWindowProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
