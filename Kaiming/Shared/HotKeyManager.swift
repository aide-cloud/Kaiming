import AppKit
import Carbon.HIToolbox
import Combine

/// 可注册的全局快捷键动作。
enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case captureRegion
    case captureWindow
    case captureFullScreen
    case openMarkdown

    var id: String { rawValue }

    var registrationID: UInt32 {
        switch self {
        case .captureRegion: 1
        case .captureWindow: 2
        case .captureFullScreen: 3
        case .openMarkdown: 4
        }
    }

    var title: String {
        switch self {
        case .captureRegion: "区域截图"
        case .captureWindow: "窗口截图"
        case .captureFullScreen: "全屏截图"
        case .openMarkdown: "Markdown 编辑器"
        }
    }

    /// Carbon 虚拟键码（kVK_* 常量）。
    var keyCode: UInt32 {
        switch self {
        case .captureRegion: UInt32(kVK_ANSI_S)
        case .captureWindow: UInt32(kVK_ANSI_W)
        case .captureFullScreen: UInt32(kVK_ANSI_F)
        case .openMarkdown: UInt32(kVK_ANSI_M)
        }
    }

    /// 默认组合：⌥⇧ + 字母。
    var carbonModifiers: UInt32 {
        UInt32(optionKey | shiftKey)
    }

    var displayString: String {
        switch self {
        case .captureRegion: "⌥⇧S"
        case .captureWindow: "⌥⇧W"
        case .captureFullScreen: "⌥⇧F"
        case .openMarkdown: "⌥⇧M"
        }
    }
}

/// Carbon 回调与 Swift 之间的桥。仅在主线程读写。
private final class HotKeyBridge: @unchecked Sendable {
    static let shared = HotKeyBridge()
    var actionForID: [UInt32: HotKeyAction] = [:]
    var onAction: (@MainActor (HotKeyAction) -> Void)?
    private init() {}
}

/// Carbon 事件回调（C 函数指针，不能捕获上下文）。Carbon 主事件循环在主线程投递。
private func kaimingHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            if let action = HotKeyBridge.shared.actionForID[id] {
                HotKeyBridge.shared.onAction?(action)
            }
        }
    }
    return noErr
}

/// 全局快捷键注册（Carbon RegisterEventHotKey）。
///
/// 说明：Carbon 虽为旧 API，但仍是注册系统级热键唯一稳定的公开方式；
/// 这里只把它包在独立 Manager 内，业务侧只依赖 `HotKeyAction`。
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    /// 注册失败的动作 → 原因（通常是被其他应用占用）。
    @Published private(set) var failures: [HotKeyAction: String] = [:]

    private static let signature: OSType = 0x4B4D4E47 // 'KMNG'
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var isInstalled = false

    private init() {}

    func install() {
        if isInstalled {
            registerAll()
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            kaimingHotKeyEventHandler,
            1,
            &eventSpec,
            nil,
            &eventHandler
        )
        guard status == noErr else {
            Log.hotkey.error("InstallEventHandler failed: \(status, privacy: .public)")
            return
        }

        HotKeyBridge.shared.onAction = { [weak self] action in
            self?.handle(action)
        }
        isInstalled = true
        registerAll()
    }

    func uninstall() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        isInstalled = false
        HotKeyBridge.shared.onAction = nil
    }

    /// 设置变化后重新注册。
    func reload() {
        guard isInstalled else {
            install()
            return
        }
        registerAll()
    }

    private func registerAll() {
        unregisterAll()
        guard SettingsStore.shared.hotkeysEnabled else {
            Log.hotkey.info("Global hotkeys disabled in settings")
            return
        }

        var newFailures: [HotKeyAction: String] = [:]
        for action in HotKeyAction.allCases {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.registrationID)
            let status = RegisterEventHotKey(
                action.keyCode,
                action.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                HotKeyBridge.shared.actionForID[action.registrationID] = action
                Log.hotkey.info("Registered \(action.rawValue, privacy: .public) as \(action.displayString, privacy: .public)")
            } else {
                newFailures[action] = "快捷键 \(action.displayString) 可能已被其他应用占用"
                Log.hotkey.error("RegisterEventHotKey failed for \(action.rawValue, privacy: .public): \(status, privacy: .public)")
            }
        }
        failures = newFailures
    }

    private func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        HotKeyBridge.shared.actionForID.removeAll()
    }

    private func handle(_ action: HotKeyAction) {
        guard SettingsStore.shared.hotkeysEnabled else { return }
        Log.hotkey.info("Hotkey triggered: \(action.rawValue, privacy: .public)")

        switch action {
        case .captureRegion:
            ScreenshotCoordinator.shared.start(mode: .region)
        case .captureWindow:
            ScreenshotCoordinator.shared.start(mode: .window)
        case .captureFullScreen:
            ScreenshotCoordinator.shared.start(mode: .fullScreen)
        case .openMarkdown:
            AppRouter.shared.openMarkdown()
        }
    }
}
