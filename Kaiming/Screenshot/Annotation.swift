import AppKit
import CoreGraphics

/// 标注工具。
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case select
    case rectangle
    case arrow
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "调整选区"
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .text: "文字"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
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
    }

    let id: UUID
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: AnnotationColor
    var lineWidth: CGFloat
    var text: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        start: CGPoint,
        end: CGPoint? = nil,
        color: AnnotationColor,
        lineWidth: CGFloat = 3,
        text: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
    }
}

/// 标注的纯几何计算。
enum AnnotationGeometry {
    static let textFontSize: CGFloat = 16
    /// 小于该尺寸的拖拽不生成矩形/箭头，避免双击或误触留下一个点。
    static let minimumDrawingSize: CGFloat = 3

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
    static func isMeaningful(kind: Annotation.Kind, start: CGPoint, end: CGPoint) -> Bool {
        switch kind {
        case .rectangle, .arrow:
            return abs(end.x - start.x) >= minimumDrawingSize || abs(end.y - start.y) >= minimumDrawingSize
        case .text:
            return true
        }
    }
}
