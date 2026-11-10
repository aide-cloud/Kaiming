import AppKit
import CoreGraphics

/// 圆角遮罩的共用计算，覆盖层预览与最终导出都使用它。
enum RoundedMask {
    static func clampedRadius(_ radius: CGFloat, in rect: CGRect) -> CGFloat {
        max(0, min(radius, min(rect.width, rect.height) / 2))
    }

    static func path(for rect: CGRect, radius: CGFloat) -> CGPath {
        let clamped = clampedRadius(radius, in: rect)
        return CGPath(
            roundedRect: rect,
            cornerWidth: clamped,
            cornerHeight: clamped,
            transform: nil
        )
    }
}

/// 标注绘制与拍平。
///
/// 覆盖层预览与最终导出共用同一套绘制代码：预览时 `origin` 是选区在屏幕上的左下角、
/// 上下文未缩放；导出时上下文按「像素 / 点」缩放、`origin` 为零，因此两者视觉一致。
enum AnnotationDrawing {
    static func draw(annotation: Annotation, in context: CGContext, origin: CGPoint) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.setShouldAntialias(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(annotation.lineWidth)
        context.setStrokeColor(annotation.color.nsColor.cgColor)
        context.setFillColor(annotation.color.nsColor.cgColor)

        switch annotation.kind {
        case .rectangle:
            let rect = AnnotationGeometry.normalizedRect(from: annotation.start, to: annotation.end)
            context.stroke(rect)

        case .arrow:
            context.move(to: annotation.start)
            context.addLine(to: annotation.end)
            context.strokePath()

            let headLength = max(10, annotation.lineWidth * 4)
            let headWidth = max(9, annotation.lineWidth * 3.5)
            let head = AnnotationGeometry.arrowHead(
                from: annotation.start,
                to: annotation.end,
                headLength: headLength,
                headWidth: headWidth
            )
            if head.count == 3 {
                context.move(to: head[0])
                context.addLine(to: head[1])
                context.addLine(to: head[2])
                context.closePath()
                context.fillPath()
            }

        case .text:
            guard let text = annotation.text, !text.isEmpty else { break }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: AnnotationGeometry.textFontSize, weight: .semibold),
                .foregroundColor: annotation.color.nsColor,
            ]
            NSAttributedString(string: text, attributes: attributes).draw(at: annotation.start)
        }

        context.restoreGState()
    }

    /// 把「冻结/窗口/长截图底图 + 标注」拍平为一张新的位图。
    ///
    /// - Parameters:
    ///   - boundsInPoints: 底图对应的点尺寸，标注坐标基于它。
    ///   - cornerRadius: 圆角半径（点）。大于 0 时圆角外透明，需用 PNG 保留 alpha。
    /// - Returns: 拍平后的位图；没有标注且圆角为 0 时直接返回底图。
    static func render(
        baseImage: CGImage,
        annotations: [Annotation],
        boundsInPoints: CGSize,
        cornerRadius: CGFloat = 0
    ) -> CGImage? {
        let radius = max(0, cornerRadius)
        guard !annotations.isEmpty || radius > 0 else { return baseImage }
        guard boundsInPoints.width > 0, boundsInPoints.height > 0 else { return baseImage }

        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Log.screenshot.error("Unable to create annotation bitmap context")
            return nil
        }

        context.interpolationQuality = .high
        let scaleX = CGFloat(width) / boundsInPoints.width
        let scaleY = CGFloat(height) / boundsInPoints.height

        if radius > 0 {
            // 半径按点换算到像素；context 尚未缩放，所以这里直接用像素半径。
            let pixelRadius = min(
                radius * min(scaleX, scaleY),
                min(CGFloat(width), CGFloat(height)) / 2
            )
            let pixelRect = CGRect(x: 0, y: 0, width: width, height: height)
            context.addPath(RoundedMask.path(for: pixelRect, radius: pixelRadius))
            context.clip()
        }

        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scaleX, y: scaleY)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        for annotation in annotations {
            draw(annotation: annotation, in: context, origin: .zero)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else {
            Log.screenshot.error("Unable to make flattened annotation image")
            return nil
        }
        return image
    }
}
