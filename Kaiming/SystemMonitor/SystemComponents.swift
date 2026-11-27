import SwiftUI

// MARK: - 视觉 token

enum SystemPalette {
    static let mint = Color.mint
    static let amber = Color.orange
    static let sky = Color.blue
    static let violet = Color.purple
    static let rose = Color.red

    static func pressure(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: mint
        case .warning: amber
        case .critical: rose
        }
    }
}

// MARK: - 进度条

struct SystemMeter: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: max(0, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(SystemFormat.percent(fraction))
    }
}

struct MemoryMeterSegment: Identifiable {
    let id: String
    var fraction: Double
    var color: Color
}

/// 内存占用分段：应用 / 联动 / 压缩 / 剩余，按总内存比例铺满整条。
struct StackedMemoryMeter: View {
    var segments: [MemoryMeterSegment]
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, proxy.size.width * CGFloat(min(max(segment.fraction, 0), 1)) - 1))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.07))
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("内存占用构成")
    }
}

// MARK: - 网络曲线

struct NetworkSparkline: View {
    var points: [NetworkPoint]
    var height: CGFloat = 46

    private var peak: Double {
        let values = points.flatMap { [$0.download, $0.upload] }
        return max(values.max() ?? 0, 1024)
    }

    private var hasTraffic: Bool {
        points.contains { $0.download > 1 || $0.upload > 1 }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if points.count > 1, hasTraffic {
                    area(values: points.map(\.download), size: proxy.size).fill(
                        LinearGradient(
                            colors: [SystemPalette.mint.opacity(0.28), SystemPalette.mint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    line(values: points.map(\.download), size: proxy.size)
                        .stroke(SystemPalette.mint, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    line(values: points.map(\.upload), size: proxy.size)
                        .stroke(SystemPalette.sky.opacity(0.9), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                } else {
                    Text(points.count > 1 ? "当前没有网络流量" : "正在采样…")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func line(values: [Double], size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let ratio = min(max(value / peak, 0), 1)
            let y = size.height - CGFloat(ratio) * (size.height - 4) - 2
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func area(values: [Double], size: CGSize) -> Path {
        var path = line(values: values, size: size)
        guard values.count > 1 else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - 指标卡片

struct SystemStatTile: View {
    var icon: String
    var title: String
    var value: String
    var caption: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
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

struct LegendDot: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
