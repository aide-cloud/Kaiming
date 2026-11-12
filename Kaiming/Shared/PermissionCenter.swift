import AppKit
import Combine
import Foundation

/// Kaiming 需要用户授权的全部系统权限。
///
/// 这是应用层唯一一份权限清单：设置「权限」页、截图失败提示、启动恢复流程
/// 都从这里读取同一套标题 / 说明 / 状态，不再各自硬编码文案或按钮。
enum KaimingPermission: String, CaseIterable, Identifiable, Sendable {
    /// 屏幕录制（TCC ScreenCapture）：截图、长截图、窗口截图的采集能力。
    case screenRecording
    /// 辅助功能（TCC Accessibility）：仅长截图的自动滚动需要。
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        }
    }

    /// 这项权限用来做什么。
    var purpose: String {
        switch self {
        case .screenRecording:
            "截取区域 / 窗口 / 全屏画面，以及长截图的逐帧采集都依赖 ScreenCaptureKit 读取屏幕内容。"
        case .accessibility:
            "长截图的「自动滚动」需要向目标窗口发送滚轮事件；手动滚动拼接不需要。"
        }
    }

    /// 未授权时的具体后果。
    var consequence: String {
        switch self {
        case .screenRecording:
            "未授权时截图不会返回任何内容，也不会弹出系统提示。"
        case .accessibility:
            "未授权时仍可截图与长截图，只是自动滚动不可用，需要手动滚动。"
        }
    }

    /// 授权后是否通常需要重启 Kaiming 才生效（TCC 只对新进程刷新）。
    var requiresRelaunch: Bool {
        switch self {
        case .screenRecording, .accessibility: true
        }
    }

    /// 对应的「系统设置 › 隐私与安全性」页面。
    var systemSettingsURL: URL? {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

/// 单次检测结果。
struct PermissionStatus: Equatable, Sendable {
    var isGranted: Bool
    /// 最近一次真实检测的时间；nil 表示本次运行还没有完成过检测。
    var checkedAt: Date?
}

/// 系统权限的唯一应用层入口。
///
/// 职责边界：
/// - 状态：在 `Shared/` 里汇总，供设置「权限」页与失败提示读取；
/// - 申请：只有设置「权限」页会主动调用 `request(_:)`（启动时的 TCC 自动恢复也走这里）；
/// - 设置：统一跳转系统设置的对应隐私页；
/// - 重置：屏幕录制 TCC 记录绑定旧构建签名时，提供一键清除后重新授权。
///
/// 底层仍复用 `ScreenCapturePermission` / `AccessibilityPermission` 两个 TCC 包装，
/// 不重复实现任何系统调用。
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    /// 每项权限的最新状态。UI 通过 `status(for:)` 读取，dict 更新本身会触发刷新。
    @Published private(set) var statuses: [KaimingPermission: PermissionStatus]
    /// 是否正在进行一次「真实能力检测」（屏幕录制的 SCK 探测是异步的）。
    @Published private(set) var isDetecting = false

    private var detectTask: Task<Void, Never>?

    private init() {
        statuses = [
            .screenRecording: PermissionStatus(isGranted: ScreenCapturePermission.isGranted, checkedAt: nil),
            .accessibility: PermissionStatus(isGranted: AccessibilityPermission.isTrusted, checkedAt: nil),
        ]
    }

    // MARK: - 读取

    func status(for permission: KaimingPermission) -> PermissionStatus {
        statuses[permission] ?? PermissionStatus(isGranted: false, checkedAt: nil)
    }

    var grantedCount: Int {
        KaimingPermission.allCases.filter { status(for: $0).isGranted }.count
    }

    var allGranted: Bool {
        KaimingPermission.allCases.allSatisfy { status(for: $0).isGranted }
    }

    // MARK: - 检测

    /// 同步快速刷新：只读 preflight / AXIsProcessTrusted，不弹系统框、不触发采集。
    /// 应用启动与回到前台时调用，保证菜单栏/设置页看到的是最新状态。
    func refresh() {
        let screen = ScreenCapturePermission.isGranted
        let accessibility = AccessibilityPermission.isTrusted
        update(.screenRecording, granted: screen)
        update(.accessibility, granted: accessibility)
        Log.app.info(
            "Permission refresh: screenRecording=\(screen, privacy: .public) accessibility=\(accessibility, privacy: .public)"
        )
    }

    /// 真实能力检测：屏幕录制用 ScreenCaptureKit 实际采集一次（避免 preflight 假阴性），
    /// 辅助功能读 AXIsProcessTrusted。不会弹出系统授权框。
    func detectAll() {
        guard !isDetecting else {
            Log.app.info("Permission detection already in progress; ignoring duplicate request")
            return
        }
        isDetecting = true
        detectTask?.cancel()
        detectTask = Task { @MainActor [weak self] in
            let screenGranted = await ScreenCapturePermission.verifyAccess()
            let accessibility = AccessibilityPermission.isTrusted
            guard let self else { return }
            self.update(.screenRecording, granted: screenGranted)
            self.update(.accessibility, granted: accessibility)
            self.isDetecting = false
            Log.app.info(
                "Permission detection finished: screenRecording=\(screenGranted, privacy: .public) accessibility=\(accessibility, privacy: .public)"
            )
        }
    }

    // MARK: - 申请 / 设置 / 重置

    /// 弹系统授权流程并返回调用后的即时状态。
    /// 屏幕录制的 TCC 授权通常要重启进程才生效，返回 true 只代表系统已记录授权。
    @discardableResult
    func request(_ permission: KaimingPermission) -> Bool {
        let granted: Bool
        switch permission {
        case .screenRecording:
            // 屏幕录制请求后系统可能只弹一次；随后用真实 SCK 能力再检测一次。
            granted = ScreenCapturePermission.request()
            update(.screenRecording, granted: granted)
            detectAll()
        case .accessibility:
            granted = AccessibilityPermission.prompt()
            update(.accessibility, granted: granted)
        }
        Log.app.info(
            "Permission requested: \(permission.rawValue, privacy: .public) granted=\(granted, privacy: .public)"
        )
        return granted
    }

    /// 打开系统设置的对应隐私页（授权/撤销都在系统里完成）。
    func openSystemSettings(_ permission: KaimingPermission) {
        guard let url = permission.systemSettingsURL else {
            Log.app.error("No system settings URL for \(permission.rawValue, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
        Log.app.info("Opened system settings for \(permission.rawValue, privacy: .public)")
    }

    /// 清除屏幕录制 TCC 记录：用于“系统设置显示已授权但当前构建仍失败”的旧签名残留。
    /// 成功后调用方需要提示用户重新授权并重启应用。
    @discardableResult
    func resetScreenRecording() -> Bool {
        let ok = ScreenCapturePermission.resetTCCEntry()
        if ok {
            update(.screenRecording, granted: false)
            Log.app.info("Screen recording TCC entry reset")
        } else {
            Log.app.error("Failed to reset screen recording TCC entry")
        }
        return ok
    }

    // MARK: - 私有

    private func update(_ permission: KaimingPermission, granted: Bool) {
        statuses[permission] = PermissionStatus(isGranted: granted, checkedAt: Date())
    }
}
