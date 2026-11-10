import SwiftUI

/// 长截图入口条的状态。
@MainActor
final class LongCaptureOptionsModel: ObservableObject {
    @Published var accessibilityTrusted: Bool
    @Published var message: String?

    init() {
        accessibilityTrusted = AccessibilityPermission.isTrusted
    }
}

/// 长截图采集过程中的进度状态。
@MainActor
final class LongCaptureProgressModel: ObservableObject {
    @Published var modeTitle = "长截图"
    @Published var statusText = "正在准备…"
    @Published var dimensionText = ""
    @Published var hintText = ""
    @Published var progress: Double = 0
}

/// 选定区域后、开始长截图前的模式选择条。
struct LongCaptureBar: View {
    static let preferredSize = CGSize(width: 640, height: 92)

    @ObservedObject var model: LongCaptureOptionsModel
    let onAutomatic: () -> Void
    let onManual: () -> Void
    let onBack: () -> Void
    let onOpenAccessibilitySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("长截图")
                        .font(.system(size: 12, weight: .semibold))
                    Text("自动滚动拼接需要辅助功能权限；也可以手动滚动，应用会定时截帧并拼接。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("自动滚动") {
                    onAutomatic()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("用 CGEvent 滚动页面并自动截帧；需要辅助功能权限")

                Button("手动滚动") {
                    onManual()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("由你滚动页面，应用定时截帧，Return 完成")

                Button("返回") {
                    onBack()
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("返回标注工具栏（Esc）")
            }

            HStack(spacing: 6) {
                Image(systemName: model.accessibilityTrusted
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(model.accessibilityTrusted ? .green : .orange)

                Text(model.message ?? defaultHint)
                    .font(.system(size: 10))
                    .foregroundStyle(model.accessibilityTrusted ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                if !model.accessibilityTrusted {
                    Button("打开辅助功能设置") {
                        onOpenAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 8, y: 2)
    }

    private var defaultHint: String {
        if model.accessibilityTrusted {
            return "辅助功能已授权，可自动滚动；也可以改用手动滚动拼接。"
        }
        return "自动滚动会先请求辅助功能权限；未授权前可先用手动滚动拼接。"
    }
}

/// 采集期间悬浮在屏幕顶部的小面板。
///
/// 这不是覆盖层：覆盖层窗口在采集期间会 `ignoresMouseEvents` 并 orderOut，
/// 这个面板保留鼠标交互，方便网页抢走焦点时仍能点「完成 / 取消」。
struct LongCaptureHUD: View {
    static let preferredSize = CGSize(width: 460, height: 122)

    @ObservedObject var model: LongCaptureProgressModel
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

                Text(model.hintText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 5) {
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
