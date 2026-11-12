import AppKit
import CoreGraphics

/// 把 macOS 标准窗口头部（红黄绿三个交通灯圆点）合成到截图成品顶部。
///
/// 位置：
/// - 区域 / 长截图在 `AnnotationDrawing.render` 里与标注、圆角一起拍平，
///   因此圆角会同时作用在「头部 + 内容」的整体外框上；
/// - 全屏截图没有覆盖层拍平步骤，由 `ScreenshotCoordinator` 直接调用 `decorate(_:scale:)`。
///
/// 头部背景按截取内容的平均亮度自适应深浅，尺寸按截图像素密度换算（28pt 高、12pt 圆点）。
enum WindowHeaderDecoration {
    /// 头部高度（点）。macOS 标准窗口标题栏约 28pt。
    static let heightInPoints: CGFloat = 28

    struct Style {
        /// 截图像素 / 点。
        let scale: CGFloat
        /// 深色头部（内容整体偏暗时）。
        let isDark: Bool

        var headerHeight: Int {
            max(1, Int((WindowHeaderDecoration.heightInPoints * max(scale, 0.5)).rounded()))
        }
    }

    /// 按底图平均亮度选择头部深浅，保证头部与截图内容观感一致。
    static func makeStyle(for image: CGImage, scale: CGFloat) -> Style {
        Style(scale: max(scale, 0.5), isDark: averageLuminance(of: image).map { $0 < 0.5 } ?? false)
    }

    /// 在 context 的指定矩形内绘制窗口头部（像素坐标，原点左下）。
    static func draw(in context: CGContext, headerRect: CGRect, style: Style) {
        guard headerRect.width >= 1, headerRect.height >= 1 else { return }
        let scale = max(style.scale, 0.5)

        context.saveGState()
        context.setShouldAntialias(true)

        let topColor: CGColor = style.isDark
            ? CGColor(srgbRed: 0.255, green: 0.255, blue: 0.263, alpha: 1)
            : CGColor(srgbRed: 0.969, green: 0.969, blue: 0.973, alpha: 1)
        let bottomColor: CGColor = style.isDark
            ? CGColor(srgbRed: 0.196, green: 0.196, blue: 0.204, alpha: 1)
            : CGColor(srgbRed: 0.910, green: 0.910, blue: 0.918, alpha: 1)

        context.saveGState()
        context.clip(to: headerRect)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [topColor, bottomColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: headerRect.minX, y: headerRect.maxY),
                end: CGPoint(x: headerRect.minX, y: headerRect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            context.setFillColor(bottomColor)
            context.fill(headerRect)
        }
        context.restoreGState()

        // 与内容交界的 1 物理像素分隔线。
        context.setFillColor(
            style.isDark
                ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.50)
                : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16)
        )
        context.fill(
            CGRect(x: headerRect.minX, y: headerRect.minY, width: headerRect.width, height: 1)
        )

        drawTrafficLights(in: context, headerRect: headerRect, style: style, scale: scale)
        context.restoreGState()
    }

    /// 把窗口头部直接合成到图片顶部（用于没有覆盖层拍平步骤的全屏截图）。
    static func decorate(_ image: CGImage, scale: CGFloat) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return image }
        let style = makeStyle(for: image, scale: scale)
        let headerHeight = style.headerHeight
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height + headerHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Log.screenshot.error("Unable to create window header bitmap context")
            return nil
        }

        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        draw(
            in: context,
            headerRect: CGRect(x: 0, y: image.height, width: image.width, height: headerHeight),
            style: style
        )
        guard let decorated = context.makeImage() else {
            Log.screenshot.error("Unable to make decorated capture image")
            return nil
        }
        return decorated
    }

    // MARK: - 绘制细节

    private struct Dot {
        let base: (red: CGFloat, green: CGFloat, blue: CGFloat)
    }

    /// macOS 标准交通灯配色（Big Sur 起）。
    private static let dots: [Dot] = [
        Dot(base: (1.00, 0.37, 0.34)),
        Dot(base: (1.00, 0.74, 0.18)),
        Dot(base: (0.16, 0.78, 0.25))
    ]

    private static func drawTrafficLights(
        in context: CGContext,
        headerRect: CGRect,
        style: Style,
        scale: CGFloat
    ) {
        let diameter = 12 * scale
        let spacing = 8 * scale
        let leftInset = 13 * scale
        let centerY = headerRect.midY
        let borderWidth = max(1, (0.5 * scale).rounded())

        for (index, dot) in dots.enumerated() {
            let centerX = headerRect.minX + leftInset + diameter / 2
                + CGFloat(index) * (diameter + spacing)
            let dotRect = CGRect(
                x: centerX - diameter / 2,
                y: centerY - diameter / 2,
                width: diameter,
                height: diameter
            )

            // 轻微的竖向渐变，避免纯色圆点显得扁平。
            let highlight: CGColor = CGColor(
                srgbRed: min(1, dot.base.red + (1 - dot.base.red) * 0.22),
                green: min(1, dot.base.green + (1 - dot.base.green) * 0.22),
                blue: min(1, dot.base.blue + (1 - dot.base.blue) * 0.22),
                alpha: 1
            )
            let base = CGColor(
                srgbRed: dot.base.red,
                green: dot.base.green,
                blue: dot.base.blue,
                alpha: 1
            )

            context.saveGState()
            context.addEllipse(in: dotRect)
            context.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [highlight, base] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: dotRect.midX, y: dotRect.maxY),
                    end: CGPoint(x: dotRect.midX, y: dotRect.minY),
                    options: []
                )
            } else {
                context.setFillColor(base)
                context.fill(dotRect)
            }
            context.restoreGState()

            context.setStrokeColor(
                CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14)
            )
            context.setLineWidth(borderWidth)
            context.strokeEllipse(
                in: dotRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            )
        }
    }

    private static func averageLuminance(of image: CGImage) -> CGFloat? {
        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        pixel.initialize(repeating: 0, count: 4)
        defer {
            pixel.deinitialize(count: 4)
            pixel.deallocate()
        }

        guard let context = CGContext(
            data: pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.01 else { return nil }
        let red = CGFloat(pixel[0]) / 255 / alpha
        let green = CGFloat(pixel[1]) / 255 / alpha
        let blue = CGFloat(pixel[2]) / 255 / alpha
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }
}
