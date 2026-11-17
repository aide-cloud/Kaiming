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
    /// 自增即请求搜索框重新获得焦点（窗口刚出现、重新成为 key window 时）。
    @State private var searchFocusToken = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            listContent

            Divider()

            footer
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(windowAccessor)
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

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
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

            Text(HotKeyAction.openClipboard.displayString)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.10))
                )
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14))
        )
    }

    // MARK: - 列表

    private var listContent: some View {
        ScrollViewReader { proxy in
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(entries) { entry in
                                row(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

        return HStack(spacing: 10) {
            leadingVisual(for: item)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title(for: item))
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if entry.isCurrent {
                        badge("当前", color: .accentColor)
                    }

                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("已置顶")
                    }
                }

                Text("\(item.kind.title) · \(ClipboardPanelView.relativeString(since: item.createdAt))")
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : (isHovered ? Color.secondary.opacity(0.08) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
        )
        .onHover { hovering in
            if hovering {
                hoveredID = entry.id
            } else if hoveredID == entry.id {
                hoveredID = nil
            }
        }
        .onTapGesture {
            activate(entry)
        }
        .help("单击复制\(item.kind.title)")
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
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(item.kind.tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(item.kind.tint.opacity(0.13))
                )
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(color.opacity(0.14))
            )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: hasSearch ? "magnifyingglass" : "clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)

            Text(hasSearch ? "没有匹配「\(trimmedSearchText)」的记录" : "暂无剪贴板记录")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(
                hasSearch
                    ? "可搜索文本内容、文件名，或「文本 / 图片 / 文件 / 富文本」。"
                    : "复制文本、图片或文件后，历史会显示在这里。"
            )
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - 底部提示

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("↑↓", "选择")
            keyHint("↵", "复制")
            keyHint("esc", "关闭")
            Spacer()
            Text("\(entries.count) 条")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

    /// 当前剪贴板内容排第一，其后是历史；当前内容若也在历史里则只显示一次。
    private var allEntries: [PickerEntry] {
        let current = manager.currentItem
        var result: [PickerEntry] = []

        if let current {
            let latest = manager.items.first(where: { $0.id == current.id }) ?? current
            result.append(PickerEntry(id: latest.id, item: latest, isCurrent: true))
        }

        let currentID = current?.id
        for item in manager.items where item.id != currentID {
            result.append(PickerEntry(id: item.id, item: item, isCurrent: false))
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
        dismissWindow(id: "clipboard-picker")

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
