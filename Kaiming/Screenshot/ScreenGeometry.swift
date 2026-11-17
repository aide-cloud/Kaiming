import CoreGraphics
import Foundation

/// 截图覆盖层使用的纯几何计算。
///
/// 这里刻意保持无副作用、无 AppKit 依赖：选区归一化、命中测试、手柄缩放、
/// 全局坐标换算与 Retina 裁剪矩形都可以脱离 UI 直接做单元验证。
enum ScreenGeometry {
    /// 允许确认的最小选区（点）。
    static let minimumSelectionSize: CGFloat = 8
    /// 手柄显示边长（点）。
    static let handleSize: CGFloat = 7
    /// 手柄命中容差（点）。
    static let handleHitTolerance: CGFloat = 7

    /// 选区四周的 8 个调整手柄。
    enum Handle: CaseIterable, Sendable {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
    }

    // MARK: - 选区

    /// 由拖拽的两个端点构造归一化矩形（支持任意方向拖拽）。
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// 把点约束在矩形内。
    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// 把矩形整体约束在边界内，必要时先收缩尺寸。
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(max(rect.width, 0), bounds.width)
        let height = min(max(rect.height, 0), bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - 坐标换算

    /// 把 CGWindow 使用的「主屏左上角为原点、y 向下」坐标转换为 AppKit 全局坐标（y 向上）。
    static func appKitRect(fromCGWindowFrame frame: CGRect, mainScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: mainScreenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// 两个矩形是否近似相等（用于把 SCK 显示器几何位置回退匹配到 `NSScreen`）。
    static func isApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    /// 全局坐标 → 屏幕局部坐标（屏幕左下角为原点）。
    static func localRect(fromGlobal rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: rect.minY - screenFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 屏幕局部坐标 → 全局坐标。
    static func globalPoint(fromLocal point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY)
    }

    /// 选区局部坐标（目标图左下角为原点）。
    static func localPoint(fromViewPoint point: CGPoint, targetRect: CGRect) -> CGPoint {
        CGPoint(x: point.x - targetRect.minX, y: point.y - targetRect.minY)
    }

    // MARK: - 手柄

    /// 计算 8 个手柄的显示矩形。
    static func handleRects(for rect: CGRect, size: CGFloat) -> [Handle: CGRect] {
        let half = size / 2
        func box(_ point: CGPoint) -> CGRect {
            CGRect(x: point.x - half, y: point.y - half, width: size, height: size)
        }
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
    }

    /// 命中测试：优先返回角落手柄，其次边手柄。
    static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> Handle? {
        let centers: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
        ]
        for (handle, center) in centers {
            let hitRect = CGRect(
                x: center.x - tolerance,
                y: center.y - tolerance,
                width: tolerance * 2,
                height: tolerance * 2
            )
            if hitRect.contains(point) {
                return handle
            }
        }
        return nil
    }

    /// 拖动某个手柄后的新矩形，结果始终落在边界内且不小于最小尺寸。
    static func resized(
        _ rect: CGRect,
        handle: Handle,
        to point: CGPoint,
        minSize: CGFloat,
        bounds: CGRect
    ) -> CGRect {
        let p = clamped(point, to: bounds)
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = p.x
            maxY = p.y
        case .top:
            maxY = p.y
        case .topRight:
            maxX = p.x
            maxY = p.y
        case .right:
            maxX = p.x
        case .bottomRight:
            maxX = p.x
            minY = p.y
        case .bottom:
            minY = p.y
        case .bottomLeft:
            minX = p.x
            minY = p.y
        case .left:
            minX = p.x
        }

        switch handle {
        case .topLeft, .left, .bottomLeft:
            minX = min(minX, maxX - minSize)
        default:
            break
        }
        switch handle {
        case .topRight, .right, .bottomRight:
            maxX = max(maxX, minX + minSize)
        default:
            break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            maxY = max(maxY, minY + minSize)
        default:
            break
        }
        switch handle {
        case .bottomLeft, .bottom, .bottomRight:
            minY = min(minY, maxY - minSize)
        default:
            break
        }

        let result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return clamped(result, to: bounds)
    }

    /// 平移矩形，保持尺寸并把结果约束在边界内。
    static func moved(_ rect: CGRect, by delta: CGSize, bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let maxX = max(bounds.minX, bounds.maxX - width)
        let maxY = max(bounds.minY, bounds.maxY - height)
        let x = min(max(rect.minX + delta.width, bounds.minX), maxX)
        let y = min(max(rect.minY + delta.height, bounds.minY), maxY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Retina 裁剪

    /// 把屏幕局部点坐标的选区换算为冻结图上的像素裁剪矩形。
    ///
    /// - 冻结图坐标原点在左上角、y 向下，而 AppKit 屏幕坐标原点在左下角，因此 y 需要翻转；
    /// - 宽高按该屏幕冻结图的实际像素尺寸 / 点尺寸计算，保证 Retina 下裁剪清晰；
    /// - 结果会取整并裁剪到图片范围内，避免 `CGImage.cropping(to:)` 越界返回 nil。
    static func pixelCropRect(selection: CGRect, screenBounds: CGRect, imageSize: CGSize) -> CGRect {
        guard screenBounds.width > 0, screenBounds.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }

        let sel = selection.intersection(screenBounds)
        guard !sel.isNull, sel.width >= 0.5, sel.height >= 0.5 else { return .zero }

        let scaleX = imageSize.width / screenBounds.width
        let scaleY = imageSize.height / screenBounds.height

        let x = (sel.minX * scaleX).rounded(.down)
        let y = ((screenBounds.maxY - sel.maxY) * scaleY).rounded(.down)
        let width = max(1, (sel.width * scaleX).rounded())
        let height = max(1, (sel.height * scaleY).rounded())

        let pixelBounds = CGRect(origin: .zero, size: imageSize)
        var rect = CGRect(x: x, y: y, width: width, height: height).integral
        rect = rect.intersection(pixelBounds).integral
        guard rect.width >= 1, rect.height >= 1 else { return .zero }
        return rect
    }

    /// 选区在冻结图上的像素尺寸（只用于展示标签）。
    static func pixelSize(for selection: CGRect, screenBounds: CGRect, imageSize: CGSize) -> CGSize {
        guard screenBounds.width > 0, screenBounds.height > 0 else { return .zero }
        return CGSize(
            width: (selection.width * imageSize.width / screenBounds.width).rounded(),
            height: (selection.height * imageSize.height / screenBounds.height).rounded()
        )
    }
}
