import AppKit
import Combine
import SwiftUI

/// 区域 / 窗口截图的冻结覆盖层。
///
/// 生命周期：
/// 1. 外部先在主线程完成「冻结截图」，再把每块屏幕的位图交给本控制器；
/// 2. `present()` 为每块屏幕创建一个 `.screenSaver` 级别的无边框窗口；
/// 3. 用户框选/点选后进入标注阶段，`confirm()` 把底图与标注拍平后通过 `onFinish` 回传；
/// 4. `teardown()` 移除事件监听、输入框、工具栏与全部窗口，避免循环引用。
@MainActor
final class CaptureOverlayController: NSObject {
    enum Mode {
        case region
        case window
    }

    struct FrozenScreen {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let image: CGImage
        /// 冻结图像素宽度 / 屏幕点宽度。
        let scale: CGFloat
    }

    struct WindowCandidate: Identifiable {
        let descriptor: ScreenCaptureService.WindowDescriptor
        let appKitFrame: CGRect
        let screenDisplayID: CGDirectDisplayID

        var id: CGWindowID { descriptor.id }
        var title: String { descriptor.title }
        var area: CGFloat { appKitFrame.width * appKitFrame.height }
    }

    struct Target {
        enum Source {
            case region
            case window
        }

        let screen: FrozenScreen
        var rect: CGRect
        let image: CGImage?
        let source: Source
        /// 窗口截图时显示在选区上方的窗口标题。
        let title: String?
    }

    private enum Interaction {
        case none
        case selecting(start: CGPoint)
        case resizing(handle: ScreenGeometry.Handle, initial: CGRect)
        case moving(start: CGPoint, initial: CGRect)
        case annotating(kind: Annotation.Kind, start: CGPoint)
    }

    let mode: Mode
    let frozenScreens: [FrozenScreen]
    private(set) var candidates: [WindowCandidate]
    let session = AnnotationSession()

    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var isFinished = false
    private var windows: [OverlayWindow] = []
    private var views: [CaptureOverlayView] = []
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var target: Target?
    private var hoveredCandidate: WindowCandidate?
    private var isCapturingWindow = false
    private var toolbarHost: NSHostingView<AnnotationToolbar>?
    private let hintDisplayID: CGDirectDisplayID?

    private var interaction: Interaction = .none
    private var draft: Annotation?
    private var activeScreen: FrozenScreen?
    private var activeSelectionRect: CGRect?

    private var textField: NSTextField?
    private var textFieldOrigin: CGPoint = .zero
    private var isCommittingText = false

    init(
        mode: Mode,
        frozenScreens: [FrozenScreen],
        windows windowDescriptors: [ScreenCaptureService.WindowDescriptor],
        initialScreen: NSScreen?
    ) {
        self.mode = mode
        self.frozenScreens = frozenScreens
        self.hintDisplayID = Self.displayID(of: initialScreen)
        self.candidates = []
        super.init()
        self.candidates = Self.makeCandidates(
            from: windowDescriptors,
            frozenScreens: frozenScreens,
            mainScreenFrame: NSScreen.main?.frame ?? .zero
        )
    }

    // MARK: - 生命周期

    func present() {
        guard windows.isEmpty else { return }
        installKeyMonitor()
        observeSession()

        for frozen in frozenScreens {
            let window = OverlayWindow(
                contentRect: frozen.screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: frozen.screen
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false

            let view = CaptureOverlayView(
                frame: CGRect(origin: .zero, size: frozen.screen.frame.size),
                controller: self,
                frozenScreen: frozen
            )
            view.autoresizingMask = [.width, .height]
            window.contentView = view

            views.append(view)
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }

        let keyIndex = frozenScreens.firstIndex(where: { $0.displayID == hintDisplayID }) ?? 0
        if windows.indices.contains(keyIndex) {
            windows[keyIndex].makeKey()
            windows[keyIndex].makeFirstResponder(views[keyIndex])
        }
        refreshViews()
        Log.screenshot.info(
            "Overlay presented mode=\(String(describing: self.mode), privacy: .public) screens=\(self.windows.count, privacy: .public)"
        )
    }

    func confirm() {
        guard !isFinished else { return }
        if textField != nil {
            commitTextEditing()
        }
        guard let target else { return }

        let flattened: CGImage?
        switch target.source {
        case .region:
            let screenBounds = CGRect(origin: .zero, size: target.screen.screen.frame.size)
            let imageSize = CGSize(width: target.screen.image.width, height: target.screen.image.height)
            let cropRect = ScreenGeometry.pixelCropRect(
                selection: target.rect,
                screenBounds: screenBounds,
                imageSize: imageSize
            )
            guard cropRect.width >= 1, cropRect.height >= 1,
                  let cropped = target.screen.image.cropping(to: cropRect) else {
                fail("无法裁剪所选区域，请重新框选后再试。")
                return
            }
            flattened = AnnotationDrawing.render(
                baseImage: cropped,
                annotations: session.annotations,
                boundsInPoints: target.rect.size
            )
        case .window:
            guard let image = target.image else {
                fail("窗口截图数据丢失，请重新截图。")
                return
            }
            flattened = AnnotationDrawing.render(
                baseImage: image,
                annotations: session.annotations,
                boundsInPoints: target.rect.size
            )
        }

        guard let image = flattened else {
            fail("生成标注图像失败，请重试。")
            return
        }
        Log.screenshot.info("Capture confirmed with \(self.session.annotations.count, privacy: .public) annotations")
        finish(with: image)
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        let callback = onCancel
        teardown()
        callback?()
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard !isFinished else { return event }
        guard let eventWindow = event.window, windows.contains(where: { $0 === eventWindow }) else {
            return event
        }
        // 文本输入中把按键完全交给 field editor。
        guard textField == nil else { return event }
        return handleKeyCode(event.keyCode) ? nil : event
    }

    /// 返回 true 表示事件已被消费（Return 确认 / Esc 取消）。
    private func handleKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 36, 76: // Return / 小键盘 Enter
            confirm()
            return true
        case 53: // Esc
            cancel()
            return true
        default:
            return false
        }
    }

    private func finish(with image: CGImage) {
        isFinished = true
        let callback = onFinish
        teardown()
        callback?(image)
    }

    private func fail(_ message: String) {
        AppState.shared.flash(message, kind: .error)
        Log.screenshot.error("Capture failed: \(message, privacy: .public)")
        cancel()
    }

    private func teardown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        cancellables.removeAll()

        if let field = textField {
            field.delegate = nil
            field.removeFromSuperview()
            textField = nil
        }
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil

        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        views.removeAll()

        target = nil
        hoveredCandidate = nil
        isCapturingWindow = false
        interaction = .none
        draft = nil
        activeScreen = nil
        activeSelectionRect = nil
        onFinish = nil
        onCancel = nil
    }

    // MARK: - 事件监听

    private func installKeyMonitor() {
        // 监控回调是 @Sendable：只把 keyCode / windowNumber 这类 Sendable 值带进主线程，
        // 避免让非 Sendable 的 NSEvent 跨 actor。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated {
                self.handleMonitoredKey(keyCode: keyCode, windowNumber: windowNumber)
            }
            return consumed ? nil : event
        }
    }

    /// 键盘监控入口：只处理落在覆盖层窗口上的 Return / Esc。
    private func handleMonitoredKey(keyCode: UInt16, windowNumber: Int) -> Bool {
        guard !isFinished, textField == nil else { return false }
        guard windows.contains(where: { $0.windowNumber == windowNumber }) else { return false }
        return handleKeyCode(keyCode)
    }

    private func observeSession() {
        session.$annotations
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshViews() }
            }
            .store(in: &cancellables)
        session.$tool
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshViews() }
            }
            .store(in: &cancellables)
        session.$color
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshViews() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 鼠标交互

    func mouseDown(at point: CGPoint, in frozenScreen: FrozenScreen, clickCount: Int) {
        guard !isFinished, !isCapturingWindow else { return }
        let local = ScreenGeometry.clamped(point, to: screenBounds(frozenScreen))

        if let target {
            guard target.screen.displayID == frozenScreen.displayID else { return }
            if target.source == .region,
               let handle = ScreenGeometry.handle(
                   at: local,
                   in: target.rect,
                   tolerance: ScreenGeometry.handleHitTolerance
               ) {
                interaction = .resizing(handle: handle, initial: target.rect)
                return
            }
            if session.tool == .select {
                guard target.rect.contains(local) else { return }
                if clickCount >= 2 {
                    confirm()
                    return
                }
                if target.source == .region {
                    interaction = .moving(start: local, initial: target.rect)
                }
                return
            }
            guard target.rect.contains(local) else { return }
            if session.tool == .text {
                beginTextEditing(at: local, in: frozenScreen)
                return
            }
            let kind: Annotation.Kind = session.tool == .arrow ? .arrow : .rectangle
            let targetBounds = CGRect(origin: .zero, size: target.rect.size)
            let annotationStart = ScreenGeometry.localPoint(fromViewPoint: local, targetRect: target.rect)
            let clampedStart = AnnotationGeometry.clampedPoint(annotationStart, to: targetBounds)
            interaction = .annotating(kind: kind, start: clampedStart)
            draft = Annotation(kind: kind, start: clampedStart, color: session.color)
            refreshViews()
            return
        }

        switch mode {
        case .region:
            activeScreen = frozenScreen
            activeSelectionRect = CGRect(origin: local, size: .zero)
            interaction = .selecting(start: local)
            refreshViews()
        case .window:
            guard let candidate = candidate(at: globalPoint(for: local, in: frozenScreen)) else { return }
            beginWindowCapture(candidate)
        }
    }

    func mouseDragged(at point: CGPoint, in frozenScreen: FrozenScreen) {
        guard !isFinished else { return }
        let local = ScreenGeometry.clamped(point, to: screenBounds(frozenScreen))

        switch interaction {
        case let .selecting(start):
            guard activeScreen?.displayID == frozenScreen.displayID else { return }
            activeSelectionRect = ScreenGeometry.rect(from: start, to: local)
            refreshViews()

        case let .resizing(handle, initial):
            guard var target, target.screen.displayID == frozenScreen.displayID else { return }
            target.rect = ScreenGeometry.resized(
                initial,
                handle: handle,
                to: local,
                minSize: ScreenGeometry.minimumSelectionSize,
                bounds: screenBounds(frozenScreen)
            )
            self.target = target
            layoutToolbar()
            refreshViews()

        case let .moving(start, initial):
            guard var target, target.screen.displayID == frozenScreen.displayID else { return }
            let delta = CGSize(width: local.x - start.x, height: local.y - start.y)
            target.rect = ScreenGeometry.moved(initial, by: delta, bounds: screenBounds(frozenScreen))
            self.target = target
            layoutToolbar()
            refreshViews()

        case .annotating:
            guard var draft, let target, target.screen.displayID == frozenScreen.displayID else { return }
            let targetBounds = CGRect(origin: .zero, size: target.rect.size)
            let annotationPoint = ScreenGeometry.localPoint(fromViewPoint: local, targetRect: target.rect)
            draft.end = AnnotationGeometry.clampedPoint(annotationPoint, to: targetBounds)
            self.draft = draft
            refreshViews()

        case .none:
            break
        }
    }

    func mouseUp(at point: CGPoint, in frozenScreen: FrozenScreen) {
        guard !isFinished else { return }

        switch interaction {
        case .selecting:
            if let activeScreen,
               let rect = activeSelectionRect,
               rect.width >= ScreenGeometry.minimumSelectionSize,
               rect.height >= ScreenGeometry.minimumSelectionSize {
                target = Target(
                    screen: activeScreen,
                    rect: ScreenGeometry.clamped(rect, to: screenBounds(activeScreen)),
                    image: nil,
                    source: .region,
                    title: nil
                )
                session.clear()
                showToolbar()
                Log.screenshot.info(
                    "Region selected \(Int(rect.width), privacy: .public)x\(Int(rect.height), privacy: .public) on display \(activeScreen.displayID, privacy: .public)"
                )
            }
            activeSelectionRect = nil
            activeScreen = nil

        case .annotating:
            if let draft, AnnotationGeometry.isMeaningful(
                kind: draft.kind,
                start: draft.start,
                end: draft.end
            ) {
                session.add(draft)
            }
            self.draft = nil

        case .resizing, .moving, .none:
            break
        }

        interaction = .none
        refreshViews()
    }

    func mouseMoved(at point: CGPoint, in frozenScreen: FrozenScreen) {
        guard !isFinished, !isCapturingWindow else { return }
        guard mode == .window, target == nil else { return }
        let local = ScreenGeometry.clamped(point, to: screenBounds(frozenScreen))
        let candidate = candidate(at: globalPoint(for: local, in: frozenScreen))
        guard candidate?.id != hoveredCandidate?.id else { return }
        hoveredCandidate = candidate
        refreshViews()
    }

    func cursor(at point: CGPoint, in frozenScreen: FrozenScreen) -> NSCursor {
        guard !isFinished else { return .arrow }
        let local = ScreenGeometry.clamped(point, to: screenBounds(frozenScreen))

        switch mode {
        case .window:
            if let target {
                guard target.screen.displayID == frozenScreen.displayID else { return .arrow }
                if target.rect.contains(local), session.tool != .select {
                    return .crosshair
                }
                return .arrow
            }
            return candidate(at: globalPoint(for: local, in: frozenScreen)) != nil ? .pointingHand : .crosshair

        case .region:
            if let target, target.screen.displayID == frozenScreen.displayID {
                if target.source == .region,
                   let handle = ScreenGeometry.handle(
                       at: local,
                       in: target.rect,
                       tolerance: ScreenGeometry.handleHitTolerance
                   ) {
                    return resizeCursor(for: handle)
                }
                if target.rect.contains(local) {
                    if session.tool == .select {
                        return isMoving ? .closedHand : .openHand
                    }
                    return .crosshair
                }
                return .arrow
            }
            return .crosshair
        }
    }

    // MARK: - 窗口点选

    private func beginWindowCapture(_ candidate: WindowCandidate) {
        guard !isCapturingWindow else { return }
        isCapturingWindow = true
        hoveredCandidate = candidate
        refreshViews()

        let scale = frozenScreen(displayID: candidate.screenDisplayID)?.screen.backingScaleFactor ?? 2
        let showsCursor = SettingsStore.shared.captureCursor

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await ScreenCaptureService.captureWindow(
                    windowID: candidate.descriptor.id,
                    backingScale: scale,
                    showsCursor: showsCursor
                )
                guard !self.isFinished else { return }
                self.isCapturingWindow = false
                self.enterWindowTarget(candidate, image: image)
            } catch {
                guard !self.isFinished else { return }
                self.isCapturingWindow = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppState.shared.flash("窗口截图失败：\(message)", kind: .error)
                Log.screenshot.error("Window capture failed: \(message, privacy: .public)")
                self.cancel()
            }
        }
    }

    private func enterWindowTarget(_ candidate: WindowCandidate, image: CGImage) {
        guard let frozen = frozenScreen(displayID: candidate.screenDisplayID) else {
            fail("找不到目标窗口所在的屏幕，请重试。")
            return
        }
        let localRect = ScreenGeometry.localRect(
            fromGlobal: candidate.appKitFrame,
            screenFrame: frozen.screen.frame
        )
        guard localRect.width >= 1, localRect.height >= 1 else {
            fail("目标窗口尺寸异常，请重试。")
            return
        }
        target = Target(
            screen: frozen,
            rect: localRect,
            image: image,
            source: .window,
            title: candidate.title
        )
        hoveredCandidate = nil
        session.clear()
        showToolbar()
        refreshViews()
        Log.screenshot.info(
            "Window target ready \(Int(localRect.width), privacy: .public)x\(Int(localRect.height), privacy: .public)"
        )
    }

    private func candidate(at globalPoint: CGPoint) -> WindowCandidate? {
        candidates
            .filter { $0.appKitFrame.contains(globalPoint) }
            .min { $0.area < $1.area }
    }

    // MARK: - 文本标注

    private func beginTextEditing(at screenPoint: CGPoint, in frozenScreen: FrozenScreen) {
        guard let target, target.screen.displayID == frozenScreen.displayID,
              let view = view(for: frozenScreen) else { return }
        commitTextEditing()

        let field = NSTextField(frame: CGRect(x: screenPoint.x, y: screenPoint.y, width: 240, height: 26))
        field.font = .systemFont(ofSize: AnnotationGeometry.textFontSize, weight: .semibold)
        field.textColor = session.color.nsColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字，Return 确认"
        field.delegate = self
        view.addSubview(field)
        textField = field
        textFieldOrigin = screenPoint
        view.window?.makeFirstResponder(field)
        refreshViews()
    }

    func commitTextEditing() {
        guard let field = textField, !isCommittingText else { return }
        isCommittingText = true
        defer { isCommittingText = false }

        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textFieldOrigin
        let color = session.color
        let targetSnapshot = target

        field.delegate = nil
        field.removeFromSuperview()
        if let targetSnapshot, let view = view(for: targetSnapshot.screen) {
            view.window?.makeFirstResponder(view)
        }

        if !text.isEmpty, let targetSnapshot {
            let bounds = CGRect(origin: .zero, size: targetSnapshot.rect.size)
            let local = CGPoint(
                x: origin.x - targetSnapshot.rect.minX,
                y: origin.y + 2 - targetSnapshot.rect.minY
            )
            let clamped = AnnotationGeometry.clampedPoint(local, to: bounds)
            session.add(Annotation(kind: .text, start: clamped, end: clamped, color: color, text: text))
        }
        refreshViews()
    }

    private func cancelTextEditing() {
        guard let field = textField else { return }
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        if let target, let view = view(for: target.screen) {
            view.window?.makeFirstResponder(view)
        }
        refreshViews()
    }

    private var isEditingText: Bool { textField != nil }

    // MARK: - 工具栏

    private func showToolbar() {
        guard let target, let view = view(for: target.screen) else {
            removeToolbar()
            return
        }
        if toolbarHost == nil {
            let host = NSHostingView(
                rootView: AnnotationToolbar(
                    session: session,
                    onComplete: { [weak self] in self?.confirm() },
                    onCancel: { [weak self] in self?.cancel() }
                )
            )
            host.frame = CGRect(origin: .zero, size: AnnotationToolbar.preferredSize)
            toolbarHost = host
        }
        guard let host = toolbarHost else { return }
        if host.superview !== view {
            host.removeFromSuperview()
            view.addSubview(host)
        }
        layoutToolbar()
    }

    private func removeToolbar() {
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
    }

    private func layoutToolbar() {
        guard let target, let host = toolbarHost, let view = view(for: target.screen) else {
            removeToolbar()
            return
        }
        let size = AnnotationToolbar.preferredSize
        let screenSize = target.screen.screen.frame.size
        let rect = target.rect

        var originX = rect.midX - size.width / 2
        var originY = rect.minY - size.height - 10
        if originY < 12 {
            originY = min(rect.maxY + 10, screenSize.height - size.height - 12)
        }
        originX = min(max(originX, 12), max(12, screenSize.width - size.width - 12))
        originY = min(max(originY, 12), max(12, screenSize.height - size.height - 12))
        host.frame = CGRect(x: originX, y: originY, width: size.width, height: size.height)
        view.window?.invalidateCursorRects(for: view)
    }

    // MARK: - 绘制

    func draw(frozenScreen: FrozenScreen, in view: CaptureOverlayView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = screenBounds(frozenScreen)

        context.saveGState()
        context.interpolationQuality = .high
        context.draw(frozenScreen.image, in: bounds)
        context.restoreGState()

        let clearRect: CGRect?
        if let target, target.screen.displayID == frozenScreen.displayID {
            clearRect = target.rect
        } else if let activeScreen,
                  activeScreen.displayID == frozenScreen.displayID,
                  let selection = activeSelectionRect,
                  selection.width > 0.5, selection.height > 0.5 {
            clearRect = selection
        } else {
            clearRect = nil
        }

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let clearRect {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(clearRect)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }
        context.restoreGState()

        if let target,
           target.source == .window,
           target.screen.displayID == frozenScreen.displayID,
           let image = target.image,
           target.rect.width > 0, target.rect.height > 0 {
            context.saveGState()
            context.clip(to: target.rect)
            context.draw(image, in: target.rect)
            context.restoreGState()
        }

        if let target, target.screen.displayID == frozenScreen.displayID {
            for annotation in session.annotations {
                AnnotationDrawing.draw(annotation: annotation, in: context, origin: target.rect.origin)
            }
            if let draft {
                AnnotationDrawing.draw(annotation: draft, in: context, origin: target.rect.origin)
            }
            drawChrome(
                rect: target.rect,
                context: context,
                scale: target.screen.scale,
                showHandles: target.source == .region,
                windowTitle: target.title,
                viewBounds: bounds
            )
        }

        if let activeScreen,
           activeScreen.displayID == frozenScreen.displayID,
           target == nil,
           let selection = activeSelectionRect,
           selection.width > 0.5, selection.height > 0.5 {
            drawChrome(
                rect: selection,
                context: context,
                scale: activeScreen.scale,
                showHandles: false,
                windowTitle: nil,
                viewBounds: bounds
            )
        }

        if mode == .window, target == nil,
           let hovered = hoveredCandidate,
           hovered.screenDisplayID == frozenScreen.displayID {
            let rect = ScreenGeometry.localRect(
                fromGlobal: hovered.appKitFrame,
                screenFrame: frozenScreen.screen.frame
            )
            drawHighlight(rect: rect, title: hovered.title, context: context, viewBounds: bounds)
        }

        if isCapturingWindow {
            drawFloatingLabel(
                "正在截取窗口…",
                centerX: bounds.midX,
                bottomY: 28,
                context: context,
                viewBounds: bounds
            )
        } else if target == nil,
                  (activeSelectionRect?.width ?? 0) < 0.5,
                  frozenScreen.displayID == hintDisplayID,
                  !isEditingText {
            let hint = mode == .window
                ? "点击选择窗口 · Esc 取消"
                : "拖拽框选区域 · Return 确认 · Esc 取消"
            drawFloatingLabel(
                hint,
                centerX: bounds.midX,
                bottomY: 28,
                context: context,
                viewBounds: bounds
            )
        }
    }

    private func drawChrome(
        rect: CGRect,
        context: CGContext,
        scale: CGFloat,
        showHandles: Bool,
        windowTitle: String?,
        viewBounds: CGRect
    ) {
        let accent = NSColor.controlAccentColor
        context.saveGState()
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
        context.restoreGState()

        if showHandles {
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1)
            let handles = ScreenGeometry.handleRects(for: rect, size: ScreenGeometry.handleSize)
            for handleRect in handles.values {
                context.fill(handleRect)
                context.stroke(handleRect)
            }
            context.restoreGState()
        }

        let pixelWidth = Int((rect.width * scale).rounded())
        let pixelHeight = Int((rect.height * scale).rounded())
        let sizeText = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt · \(pixelWidth) × \(pixelHeight) px"
        let label: String
        if let windowTitle, !windowTitle.isEmpty {
            label = windowTitle
        } else {
            label = sizeText
        }
        drawLabel(label, near: rect, context: context, viewBounds: viewBounds)
    }

    private func drawHighlight(rect: CGRect, title: String, context: CGContext, viewBounds: CGRect) {
        let accent = NSColor.controlAccentColor
        context.saveGState()
        context.setFillColor(accent.withAlphaComponent(0.10).cgColor)
        context.fill(rect)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))
        context.restoreGState()
        drawLabel(title, near: rect, context: context, viewBounds: viewBounds)
    }

    private func drawLabel(_ text: String, near rect: CGRect, context: CGContext, viewBounds: CGRect) {
        let displayText = text.count > 64 ? String(text.prefix(63)) + "…" : text
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (displayText as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 6, height: 3)
        let boxSize = CGSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 5)
        if origin.y + boxSize.height > viewBounds.maxY - 4 {
            origin.y = max(viewBounds.minY + 4, rect.minY - boxSize.height - 5)
        }
        if origin.x + boxSize.width > viewBounds.maxX - 4 {
            origin.x = max(viewBounds.minX + 4, viewBounds.maxX - boxSize.width - 4)
        }
        let box = CGRect(origin: origin, size: boxSize)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.68).cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        context.restoreGState()
        NSAttributedString(string: displayText, attributes: attributes)
            .draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }

    private func drawFloatingLabel(
        _ text: String,
        centerX: CGFloat,
        bottomY: CGFloat,
        context: CGContext,
        viewBounds: CGRect
    ) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 10, height: 6)
        let boxSize = CGSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
        let x = min(max(centerX - boxSize.width / 2, 8), max(8, viewBounds.maxX - boxSize.width - 8))
        let y = min(max(bottomY, 8), max(8, viewBounds.maxY - boxSize.height - 8))
        let box = CGRect(x: x, y: y, width: boxSize.width, height: boxSize.height)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.60).cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 7, cornerHeight: 7, transform: nil))
        context.fillPath()
        context.restoreGState()
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }

    // MARK: - 辅助

    private func refreshViews() {
        for view in views {
            view.needsDisplay = true
        }
    }

    private var isMoving: Bool {
        if case .moving = interaction { return true }
        return false
    }

    private func screenBounds(_ frozenScreen: FrozenScreen) -> CGRect {
        CGRect(origin: .zero, size: frozenScreen.screen.frame.size)
    }

    private func globalPoint(for localPoint: CGPoint, in frozenScreen: FrozenScreen) -> CGPoint {
        ScreenGeometry.globalPoint(fromLocal: localPoint, screenFrame: frozenScreen.screen.frame)
    }

    private func frozenScreen(displayID: CGDirectDisplayID) -> FrozenScreen? {
        frozenScreens.first { $0.displayID == displayID }
    }

    private func view(for frozenScreen: FrozenScreen) -> CaptureOverlayView? {
        guard let index = frozenScreens.firstIndex(where: { $0.displayID == frozenScreen.displayID }),
              views.indices.contains(index) else {
            return nil
        }
        return views[index]
    }

    private func view(for screen: NSScreen) -> CaptureOverlayView? {
        guard let frozen = frozenScreens.first(where: { $0.screen === screen }) else { return nil }
        return view(for: frozen)
    }

    private func resizeCursor(for handle: ScreenGeometry.Handle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        }
    }

    private static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func makeCandidates(
        from descriptors: [ScreenCaptureService.WindowDescriptor],
        frozenScreens: [FrozenScreen],
        mainScreenFrame: CGRect
    ) -> [WindowCandidate] {
        descriptors.compactMap { descriptor -> WindowCandidate? in
            let appKitFrame = ScreenGeometry.appKitRect(
                fromCGWindowFrame: descriptor.frame,
                mainScreenFrame: mainScreenFrame
            )
            guard appKitFrame.width >= 1, appKitFrame.height >= 1 else { return nil }

            var bestScreen: FrozenScreen?
            var bestArea: CGFloat = 0
            for frozen in frozenScreens {
                let intersection = frozen.screen.frame.intersection(appKitFrame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = frozen
                }
            }
            guard let bestScreen, bestArea >= 16 else { return nil }
            return WindowCandidate(
                descriptor: descriptor,
                appKitFrame: appKitFrame,
                screenDisplayID: bestScreen.displayID
            )
        }
    }
}

// MARK: - 文本输入

extension CaptureOverlayController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // 点击别处导致失焦时提交；commitTextEditing 内部会把 textField 置空，避免重复提交。
        commitTextEditing()
    }
}
