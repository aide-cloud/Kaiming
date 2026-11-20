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

/// 马赛克取样来源。
///
/// 覆盖层预览取「冻结屏图 / 窗口图」，导出取裁剪后的底图；两者都通过
/// `pointSize` 与 `pointOrigin` 把标注的点坐标映射到源图像素，保证预览与成品一致。
struct MosaicSource {
    let image: CGImage
    /// 源图覆盖的点尺寸。
    let pointSize: CGSize
    /// 源图左下角在（含 origin 偏移的）标注坐标系中的位置。
    let pointOrigin: CGPoint
}

/// 马赛克的像素化计算：把目标区域降采样成小块，再由调用方用最近邻放大。
enum MosaicRenderer {
    /// 马赛克块边长（点）。按底图像素密度换算，不同缩放屏幕上视觉大小一致。
    static let blockSizeInPoints: CGFloat = 12

    /// 生成矩形区域的马赛克小块图；返回 nil 表示无法取样（调用方需兜底）。
    static func pixelatedImage(
        for rect: CGRect,
        origin: CGPoint,
        source: MosaicSource?
    ) -> CGImage? {
        guard let source,
              source.image.width > 0, source.image.height > 0,
              source.pointSize.width > 0, source.pointSize.height > 0,
              rect.width > 0, rect.height > 0 else { return nil }

        let absolute = rect.offsetBy(dx: origin.x, dy: origin.y)
        guard absolute.width > 0, absolute.height > 0 else { return nil }

        let scaleX = CGFloat(source.image.width) / source.pointSize.width
        let scaleY = CGFloat(source.image.height) / source.pointSize.height

        // CGImage.cropping(to:) 使用「左上角为原点、y 向下」的像素坐标，这里做 y 翻转。
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(source.image.width),
            height: CGFloat(source.image.height)
        )
        let pixelRect = CGRect(
            x: (absolute.minX - source.pointOrigin.x) * scaleX,
            y: (source.pointSize.height - (absolute.maxY - source.pointOrigin.y)) * scaleY,
            width: absolute.width * scaleX,
            height: absolute.height * scaleY
        ).integral
        let cropRect = pixelRect.intersection(imageBounds).integral
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = source.image.cropping(to: cropRect) else { return nil }

        let blockPixels = max(1, blockSizeInPoints * (scaleX + scaleY) / 2)
        let columns = max(1, Int((CGFloat(cropped.width) / blockPixels).rounded()))
        let rows = max(1, Int((CGFloat(cropped.height) / blockPixels).rounded()))

        guard let context = CGContext(
            data: nil,
            width: columns,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Log.screenshot.error("Unable to create mosaic bitmap context")
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return context.makeImage()
    }
}

/// 标注绘制与拍平。
///
/// 覆盖层预览与最终导出共用同一套绘制代码：预览时 `origin` 是选区在屏幕上的左下角、
/// 上下文未缩放；导出时上下文按「像素 / 点」缩放、`origin` 为零，因此两者视觉一致。
enum AnnotationDrawing {
    static func draw(
        annotation: Annotation,
        in context: CGContext,
        origin: CGPoint,
        mosaicSource: MosaicSource? = nil
    ) {
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

        case .mosaic:
            let rect = AnnotationGeometry.normalizedRect(from: annotation.start, to: annotation.end)
            guard let patch = MosaicRenderer.pixelatedImage(for: rect, origin: origin, source: mosaicSource) else {
                // 没有可用的底图像素时退化为纯色遮挡，避免敏感内容直接漏出。
                context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
                context.fill(rect)
                break
            }
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(patch, in: rect)
            context.restoreGState()

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
    ///   - addsWindowHeader: 是否在内容上方合成 macOS 标准窗口头部（红黄绿圆点）。
    ///     头部计入画布高度，圆角同时作用于「头部 + 内容」的整体外框。
    /// - Returns: 拍平后的位图；没有标注、圆角为 0 且不加头部时直接返回底图。
    static func render(
        baseImage: CGImage,
        annotations: [Annotation],
        boundsInPoints: CGSize,
        cornerRadius: CGFloat = 0,
        addsWindowHeader: Bool = false
    ) -> CGImage? {
        let radius = max(0, cornerRadius)
        guard boundsInPoints.width > 0, boundsInPoints.height > 0 else { return baseImage }

        let contentWidth = baseImage.width
        let contentHeight = baseImage.height
        guard contentWidth > 0, contentHeight > 0 else { return nil }

        let scaleX = CGFloat(contentWidth) / boundsInPoints.width
        let scaleY = CGFloat(contentHeight) / boundsInPoints.height
        let headerStyle = addsWindowHeader
            ? WindowHeaderDecoration.makeStyle(for: baseImage, scale: (scaleX + scaleY) / 2)
            : nil
        let headerHeight = headerStyle?.headerHeight ?? 0

        guard !annotations.isEmpty || radius > 0 || headerHeight > 0 else { return baseImage }

        let width = contentWidth
        let height = contentHeight + headerHeight
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

        context.draw(
            baseImage,
            in: CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        )

        context.saveGState()
        context.scaleBy(x: scaleX, y: scaleY)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let mosaicSource = MosaicSource(
            image: baseImage,
            pointSize: boundsInPoints,
            pointOrigin: .zero
        )
        for annotation in annotations {
            draw(annotation: annotation, in: context, origin: .zero, mosaicSource: mosaicSource)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()

        if let headerStyle {
            WindowHeaderDecoration.draw(
                in: context,
                headerRect: CGRect(
                    x: 0,
                    y: contentHeight,
                    width: width,
                    height: headerHeight
                ),
                style: headerStyle
            )
        }

        guard let image = context.makeImage() else {
            Log.screenshot.error("Unable to make flattened annotation image")
            return nil
        }
        return image
    }
}
