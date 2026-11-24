#if DEBUG
import AppKit
import CoreGraphics

/// 标注编辑逻辑回归：命中、拖动夹取、手柄缩放、文字/画笔命中与撤销栈。
/// 不依赖屏幕录制权限，也不创建窗口；用法 `Kaiming --logic-test-annotations`。
@MainActor
enum AnnotationEditingTest {
    static func run() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let container = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rect = Annotation(
            kind: .rectangle,
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: 150, y: 120),
            color: AnnotationColor.palette[0]
        )

        // 命中：矩形内部可选中，远处不可。
        expect(
            AnnotationGeometry.hitTest(rect, at: CGPoint(x: 100, y: 80)),
            "rect interior should hit"
        )
        expect(
            !AnnotationGeometry.hitTest(rect, at: CGPoint(x: 300, y: 250)),
            "rect outside should miss"
        )

        // 拖动：夹取到选区边界，保持尺寸。
        let movedRight = AnnotationGeometry.moved(
            rect,
            by: CGSize(width: 10_000, height: 0),
            within: container
        )
        expect(
            abs(movedRight.end.x - container.maxX) < 0.01,
            "rect move should clamp at right edge, got \(movedRight.end)"
        )
        expect(
            abs((movedRight.end.x - movedRight.start.x) - 100) < 0.01,
            "rect move should keep width"
        )
        let movedCorner = AnnotationGeometry.moved(
            rect,
            by: CGSize(width: -10_000, height: -10_000),
            within: container
        )
        expect(
            abs(movedCorner.start.x) < 0.01 && abs(movedCorner.start.y) < 0.01,
            "rect move should clamp at bottom-left, got \(movedCorner.start)"
        )

        // 编辑手柄与缩放。
        expect(
            AnnotationGeometry.editHandle(at: CGPoint(x: 50, y: 120), of: rect) == .topLeft,
            "top-left handle lookup"
        )
        let resized = AnnotationGeometry.resized(
            rect,
            handle: .topRight,
            to: CGPoint(x: 250, y: 200),
            bounds: container
        )
        expect(
            abs(resized.end.x - 250) < 0.01 && abs(resized.end.y - 200) < 0.01,
            "rect resize top-right"
        )
        expect(
            abs(resized.start.x - 50) < 0.01 && abs(resized.start.y - 50) < 0.01,
            "rect resize keeps bottom-left"
        )
        expect(
            AnnotationGeometry.editHandles(for: rect).count == 8,
            "rect exposes 8 handles"
        )

        // 箭头：端点手柄移动。
        let arrow = Annotation(
            kind: .arrow,
            start: CGPoint(x: 60, y: 60),
            end: CGPoint(x: 160, y: 140),
            color: AnnotationColor.palette[4]
        )
        expect(
            AnnotationGeometry.editHandles(for: arrow).count == 2,
            "arrow exposes 2 endpoint handles"
        )
        let arrowEdited = AnnotationGeometry.resized(
            arrow,
            handle: .arrowEnd,
            to: CGPoint(x: 220, y: 210),
            bounds: container
        )
        expect(
            abs(arrowEdited.end.x - 220) < 0.01 && abs(arrowEdited.end.y - 210) < 0.01,
            "arrow endpoint resize"
        )
        expect(
            arrowEdited.start == arrow.start,
            "arrow resize keeps start"
        )

        // 文字：包围盒/命中，拖动后文字内容不变。
        let text = Annotation(
            kind: .text,
            start: CGPoint(x: 20, y: 20),
            color: AnnotationColor.palette[3],
            text: "编辑测试"
        )
        let textSize = AnnotationGeometry.textSize(for: "编辑测试")
        expect(textSize.width > 0 && textSize.height > 0, "text size should be positive")
        expect(
            AnnotationGeometry.hitTest(
                text,
                at: CGPoint(x: 20 + textSize.width / 2, y: 20 + textSize.height / 2)
            ),
            "text hit inside bounds"
        )
        let movedText = AnnotationGeometry.moved(
            text,
            by: CGSize(width: 100, height: 100),
            within: container
        )
        expect(movedText.text == "编辑测试", "text move keeps contents")
        expect(
            abs(movedText.start.x - 120) < 0.01 && abs(movedText.start.y - 120) < 0.01,
            "text move offset"
        )

        // 画笔：命中笔迹线段，远离笔迹不命中。
        let pen = Annotation(
            kind: .pen,
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 160, y: 100),
            color: AnnotationColor.palette[1],
            lineWidth: 4,
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 130, y: 100), CGPoint(x: 160, y: 100)]
        )
        expect(
            AnnotationGeometry.hitTest(pen, at: CGPoint(x: 130, y: 102)),
            "pen stroke should hit"
        )
        expect(
            !AnnotationGeometry.hitTest(pen, at: CGPoint(x: 130, y: 160)),
            "pen far point should miss"
        )

        // 会话：新增/选中/删除/撤销、切换工具收起选中。
        let session = AnnotationSession()
        session.add(rect)
        expect(session.annotations.count == 1, "session add")
        expect(session.canUndo, "session can undo add")
        session.select(rect.id)
        expect(session.selectedAnnotation?.id == rect.id, "session select")
        session.deleteSelected()
        expect(session.annotations.isEmpty, "session delete selected")
        expect(session.undo(), "session undo delete")
        expect(session.annotations.count == 1, "session undo restores annotation")
        expect(session.undo(), "session undo add")
        expect(session.annotations.isEmpty && !session.canUndo, "session undo stack empty")

        session.clear()
        session.add(rect)
        session.select(rect.id)
        session.tool = .pen
        expect(session.selectedAnnotation == nil, "switching tool clears selection")
        session.tool = .select

        // 会话：文字内容替换 + 撤销。
        session.add(text)
        session.beginMutation()
        var updated = text
        updated.text = "修改后"
        session.replace(updated)
        expect(
            session.annotation(id: text.id)?.text == "修改后",
            "session replace text"
        )
        expect(session.undo(), "session undo text edit")
        expect(
            session.annotation(id: text.id)?.text == "编辑测试",
            "session undo restores text"
        )

        // 删除后选中态必须被清空。
        session.select(text.id)
        session.delete(text.id)
        expect(session.selectedAnnotationID == nil, "delete clears selection")

        if failures.isEmpty {
            NSLog("Kaiming debug: annotation editing logic test PASS")
        } else {
            NSLog(
                "Kaiming debug: annotation editing logic test FAIL "
                    + failures.joined(separator: "; ")
            )
        }
        NSApp.terminate(nil)
    }
}
#endif
