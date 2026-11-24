import AppKit
import CoreGraphics

/// 标注工具。
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case select
    case pen
    case rectangle
    case arrow
    case text
    case mosaic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "调整选区 / 编辑标注"
        case .pen: "画笔（手写）"
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .text: "文字"
        case .mosaic: "马赛克"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "scribble.variable"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

/// 标注颜色。以 sRGB 分量保存，便于跨线程/持久化，不直接持有 NSColor。
struct AnnotationColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// 固定调色板：避免弹出系统颜色面板（颜色面板层级低于全屏覆盖层，会被遮住）。
    static let palette: [AnnotationColor] = [
        AnnotationColor(red: 1.00, green: 0.23, blue: 0.19),
        AnnotationColor(red: 1.00, green: 0.58, blue: 0.00),
        AnnotationColor(red: 1.00, green: 0.84, blue: 0.00),
        AnnotationColor(red: 0.20, green: 0.78, blue: 0.35),
        AnnotationColor(red: 0.00, green: 0.48, blue: 1.00),
        AnnotationColor(red: 1.00, green: 1.00, blue: 1.00),
    ]
}

/// 一条标注。坐标均为「目标图左下角为原点、y 向上」的点坐标。
struct Annotation: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case rectangle
        case arrow
        case text
        case mosaic
        /// 手写笔迹：由连续的采样点连成的自由曲线。
        case pen
    }

    let id: UUID
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: AnnotationColor
    var lineWidth: CGFloat
    var text: String?
    /// 手写笔迹的采样点（含起点）。其它标注类型为空。
    var points: [CGPoint]

    init(
        id: UUID = UUID(),
        kind: Kind,
        start: CGPoint,
        end: CGPoint? = nil,
        color: AnnotationColor,
        lineWidth: CGFloat = 3,
        text: String? = nil,
        points: [CGPoint] = []
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.points = points
    }
}

/// 标注的纯几何计算。
enum AnnotationGeometry {
    static let textFontSize: CGFloat = 16
    /// 小于该尺寸的拖拽不生成矩形/箭头，避免双击或误触留下一个点。
    static let minimumDrawingSize: CGFloat = 3
    /// 手写笔迹的最小采样间距（点）：更近的鼠标事件并入上一个点。
    static let minimumPenSampleDistance: CGFloat = 0.6
    /// 手写笔迹的默认线宽（点），比矩形/箭头略粗，接近日常手写笔。
    static let penLineWidth: CGFloat = 4
    /// 点击选中已有标注的命中容差（点）。
    static let hitTolerance: CGFloat = 6
    /// 选中标注后编辑手柄的显示边长与命中容差（点）。
    static let editHandleSize: CGFloat = 7
    static let editHandleHitTolerance: CGFloat = 9
    /// 缩放已有标注时的最小尺寸（点）。
    static let minimumEditSize: CGFloat = 4

    /// 选中标注后的编辑手柄。矩形/马赛克使用 8 个包围盒手柄，
    /// 箭头使用起点/终点两个手柄，文字与手写笔迹只支持整体拖动。
    enum EditHandle: Hashable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case arrowStart, arrowEnd

        /// 复用选区缩放的几何计算。
        var screenHandle: ScreenGeometry.Handle? {
            switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            case .arrowStart, .arrowEnd: nil
            }
        }
    }

    /// 标注绘制使用的字体。测量、预览与最终导出共用，避免尺寸漂移。
    static var textFont: NSFont {
        NSFont.systemFont(ofSize: textFontSize, weight: .semibold)
    }

    static func textSize(for text: String) -> CGSize {
        guard !text.isEmpty else { return .zero }
        return (text as NSString).size(withAttributes: [.font: textFont])
    }

    static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func clampedPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    static func clampedRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 箭头尖端两侧的三角形顶点。
    static func arrowHead(
        from start: CGPoint,
        to end: CGPoint,
        headLength: CGFloat,
        headWidth: CGFloat
    ) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return [] }
        let ux = dx / length
        let uy = dy / length
        let baseX = end.x - ux * headLength
        let baseY = end.y - uy * headLength
        let nx = -uy
        let ny = ux
        let halfWidth = headWidth / 2
        return [
            end,
            CGPoint(x: baseX + nx * halfWidth, y: baseY + ny * halfWidth),
            CGPoint(x: baseX - nx * halfWidth, y: baseY - ny * halfWidth),
        ]
    }

    /// 拖拽出来的标注是否足够大，值得记录。
    /// - Parameter points: 手写笔迹的采样点；其它标注类型传空数组。
    static func isMeaningful(
        kind: Annotation.Kind,
        start: CGPoint,
        end: CGPoint,
        points: [CGPoint] = []
    ) -> Bool {
        switch kind {
        case .rectangle, .arrow:
            return abs(end.x - start.x) >= minimumDrawingSize || abs(end.y - start.y) >= minimumDrawingSize
        case .mosaic:
            // 马赛克需要真实覆盖一块区域，细条没有遮挡意义。
            return abs(end.x - start.x) >= minimumDrawingSize && abs(end.y - start.y) >= minimumDrawingSize
        case .pen:
            // 至少两个采样点且达到最小长度，避免单击/误触留下一个点。
            guard points.count >= 2 else { return false }
            return freehandLength(points) >= minimumDrawingSize
        case .text:
            return true
        }
    }

    /// 手写笔迹的累计长度（点）。
    static func freehandLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var length: CGFloat = 0
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            length += (dx * dx + dy * dy).squareRoot()
        }
        return length
    }

    /// 手写笔迹的平滑路径：以相邻采样点的中点为锚、原采样点为控制点做二次贝塞尔，
    /// 消除鼠标/触控板采样折线的棱角。
    static func freehandPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 {
                path.addLine(to: points[1])
            }
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }

    // MARK: - 已有标注：包围盒 / 命中 / 拖动 / 缩放

    static func arrowHeadMetrics(lineWidth: CGFloat) -> (length: CGFloat, width: CGFloat) {
        (max(10, lineWidth * 4), max(9, lineWidth * 3.5))
    }

    /// 标注的绘制包围盒（坐标与 `Annotation.start/end` 一致）。
    static func bounds(of annotation: Annotation) -> CGRect {
        switch annotation.kind {
        case .rectangle, .mosaic:
            return normalizedRect(from: annotation.start, to: annotation.end)

        case .arrow:
            let rect = normalizedRect(from: annotation.start, to: annotation.end)
            let metrics = arrowHeadMetrics(lineWidth: annotation.lineWidth)
            let pad = max(metrics.length, metrics.width) / 2 + annotation.lineWidth
            return rect.insetBy(dx: -pad, dy: -pad)

        case .text:
            guard let text = annotation.text, !text.isEmpty else {
                return CGRect(origin: annotation.start, size: .zero)
            }
            return CGRect(origin: annotation.start, size: textSize(for: text))

        case .pen:
            let points = annotation.points.isEmpty ? [annotation.start] : annotation.points
            var minX = points[0].x
            var maxX = points[0].x
            var minY = points[0].y
            var maxY = points[0].y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            let pad = max(annotation.lineWidth / 2, 1.5) + 2
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -pad, dy: -pad)
        }
    }

    /// 点到线段的最短距离。
    static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projected = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    /// 点是否命中某条标注（用于点击选中）。后绘制的标注优先由调用方处理。
    static func hitTest(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat = hitTolerance) -> Bool {
        switch annotation.kind {
        case .rectangle, .mosaic, .text:
            return bounds(of: annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .arrow:
            return distance(from: point, toSegmentFrom: annotation.start, to: annotation.end)
                <= tolerance + annotation.lineWidth / 2

        case .pen:
            let points = annotation.points.isEmpty ? [annotation.start] : annotation.points
            let limit = tolerance + annotation.lineWidth / 2
            guard points.count > 1 else {
                return hypot(point.x - points[0].x, point.y - points[0].y) <= limit
            }
            for index in 1..<points.count {
                if distance(from: point, toSegmentFrom: points[index - 1], to: points[index]) <= limit {
                    return true
                }
            }
            return false
        }
    }

    /// 整体平移标注，并保证标注不会被拖出选区。
    static func moved(_ annotation: Annotation, by delta: CGSize, within container: CGRect) -> Annotation {
        guard container.width > 0, container.height > 0 else { return annotation }
        let shape = bounds(of: annotation)
        let dx = clampedDelta(
            delta.width,
            shapeMin: shape.minX,
            shapeMax: shape.maxX,
            containerMin: container.minX,
            containerMax: container.maxX
        )
        let dy = clampedDelta(
            delta.height,
            shapeMin: shape.minY,
            shapeMax: shape.maxY,
            containerMin: container.minY,
            containerMax: container.maxY
        )
        return translated(annotation, by: CGSize(width: dx, height: dy))
    }

    /// 平移标注的所有坐标（不改尺寸）。
    static func translated(_ annotation: Annotation, by delta: CGSize) -> Annotation {
        var result = annotation
        result.start = CGPoint(x: annotation.start.x + delta.width, y: annotation.start.y + delta.height)
        result.end = CGPoint(x: annotation.end.x + delta.width, y: annotation.end.y + delta.height)
        if !annotation.points.isEmpty {
            result.points = annotation.points.map {
                CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
            }
        }
        return result
    }

    private static func clampedDelta(
        _ delta: CGFloat,
        shapeMin: CGFloat,
        shapeMax: CGFloat,
        containerMin: CGFloat,
        containerMax: CGFloat
    ) -> CGFloat {
        let shapeSize = shapeMax - shapeMin
        let containerSize = containerMax - containerMin
        guard shapeSize < containerSize else {
            // 文字可能比选区更宽：此时只保持左/下边缘对齐，避免来回跳动。
            return containerMin - shapeMin
        }
        return min(max(delta, containerMin - shapeMin), containerMax - shapeMax)
    }

    /// 当前标注可用的编辑手柄（坐标与标注一致）。
    static func editHandles(
        for annotation: Annotation,
        size: CGFloat = editHandleSize
    ) -> [EditHandle: CGRect] {
        let half = size / 2
        func box(_ point: CGPoint) -> CGRect {
            CGRect(x: point.x - half, y: point.y - half, width: size, height: size)
        }

        switch annotation.kind {
        case .rectangle, .mosaic:
            let rect = normalizedRect(from: annotation.start, to: annotation.end)
            return [
                .topLeft: box(CGPoint(x: rect.minX, y: rect.maxY)),
                .top: box(CGPoint(x: rect.midX, y: rect.maxY)),
                .topRight: box(CGPoint(x: rect.maxX, y: rect.maxY)),
                .right: box(CGPoint(x: rect.maxX, y: rect.midY)),
                .bottomRight: box(CGPoint(x: rect.maxX, y: rect.minY)),
                .bottom: box(CGPoint(x: rect.midX, y: rect.minY)),
                .bottomLeft: box(CGPoint(x: rect.minX, y: rect.minY)),
                .left: box(CGPoint(x: rect.minX, y: rect.midY)),
            ]
        case .arrow:
            return [
                .arrowStart: box(annotation.start),
                .arrowEnd: box(annotation.end),
            ]
        case .text, .pen:
            return [:]
        }
    }

    /// 命中某个编辑手柄（优先角点）。
    static func editHandle(
        at point: CGPoint,
        of annotation: Annotation,
        tolerance: CGFloat = editHandleHitTolerance
    ) -> EditHandle? {
        let handles = editHandles(for: annotation)
        let ordered: [EditHandle] = [
            .topLeft, .topRight, .bottomLeft, .bottomRight,
            .top, .bottom, .left, .right,
            .arrowStart, .arrowEnd,
        ]
        for handle in ordered {
            guard let rect = handles[handle] else { continue }
            if rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return handle
            }
        }
        return nil
    }

    /// 拖动编辑手柄后的新标注。矩形/马赛克缩放包围盒，箭头移动单个端点。
    static func resized(
        _ annotation: Annotation,
        handle: EditHandle,
        to point: CGPoint,
        minSize: CGFloat = minimumEditSize,
        bounds container: CGRect
    ) -> Annotation {
        switch annotation.kind {
        case .rectangle, .mosaic:
            guard let screenHandle = handle.screenHandle else { return annotation }
            let rect = normalizedRect(from: annotation.start, to: annotation.end)
            let resized = ScreenGeometry.resized(
                rect,
                handle: screenHandle,
                to: point,
                minSize: minSize,
                bounds: container
            )
            var result = annotation
            result.start = CGPoint(x: resized.minX, y: resized.minY)
            result.end = CGPoint(x: resized.maxX, y: resized.maxY)
            return result

        case .arrow:
            var result = annotation
            let clamped = clampedPoint(point, to: container)
            switch handle {
            case .arrowStart:
                result.start = clamped
            case .arrowEnd:
                result.end = clamped
            default:
                return annotation
            }
            let length = hypot(result.end.x - result.start.x, result.end.y - result.start.y)
            return length >= minSize ? result : annotation

        case .text, .pen:
            return annotation
        }
    }
}
