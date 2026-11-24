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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if coordinator.isCapturing {
                capturingRow
            }

            modeSection
            recentSection

            Text("区域截图支持 8 个手柄、0–48pt 圆角（四角透明）与画笔手写/矩形/箭头/文字标注；已有标注可拖动、缩放、编辑文字或删除，选中区域后可进入长截图（自动滚动需辅助功能权限，也可手动滚动拼接）。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var capturingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("截图进行中：拖拽或点击屏幕，Return 确认，Esc 取消。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - 三种模式

    private var modeSection: some View {
        VStack(spacing: 7) {
            ForEach(CaptureMode.allCases) { mode in
                modeCard(mode, shortcut: shortcut(for: mode))
            }
        }
    }

    private func modeCard(_ mode: CaptureMode, shortcut: String) -> some View {
        let isHovering = hoveredMode == mode
        return Button {
            coordinator.start(mode: mode)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(mode.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isCapturing)
        .onHover { hovering in
            hoveredMode = hovering ? mode : (hoveredMode == mode ? nil : hoveredMode)
        }
        .help("\(mode.title)（\(shortcut)）")
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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("最近截图")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("在 Finder 中打开") {
                    openCapturesFolder()
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
            }

            if recentCaptures.isEmpty {
                Text("还没有截图记录，截图成功后会自动保存到应用数据目录。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ForEach(recentCaptures) { capture in
                        thumbnail(for: capture)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
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
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 84, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(capture.url.lastPathComponent)
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
