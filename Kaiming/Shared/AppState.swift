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
        case system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenshot: "截图"
            case .clipboard: "剪贴板"
            case .system: "系统"
            }
        }

        var symbolName: String {
            switch self {
            case .screenshot: "crop"
            case .clipboard: "doc.on.clipboard"
            case .system: "cpu"
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
    /// 屏幕录制权限的镜像状态；唯一来源是 `PermissionCenter`（设置「权限」页读同一份）。
    @Published private(set) var screenRecordingGranted = ScreenCapturePermission.isGranted
    /// 是否完成过一次权限检测（完成前不显示“未授权”类提示，避免假阴性闪烁）。
    @Published private(set) var permissionProbeFinished = false
    @Published private(set) var lastCapturedImage: NSImage?
    @Published private(set) var lastCaptureDate: Date?
    @Published var notice: Notice?

    private var noticeTask: Task<Void, Never>?
    private var permissionCancellable: AnyCancellable?

    private init() {
        permissionCancellable = PermissionCenter.shared.$statuses
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let status = PermissionCenter.shared.status(for: .screenRecording)
                    self.screenRecordingGranted = status.isGranted
                    self.permissionProbeFinished = status.checkedAt != nil
                }
            }
    }

    /// 同步刷新 preflight（不触发采集，面板每次打开/回到前台都能快速更新）。
    /// 真正的 ScreenCaptureKit 能力检测由 `probePermission()` / 设置 → 权限 的「检测」执行。
    func refreshPermission() {
        PermissionCenter.shared.refresh()
    }

    /// 真实能力探测（不会弹系统授权框，只判断当前构建是否真的能采集）。
    func probePermission() {
        PermissionCenter.shared.detectAll()
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
