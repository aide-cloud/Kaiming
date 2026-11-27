import AppKit
import SwiftUI

/// 菜单栏面板中的截图页。无参初始化，嵌入 400pt 宽面板的滚动区。
struct ScreenshotPanelView: View {
    @EnvironmentObject private var appState: AppState
    /// 观察设置变化，让面板里的快捷键文案跟随自定义值刷新。
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var coordinator = ScreenshotCoordinator.shared

    @State private var recentCaptures: [RecentCapture] = []
    @State private var hoveredMode: CaptureMode?

    private struct RecentCapture: Identifiable {
        let url: URL
        let date: Date
        let image: NSImage?

        var id: URL { url }
    }

    private let modeColumns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if coordinator.isCapturing {
                capturingCard
            }

            PanelHeader(icon: "camera.viewfinder", title: "快速截图", caption: "点击或按快捷键")
            modeGrid
            recentCard
            capabilityCard
            behaviorCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            appState.refreshPermission()
            reloadRecentCaptures()
        }
        .onChange(of: appState.lastCaptureDate) {
            reloadRecentCaptures()
        }
    }

    // MARK: - 截图进行中

    private var capturingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("截图进行中")
                    .font(.system(size: 10, weight: .semibold))
                Text("拖拽或点击屏幕 · Return 确认 · Esc 取消")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .panelCard()
    }

    // MARK: - 三种模式

    private var modeGrid: some View {
        LazyVGrid(columns: modeColumns, spacing: 7) {
            ForEach(CaptureMode.allCases) { mode in
                modeTile(mode)
            }
        }
    }

    private func modeTile(_ mode: CaptureMode) -> some View {
        let shortcut = shortcut(for: mode)
        let tint = tint(for: mode)
        let isHovering = hoveredMode == mode

        return Button {
            coordinator.start(mode: mode)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 4) {
                    PanelIconBadge(symbol: mode.symbolName, tint: tint, size: 26)
                    Spacer(minLength: 0)
                    Text(shortcut)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .fixedSize()
                }

                Text(mode.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)

                Text(mode.subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .panelTile(padding: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isHovering ? tint.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isCapturing)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredMode = hovering ? mode : (hoveredMode == mode ? nil : hoveredMode)
            }
        }
        .help("\(mode.title)（\(shortcut)）")
    }

    private func tint(for mode: CaptureMode) -> Color {
        switch mode {
        case .region: PanelPalette.mint
        case .window: PanelPalette.sky
        case .fullScreen: PanelPalette.violet
        }
    }

    private func shortcut(for mode: CaptureMode) -> String {
        let action: HotKeyAction = switch mode {
        case .region: .captureRegion
        case .window: .captureWindow
        case .fullScreen: .captureFullScreen
        }
        return action.displayString
    }

    // MARK: - 最近截图

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                PanelHeader(
                    icon: "photo.stack",
                    title: "最近截图",
                    caption: recentCaptures.isEmpty ? nil : "\(recentCaptures.count) 张"
                )
                Spacer(minLength: 4)
                Button {
                    openCapturesFolder()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 8))
                        Text("打开文件夹")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("在 Finder 中打开截图目录")
            }

            if recentCaptures.isEmpty {
                HStack(spacing: 8) {
                    PanelIconBadge(symbol: "photo", tint: .secondary, size: 26)
                    Text("截图完成后会显示在这里。")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            Color.secondary.opacity(0.22),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
            } else {
                HStack(spacing: 6) {
                    ForEach(recentCaptures) { capture in
                        thumbnail(for: capture)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .panelCard()
    }

    private func thumbnail(for capture: RecentCapture) -> some View {
        Button {
            NSWorkspace.shared.open(capture.url)
        } label: {
            Group {
                if let image = capture.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 78, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(capture.url.lastPathComponent)
    }

    // MARK: - 能力说明

    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                PanelChip(icon: "hand.draw", text: "8 手柄", tint: PanelPalette.mint)
                PanelChip(icon: "square.dashed", text: "圆角 0–48pt", tint: PanelPalette.sky)
                PanelChip(icon: "pencil.tip", text: "标注编辑", tint: PanelPalette.violet)
                PanelChip(icon: "arrow.up.and.down", text: "长截图", tint: PanelPalette.amber)
                Spacer(minLength: 0)
            }
            Text("自动滚动需辅助功能权限；也可手动滚动拼接。")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .panelCard()
    }

    // MARK: - 截图之后

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            PanelHeader(icon: "slider.horizontal.3", title: "截图之后", caption: "保存与剪贴板")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6),
                ],
                spacing: 6
            ) {
                behaviorToggle(
                    "复制到剪贴板",
                    icon: "doc.on.doc",
                    isOn: $settings.copyScreenshotToClipboard
                )
                behaviorToggle(
                    "自动保存",
                    icon: "square.and.arrow.down",
                    isOn: $settings.autoSaveScreenshots
                )
                behaviorToggle(
                    "窗口头部",
                    icon: "macwindow",
                    isOn: $settings.screenshotImageWindowHeader
                )
                behaviorToggle(
                    "隐藏本应用",
                    icon: "eye.slash",
                    isOn: $settings.screenshotHideOwnWindows
                )
            }
        }
        .panelCard()
    }

    private func behaviorToggle(
        _ title: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 8.5))
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func reloadRecentCaptures() {
        let files = CaptureHistory.recentFiles(limit: 4)
        recentCaptures = files.map { file in
            RecentCapture(
                url: file.url,
                date: file.date,
                image: NSImage(contentsOf: file.url)
            )
        }
    }

    private func openCapturesFolder() {
        do {
            try AppPaths.ensureDirectory(AppPaths.captures)
        } catch {
            appState.flash("无法创建截图目录：\(error.localizedDescription)", kind: .error)
            Log.screenshot.error(
                "Failed to create captures directory: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        if !NSWorkspace.shared.open(AppPaths.captures) {
            appState.flash("无法在 Finder 中打开截图文件夹。", kind: .error)
        }
    }
}
