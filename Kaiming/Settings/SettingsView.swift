import SwiftUI

/// 偏好设置根视图。所有模块共享这一处入口。
///
/// 使用显式分段选择器而不是 `TabView`：在 LSUIElement + 独立 Window scene 中，
/// `TabView` 的标签栏依赖 Settings scene 的 toolbar，渲染不稳定。
struct SettingsView: View {
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case screenshot
        case clipboard
        case markdown
        case shortcuts
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .screenshot: "截图"
            case .clipboard: "剪贴板"
            case .markdown: "Markdown"
            case .shortcuts: "快捷键"
            case .about: "关于"
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .screenshot: "crop"
            case .clipboard: "doc.on.clipboard"
            case .markdown: "doc.richtext"
            case .shortcuts: "command"
            case .about: "info.circle"
            }
        }
    }

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
    }
}

// MARK: - 通用

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var appState: AppState
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

            Section("屏幕录制权限") {
                HStack {
                    Label(
                        appState.screenRecordingGranted ? "已授权" : "未授权",
                        systemImage: appState.screenRecordingGranted
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(appState.screenRecordingGranted ? .green : .orange)

                    Spacer()

                    if !appState.screenRecordingGranted {
                        Button("请求权限") {
                            ScreenCapturePermission.request()
                            appState.refreshPermission()
                        }
                        Button("打开系统设置") {
                            ScreenCapturePermission.openSystemSettings()
                        }
                    }
                }

                Text("授权后需要重新打开 Kaiming 才会生效。未授权时 ScreenCaptureKit 会静默返回空列表。")
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
                Text("区域 / 窗口 / 全屏三种模式均可通过菜单栏或全局快捷键触发。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

// MARK: - 剪贴板

private struct ClipboardSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("历史记录") {
                Toggle("监控剪贴板变化", isOn: $settings.clipboardMonitoringEnabled)
                Stepper(
                    "最多保留 \(settings.clipboardHistoryLimit) 条",
                    value: $settings.clipboardHistoryLimit,
                    in: 10...500,
                    step: 10
                )

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
                Button("清空全部历史记录", role: .destructive) {
                    ClipboardManager.shared.clearHistory()
                }
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
                    in: 11...24,
                    step: 1
                )

                Toggle("实时渲染", isOn: $settings.markdownLivePreview)

                Text("关闭实时渲染会切换到源码模式，仅显示 Markdown 文本；重新打开开关恢复内联渲染。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("说明") {
                Text("Markdown 使用原生 TextKit 2 渲染，不包含 WebView。支持标题、列表、表格、代码高亮、任务列表与 LaTeX 公式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Markdown 窗口从菜单栏面板右上角按钮或 ⌥⇧M 打开，拥有独立的 Window scene。")
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

    var body: some View {
        Form {
            Section("全局快捷键") {
                Toggle("启用全局快捷键", isOn: $settings.hotkeysEnabled)
                    .onChange(of: settings.hotkeysEnabled) {
                        HotKeyManager.shared.reload()
                    }

                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        Text(action.displayString)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                }
            }

            if !hotKeyManager.failures.isEmpty {
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
                Text("⌥⇧ 组合键避开系统自带的 ⌘⇧3 / ⌘⇧4 / ⌘⇧5。若与其他应用冲突，可在该应用中调整或在此关闭全局快捷键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("重新注册快捷键") {
                    HotKeyManager.shared.reload()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 关于

private struct AboutSettingsPane: View {
    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 84, height: 84)
                .overlay {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)
                }
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
                aboutRow("photo", "壁纸：NSWorkspace，多显示器，持久化到 Application Support")
                aboutRow("doc.richtext", "Markdown：SwiftUI + TextKit 2 原生渲染")
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
