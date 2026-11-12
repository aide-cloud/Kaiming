import SwiftUI

/// 长截图采集过程中的进度状态。
@MainActor
final class LongCaptureProgressModel: ObservableObject {
    @Published var modeTitle = "长截图 · 手动滚动"
    @Published var statusText = "正在准备…"
    @Published var dimensionText = ""
    @Published var hintText = ""
    @Published var progress: Double = 0
    /// HUD 是否已切换到自动滚动。
    @Published var isAutomatic = false
    /// 辅助功能未授权等提示，显示在 HUD 内。
    @Published var message: String?
}

/// 采集期间悬浮在屏幕顶部的小面板。
///
/// 覆盖层窗口在采集期间会 orderOut，只保留一个 ignoresMouseEvents 的边框窗口；
/// 这个面板保留鼠标交互，方便网页抢走焦点时仍能点「完成 / 取消」。
struct LongCaptureHUD: View {
    static let preferredSize = CGSize(width: 520, height: 150)

    @ObservedObject var model: LongCaptureProgressModel
    let onAutomatic: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.modeTitle)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 6)
                    Text(model.dimensionText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(model.statusText)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 3)

                if let message = model.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(model.hintText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if model.isAutomatic {
                        Label("自动滚动中", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("自动滚动") {
                            onAutomatic()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("在「设置 → 权限」中申请辅助功能权限后，切换为 CGEvent 自动滚动，沿用已拼接内容")
                    }

                    Spacer(minLength: 4)

                    Button("完成") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .help("结束采集并使用已采集内容生成拼接图（Return）")

                    Button("取消") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("放弃本次长截图（Esc）")
                }
            }
        }
        .padding(12)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 10, y: 3)
    }
}
