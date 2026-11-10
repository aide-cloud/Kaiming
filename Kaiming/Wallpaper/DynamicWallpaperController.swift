import AVFoundation
import AppKit
import QuartzCore

/// 动态壁纸的桌面层窗口：不接收键盘/鼠标，不参与窗口循环。
final class DynamicWallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 承载 `AVPlayerLayer` 的视图，按窗口尺寸做 resizeAspectFill。
final class DynamicWallpaperPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// 动态视频壁纸的窗口/播放器管理。
///
/// macOS 没有公开 API 把视频设为系统壁纸，这里用每块屏幕一个桌面层窗口模拟：
/// - level = `CGWindowLevelForKey(.desktopWindow) + 1`，位于壁纸之上、桌面图标之下；
/// - `canJoinAllSpaces` / `stationary` / `ignoresCycle`，不接收鼠标事件、无阴影；
/// - 每块屏幕独立 `AVQueuePlayer` + `AVPlayerLooper`，循环静音播放。
///
/// 仅由 `WallpaperManager` 在主线程持有和调用。
@MainActor
final class DynamicWallpaperController {
    /// 桌面层 + 1：桌面图标层级比它更高，图标仍可见。
    static let desktopWindowLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
    )

    private final class Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let window: DynamicWallpaperWindow
        let view: DynamicWallpaperPlayerView

        init(
            player: AVQueuePlayer,
            looper: AVPlayerLooper,
            window: DynamicWallpaperWindow,
            view: DynamicWallpaperPlayerView
        ) {
            self.player = player
            self.looper = looper
            self.window = window
            self.view = view
        }
    }

    private var entries: [String: Entry] = [:]

    var activeScreenIDs: Set<String> { Set(entries.keys) }
    var isActive: Bool { !entries.isEmpty }

    /// 为每块目标屏幕创建窗口并开始循环播放；返回实际启动成功的屏幕 id。
    func start(videoURL: URL, screenIDs: Set<String>, screens: [String: NSScreen]) -> Set<String> {
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            Log.wallpaper.error("Dynamic wallpaper video is not readable: \(videoURL.lastPathComponent, privacy: .public)")
            return []
        }

        let asset = AVURLAsset(url: videoURL)
        var started: Set<String> = []

        for screenID in screenIDs.sorted() {
            guard let screen = screens[screenID] else {
                Log.wallpaper.error("Dynamic wallpaper skipped: screen \(screenID, privacy: .public) not found")
                continue
            }
            stop(screenID: screenID)

            let templateItem = AVPlayerItem(asset: asset)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.volume = 0
            let looper = AVPlayerLooper(player: player, templateItem: templateItem)

            let view = DynamicWallpaperPlayerView(player: player)
            view.frame = NSRect(origin: .zero, size: screen.frame.size)

            let window = DynamicWallpaperWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = Self.desktopWindowLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isOpaque = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()

            player.play()

            entries[screenID] = Entry(player: player, looper: looper, window: window, view: view)
            started.insert(screenID)
            Log.wallpaper.info(
                "Dynamic wallpaper started on \(screenID, privacy: .public) level=\(Self.desktopWindowLevel.rawValue, privacy: .public) frame=\(NSStringFromRect(screen.frame), privacy: .public)"
            )
        }
        return started
    }

    func stop(screenID: String) {
        guard let entry = entries.removeValue(forKey: screenID) else { return }
        entry.player.pause()
        entry.looper.disableLooping()
        entry.player.replaceCurrentItem(with: nil)
        entry.window.orderOut(nil)
        entry.window.contentView = nil
        entry.window.close()
        Log.wallpaper.info("Dynamic wallpaper window closed for \(screenID, privacy: .public)")
    }

    func stop(screenIDs: Set<String>) {
        for screenID in screenIDs {
            stop(screenID: screenID)
        }
    }

    func stopAll() {
        let screenIDs = Array(entries.keys)
        for screenID in screenIDs {
            stop(screenID: screenID)
        }
    }

    /// 屏幕参数变化后重新贴合窗口；断开连接的屏幕直接清理。
    func syncScreens(_ screens: [String: NSScreen]) {
        for screenID in Array(entries.keys) {
            guard let screen = screens[screenID] else {
                stop(screenID: screenID)
                continue
            }
            guard let entry = entries[screenID] else { continue }
            if entry.window.frame != screen.frame {
                entry.window.setFrame(screen.frame, display: true)
                Log.wallpaper.info(
                    "Dynamic wallpaper window repositioned for \(screenID, privacy: .public): \(NSStringFromRect(screen.frame), privacy: .public)"
                )
            }
            entry.window.orderFrontRegardless()
        }
    }

    // MARK: - 诊断（构建日志 / 冒烟测试使用）

    func playbackStatus(for screenID: String) -> String {
        guard let entry = entries[screenID] else { return "missing" }
        let item = entry.player.currentItem
        let itemStatus = item?.status.rawValue ?? -99
        let itemError = item?.error?.localizedDescription ?? "nil"
        let waitReason = entry.player.reasonForWaitingToPlay?.rawValue ?? "nil"
        let looperError = entry.looper.error?.localizedDescription ?? "nil"
        return "timeControlStatus=\(entry.player.timeControlStatus.rawValue)"
            + " rate=\(entry.player.rate)"
            + " itemStatus=\(itemStatus)"
            + " waitReason=\(waitReason)"
            + " looperStatus=\(entry.looper.status.rawValue)"
            + " itemError=\(itemError)"
            + " looperError=\(looperError)"
    }

    var allPlayersPlaying: Bool {
        !entries.isEmpty && entries.values.allSatisfy { $0.player.timeControlStatus == .playing }
    }

    var windowLevels: [String: Int] {
        entries.mapValues { $0.window.level.rawValue }
    }

    var windowFrames: [String: NSRect] {
        entries.mapValues { $0.window.frame }
    }
}
