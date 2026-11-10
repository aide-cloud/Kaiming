import Foundation

/// 长截图停止原因。纯数据 + 文案，便于独立合成测试。
enum LongCaptureStopReason: Equatable, Sendable {
    case userFinished
    case noChange
    case manualIdle
    case noOverlap
    case heightLimit
    case frameLimit
    case failed

    var message: String {
        switch self {
        case .userFinished:
            "长截图已生成，请确认后保存。"
        case .noChange:
            "页面内容没有变化，已停止：可能已到页面顶部/底部，或自动滚动未生效。已保留当前采集内容，可确认后保存。"
        case .manualIdle:
            "长时间没有检测到页面滚动，已停止并保留当前内容。请在预览中确认，或取消后重新进入长截图。"
        case .noOverlap:
            "未检测到与上一屏的重叠区域，已停止：滚动幅度可能过大，或页面含固定标题栏。已保留当前采集内容，可确认后保存。"
        case .heightLimit:
            "已达到 20000px 高度上限，已停止并保留当前内容。"
        case .frameLimit:
            "已达到采集屏数上限，已停止并保留当前内容。"
        case .failed:
            "当前画面无法拼接，已停止。可取消后重试，或缩小选区避开动画/固定标题栏。"
        }
    }
}

enum LongCaptureDecision: Equatable, Sendable {
    case continueCapture
    case stop(LongCaptureStopReason)
}

/// 长截图采集状态机（纯逻辑，不依赖 AppKit / SCK / 屏幕）。
///
/// - 默认总是手动滚动，符合「点击长截图 → 立即手动采集」的交互；
/// - HUD 点「自动滚动」后，只有辅助功能已授权才切换，并重置空闲计数；
/// - 自动模式连续 2 次无变化停止；手动模式长时间（默认 60 次采样）无变化停止；
/// - 无重叠 / 高度上限 / 拼接失败 / 采集步数上限都会停止。
struct LongCaptureSessionState {
    private(set) var mode: LongScreenshotMode
    private(set) var idleSteps = 0
    private(set) var stepCount = 0

    let maximumSteps: Int
    let automaticIdleThreshold: Int
    let manualIdleThreshold: Int

    init(
        mode: LongScreenshotMode = .manual,
        maximumSteps: Int = 300,
        automaticIdleThreshold: Int = 2,
        manualIdleThreshold: Int = 60
    ) {
        self.mode = mode
        self.maximumSteps = max(1, maximumSteps)
        self.automaticIdleThreshold = max(1, automaticIdleThreshold)
        self.manualIdleThreshold = max(1, manualIdleThreshold)
    }

    var isAutomatic: Bool { mode == .automatic }

    /// 只有已授权且当前是手动模式时才允许切换；切换成功会清空空闲计数。
    @discardableResult
    mutating func requestAutomatic(accessibilityTrusted: Bool) -> Bool {
        guard accessibilityTrusted, mode == .manual else { return false }
        mode = .automatic
        idleSteps = 0
        return true
    }

    /// 记录一帧拼接结果；返回继续采集还是停止及原因。
    mutating func record(_ result: LongScreenshotComposer.AppendResult) -> LongCaptureDecision {
        switch result {
        case .firstFrame, .appended:
            idleSteps = 0
            return .continueCapture

        case .noChange:
            idleSteps += 1
            if mode == .automatic {
                return idleSteps >= automaticIdleThreshold ? .stop(.noChange) : .continueCapture
            }
            return idleSteps >= manualIdleThreshold ? .stop(.manualIdle) : .continueCapture

        case .noOverlap:
            return .stop(.noOverlap)
        case .heightLimit:
            return .stop(.heightLimit)
        case .failed:
            return .stop(.failed)
        }
    }

    /// 每完成一次采集调用；达到步数上限时停止。
    mutating func markStep() -> LongCaptureDecision {
        stepCount += 1
        return stepCount >= maximumSteps ? .stop(.frameLimit) : .continueCapture
    }
}
