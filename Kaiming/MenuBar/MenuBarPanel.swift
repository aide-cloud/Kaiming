import SwiftUI

/// 菜单栏弹出面板：截图、剪贴板与 Markdown 的统一入口。
struct MenuBarPanel: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    /// 剪贴板页初始分区；正式启动保持默认「实时」，调试快照可显式指定。
    var clipboardScope: ClipboardScope = .live
    /// 系统页初始分区；正式启动保持「清理释放」，调试快照可显式指定。
    var systemSection: SystemSection = .clean

    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = appState.notice {
                noticeBanner(notice)
            }
            tabPicker
            Divider()
            tabContent
            Divider()
            footer
        }
        .frame(width: 400, height: 580)
        .onAppear {
            appState.refreshPermission()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("开明")
                    .font(.system(size: 14, weight: .semibold))
                Text("Kaiming · 目视四方")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                // 面板可能停在任意一块屏幕，Markdown 窗口跟随鼠标所在屏幕出现。
                WindowPlacementCenter.shared.willOpen(scene: AppWindowScene.markdown)
                openWindow(id: AppWindowScene.markdown)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Markdown 编辑器 (\(HotKeyAction.openMarkdown.displayString))")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 轻提示

    private func noticeBanner(_ notice: AppState.Notice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(for: notice.kind))
                .font(.system(size: 11, weight: .semibold))
            Text(notice.text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color(for: notice.kind))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color(for: notice.kind).opacity(0.12))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func symbol(for kind: AppState.Notice.Kind) -> String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(for kind: AppState.Notice.Kind) -> Color {
        switch kind {
        case .info: .accentColor
        case .success: .green
        case .error: .red
        }
    }

    // MARK: - Tab

    private var tabPicker: some View {
        Picker("功能", selection: $appState.selectedTab) {
            ForEach(AppState.PanelTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbolName)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var tabContent: some View {
        ScrollView {
            Group {
                switch appState.selectedTab {
                case .screenshot:
                    VStack(alignment: .leading, spacing: 12) {
                        if let image = appState.lastCapturedImage {
                            captureQuickActions(image)
                        }
                        ScreenshotPanelView()
                    }
                case .clipboard:
                    ClipboardPanelView(initialScope: clipboardScope)
                case .system:
                    SystemPanelView(
                        initialSection: systemSection,
                        availableHeight: max(0, viewportHeight - 28)
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelViewportHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PanelViewportHeightKey.self) { height in
            MainActor.assumeIsolated {
                viewportHeight = height
            }
        }
    }

    // MARK: - 底部


    // MARK: - 截图后快捷操作（阶段 6）

    private func captureQuickActions(_ image: NSImage) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 62, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("截图完成")
                        .font(.system(size: 10, weight: .semibold))
                    PanelChip(
                        text: settings.copyScreenshotToClipboard ? "已复制" : "未复制",
                        tint: settings.copyScreenshotToClipboard ? PanelPalette.mint : .secondary
                    )
                }
                Text("可保存或再次复制，无需重新截图")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            quickActionButton("square.and.arrow.down", help: "保存副本到截图文件夹") {
                saveCapture(image)
            }
            quickActionButton("doc.on.doc", help: "复制到剪贴板") {
                copyCaptureToPasteboard(image)
            }
            quickActionButton("xmark", help: "收起") {
                appState.clearLastCapture()
            }
        }
        .panelCard(padding: 8)
    }

    private func quickActionButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func saveCapture(_ image: NSImage) {
        do {
            guard let png = Self.pngData(from: image) else {
                appState.flash("图片编码失败，无法保存。", kind: .error)
                return
            }
            let directory = try AppPaths.ensureDirectory(settings.screenshotSaveDirectory)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())
            var url = directory.appendingPathComponent("Kaiming-\(stamp).png")
            var suffix = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("Kaiming-\(stamp)-\(suffix).png")
                suffix += 1
            }
            try png.write(to: url, options: .atomic)
            appState.flash("已保存到 \(directory.lastPathComponent)/\(url.lastPathComponent)", kind: .success)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            appState.flash("保存截图失败：\(error.localizedDescription)", kind: .error)
            Log.app.error("Quick save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func copyCaptureToPasteboard(_ image: NSImage) {
        guard let png = Self.pngData(from: image) else {
            appState.flash("图片编码失败，无法复制。", kind: .error)
            return
        }
        let succeeded = PasteboardQueue.serial.sync {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setData(png, forType: .png)
        }
        appState.flash(succeeded ? "已复制到剪贴板" : "写入剪贴板失败", kind: succeeded ? .success : .error)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("v\(Self.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                AppRouter.shared.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("偏好设置")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("退出 Kaiming")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

private struct PanelViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
