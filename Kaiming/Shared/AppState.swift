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
    /// 是否完成过一次真实 SCK 能力探测（完成前不显示“未授权”横幅，避免假阴性闪烁）。
    @Published private(set) var permissionProbeFinished = false
    @Published private(set) var lastCapturedImage: NSImage?
    @Published private(set) var lastCaptureDate: Date?
    @Published var notice: Notice?

    private var noticeTask: Task<Void, Never>?
    private var isProbingPermission = false

    private init() {}

    /// 同步刷新 preflight；若 preflight 为 false，再用真实 SCK 探测一次，避免假阴性。
    func refreshPermission() {
        let preflight = ScreenCapturePermission.isGranted
        if preflight {
            screenRecordingGranted = true
            permissionProbeFinished = true
            return
        }
        probePermission()
    }

    /// 真实 SCK 能力探测（不会弹系统授权框，只判断当前构建是否真的能采集）。
    func probePermission() {
        guard !isProbingPermission else { return }
        isProbingPermission = true
        Task { @MainActor [weak self] in
            let granted = await ScreenCapturePermission.verifyAccess()
            guard let self else { return }
            self.isProbingPermission = false
            self.screenRecordingGranted = granted
            self.permissionProbeFinished = true
            Log.app.info("Screen capture probe finished: \(granted, privacy: .public)")
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
