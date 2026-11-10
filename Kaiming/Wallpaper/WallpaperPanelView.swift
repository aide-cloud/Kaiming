import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 壁纸数据源的媒体类型。
private enum WallpaperMediaKind: String, CaseIterable, Identifiable {
    case image
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "图片"
        case .video: "视频"
        }
    }
}

/// 菜单栏面板中的「壁纸」页。
///
/// 布局适配 372pt 内容宽（菜单栏面板 400pt 减去左右各 14pt），所有数据源操作都作用于
/// 上方勾选的屏幕集合；成功 / 失败通过 `AppState.flash` 反馈。
struct WallpaperPanelView: View {
    @ObservedObject private var manager = WallpaperManager.shared

    @State private var selectedScreenIDs: Set<String> = []
    @State private var mediaKind: WallpaperMediaKind = .image
    @State private var rotationMinutes = 5
    @State private var isRotationExpanded = false

    /// 菜单栏面板内容宽：400 - 2 × 14 = 372pt。
    private let panelContentWidth: CGFloat = 372

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if manager.screens.isEmpty {
                emptyScreensCard
            } else {
                screensCard
            }

            dataSourceCard
            rotationCard
            storageHint
        }
        .frame(maxWidth: panelContentWidth, alignment: .leading)
        .onAppear {
            manager.refreshScreens()
            if manager.isDynamicWallpaperActive {
                mediaKind = .video
            }
            if selectedScreenIDs.isEmpty {
                selectedScreenIDs = Set(manager.screens.map(\.id))
            }
        }
        .onChange(of: manager.screens) {
            let available = Set(manager.screens.map(\.id))
            if selectedScreenIDs.isEmpty {
                selectedScreenIDs = available
            } else {
                selectedScreenIDs.formIntersection(available)
            }
        }
        .onChange(of: manager.isDynamicWallpaperActive) {
            if manager.isDynamicWallpaperActive {
                mediaKind = .video
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Label("壁纸", systemImage: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 0)

            if manager.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                manager.refreshScreens()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("刷新屏幕列表")
            .disabled(manager.isBusy)
        }
    }

    // MARK: - 屏幕

    private var screensCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle("屏幕")
                Spacer(minLength: 0)
                Button("全选") {
                    selectedScreenIDs = Set(manager.screens.map(\.id))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(manager.isBusy)

                Button("反选") {
                    let all = Set(manager.screens.map(\.id))
                    selectedScreenIDs = all.subtracting(selectedScreenIDs)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(manager.isBusy)
            }

            ForEach(manager.screens) { screen in
                screenRow(screen)
            }

            targetSummary
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func screenRow(_ screen: ScreenInfo) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selectedScreenIDs.contains(screen.id) },
                set: { isSelected in
                    if isSelected {
                        selectedScreenIDs.insert(screen.id)
                    } else {
                        selectedScreenIDs.remove(screen.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(manager.isBusy)

            WallpaperURLThumbnail(url: screen.currentWallpaper)
                .frame(width: 72, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(screen.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if screen.isMain {
                        Text("主屏")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }

                    if manager.dynamicWallpaperScreens.contains(screen.id) {
                        Text("动态")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.15)))
                            .foregroundStyle(Color.purple)
                    }
                }

                Text(pixelSizeText(screen.pixelSize))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(screenSubtitle(for: screen))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private var targetSummary: some View {
        HStack(spacing: 5) {
            Image(systemName: selectedScreenIDs.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(selectedScreenIDs.isEmpty ? Color.orange : Color.green)

            Text(selectedScreenIDs.isEmpty ? "请至少勾选一块屏幕" : "目标：已选 \(selectedScreenIDs.count) 块屏幕")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private func pixelSizeText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    private func screenSubtitle(for screen: ScreenInfo) -> String {
        if manager.dynamicWallpaperScreens.contains(screen.id),
           let info = manager.dynamicWallpaperInfo {
            return "动态壁纸 · \(info.url.lastPathComponent)"
        }
        return screen.currentWallpaper?.lastPathComponent ?? "系统默认或动态壁纸"
    }

    private var emptyScreensCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("未检测到可用显示器", systemImage: "display")
                .font(.system(size: 12, weight: .semibold))

            Text("请确认显示器连接正常，然后刷新屏幕列表。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button("刷新屏幕") {
                manager.refreshScreens()
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - 数据源

    private var dataSourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle("数据源")

                Spacer(minLength: 0)

                Picker("媒体类型", selection: $mediaKind) {
                    ForEach(WallpaperMediaKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
                .disabled(manager.isBusy)
            }

            if mediaKind == .image {
                imageSourceControls
            } else {
                videoSourceControls
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var imageSourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    manager.setFromPasteboard(screenIDs: selectedScreenIDs)
                } label: {
                    Label("从剪贴板", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .disabled(manager.isBusy || selectedScreenIDs.isEmpty)

                Button {
                    chooseImageFile()
                } label: {
                    Label("选择图片…", systemImage: "photo.badge.plus")
                        .font(.system(size: 11))
                }
                .disabled(manager.isBusy || selectedScreenIDs.isEmpty)

                Spacer(minLength: 0)
            }
            .controlSize(.small)

            Text("图片会复制到应用数据目录后再设为壁纸，不引用临时路径。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var videoSourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    chooseVideoFile()
                } label: {
                    Label("选择视频…", systemImage: "film.badge.plus")
                        .font(.system(size: 11))
                }
                .disabled(manager.isBusy || selectedScreenIDs.isEmpty)

                if manager.isDynamicWallpaperActive {
                    Text("已启用")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.15)))
                        .foregroundStyle(Color.purple)
                }

                Spacer(minLength: 0)
            }
            .controlSize(.small)

            Text("支持 MP4 / MOV，循环静音播放（新视频会替换当前动态壁纸）。macOS 没有系统级视频壁纸 API，动态壁纸由桌面层窗口模拟，仅在 Kaiming 运行期间显示。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let info = manager.dynamicWallpaperInfo, manager.isDynamicWallpaperActive {
                dynamicVideoCard(info)
            }
        }
    }

    private func dynamicVideoCard(_ info: WallpaperVideoInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            WallpaperDataThumbnail(data: info.thumbnailData, symbol: "film")
                .frame(width: 96, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.url.lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(
                    "\(durationText(info.duration)) · \(info.pixelWidth)×\(info.pixelHeight) · \(manager.dynamicWallpaperScreens.count) 块屏幕"
                )
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text("动态壁纸进行中")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            Button("停止") {
                manager.stopDynamicWallpaper()
            }
            .controlSize(.small)
            .disabled(manager.isBusy)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func chooseImageFile() {
        WallpaperFilePicker.shared.chooseImage { urls in
            guard let url = urls.first else { return }
            manager.setWallpaper(fileURL: url, screenIDs: selectedScreenIDs)
        }
    }

    private func chooseVideoFile() {
        WallpaperFilePicker.shared.chooseVideo { urls in
            guard let url = urls.first else { return }
            manager.startDynamicWallpaper(fileURL: url, screenIDs: selectedScreenIDs)
        }
    }

    // MARK: - 文件夹轮换（可选能力）

    private var rotationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isRotationExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    sectionTitle("文件夹轮换")

                    if manager.isRotating {
                        Text("进行中")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isRotationExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isRotationExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("选择文件夹…") {
                            chooseRotationFolder()
                        }
                        .controlSize(.small)
                        .disabled(manager.isRotating)

                        Text(manager.rotationFolder?.lastPathComponent ?? "未选择文件夹")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }

                    Picker("间隔", selection: $rotationMinutes) {
                        Text("1 分钟").tag(1)
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(manager.isRotating)

                    HStack(spacing: 8) {
                        if manager.isRotating {
                            Text("每 \(Int(manager.rotationInterval / 60)) 分钟换一张，使用开始时的屏幕。")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)

                            Button("停止轮换") {
                                manager.stopRotation()
                            }
                            .controlSize(.small)
                        } else {
                            Text("使用当前勾选的屏幕；轮换仅本次运行有效。")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)

                            Button("开始轮换") {
                                guard let folder = manager.rotationFolder else { return }
                                manager.startRotation(
                                    folder: folder,
                                    interval: TimeInterval(rotationMinutes * 60),
                                    screenIDs: selectedScreenIDs
                                )
                            }
                            .controlSize(.small)
                            .disabled(manager.rotationFolder == nil || selectedScreenIDs.isEmpty || manager.isBusy)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func chooseRotationFolder() {
        WallpaperFilePicker.shared.chooseFolder { urls in
            guard let url = urls.first else { return }
            manager.selectRotationFolder(url)
        }
    }

    // MARK: - 持久化说明

    private var storageHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("壁纸文件保存在 Application Support/Kaiming/Wallpapers，系统会记住路径，重启后仍然有效。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("打开壁纸文件夹") {
                    openWallpapersFolder()
                }
                .controlSize(.small)

                Text("最多保留 50 张；正在使用的文件不会被清理。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
        }
    }

    private func openWallpapersFolder() {
        do {
            let url = try AppPaths.ensureDirectory(AppPaths.wallpapers)
            NSWorkspace.shared.open(url)
        } catch {
            AppState.shared.flash("无法打开壁纸目录：\(error.localizedDescription)", kind: .error)
        }
    }

    // MARK: - 通用视图

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
    }
}

// MARK: - 缩略图

/// 用 `Data` 承载缩略图（后台队列解码好），主线程按需转成 `NSImage`。
private struct WallpaperDataThumbnail: View {
    let data: Data?
    let symbol: String

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: data) {
            if let data {
                image = NSImage(data: data)
            } else {
                image = nil
            }
        }
    }
}

/// 屏幕上“当前壁纸”的缩略图，按 URL 异步加载。
private struct WallpaperURLThumbnail: View {
    let url: URL?

    @State private var thumbnailData: Data?

    var body: some View {
        WallpaperDataThumbnail(data: thumbnailData, symbol: "display")
            .task(id: url) {
                thumbnailData = nil
                guard let url else { return }
                thumbnailData = await WallpaperManager.shared.thumbnailData(for: url)
            }
    }
}
