import AppKit
import Combine
import SwiftUI

/// 区域 / 窗口截图的冻结覆盖层。
///
/// 生命周期：
/// 1. 外部先在主线程完成「冻结截图」，再把每块屏幕的位图交给本控制器；
/// 2. `present()` 为每块屏幕创建一个 `.screenSaver` 级别的无边框窗口；
/// 3. 用户框选/点选后进入标注阶段，`confirm()` 把底图、标注与圆角遮罩拍平后通过 `onFinish` 回传；
/// 4. 区域截图可进入长截图：隐藏覆盖层、用 CGEvent/用户滚动逐帧重新截取选区，
///    行哈希拼接后回到预览确认；
/// 5. `teardown()` 移除事件监听、输入框、工具栏、长截图任务与全部窗口，避免循环引用。
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
            case longPreview
        }

        let screen: FrozenScreen
        var rect: CGRect
        let image: CGImage?
        let source: Source
        /// 窗口标题 / 长截图信息，显示在选区上方。
        let title: String?
    }

    private enum Interaction {
        case none
        case selecting(start: CGPoint)
        case resizing(handle: ScreenGeometry.Handle, initial: CGRect)
        case moving(start: CGPoint, initial: CGRect)
        case annotating(kind: Annotation.Kind, start: CGPoint)
    }

    private enum LongCapturePhase {
        case idle
        case choosing
        case capturing
        case preview
    }

    private enum LongCaptureStopReason {
        case userFinished
        case noChange
        case manualIdle
        case noOverlap
        case heightLimit
        case frameLimit

        var message: String {
            switch self {
            case .userFinished:
                "长截图已生成，请确认后保存。"
            case .noChange:
                "页面内容没有变化，已停止：可能已到页面顶部/底部，或自动滚动未生效。已保留当前采集内容，可确认或改用手动滚动拼接。"
            case .manualIdle:
                "长时间没有检测到页面滚动，已停止并保留当前内容。可点「完成」确认，或返回后重新进入长截图继续采集。"
            case .noOverlap:
                "未检测到与上一屏的重叠区域，已停止：滚动幅度可能过大，或页面含固定标题栏。已保留当前采集内容，可确认或改用手动滚动拼接。"
            case .heightLimit:
                "已达到 20000px 高度上限，已停止并保留当前内容。"
            case .frameLimit:
                "已达到采集屏数上限，已停止并保留当前内容。"
            }
        }
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

    // MARK: 长截图

    private var longCapturePhase: LongCapturePhase = .idle
    private var longCaptureMode: LongScreenshotMode = .manual
    private var longCaptureSessionID = UUID()
    private var longCaptureTask: Task<Void, Never>?
    private var composer = LongScreenshotComposer()
    private var longCaptureBarHost: NSHostingView<LongCaptureBar>?
    private var longCaptureHUDWindow: OverlayWindow?
    private var longCaptureHUDHost: NSHostingView<LongCaptureHUD>?
    private let longCaptureOptions = LongCaptureOptionsModel()
    private let longCaptureProgress = LongCaptureProgressModel()
    private var noticeText: String?
    private var noticeIsError = false
    private var noticeTask: Task<Void, Never>?

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

    private var isOverlayMouseEnabled: Bool {
        switch longCapturePhase {
        case .idle, .preview: true
        case .choosing, .capturing: false
        }
    }

    private var isLongCapturing: Bool {
        if case .capturing = longCapturePhase { return true }
        return false
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

        let cornerRadius = session.clampedCornerRadius
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
                boundsInPoints: target.rect.size,
                cornerRadius: cornerRadius
            )
        case .window, .longPreview:
            guard let image = target.image else {
                fail("截图数据丢失，请重新截图。")
                return
            }
            flattened = AnnotationDrawing.render(
                baseImage: image,
                annotations: session.annotations,
                boundsInPoints: target.rect.size,
                cornerRadius: cornerRadius
            )
        }

        guard let image = flattened else {
            fail("生成标注图像失败，请重试。")
            return
        }
        Log.screenshot.info(
            "Capture confirmed audio=\(self.session.annotations.count, privacy: .public) radius=\(Int(cornerRadius), privacy: .public)"
        )
        finish(with: image)
    }

    func cancel() {
        guard !isFinished else { return }
        if isLongCapturing {
            cancelLongCapture()
            return
        }
        isFinished = true
        let callback = onCancel
        teardown()
        callback?()
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard !isFinished, let eventWindow = event.window else { return event }
        let consumed = handleMonitoredKey(keyCode: event.keyCode, windowNumber: eventWindow.windowNumber)
        return consumed ? nil : event
    }

    private func handleMonitoredKey(keyCode: UInt16, windowNumber: Int) -> Bool {
        guard !isFinished, textField == nil else { return false }

        switch longCapturePhase {
        case .capturing:
            guard longCaptureHUDWindow?.windowNumber == windowNumber else { return false }
            switch keyCode {
            case 53: // Esc
                cancelLongCapture()
                return true
            case 36, 76: // Return / 小键盘 Enter
                finishLongCaptureFromUser()
                return true
            default:
                return false
            }

        case .choosing:
            guard windows.contains(where: { $0.windowNumber == windowNumber }) else { return false }
            if keyCode == 53 {
                cancelLongCaptureChoosing()
                return true
            }
            return false

        case .idle, .preview:
            guard windows.contains(where: { $0.windowNumber == windowNumber }) else { return false }
            return handleKeyCode(keyCode)
        }
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
        longCaptureTask?.cancel()
        longCaptureTask = nil
        longCapturePhase = .idle
        closeLongCaptureHUD()
        removeLongCaptureBar()
        noticeTask?.cancel()
        noticeTask = nil
        noticeText = nil

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
        session.$cornerRadius
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshViews() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 鼠标交互

    func mouseDown(at point: CGPoint, in frozenScreen: FrozenScreen, clickCount: Int) {
        guard isOverlayMouseEnabled, !isFinished, !isCapturingWindow else { return }
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
        guard isOverlayMouseEnabled, !isFinished else { return }
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
        guard isOverlayMouseEnabled, !isFinished else { return }

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
                showToolbar(showsLongCapture: true)
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
        guard isOverlayMouseEnabled, !isFinished, !isCapturingWindow else { return }
        guard mode == .window, target == nil else { return }
        let local = ScreenGeometry.clamped(point, to: screenBounds(frozenScreen))
        let candidate = candidate(at: globalPoint(for: local, in: frozenScreen))
        guard candidate?.id != hoveredCandidate?.id else { return }
        hoveredCandidate = candidate
        refreshViews()
    }

    func cursor(at point: CGPoint, in frozenScreen: FrozenScreen) -> NSCursor {
        guard !isFinished, isOverlayMouseEnabled else { return .arrow }
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
                        if target.source != .region { return .arrow }
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
        showToolbar(showsLongCapture: false)
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

    // MARK: - 工具栏 / 长截图入口

    private func showToolbar(showsLongCapture: Bool) {
        removeToolbar()
        removeLongCaptureBar()
        guard let target, let view = view(for: target.screen) else { return }
        let host = NSHostingView(
            rootView: AnnotationToolbar(
                session: session,
                showsLongCapture: showsLongCapture,
                onStartLongCapture: { [weak self] in self?.beginLongCaptureChoosing() },
                onComplete: { [weak self] in self?.confirm() },
                onCancel: { [weak self] in self?.cancel() }
            )
        )
        host.frame = CGRect(origin: .zero, size: AnnotationToolbar.preferredSize)
        toolbarHost = host
        view.addSubview(host)
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
        host.frame = floatingFrame(
            size: AnnotationToolbar.preferredSize,
            targetRect: target.rect,
            viewBounds: screenBounds(target.screen)
        )
        view.window?.invalidateCursorRects(for: view)
    }

    private func beginLongCaptureChoosing() {
        guard !isFinished, longCapturePhase == .idle, let target, target.source == .region,
              let view = view(for: target.screen) else { return }
        if textField != nil {
            commitTextEditing()
        }
        longCapturePhase = .choosing
        longCaptureOptions.accessibilityTrusted = AccessibilityPermission.isTrusted
        longCaptureOptions.message = nil
        removeToolbar()
        removeLongCaptureBar()

        let host = NSHostingView(
            rootView: LongCaptureBar(
                model: longCaptureOptions,
                onAutomatic: { [weak self] in self?.attemptAutomaticLongCapture() },
                onManual: { [weak self] in self?.startLongCapture(mode: .manual) },
                onBack: { [weak self] in self?.cancelLongCaptureChoosing() },
                onOpenAccessibilitySettings: {
                    AccessibilityPermission.openSystemSettings()
                }
            )
        )
        host.frame = CGRect(origin: .zero, size: LongCaptureBar.preferredSize)
        longCaptureBarHost = host
        view.addSubview(host)
        layoutLongCaptureBar()
        refreshViews()
        Log.screenshot.info("Long capture mode chooser presented")
    }

    private func attemptAutomaticLongCapture() {
        guard longCapturePhase == .choosing else { return }
        var trusted = AccessibilityPermission.isTrusted
        if !trusted {
            _ = AccessibilityPermission.prompt()
            trusted = AccessibilityPermission.isTrusted
            longCaptureOptions.accessibilityTrusted = trusted
        }
        guard trusted else {
            longCaptureOptions.message = "辅助功能未授权：请在“系统设置 › 隐私与安全性 › 辅助功能”中勾选 Kaiming，并重新启动应用；也可以直接手动滚动拼接。"
            Log.screenshot.error("Long capture auto scroll blocked: accessibility not trusted")
            return
        }
        longCaptureOptions.accessibilityTrusted = true
        startLongCapture(mode: .automatic)
    }

    private func cancelLongCaptureChoosing() {
        guard longCapturePhase == .choosing else { return }
        removeLongCaptureBar()
        longCapturePhase = .idle
        if let target, target.source == .region {
            showToolbar(showsLongCapture: true)
        }
        refreshViews()
    }

    private func startLongCapture(mode: LongScreenshotMode) {
        guard longCapturePhase == .choosing, let target, target.source == .region else { return }
        longCapturePhase = .capturing
        longCaptureMode = mode
        longCaptureSessionID = UUID()
        let sessionID = longCaptureSessionID
        // 自动滚动步长约为选区高度的 55%，因此重叠窗口按帧高度的 80% 配置，
        // 兼容高分辨率/大选区（默认 1600px 在高分屏下可能不够）。
        let estimatedFrameHeight = max(1, Int(target.rect.height * max(target.screen.scale, 1)))
        let overlapWindow = min(6_000, max(600, Int(Double(estimatedFrameHeight) * 0.8)))
        composer = LongScreenshotComposer(maximumOverlap: overlapWindow)
        session.clear()
        removeLongCaptureBar()
        removeToolbar()
        hideOverlaysForLongCapture()
        showLongCaptureHUD(on: target.screen, mode: mode)
        updateLongProgress(for: nil, mode: mode, statusOverride: "正在截取第一屏…")
        Log.screenshot.info(
            "Long capture started mode=\(mode.rawValue, privacy: .public) display=\(target.screen.displayID, privacy: .public) selection=\(Int(target.rect.width), privacy: .public)x\(Int(target.rect.height), privacy: .public)pt"
        )

        longCaptureTask = Task { @MainActor [weak self] in
            await self?.runLongCapture(sessionID: sessionID)
        }
    }

    private func layoutLongCaptureBar() {
        guard let target, let host = longCaptureBarHost, let view = view(for: target.screen) else {
            return
        }
        host.frame = floatingFrame(
            size: LongCaptureBar.preferredSize,
            targetRect: target.rect,
            viewBounds: screenBounds(target.screen)
        )
        view.window?.invalidateCursorRects(for: view)
    }

    private func removeLongCaptureBar() {
        longCaptureBarHost?.removeFromSuperview()
        longCaptureBarHost = nil
    }

    // MARK: - 长截图采集

    private func hideOverlaysForLongCapture() {
        for window in windows {
            window.ignoresMouseEvents = true
            window.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreOverlays() {
        for window in windows {
            window.ignoresMouseEvents = false
            window.orderFrontRegardless()
        }
        if let target,
           let index = frozenScreens.firstIndex(where: { $0.displayID == target.screen.displayID }),
           windows.indices.contains(index) {
            windows[index].makeKey()
            if views.indices.contains(index) {
                windows[index].makeFirstResponder(views[index])
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showLongCaptureHUD(on frozen: FrozenScreen, mode: LongScreenshotMode) {
        closeLongCaptureHUD()
        let size = LongCaptureHUD.preferredSize
        let screenFrame = frozen.screen.frame
        let frame = CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
        let window = OverlayWindow(
            contentRect: frame,
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
        window.isReleasedWhenClosed = false

        let host = NSHostingView(
            rootView: LongCaptureHUD(
                model: longCaptureProgress,
                onFinish: { [weak self] in self?.finishLongCaptureFromUser() },
                onCancel: { [weak self] in self?.cancelLongCapture() }
            )
        )
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(host)
        longCaptureHUDWindow = window
        longCaptureHUDHost = host
        longCaptureProgress.modeTitle = mode.title
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeLongCaptureHUD() {
        longCaptureHUDWindow?.orderOut(nil)
        longCaptureHUDWindow?.close()
        longCaptureHUDWindow = nil
        longCaptureHUDHost = nil
    }

    private func runLongCapture(sessionID: UUID) async {
        guard let target, target.source == .region,
              longCapturePhase == .capturing,
              longCaptureSessionID == sessionID else { return }
        let screen = target.screen.screen
        let selection = target.rect
        let selectionCenterGlobal = ScreenGeometry.globalPoint(
            fromLocal: CGPoint(x: selection.midX, y: selection.midY),
            screenFrame: screen.frame
        )
        // 长截图的逐帧画面不采集鼠标指针：指针停在选区里会破坏行哈希重叠匹配。
        let showsCursor = false
        let selectedMode = longCaptureMode

        // 第一帧：每次都用 SCK 重新截取选区，不使用冻结图。
        do {
            let frame = try await captureSelectionFrame(
                screen: screen,
                selection: selection,
                showsCursor: showsCursor
            )
            guard isCurrentLongCapture(sessionID) else { return }
            let result = composer.append(frame)
            guard isCurrentLongCapture(sessionID) else { return }
            updateLongProgress(for: result, mode: selectedMode)
            if case .failed = result {
                stopLongCaptureWithError("第一帧无法拼接，请重试。")
                return
            }
        } catch {
            stopLongCaptureWithError(longCaptureErrorMessage(error))
            return
        }

        var idleSteps = 0
        var stepCount = 0
        let maximumSteps = selectedMode == .automatic ? 80 : 300

        while isCurrentLongCapture(sessionID) {
            if composer.totalHeight >= LongScreenshotComposer.maxHeightPixels {
                finishLongCapture(reason: .heightLimit)
                return
            }

            if selectedMode == .automatic {
                let step = max(24, Int(selection.height * 0.55))
                postScrollEvent(stepPoints: step, atGlobal: selectionCenterGlobal)
            }

            do {
                // 自动滚动的等待包含滚动动画时间；手动模式则固定间隔采样。
                try await Task.sleep(
                    nanoseconds: selectedMode == .automatic ? 550_000_000 : 900_000_000
                )
            } catch {
                return
            }
            guard isCurrentLongCapture(sessionID) else { return }

            do {
                let frame = try await captureSelectionFrame(
                    screen: screen,
                    selection: selection,
                    showsCursor: showsCursor
                )
                guard isCurrentLongCapture(sessionID) else { return }
                let result = composer.append(frame)
                guard isCurrentLongCapture(sessionID) else { return }

                switch result {
                case .firstFrame:
                    break
                case let .appended(_, added, _, headerTrimmed):
                    idleSteps = 0
                    updateLongProgress(for: result, mode: selectedMode)
                    Log.screenshot.info(
                        "Long capture appended \(added, privacy: .public)px total=\(self.composer.totalHeight, privacy: .public)px header=\(headerTrimmed, privacy: .public)px"
                    )
                case .noChange:
                    if selectedMode == .automatic {
                        idleSteps += 1
                        updateLongProgress(for: result, mode: selectedMode)
                        if idleSteps >= 2 {
                            finishLongCapture(reason: .noChange)
                            return
                        }
                    } else {
                        idleSteps += 1
                        updateLongProgress(
                            for: result,
                            mode: selectedMode,
                            statusOverride: idleSteps >= 3
                                ? "等待页面滚动…（长时间无变化会自动停止）"
                                : "等待页面滚动…"
                        )
                        if idleSteps >= 60 {
                            finishLongCapture(reason: .manualIdle)
                            return
                        }
                    }
                case .noOverlap:
                    finishLongCapture(reason: .noOverlap)
                    return
                case .heightLimit:
                    finishLongCapture(reason: .heightLimit)
                    return
                case .failed:
                    stopLongCaptureWithError("当前画面无法拼接，已停止。")
                    return
                }
            } catch {
                stopLongCaptureWithError(longCaptureErrorMessage(error))
                return
            }

            stepCount += 1
            if stepCount >= maximumSteps {
                finishLongCapture(reason: .frameLimit)
                return
            }
        }
    }

    private func captureSelectionFrame(
        screen: NSScreen,
        selection: CGRect,
        showsCursor: Bool
    ) async throws -> CGImage {
        guard let displayID = Self.displayID(of: screen) else {
            throw ScreenshotError.noDisplay
        }
        return try await ScreenCaptureService.captureRegion(
            displayID: displayID,
            selectionInScreen: selection,
            screenPointSize: screen.frame.size,
            showsCursor: showsCursor
        )
    }

    private func longCaptureErrorMessage(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "长截图采集失败：\(detail)"
    }

    private func isCurrentLongCapture(_ sessionID: UUID) -> Bool {
        !Task.isCancelled
            && !isFinished
            && longCapturePhase == .capturing
            && longCaptureSessionID == sessionID
    }

    private func postScrollEvent(stepPoints: Int, atGlobal point: CGPoint) {
        let mainHeight = NSScreen.main?.frame.maxY ?? 0
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-max(1, stepPoints)),
            wheel2: 0,
            wheel3: 0
        ) else {
            Log.screenshot.error("Unable to create long capture scroll event")
            return
        }
        // CGEvent 使用主屏左上角为原点的坐标。
        event.location = CGPoint(x: point.x, y: mainHeight - point.y)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func updateLongProgress(
        for result: LongScreenshotComposer.AppendResult?,
        mode: LongScreenshotMode,
        statusOverride: String? = nil
    ) {
        longCaptureProgress.modeTitle = mode.title
        if composer.totalHeight > 0 {
            longCaptureProgress.dimensionText = "\(composer.pixelWidth) × \(composer.totalHeight) px"
        } else {
            longCaptureProgress.dimensionText = ""
        }
        longCaptureProgress.progress = min(
            1,
            Double(composer.totalHeight) / Double(LongScreenshotComposer.maxHeightPixels)
        )

        if let statusOverride {
            longCaptureProgress.statusText = statusOverride
        } else if let result {
            switch result {
            case .firstFrame:
                longCaptureProgress.statusText = "已截取第一屏，等待滚动…"
            case let .appended(_, added, _, headerTrimmed):
                var text = "已采集 \(composer.frameCount) 屏，本次新增 \(added) px"
                if headerTrimmed > 0 {
                    text += "（已折叠固定标题 \(headerTrimmed)px）"
                }
                longCaptureProgress.statusText = text
            case .noChange:
                longCaptureProgress.statusText = mode == .automatic
                    ? "页面没有变化：可能已到顶部/底部，或自动滚动未生效…"
                    : "等待页面滚动…"
            case .noOverlap:
                longCaptureProgress.statusText = "未检测到与上一屏的重叠区域。"
            case .heightLimit:
                longCaptureProgress.statusText = "已达到 20000px 高度上限。"
            case .failed:
                longCaptureProgress.statusText = "当前帧无法处理。"
            }
        }

        longCaptureProgress.hintText = mode == .automatic
            ? "自动滚动中：若页面未移动，请检查辅助功能权限或改用手动滚动。Return 提前完成 · Esc 取消。"
            : "滚动页面即可自动采样。Return 完成 · Esc 取消；若网页抢走焦点，可点本面板按钮。"
    }

    private func finishLongCaptureFromUser() {
        guard longCapturePhase == .capturing else { return }
        finishLongCapture(reason: .userFinished)
    }

    private func finishLongCapture(reason: LongCaptureStopReason) {
        guard longCapturePhase == .capturing else { return }
        longCaptureTask?.cancel()
        longCaptureTask = nil

        guard let target, target.source == .region, let image = composer.image else {
            stopLongCaptureWithError("没有采集到可以拼接的画面，请重试。")
            return
        }
        let headerHeight = composer.fixedHeaderHeight
        let totalHeight = composer.totalHeight
        let frameCount = composer.frameCount
        let sourceScreen = target.screen

        longCapturePhase = .preview
        closeLongCaptureHUD()
        restoreOverlays()

        self.target = previewTarget(for: image, on: sourceScreen)
        // 预览持有裁剪后的 CGImage，可以释放拼接画布，避免长图在内存里保留多份。
        composer = LongScreenshotComposer()
        showToolbar(showsLongCapture: false)
        refreshViews()

        var message = reason.message
        if headerHeight > 0 {
            message += "（检测到固定标题栏：只保留首帧标题，后续帧已折叠 \(headerHeight)px）"
        }
        showOverlayNotice(message, isError: false)
        Log.screenshot.info(
            "Long capture finished height=\(totalHeight, privacy: .public)px frames=\(frameCount, privacy: .public) header=\(headerHeight, privacy: .public)"
        )
    }

    private func previewTarget(for image: CGImage, on frozen: FrozenScreen) -> Target {
        let scale = max(frozen.scale, 0.5)
        let pointSize = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let screenSize = frozen.screen.frame.size
        let maxWidth = max(120, screenSize.width * 0.74)
        let maxHeight = max(120, screenSize.height * 0.70)
        let factor = min(
            1,
            maxWidth / max(pointSize.width, 1),
            maxHeight / max(pointSize.height, 1)
        )
        let displaySize = CGSize(
            width: pointSize.width * factor,
            height: pointSize.height * factor
        )
        let rect = CGRect(
            x: (screenSize.width - displaySize.width) / 2,
            y: (screenSize.height - displaySize.height) / 2,
            width: displaySize.width,
            height: displaySize.height
        )
        return Target(
            screen: frozen,
            rect: rect,
            image: image,
            source: .longPreview,
            title: "长截图 · \(image.width) × \(image.height) px"
        )
    }

    private func cancelLongCapture() {
        switch longCapturePhase {
        case .capturing:
            longCaptureTask?.cancel()
            longCaptureTask = nil
            closeLongCaptureHUD()
            restoreOverlays()
            composer = LongScreenshotComposer()
            longCapturePhase = .idle
            if let target, target.source == .region {
                showToolbar(showsLongCapture: true)
            }
            showOverlayNotice("已取消长截图，可重新框选或再次进入长截图。")
            Log.screenshot.info("Long capture cancelled")
            refreshViews()
        case .choosing:
            cancelLongCaptureChoosing()
        case .idle, .preview:
            break
        }
    }

    private func stopLongCaptureWithError(_ message: String) {
        guard longCapturePhase == .capturing else { return }
        longCaptureTask?.cancel()
        longCaptureTask = nil
        closeLongCaptureHUD()
        restoreOverlays()
        composer = LongScreenshotComposer()
        longCapturePhase = .idle
        if let target, target.source == .region {
            showToolbar(showsLongCapture: true)
        }
        showOverlayNotice(message, isError: true)
        AppState.shared.flash(message, kind: .error)
        Log.screenshot.error("Long capture stopped: \(message, privacy: .public)")
        refreshViews()
    }

    // MARK: - 覆盖层提示

    private func showOverlayNotice(_ text: String, isError: Bool = false) {
        noticeText = text
        noticeIsError = isError
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.noticeText = nil
            self.noticeIsError = false
            self.refreshViews()
        }
        refreshViews()
    }

    private func floatingFrame(size: CGSize, targetRect: CGRect, viewBounds: CGRect) -> CGRect {
        var originX = targetRect.midX - size.width / 2
        var originY = targetRect.minY - size.height - 10
        if originY < 12 {
            originY = min(targetRect.maxY + 10, viewBounds.height - size.height - 12)
        }
        originX = min(max(originX, 12), max(12, viewBounds.width - size.width - 12))
        originY = min(max(originY, 12), max(12, viewBounds.height - size.height - 12))
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    // MARK: - 绘制

    func draw(frozenScreen: FrozenScreen, in view: CaptureOverlayView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = screenBounds(frozenScreen)
        let cornerRadius = session.clampedCornerRadius

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
            path.addPath(RoundedMask.path(for: clearRect, radius: cornerRadius))
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }
        context.restoreGState()

        if let target,
           target.source != .region,
           target.screen.displayID == frozenScreen.displayID,
           let image = target.image,
           target.rect.width > 0, target.rect.height > 0 {
            context.saveGState()
            context.addPath(RoundedMask.path(for: target.rect, radius: cornerRadius))
            context.clip()
            context.draw(image, in: target.rect)
            context.restoreGState()
        }

        if let target, target.screen.displayID == frozenScreen.displayID {
            context.saveGState()
            context.addPath(RoundedMask.path(for: target.rect, radius: cornerRadius))
            context.clip()
            for annotation in session.annotations {
                AnnotationDrawing.draw(annotation: annotation, in: context, origin: target.rect.origin)
            }
            if let draft {
                AnnotationDrawing.draw(annotation: draft, in: context, origin: target.rect.origin)
            }
            context.restoreGState()

            clearRoundedCorners(rect: target.rect, radius: cornerRadius, context: context)

            drawChrome(
                rect: target.rect,
                cornerRadius: cornerRadius,
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
            clearRoundedCorners(rect: selection, radius: cornerRadius, context: context)
            drawChrome(
                rect: selection,
                cornerRadius: cornerRadius,
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

        if let noticeText,
           frozenScreen.displayID == (target?.screen.displayID ?? hintDisplayID) {
            drawNotice(noticeText, isError: noticeIsError, context: context, viewBounds: bounds)
        }
    }

    /// 覆盖层预览也把圆角外区域真正“挖空”，让窗口透明处露出桌面，
    /// 与最终 PNG 的圆角外透明保持一致（而不是只有边框变圆）。
    private func clearRoundedCorners(rect: CGRect, radius: CGFloat, context: CGContext) {
        let clamped = RoundedMask.clampedRadius(radius, in: rect)
        guard clamped > 0 else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(CGPath(rect: rect, transform: nil))
        context.addPath(RoundedMask.path(for: rect, radius: clamped))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    private func drawChrome(
        rect: CGRect,
        cornerRadius: CGFloat,
        context: CGContext,
        scale: CGFloat,
        showHandles: Bool,
        windowTitle: String?,
        viewBounds: CGRect
    ) {
        let accent = NSColor.controlAccentColor
        let borderRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let borderRadius = RoundedMask.clampedRadius(max(0, cornerRadius - 0.75), in: borderRect)
        context.saveGState()
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1.5)
        context.addPath(RoundedMask.path(for: borderRect, radius: borderRadius))
        context.strokePath()
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
        var sizeText = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt · \(pixelWidth) × \(pixelHeight) px"
        if cornerRadius > 0 {
            sizeText += " · 圆角 \(Int(cornerRadius.rounded()))pt"
        }
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

    private func drawNotice(
        _ text: String,
        isError: Bool,
        context: CGContext,
        viewBounds: CGRect
    ) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let maxWidth = max(200, min(viewBounds.width - 64, 760))
        let bounding = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let padding = CGSize(width: 12, height: 8)
        let boxSize = CGSize(
            width: ceil(bounding.width) + padding.width * 2,
            height: ceil(bounding.height) + padding.height * 2
        )
        let box = CGRect(
            x: viewBounds.midX - boxSize.width / 2,
            y: viewBounds.maxY - boxSize.height - 52,
            width: boxSize.width,
            height: boxSize.height
        )
        context.saveGState()
        context.setFillColor((isError ? NSColor.systemRed : NSColor.black).withAlphaComponent(0.82).cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        context.restoreGState()
        attributed.draw(
            with: CGRect(
                x: box.minX + padding.width,
                y: box.minY + padding.height,
                width: bounding.width,
                height: bounding.height
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
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
