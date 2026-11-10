import AppKit
import UniformTypeIdentifiers

/// 壁纸模块内部的文件选择器。
///
/// 背景：壁纸面板位于 MenuBarExtra popover 内。SwiftUI `.fileImporter` 会随 popover
/// 失焦关闭而取消，导致用户选不到文件；因此这里改用 AppKit 的 modeless `NSOpenPanel`：
/// - `activePanels` 强引用面板直到 completion，popover 关闭不会释放/取消面板；
/// - `begin` 异步显示，选择完成后在主线程回调；
/// - 面板自身独立于菜单栏面板，选择结果不需要重新打开面板即可应用。
@MainActor
final class WallpaperFilePicker {
    static let shared = WallpaperFilePicker()

    static let imageContentTypes: [UTType] = [.image]
    static let videoContentTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
    static let folderContentTypes: [UTType] = [.folder]

    private var activePanels: [NSOpenPanel] = []

    /// 当前仍打开的选择面板数量（诊断/测试用）。
    var activePanelCount: Int { activePanels.count }

    private init() {}

    func chooseImage(completion: @escaping @MainActor ([URL]) -> Void) {
        present(
            contentTypes: Self.imageContentTypes,
            title: "选择图片壁纸",
            message: "图片会复制到应用数据目录后再设为壁纸。",
            canChooseFiles: true,
            canChooseDirectories: false,
            completion: completion
        )
    }

    func chooseVideo(completion: @escaping @MainActor ([URL]) -> Void) {
        present(
            contentTypes: Self.videoContentTypes,
            title: "选择动态壁纸视频",
            message: "支持 MP4 / MOV；视频会复制到应用数据目录后循环播放。",
            canChooseFiles: true,
            canChooseDirectories: false,
            completion: completion
        )
    }

    func chooseFolder(completion: @escaping @MainActor ([URL]) -> Void) {
        present(
            contentTypes: Self.folderContentTypes,
            title: "选择轮换文件夹",
            message: "选择包含图片的文件夹用于定时轮换。",
            canChooseFiles: false,
            canChooseDirectories: true,
            completion: completion
        )
    }

    /// 关闭当前面板（例如应用退出或测试收尾）。
    func cancelActivePanels() {
        let panels = activePanels
        activePanels.removeAll()
        for panel in panels {
            panel.cancel(nil)
        }
    }

    private func present(
        contentTypes: [UTType],
        title: String,
        message: String,
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        completion: @escaping @MainActor ([URL]) -> Void
    ) {
        // 已有面板时只带到前台，避免快速重复点击叠出多个选择面板。
        if let existing = activePanels.last {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "选择"
        panel.message = message
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.level = .floating

        activePanels.append(panel)
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { [weak self] response in
            guard let self else { return }
            self.activePanels.removeAll { $0 === panel }
            guard response == .OK else {
                Log.wallpaper.info("Wallpaper file picker cancelled")
                return
            }
            let urls = panel.urls
            guard !urls.isEmpty else {
                Log.wallpaper.info("Wallpaper file picker returned no URLs")
                return
            }
            Log.wallpaper.info("Wallpaper file picker selected \(urls.count, privacy: .public) item(s)")
            completion(urls)
        }
    }
}
