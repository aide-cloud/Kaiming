import SwiftUI

/// 菜单栏面板内共享的视觉 token，保证截图 / 剪贴板 / 系统三页使用同一套卡片语言。
enum PanelPalette {
    static let mint = Color.mint
    static let sky = Color.blue
    static let violet = Color.purple
    static let amber = Color.orange
    static let rose = Color.red
}

extension View {
    /// 面板内的大卡片：9–10pt 圆角、5% 叠色、6% 描边。
    func panelCard(padding: CGFloat = 9) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    /// 指标 / 模式的小磁贴。
    func panelTile(padding: CGFloat = 9) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}

/// 带渐变底色的图标徽章，和系统页的缓存 / 指标图标保持同一语言。
struct PanelIconBadge: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 36

    private var cornerRadius: CGFloat { max(6, size * 0.26) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.30), tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

/// 小标题：图标 + 标题 + 可选说明，供卡片内部使用。
struct PanelHeader: View {
    var icon: String
    var title: String
    var caption: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// 紧凑的信息胶囊（类型、快捷键、能力标签等）。
struct PanelChip: View {
    var icon: String?
    var text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .medium))
            }
            Text(text)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .lineLimit(1)
        .fixedSize()
    }
}
