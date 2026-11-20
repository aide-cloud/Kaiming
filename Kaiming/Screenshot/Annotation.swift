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
        case .select: "调整选区"
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
}
