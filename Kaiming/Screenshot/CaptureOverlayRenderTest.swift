#if DEBUG
import AppKit
import CoreGraphics

/// 覆盖层预览的圆角透明回归测试。
///
/// 不依赖屏幕录制权限：用一块合成的冻结屏图 + 注入的目标选区，把
/// `CaptureOverlayController.draw` 画到离屏 bitmap，检查选区四个圆角
/// 区域 alpha=0、内容与遮罩仍不透明，并输出 PNG 供人工核对。
@MainActor
enum CaptureOverlayRenderTest {
    static let cornerRadius: CGFloat = 28
    private static let cornerSampleInset: CGFloat = 5

    static func run(outputPath: String) {
        guard let screen = NSScreen.main else {
            fail("no main screen", outputPath: outputPath)
            return
        }

        let scale = max(screen.backingScaleFactor, 1)
        let pointSize = screen.frame.size
        guard pointSize.width >= 320, pointSize.height >= 240 else {
            fail("main screen too small: \(pointSize)", outputPath: outputPath)
            return
        }

        guard let base = makeBaseImage(
            width: max(1, Int(pointSize.width * scale)),
            height: max(1, Int(pointSize.height * scale))
        ) else {
            fail("cannot create frozen image", outputPath: outputPath)
            return
        }

        let frozen = CaptureOverlayController.FrozenScreen(
            screen: screen,
            displayID: 0,
            image: base,
            scale: scale
        )
        let controller = CaptureOverlayController(
            mode: .region,
            frozenScreens: [frozen],
            windows: [],
            initialScreen: screen
        )
        controller.session.cornerRadius = cornerRadius

        let targetRect = CGRect(
            x: min(200, pointSize.width * 0.2),
            y: min(180, pointSize.height * 0.2),
            width: min(640, pointSize.width * 0.5),
            height: min(360, pointSize.height * 0.4)
        )
        controller.session.add(
            Annotation(
                kind: .rectangle,
                start: CGPoint(x: 24, y: 24),
                end: CGPoint(x: 200, y: 150),
                color: AnnotationColor.palette[0]
            )
        )
        controller.session.add(
            Annotation(
                kind: .text,
                start: CGPoint(x: 24, y: 210),
                color: AnnotationColor.palette[3],
                text: "覆盖层圆角透明"
            )
        )
        // 选中矩形，让快照同时覆盖虚线选中框与 8 个编辑手柄。
        if let selectedID = controller.session.annotations.first?.id {
            controller.session.select(selectedID)
        }
        controller.debugInstallTargetForRenderTest(
            CaptureOverlayController.Target(
                screen: frozen,
                rect: targetRect,
                image: nil,
                source: .region,
                title: nil
            )
        )

        let view = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: pointSize),
            controller: controller,
            frozenScreen: frozen
        )

        guard let context = CGContext(
            data: nil,
            width: Int(pointSize.width),
            height: Int(pointSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fail("cannot create overlay bitmap", outputPath: outputPath)
            return
        }

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        controller.draw(frozenScreen: frozen, in: view)
        NSGraphicsContext.current = previous

        guard let image = context.makeImage() else {
            fail("cannot make overlay image", outputPath: outputPath)
            return
        }

        let inset = cornerSampleInset
        let samples: [(String, CGPoint, UInt8)] = [
            ("topLeft", CGPoint(x: targetRect.minX + inset, y: targetRect.minY + inset), 0),
            ("topRight", CGPoint(x: targetRect.maxX - inset, y: targetRect.minY + inset), 0),
            ("bottomLeft", CGPoint(x: targetRect.minX + inset, y: targetRect.maxY - inset), 0),
            ("bottomRight", CGPoint(x: targetRect.maxX - inset, y: targetRect.maxY - inset), 0),
            ("center", CGPoint(x: targetRect.midX, y: targetRect.midY), 255),
            ("outside", CGPoint(x: targetRect.minX - 12, y: targetRect.midY), 255),
        ]

        var failures: [String] = []
        for (name, point, expected) in samples {
            guard let alpha = alphaValue(of: image, at: point) else {
                failures.append("\(name): alpha read failed")
                continue
            }
            if alpha != expected {
                failures.append("\(name): alpha=\(alpha) expected=\(expected)")
            }
        }

        var pngWritten = false
        do {
            let data = try CaptureHistory.encode(image, format: .png)
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            pngWritten = true
        } catch {
            failures.append("png: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            NSLog(
                "Kaiming debug: overlay corner test PASS rect=\(targetRect) "
                    + "radius=\(Int(cornerRadius)) png=\(pngWritten ? outputPath : "-")"
            )
        } else {
            NSLog("Kaiming debug: overlay corner test FAIL \(failures.joined(separator: "; "))")
        }
        NSApp.terminate(nil)
    }

    /// 真实覆盖层视图路径：把鼠标事件交给 `CaptureOverlayView`，验证
    /// 「画完自动选中 + 直接拖动」在 view 的坐标转换与转发下同样成立。
    static func runViewPathTest() {
        guard let screen = NSScreen.main else {
            NSLog("Kaiming debug: overlay view test FAIL no main screen")
            NSApp.terminate(nil)
            return
        }
        let scale = max(screen.backingScaleFactor, 1)
        let pointSize = screen.frame.size
        guard let base = makeBaseImage(
            width: max(1, Int(pointSize.width * scale)),
            height: max(1, Int(pointSize.height * scale))
        ) else {
            NSLog("Kaiming debug: overlay view test FAIL no base image")
            NSApp.terminate(nil)
            return
        }
        let frozen = CaptureOverlayController.FrozenScreen(
            screen: screen,
            displayID: 0,
            image: base,
            scale: scale
        )
        let controller = CaptureOverlayController(
            mode: .region,
            frozenScreens: [frozen],
            windows: [],
            initialScreen: screen
        )
        let targetRect = CGRect(
            x: min(180, pointSize.width * 0.15),
            y: min(160, pointSize.height * 0.15),
            width: min(560, pointSize.width * 0.45),
            height: min(320, pointSize.height * 0.35)
        )
        controller.debugInstallTargetForRenderTest(
            CaptureOverlayController.Target(
                screen: frozen,
                rect: targetRect,
                image: nil,
                source: .region,
                title: nil
            )
        )
        controller.session.tool = .rectangle

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: pointSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        let view = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: pointSize),
            controller: controller,
            frozenScreen: frozen
        )
        window.contentView = view

        func event(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            )
        }

        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let drawStart = CGPoint(x: targetRect.minX + 60, y: targetRect.minY + 60)
        let drawEnd = CGPoint(x: targetRect.minX + 240, y: targetRect.minY + 180)
        if let down = event(.leftMouseDown, at: drawStart) {
            view.mouseDown(with: down)
        } else {
            failures.append("cannot create mouse down event")
        }
        if let dragged = event(.leftMouseDragged, at: drawEnd) {
            view.mouseDragged(with: dragged)
        }
        if let up = event(.leftMouseUp, at: drawEnd) {
            view.mouseUp(with: up)
        }

        expect(
            controller.session.annotations.count == 1,
            "view path should draw one annotation"
        )
        expect(
            controller.session.selectedAnnotationID != nil,
            "view path should auto-select new annotation"
        )

        // 保持矩形工具，直接拖动刚画完的标注。
        let moveStart = CGPoint(x: targetRect.minX + 150, y: targetRect.minY + 120)
        let moveEnd = CGPoint(x: moveStart.x + 40, y: moveStart.y + 30)
        if let down = event(.leftMouseDown, at: moveStart) {
            view.mouseDown(with: down)
        }
        if let dragged = event(.leftMouseDragged, at: moveEnd) {
            view.mouseDragged(with: dragged)
        }
        if let up = event(.leftMouseUp, at: moveEnd) {
            view.mouseUp(with: up)
        }
        let moved = controller.session.annotations.first
        expect(
            abs((moved?.start.x ?? 0) - 100) < 0.01
                && abs((moved?.start.y ?? 0) - 90) < 0.01,
            "view path drag start expected (100,90), got \(String(describing: moved?.start))"
        )
        expect(
            controller.session.annotations.count == 1,
            "view path drag should not create a second annotation"
        )

        if failures.isEmpty {
            NSLog("Kaiming debug: overlay view path test PASS")
        } else {
            NSLog(
                "Kaiming debug: overlay view path test FAIL "
                    + failures.joined(separator: "; ")
            )
        }
        NSApp.terminate(nil)
    }

    private static func fail(_ message: String, outputPath: String) {
        NSLog("Kaiming debug: overlay corner test FAIL \(message) png=\(outputPath)")
        NSApp.terminate(nil)
    }

    /// 覆盖层鼠标接线回归：不创建窗口，直接调用 controller 的
    /// mouseDown/Dragged/Up，验证「单击选中 + 拖动」「手柄缩放」与撤销快照。
    static func runInteractionTest() {
        guard let screen = NSScreen.main else {
            NSLog("Kaiming debug: overlay interaction test FAIL no main screen")
            NSApp.terminate(nil)
            return
        }
        let scale = max(screen.backingScaleFactor, 1)
        let pointSize = screen.frame.size
        guard let base = makeBaseImage(
            width: max(1, Int(pointSize.width * scale)),
            height: max(1, Int(pointSize.height * scale))
        ) else {
            NSLog("Kaiming debug: overlay interaction test FAIL no base image")
            NSApp.terminate(nil)
            return
        }
        let frozen = CaptureOverlayController.FrozenScreen(
            screen: screen,
            displayID: 0,
            image: base,
            scale: scale
        )
        let controller = CaptureOverlayController(
            mode: .region,
            frozenScreens: [frozen],
            windows: [],
            initialScreen: screen
        )
        let targetRect = CGRect(
            x: min(160, pointSize.width * 0.15),
            y: min(140, pointSize.height * 0.15),
            width: min(560, pointSize.width * 0.45),
            height: min(320, pointSize.height * 0.35)
        )
        controller.debugInstallTargetForRenderTest(
            CaptureOverlayController.Target(
                screen: frozen,
                rect: targetRect,
                image: nil,
                source: .region,
                title: nil
            )
        )
        controller.session.tool = .select
        controller.session.add(
            Annotation(
                kind: .rectangle,
                start: CGPoint(x: 100, y: 100),
                end: CGPoint(x: 300, y: 250),
                color: AnnotationColor.palette[0]
            )
        )

        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        // 单击标注内部并拖动 +50/+30。
        let moveStart = CGPoint(x: targetRect.minX + 200, y: targetRect.minY + 175)
        controller.mouseDown(at: moveStart, in: frozen, clickCount: 1)
        expect(
            controller.session.selectedAnnotationID != nil,
            "click should select annotation"
        )
        controller.mouseDragged(
            at: CGPoint(x: moveStart.x + 50, y: moveStart.y + 30),
            in: frozen
        )
        controller.mouseUp(at: CGPoint(x: moveStart.x + 50, y: moveStart.y + 30), in: frozen)
        let moved = controller.session.annotations.first
        expect(
            abs((moved?.start.x ?? 0) - 150) < 0.01 && abs((moved?.start.y ?? 0) - 130) < 0.01,
            "drag should move annotation start, got \(String(describing: moved?.start))"
        )
        expect(
            abs((moved?.end.x ?? 0) - 350) < 0.01 && abs((moved?.end.y ?? 0) - 280) < 0.01,
            "drag should move annotation end, got \(String(describing: moved?.end))"
        )

        // 拖动右上角手柄到 (420, 320)。
        let resizeStart = CGPoint(x: targetRect.minX + 350, y: targetRect.minY + 280)
        controller.mouseDown(at: resizeStart, in: frozen, clickCount: 1)
        controller.mouseDragged(
            at: CGPoint(x: targetRect.minX + 420, y: targetRect.minY + 320),
            in: frozen
        )
        controller.mouseUp(
            at: CGPoint(x: targetRect.minX + 420, y: targetRect.minY + 320),
            in: frozen
        )
        let resized = controller.session.annotations.first
        expect(
            abs((resized?.end.x ?? 0) - 420) < 0.01 && abs((resized?.end.y ?? 0) - 320) < 0.01,
            "handle drag should resize annotation, got \(String(describing: resized?.end))"
        )
        expect(
            abs((resized?.start.x ?? 0) - 150) < 0.01 && abs((resized?.start.y ?? 0) - 130) < 0.01,
            "handle drag should keep opposite corner"
        )

        // 两次撤销：先回缩放，再回拖动。
        expect(controller.session.undo(), "undo resize should succeed")
        let afterUndoResize = controller.session.annotations.first
        expect(
            abs((afterUndoResize?.end.x ?? 0) - 350) < 0.01,
            "undo resize should restore previous size"
        )
        expect(controller.session.undo(), "undo move should succeed")
        let afterUndoMove = controller.session.annotations.first
        expect(
            abs((afterUndoMove?.start.x ?? 0) - 100) < 0.01
                && abs((afterUndoMove?.end.x ?? 0) - 300) < 0.01,
            "undo move should restore original position"
        )

        // 画完自动选中：保持矩形工具不切换，直接拖动刚画的标注。
        controller.session.clear()
        controller.session.tool = .rectangle
        let drawStart = CGPoint(x: targetRect.minX + 40, y: targetRect.minY + 40)
        let drawEnd = CGPoint(x: targetRect.minX + 180, y: targetRect.minY + 140)
        controller.mouseDown(at: drawStart, in: frozen, clickCount: 1)
        controller.mouseDragged(at: drawEnd, in: frozen)
        controller.mouseUp(at: drawEnd, in: frozen)
        expect(
            controller.session.annotations.count == 1,
            "drawing should add exactly one annotation"
        )
        expect(
            controller.session.selectedAnnotationID != nil,
            "new annotation should be auto-selected"
        )
        let firstDrawn = controller.session.annotations.first
        expect(
            abs((firstDrawn?.start.x ?? 0) - 40) < 0.01,
            "drawn annotation start"
        )
        let dragStart = CGPoint(x: targetRect.minX + 100, y: targetRect.minY + 90)
        let dragEnd = CGPoint(x: dragStart.x + 30, y: dragStart.y + 20)
        controller.mouseDown(at: dragStart, in: frozen, clickCount: 1)
        controller.mouseDragged(at: dragEnd, in: frozen)
        controller.mouseUp(at: dragEnd, in: frozen)
        let dragged = controller.session.annotations.first
        expect(
            abs((dragged?.start.x ?? 0) - 70) < 0.01
                && abs((dragged?.start.y ?? 0) - 60) < 0.01,
            "auto-selected annotation should drag with drawing tool active, "
                + "got \(String(describing: dragged?.start))"
        )
        expect(
            controller.session.annotations.count == 1,
            "dragging auto-selected annotation should not create a new one"
        )

        if failures.isEmpty {
            NSLog("Kaiming debug: overlay interaction test PASS")
        } else {
            NSLog(
                "Kaiming debug: overlay interaction test FAIL "
                    + failures.joined(separator: "; ")
            )
        }
        NSApp.terminate(nil)
    }

    /// 在 y 向上的位图坐标里取样 alpha。
    private static func alphaValue(of image: CGImage, at point: CGPoint) -> UInt8? {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            image,
            in: CGRect(
                x: -point.x,
                y: -point.y,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        guard let data = context.data else { return nil }
        return data.assumingMemoryBound(to: UInt8.self)[3]
    }

    private static func makeBaseImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)

        let colors: [NSColor] = [
            NSColor(srgbRed: 0.16, green: 0.45, blue: 0.86, alpha: 1),
            NSColor(srgbRed: 0.94, green: 0.58, blue: 0.12, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.72, blue: 0.42, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(
                CGRect(
                    x: bounds.width * 0.62,
                    y: bounds.height * 0.18 + CGFloat(index) * 80,
                    width: bounds.width * 0.30,
                    height: 60
                )
            )
        }
        return context.makeImage()
    }
}
#endif
