import SwiftUI

/// 偏好设置根视图。所有模块共享这一处入口。
///
/// 使用显式分段选择器而不是 `TabView`：在 LSUIElement + 独立 Window scene 中，
/// `TabView` 的标签栏依赖 Settings scene 的 toolbar，渲染不稳定。
struct SettingsView: View {
    @ObservedObject private var route = SettingsRoute.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分类", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch selectedTab {
                case .general: GeneralSettingsPane()
                case .permissions: PermissionSettingsPane()
                case .screenshot: ScreenshotSettingsPane()
                case .clipboard: ClipboardSettingsPane()
                case .markdown: MarkdownSettingsPane()
                case .shortcuts: ShortcutSettingsPane()
                case .about: AboutSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            applyPendingRoute()
        }
        .onChange(of: route.pendingTab) { _, _ in
            applyPendingRoute()
        }
    }

    /// 消费一次性的设置页跳转请求；`consume()` 会把 pendingTab 置 nil，
    /// 因此 nil 时直接忽略，避免 onChange 循环。
    private func applyPendingRoute() {
        guard let tab = route.consume() else { return }
        selectedTab = tab
    }
}

// MARK: - 通用

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle(
                    "登录时自动启动",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )

                if let error = settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Kaiming 常驻菜单栏，不显示 Dock 图标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("重置") {
                Button("恢复默认设置…", role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("确定恢复所有默认设置？", isPresented: $showResetConfirmation) {
            Button("恢复默认设置", role: .destructive) {
                settings.resetToDefaults()
                HotKeyManager.shared.reload()
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - 截图

private struct ScreenshotSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var isChoosingFolder = false

    var body: some View {
        Form {
            Section("截图后") {
                Toggle("自动复制到剪贴板", isOn: $settings.copyScreenshotToClipboard)
                Toggle("自动保存到文件夹", isOn: $settings.autoSaveScreenshots)

                Picker("文件格式", selection: $settings.screenshotFormat) {
                    ForEach(ScreenshotFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("保存位置") {
                LabeledContent("目录") {
                    Text(settings.screenshotSaveDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("选择文件夹…") { isChoosingFolder = true }
                    Button("在 Finder 中打开") {
                        _ = try? AppPaths.ensureDirectory(settings.screenshotSaveDirectory)
                        NSWorkspace.shared.open(settings.screenshotSaveDirectory)
                    }
                    if !settings.screenshotSaveDirectoryPath.isEmpty {
                        Button("恢复默认") { settings.screenshotSaveDirectoryPath = "" }
                    }
                }
            }

            Section("行为") {
                Toggle("显示鼠标指针", isOn: $settings.captureCursor)
                Toggle("播放截图声音", isOn: $settings.playCaptureSound)
                Toggle("截图时隐藏 Kaiming 窗口", isOn: $settings.screenshotHideOwnWindows)
                Text("默认不隐藏：区域/窗口/全屏截图会保留 Markdown 等本应用窗口，方便把文档内容一起截进图里。开启后截图不包含 Kaiming 自己的窗口。长截图逐帧采集始终排除截图边框与 HUD，避免辅助界面被拼进结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("区域 / 窗口 / 全屏三种模式均可通过菜单栏或全局快捷键触发。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外观") {
                Toggle("截图成品带窗口头部圆点", isOn: $settings.screenshotImageWindowHeader)
                Text("在区域 / 全屏 / 长截图成品顶部合成一条 macOS 标准窗口头部（红黄绿三个圆点），剪贴板、保存文件与截图历史都会包含。窗口截图本身已含标题栏，不会重复叠加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("长截图（自动滚动）") {
                Text("长截图的自动滚动需要辅助功能权限；普通截图与手动滚动拼接不需要。所有权限的检测、申请与设置统一在「权限」页完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("打开权限设置") {
                    AppRouter.shared.openSettings(tab: .permissions)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                settings.screenshotSaveDirectoryPath = url.path
            }
        }
    }
}

// MARK: - 权限

/// 应用唯一的权限交互页：检测、申请、跳转系统设置、重置屏幕录制授权记录都在这里。
/// 状态与底层调用统一来自 `PermissionCenter`，不在其它页面重复申请或展示。
private struct PermissionSettingsPane: View {
    @ObservedObject private var center = PermissionCenter.shared
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kaiming 需要的系统权限全部集中在这里检测、申请和设置。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Text("已授权 \(center.grantedCount) / \(KaimingPermission.allCases.count)")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(center.allGranted ? .green : .secondary)

                        Spacer(minLength: 0)

                        if center.isDetecting {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button("全部重新检测") {
                            center.detectAll()
                        }
                        .controlSize(.small)
                        .disabled(center.isDetecting)
                    }
                }
                .padding(.vertical, 2)
            }

            ForEach(KaimingPermission.allCases) { permission in
                Section {
                    PermissionCard(
                        permission: permission,
                        status: center.status(for: permission),
                        isDetecting: center.isDetecting,
                        onRequest: { center.request(permission) },
                        onOpenSettings: { center.openSystemSettings(permission) },
                        onDetect: { center.detectAll() },
                        onReset: { showResetConfirmation = true }
                    )
                }
            }

            Section("关于 TCC 授权") {
                Text("macOS 的 TCC 授权通常只对之后新启动的进程生效。重新构建应用后，系统设置里可能仍显示 Kaiming 已授权，但当前构建实际无法使用权限，此时请在屏幕录制一栏使用「重置授权记录…」后重新授权并重启应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            center.detectAll()
        }
        .confirmationDialog(
            "重置屏幕录制授权记录？",
            isPresented: $showResetConfirmation
        ) {
            Button("重置授权记录", role: .destructive) {
                if center.resetScreenRecording() {
                    AppState.shared.flash(
                        "已重置屏幕录制授权记录：请在系统设置中重新勾选 Kaiming，然后重启应用。",
                        kind: .info
                    )
                    // 重置后直接打开系统设置的「屏幕录制」页，用户只需勾选并回到本页重启。
                    center.openSystemSettings(.screenRecording)
                } else {
                    AppState.shared.flash(
                        "重置屏幕录制授权记录失败，请手动在系统设置中移除 Kaiming 后重新添加。",
                        kind: .error
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除 Kaiming 的屏幕录制授权记录，需要在系统设置中重新勾选 Kaiming 并重启应用。仅在系统设置显示已授权但仍提示未授权时使用。")
        }
    }
}

/// 单项权限卡片：状态徽标 + 用途 / 后果说明 + 检测、申请、跳转系统设置等操作。
private struct PermissionCard: View {
    let permission: KaimingPermission
    let status: PermissionStatus
    let isDetecting: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void
    let onDetect: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: permission.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(permission.title)
                            .font(.headline)
                        statusBadge
                    }

                    Text(permission.purpose)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(permission.consequence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("请求权限", action: onRequest)
                Button("打开系统设置", action: onOpenSettings)
                Button("检测", action: onDetect)
                    .disabled(isDetecting)
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            if permission == .screenRecording || (!status.isGranted && permission.requiresRelaunch) {
                HStack(spacing: 8) {
                    if permission == .screenRecording {
                        Button("重置授权记录…", role: .destructive, action: onReset)
                    }
                    if !status.isGranted && permission.requiresRelaunch {
                        Button("重启应用") {
                            AppRelauncher.relaunch()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if status.checkedAt == nil {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("检测中…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if status.isGranted {
            Label("已授权", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Label("未授权", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - 剪贴板

private struct ClipboardSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("历史记录") {
                Toggle("监控剪贴板变化", isOn: $settings.clipboardMonitoringEnabled)
                Stepper(
                    "实时最多保留 \(settings.clipboardHistoryLimit) 条",
                    value: $settings.clipboardHistoryLimit,
                    in: 10...500,
                    step: 10
                )
                Text("收藏项永久保留，不计入这个上限，也不会被自动淘汰。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("轮询间隔") {
                    Text(String(format: "%.1f 秒", settings.clipboardPollInterval))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.clipboardPollInterval, in: 0.3...2.0, step: 0.1)
            }

            Section {
                Text("剪贴板读写全部串行化到专用队列，避免 NSPasteboard 并发访问崩溃。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("类型识别使用 changeCount + pasteboard 类型检查；仅在内容变化时读取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("清理") {
                Button("清空实时历史（保留收藏）", role: .destructive) {
                    ClipboardManager.shared.clearHistory()
                }
                Text("只删除「实时」分区里的历史记录；收藏项需要在剪贴板面板里逐条取消收藏或删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Markdown

private struct MarkdownSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("编辑器") {
                Stepper(
                    "正文字号：\(Int(settings.markdownFontSize)) pt",
                    value: $settings.markdownFontSize,
                    in: 10...36,
                    step: 1
                )

                Toggle("实时渲染", isOn: $settings.markdownLivePreview)

                Picker("页宽", selection: $settings.markdownPageWidth) {
                    ForEach(MarkdownPageWidth.allCases) { width in
                        Text(width.title).tag(width)
                    }
                }
                .pickerStyle(.segmented)

                Text("页宽控制正文阅读栏的最大宽度；在内容区按住 ⌘ 滚动鼠标滚轮可缩放字号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("关闭实时渲染会切换到源码模式，仅显示 Markdown 文本；重新打开开关恢复内联渲染。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("说明") {
                Text("Markdown 编辑器使用原生 TextKit 2 渲染，采用 GitHub 浅色/深色配色；渲染预览使用 WebView，支持 HTML 块、Mermaid 图表与导出 PDF。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Markdown 窗口从菜单栏面板右上角按钮或 \(HotKeyAction.openMarkdown.displayString) 打开，拥有独立的 Window scene。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷键

private struct ShortcutSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var hotKeyManager = HotKeyManager.shared

    /// 编辑中的组合键；点「保存快捷键」后才写回设置并重新注册。
    @State private var draft: [HotKeyAction: HotKeyBinding] = [:]
    @State private var recordingAction: HotKeyAction?
    @State private var savedNotice = false
    @State private var noticeTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("全局快捷键") {
                Toggle("启用全局快捷键", isOn: $settings.hotkeysEnabled)
                    .onChange(of: settings.hotkeysEnabled) {
                        HotKeyManager.shared.reload()
                    }

                Text("点击右侧组合键后直接按下新按键，按 Esc 取消；录入结果显示在按钮上，点「保存快捷键」后生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("组合键") {
                ForEach(HotKeyAction.allCases) { action in
                    row(for: action)
                }
            }

            if let conflictMessage {
                Section("组合键冲突") {
                    Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if !hotKeyManager.failures.isEmpty {
                Section("注册失败") {
                    ForEach(Array(hotKeyManager.failures.keys), id: \.self) { action in
                        Label(
                            "\(action.title)：\(hotKeyManager.failures[action] ?? "")",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("恢复全部默认") {
                        resetDraftToDefaults()
                    }
                    .disabled(!hasCustomDraft)

                    Spacer(minLength: 8)

                    if savedNotice {
                        Label("已保存并生效", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Button("保存快捷键") {
                        save()
                    }
                    .disabled(!isDirty || conflictMessage != nil)
                    .keyboardShortcut("s", modifiers: .command)
                }

                Text("组合键至少需要包含 ⌘、⌥ 或 ⌃ 之一；默认的 ⌥⇧ 系列避开了系统自带的 ⌘⇧3 / ⌘⇧4 / ⌘⇧5。若被系统或其他应用占用，保存后会在上方提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncDraftFromSettings()
        }
        .onChange(of: settings.hotKeyBindings) { _, _ in
            guard recordingAction == nil else { return }
            syncDraftFromSettings()
        }
        .onDisappear {
            stopRecording()
            noticeTask?.cancel()
            noticeTask = nil
        }
    }

    // MARK: - 行

    private func row(for action: HotKeyAction) -> some View {
        let binding = draft[action] ?? action.defaultBinding
        let conflicted = conflictingActions.contains(action)

        return HStack(spacing: 10) {
            Text(action.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            if conflicted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("与其他动作使用了相同的组合键")
            }

            ShortcutRecorderField(
                binding: binding,
                isRecording: recordingAction == action,
                onToggle: { toggleRecording(action) },
                onCapture: { newBinding in
                    draft[action] = newBinding
                    stopRecording()
                },
                onCancel: { stopRecording() }
            )
        }
        .contentShape(Rectangle())
    }

    // MARK: - 录制

    private func toggleRecording(_ action: HotKeyAction) {
        if recordingAction == action {
            stopRecording()
            return
        }
        if recordingAction != nil {
            stopRecording()
        }
        recordingAction = action
        // 录制期间先注销全局热键，否则按下已有组合键会先触发原来的动作。
        HotKeyManager.shared.suspend()
    }

    private func stopRecording() {
        guard recordingAction != nil else { return }
        recordingAction = nil
        HotKeyManager.shared.resume()
    }

    // MARK: - 草稿

    private func syncDraftFromSettings() {
        draft = Dictionary(
            uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, settings.binding(for: $0)) }
        )
    }

    private func resetDraftToDefaults() {
        draft = Dictionary(
            uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultBinding) }
        )
    }

    private var isDirty: Bool {
        HotKeyAction.allCases.contains { action in
            (draft[action] ?? action.defaultBinding) != settings.binding(for: action)
        }
    }

    private var hasCustomDraft: Bool {
        HotKeyAction.allCases.contains { action in
            (draft[action] ?? action.defaultBinding) != action.defaultBinding
        }
    }

    private var conflictingActions: Set<HotKeyAction> {
        var groups: [HotKeyBinding: [HotKeyAction]] = [:]
        for action in HotKeyAction.allCases {
            let binding = draft[action] ?? action.defaultBinding
            groups[binding, default: []].append(action)
        }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    private var conflictMessage: String? {
        let invalid = HotKeyAction.allCases.filter { action in
            ((draft[action] ?? action.defaultBinding).validationError != nil
                && !conflictingActions.contains(action))
        }
        if let action = invalid.first,
           let error = (draft[action] ?? action.defaultBinding).validationError {
            return "\(action.title)：\(error)"
        }
        guard !conflictingActions.isEmpty else { return nil }
        let titles = HotKeyAction.allCases
            .filter { conflictingActions.contains($0) }
            .map(\.title)
            .joined(separator: "、")
        return "以下动作使用了相同组合键，请修改后再保存：\(titles)"
    }

    private func save() {
        guard conflictMessage == nil else { return }
        settings.updateHotKeyBindings(draft)
        syncDraftFromSettings()
        showSavedNotice()
    }

    private func showSavedNotice() {
        noticeTask?.cancel()
        savedNotice = true
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            savedNotice = false
        }
    }
}

// MARK: - 关于

private struct AboutSettingsPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
                .padding(.top, 26)

            Text("开明 Kaiming")
                .font(.title2.weight(.semibold))
            Text("山海经 · 开明兽，目视四方，明察万物")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("版本 \(Self.version)（\(Self.build)）")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()
                .padding(.horizontal, 60)

            VStack(alignment: .leading, spacing: 8) {
                aboutRow("crop", "截图：ScreenCaptureKit + AppKit 全屏覆盖层")
                aboutRow("doc.on.clipboard", "剪贴板：NSPasteboard 串行队列 + 历史记录")
                aboutRow("doc.richtext", "Markdown：TextKit 2 原生编辑器 + WebView 渲染预览")
            }
            .padding(.horizontal, 40)

            Spacer()

            Text("Copyright © 2026 Kaiming. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func aboutRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
