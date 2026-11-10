import AppKit
import CoreGraphics

/// 长截图采集期间只画选区边框的覆盖窗口。
///
/// 特点：
/// - `.screenSaver` 级别，覆盖在实时页面之上；
/// - `ignoresMouseEvents = true`，不拦截滚轮/点击，用户可以在实时页面上滚动；
/// - 透明背景，只绘制圆角边框与尺寸标签，不遮挡页面内容；
/// - 属于本应用，SCK 的 `excludingApplications` 会把它排除在截图之外。
@MainActor
final class LongCaptureBorderWindow: NSWindow {
    /// 边框窗口永远不抢键盘焦点，HUD 才是采集期间的 key window。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // 允许覆盖菜单栏/Dock，保持选区边框完整可见。
        frameRect
    }
}

/// 只绘制圆角选区边框和尺寸的透明视图。
@MainActor
final class LongCaptureBorderView: NSView {
    struct Configuration: Equatable {
        /// 屏幕局部坐标（与覆盖层一致，左下角为原点）。
        var selectionRect: CGRect
        var scale: CGFloat
        var cornerRadius: CGFloat
    }

    private var configuration: Configuration?

    init(frame: NSRect, configuration: Configuration) {
        self.configuration = configuration
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isOpaque: Bool { false }

    func update(configuration: Configuration) {
        self.configuration = configuration
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let configuration,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = configuration.selectionRect
        guard rect.width > 0, rect.height > 0 else { return }

        let radius = RoundedMask.clampedRadius(configuration.cornerRadius, in: rect)
        let borderRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let borderRadius = RoundedMask.clampedRadius(max(0, radius - 0.75), in: borderRect)

        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.addPath(RoundedMask.path(for: borderRect, radius: borderRadius))
        context.strokePath()
        context.restoreGState()

        drawSizeLabel(configuration: configuration, context: context)
    }

    private func drawSizeLabel(configuration: Configuration, context: CGContext) {
        let rect = configuration.selectionRect
        let pointsWidth = Int(rect.width.rounded())
        let pointsHeight = Int(rect.height.rounded())
        let pixelsWidth = Int((rect.width * configuration.scale).rounded())
        let pixelsHeight = Int((rect.height * configuration.scale).rounded())
        var text = "\(pointsWidth) × \(pointsHeight) pt · \(pixelsWidth) × \(pixelsHeight) px"
        if configuration.cornerRadius > 0 {
            text += " · 圆角 \(Int(configuration.cornerRadius.rounded()))pt"
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 6, height: 3)
        let boxSize = CGSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
        let bounds = self.bounds
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 5)
        if origin.y + boxSize.height > bounds.maxY - 4 {
            origin.y = max(bounds.minY + 4, rect.minY - boxSize.height - 5)
        }
        if origin.x + boxSize.width > bounds.maxX - 4 {
            origin.x = max(bounds.minX + 4, bounds.maxX - boxSize.width - 4)
        }
        let box = CGRect(origin: origin, size: boxSize)

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.68).cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        context.restoreGState()
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }
}
