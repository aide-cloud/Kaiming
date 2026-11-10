import AppKit
import Combine

/// 应用级 UI 状态：菜单栏面板当前页、权限状态、最近一次截图与轻提示。
/// 只放 UI 状态，业务状态由各模块自己的 Manager 持有。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum PanelTab: String, CaseIterable, Identifiable {
        case screenshot
        case clipboard
        case wallpaper
        case apps

        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenshot: "截图"
            case .clipboard: "剪贴板"
            case .wallpaper: "壁纸"
            case .apps: "应用"
            }
        }

        var symbolName: String {
            switch self {
            case .screenshot: "crop"
            case .clipboard: "doc.on.clipboard"
            case .wallpaper: "photo"
            case .apps: "square.grid.2x2"
            }
        }
    }

    struct Notice: Identifiable, Equatable {
        enum Kind: Equatable {
            case info
            case success
            case error
        }

        let id = UUID()
        var text: String
        var kind: Kind
    }

    @Published var selectedTab: PanelTab = .screenshot
    @Published private(set) var screenRecordingGranted = ScreenCapturePermission.isGranted
    @Published private(set) var lastCapturedImage: NSImage?
    @Published private(set) var lastCaptureDate: Date?
    @Published var notice: Notice?

    private var noticeTask: Task<Void, Never>?

    private init() {}

    func refreshPermission() {
        let granted = ScreenCapturePermission.isGranted
        if granted != screenRecordingGranted {
            screenRecordingGranted = granted
            Log.app.info("Screen capture permission changed to \(granted, privacy: .public)")
        }
    }

    /// 截图模块完成后调用，用于面板预览与快捷操作。
    func recordCapture(_ image: NSImage) {
        lastCapturedImage = image
        lastCaptureDate = Date()
        selectedTab = .screenshot
    }

    func clearLastCapture() {
        lastCapturedImage = nil
        lastCaptureDate = nil
    }

    /// 4 秒后自动消失的轻提示。
    func flash(_ text: String, kind: Notice.Kind = .info) {
        let notice = Notice(text: text, kind: kind)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.notice?.id == notice.id {
                self?.notice = nil
            }
        }
    }
}
