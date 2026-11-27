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
            header

            Picker("设置分类", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
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

    private var header: some View {
        HStack(spacing: 9) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                Text("Kaiming · 目视四方")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            PanelChip(icon: "info.circle", text: "v\(Self.version)", tint: .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// 消费一次性的设置页跳转请求；`consume()` 会把 pendingTab 置 nil，
    /// 因此 nil 时直接忽略，避免 onChange 循环。
    private func applyPendingRoute() {
        guard let tab = route.consume() else { return }
        selectedTab = tab
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

// MARK: - 通用布局

/// 设置页统一的滚动容器：16pt 边距、12pt 卡片间距。
private struct SettingsPane<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 设置卡片：22pt 图标徽章 + 标题 + 内容，沿用面板的 10pt 圆角 / 5% 叠色。
private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = .secondary
    private let content: Content

    init(
        title: String,
        icon: String,
        tint: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                PanelIconBadge(symbol: icon, tint: tint, size: 22)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }

            content
        }
        .panelCard(padding: 12)
    }
}

private struct SettingsHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 通用

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var showResetConfirmation = false

    var body: some View {
        SettingsPane {
            SettingsCard(title: "启动", icon: "power", tint: PanelPalette.mint) {
                Toggle(
                    "登录时自动启动",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )

                if let error = settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsHint(text: "Kaiming 常驻菜单栏，不显示 Dock 图标。")
            }

            SettingsCard(title: "重置", icon: "arrow.counterclockwise", tint: PanelPalette.rose) {
                Button("恢复默认设置…", role: .destructive) {
                    showResetConfirmation = true
                }
                .controlSize(.small)

                SettingsHint(text: "恢复截图、剪贴板、Markdown、快捷键与菜单栏指标等所有偏好。")
            }
        }
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
        SettingsPane {
            SettingsCard(title: "截图后", icon: "camera", tint: PanelPalette.sky) {
                Toggle("自动复制到剪贴板", isOn: $settings.copyScreenshotToClipboard)
                Toggle("自动保存到文件夹", isOn: $settings.autoSaveScreenshots)

                Picker("文件格式", selection: $settings.screenshotFormat) {
                    ForEach(ScreenshotFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                SettingsHint(text: "PNG 保留圆角外的透明区域；JPEG 不支持透明，自动保存的圆角外会变成不透明底色（剪贴板会附带 PNG 回退，截图历史固定为 PNG）。")
            }

            SettingsCard(title: "保存位置", icon: "folder", tint: PanelPalette.mint) {
                LabeledContent("目录") {
                    Text(settings.screenshotSaveDirectory.path)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    Button("选择文件夹…") { isChoosingFolder = true }
                    Button("在 Finder 中打开") {
                        _ = try? AppPaths.ensureDirectory(settings.screenshotSaveDirectory)
                        NSWorkspace.shared.open(settings.screenshotSaveDirectory)
                    }
                    if !settings.screenshotSaveDirectoryPath.isEmpty {
                        Button("恢复默认") { settings.screenshotSaveDirectoryPath = "" }
                    }
                }
                .controlSize(.small)
            }

            SettingsCard(title: "行为", icon: "cursorarrow.click", tint: PanelPalette.violet) {
                Toggle("显示鼠标指针", isOn: $settings.captureCursor)
                Toggle("播放截图声音", isOn: $settings.playCaptureSound)
                Toggle("截图时隐藏 Kaiming 窗口", isOn: $settings.screenshotHideOwnWindows)

                SettingsHint(text: "默认不隐藏：区域/窗口/全屏截图会保留 Markdown 等本应用窗口，方便把文档内容一起截进图里。开启后截图不包含 Kaiming 自己的窗口。长截图逐帧采集始终排除截图边框与 HUD，避免辅助界面被拼进结果。")
                SettingsHint(text: "区域 / 窗口 / 全屏三种模式均可通过菜单栏或全局快捷键触发。")
            }

            SettingsCard(title: "外观", icon: "rectangle.inset.filled", tint: PanelPalette.amber) {
                Toggle("截图成品带窗口头部圆点", isOn: $settings.screenshotImageWindowHeader)

                SettingsHint(text: "在区域 / 全屏 / 长截图成品顶部合成一条 macOS 标准窗口头部（红黄绿三个圆点），剪贴板、保存文件与截图历史都会包含。窗口截图本身已含标题栏，不会重复叠加。")
            }

            SettingsCard(title: "长截图（自动滚动）", icon: "arrow.up.and.down", tint: PanelPalette.amber) {
                SettingsHint(text: "长截图的自动滚动需要辅助功能权限；普通截图与手动滚动拼接不需要。所有权限的检测、申请与设置统一在「权限」页完成。")

                Button("打开权限设置") {
                    AppRouter.shared.openSettings(tab: .permissions)
                }
                .controlSize(.small)
            }
        }
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
        SettingsPane {
            SettingsCard(title: "权限总览", icon: "lock.shield", tint: PanelPalette.amber) {
                HStack(spacing: 10) {
                    Text("已授权 \(center.grantedCount) / \(KaimingPermission.allCases.count)")
                        .font(.system(size: 11, weight: .medium))
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

                SettingsHint(text: "Kaiming 需要的系统权限全部集中在这里检测、申请和设置。")
            }

            ForEach(KaimingPermission.allCases) { permission in
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

            SettingsCard(title: "关于 TCC 授权", icon: "info.circle", tint: .secondary) {
                SettingsHint(text: "macOS 的 TCC 授权通常只对之后新启动的进程生效。重新构建应用后，系统设置里可能仍显示 Kaiming 已授权，但当前构建实际无法使用权限，此时请在屏幕录制一栏使用「重置授权记录…」后重新授权并重启应用。")
            }
        }
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
                    center.openSystemSettings(.screenRecording)
                } else {
                    AppState.shared.flash(
                        "已重置屏幕录制授权记录失败，请手动在系统设置中移除 Kaiming 后重新添加。",
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                PanelIconBadge(symbol: permission.symbolName, tint: badgeTint, size: 32)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(permission.title)
                            .font(.system(size: 12, weight: .semibold))
                        statusBadge
                        Spacer(minLength: 0)
                    }

                    Text(permission.purpose)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(permission.consequence)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Button("请求权限", action: onRequest)
                    .buttonStyle(.borderedProminent)
                Button("打开系统设置", action: onOpenSettings)
                    .buttonStyle(.bordered)
                Button("检测", action: onDetect)
                    .disabled(isDetecting)
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            if permission == .screenRecording || (!status.isGranted && permission.requiresRelaunch) {
                HStack(spacing: 6) {
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
        .panelCard(padding: 11)
    }

    private var badgeTint: Color {
        guard status.checkedAt != nil else { return .secondary }
        return status.isGranted ? .green : .orange
    }

    @ViewBuilder
    private var statusBadge: some View {
        if status.checkedAt == nil {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("检测中…")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        } else if status.isGranted {
            PanelChip(icon: "checkmark.seal.fill", text: "已授权", tint: .green)
        } else {
            PanelChip(icon: "exclamationmark.triangle.fill", text: "未授权", tint: .orange)
        }
    }
}

// MARK: - 剪贴板

private struct ClipboardSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsCard(title: "历史记录", icon: "clock.arrow.circlepath", tint: PanelPalette.sky) {
                Toggle("监控剪贴板变化", isOn: $settings.clipboardMonitoringEnabled)

                Stepper(
                    "实时最多保留 \(settings.clipboardHistoryLimit) 条",
                    value: $settings.clipboardHistoryLimit,
                    in: 10...500,
                    step: 10
                )

                SettingsHint(text: "收藏项永久保留，不计入这个上限，也不会被自动淘汰。")

                Stepper(
                    "轮询间隔 \(settings.clipboardPollInterval, specifier: "%.1f") 秒",
                    value: $settings.clipboardPollInterval,
                    in: 0.3...2.0,
                    step: 0.1
                )
            }

            SettingsCard(title: "实现", icon: "gearshape.2", tint: .secondary) {
                SettingsHint(text: "剪贴板读写全部串行化到专用队列，避免 NSPasteboard 并发访问崩溃。")
                SettingsHint(text: "类型识别使用 changeCount + pasteboard 类型检查；仅在内容变化时读取。")
            }

            SettingsCard(title: "清理", icon: "trash", tint: PanelPalette.rose) {
                Button("清空实时历史（保留收藏）", role: .destructive) {
                    ClipboardManager.shared.clearHistory()
                }
                .controlSize(.small)

                SettingsHint(text: "只删除「实时」分区里的历史记录；收藏项需要在剪贴板面板或快捷选择窗口里逐条取消收藏或删除。")
            }
        }
    }
}

// MARK: - Markdown

private struct MarkdownSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsCard(title: "编辑器", icon: "textformat", tint: PanelPalette.violet) {
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

                SettingsHint(text: "页宽控制正文阅读栏的最大宽度；在内容区按住 ⌘ 滚动鼠标滚轮可缩放字号。")
                SettingsHint(text: "关闭实时渲染会切换到源码模式，仅显示 Markdown 文本；重新打开开关恢复内联渲染。")
            }

            SettingsCard(title: "说明", icon: "info.circle", tint: .secondary) {
                SettingsHint(text: "Markdown 编辑器使用原生 TextKit 2 渲染，采用 GitHub 浅色/深色配色；渲染预览使用 WebView，支持 HTML 块、Mermaid 图表与导出 PDF。")
                SettingsHint(text: "Markdown 窗口从菜单栏面板右上角按钮或 \(HotKeyAction.openMarkdown.displayString) 打开，拥有独立的 Window scene。")
            }
        }
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
        SettingsPane {
            SettingsCard(title: "全局快捷键", icon: "command", tint: PanelPalette.amber) {
                Toggle("启用全局快捷键", isOn: $settings.hotkeysEnabled)
                    .onChange(of: settings.hotkeysEnabled) {
                        HotKeyManager.shared.reload()
                    }

                SettingsHint(text: "点击右侧组合键后直接按下新按键，按 Esc 取消；录入结果显示在按钮上，点「保存快捷键」后生效。")
            }

            SettingsCard(title: "组合键", icon: "keyboard", tint: PanelPalette.sky) {
                VStack(spacing: 0) {
                    ForEach(Array(HotKeyAction.allCases.enumerated()), id: \.element) { index, action in
                        row(for: action)
                            .padding(.vertical, 4)
                        if index < HotKeyAction.allCases.count - 1 {
                            Divider()
                                .opacity(0.18)
                        }
                    }
                }
            }

            if let conflictMessage {
                SettingsCard(
                    title: "组合键冲突",
                    icon: "exclamationmark.triangle.fill",
                    tint: PanelPalette.amber
                ) {
                    Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !hotKeyManager.failures.isEmpty {
                SettingsCard(
                    title: "注册失败",
                    icon: "exclamationmark.triangle",
                    tint: PanelPalette.amber
                ) {
                    ForEach(Array(hotKeyManager.failures.keys), id: \.self) { action in
                        Label(
                            "\(action.title)：\(hotKeyManager.failures[action] ?? "")",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard(title: "保存", icon: "checkmark.circle", tint: PanelPalette.mint) {
                HStack(spacing: 10) {
                    Button("恢复全部默认") {
                        resetDraftToDefaults()
                    }
                    .disabled(!hasCustomDraft)

                    Spacer(minLength: 8)

                    if savedNotice {
                        Label("已保存并生效", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.green)
                    }

                    Button("保存快捷键") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || conflictMessage != nil)
                    .keyboardShortcut("s", modifiers: .command)
                }
                .controlSize(.small)

                SettingsHint(text: "组合键至少需要包含 ⌘、⌥ 或 ⌃ 之一；默认的 ⌥⇧ 系列避开了系统自带的 ⌘⇧3 / ⌘⇧4 / ⌘⇧5。若被系统或其他应用占用，保存后会在上方提示。")
            }
        }
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
                .font(.system(size: 11))
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
        SettingsPane {
            VStack(spacing: 8) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)

                Text("开明 Kaiming")
                    .font(.system(size: 18, weight: .semibold))
                Text("山海经 · 开明兽，目视四方，明察万物")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                PanelChip(text: "版本 \(Self.version)（\(Self.build)）", tint: .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            SettingsCard(title: "组成", icon: "sparkles", tint: PanelPalette.mint) {
                aboutRow("crop", "截图：ScreenCaptureKit + AppKit 全屏覆盖层", tint: PanelPalette.mint)
                aboutRow("doc.on.clipboard", "剪贴板：NSPasteboard 串行队列 + 历史记录", tint: PanelPalette.sky)
                aboutRow("doc.richtext", "Markdown：TextKit 2 原生编辑器 + WebView 渲染预览", tint: PanelPalette.violet)
            }

            SettingsCard(title: "版权", icon: "c.circle", tint: .secondary) {
                Text("Copyright © 2026 Kaiming. All rights reserved.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func aboutRow(_ symbol: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            PanelIconBadge(symbol: symbol, tint: tint, size: 22)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
