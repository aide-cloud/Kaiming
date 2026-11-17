import AppKit
import Carbon.HIToolbox
import Combine

/// 可注册的全局快捷键动作。
enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case captureRegion
    case captureWindow
    case captureFullScreen
    case openClipboard
    case openMarkdown

    var id: String { rawValue }

    var registrationID: UInt32 {
        switch self {
        case .captureRegion: 1
        case .captureWindow: 2
        case .captureFullScreen: 3
        case .openClipboard: 4
        case .openMarkdown: 5
        }
    }

    var title: String {
        switch self {
        case .captureRegion: "区域截图"
        case .captureWindow: "窗口截图"
        case .captureFullScreen: "全屏截图"
        case .openClipboard: "剪贴板快捷选择"
        case .openMarkdown: "Markdown 编辑器"
        }
    }

    /// 默认组合：⌥⇧ + 字母。
    var defaultBinding: HotKeyBinding {
        let modifiers = UInt32(optionKey | shiftKey)
        return switch self {
        case .captureRegion:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers)
        case .captureWindow:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_W), modifiers: modifiers)
        case .captureFullScreen:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: modifiers)
        case .openClipboard:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: modifiers)
        case .openMarkdown:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: modifiers)
        }
    }

    /// 当前生效的组合键（来自设置；未自定义时取默认值）。
    @MainActor
    var binding: HotKeyBinding {
        SettingsStore.shared.binding(for: self)
    }

    @MainActor
    var displayString: String {
        binding.displayString
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
    /// 录制快捷键期间暂停注册，避免按下已有组合键时先触发原来的全局动作。
    private var isSuspended = false

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

    /// 进入录制状态：临时注销全部全局热键，让设置页能收到组合键本身。
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
        failures = [:]
        Log.hotkey.info("Global hotkeys suspended for recording")
    }

    /// 结束录制并恢复到设置中的组合键。
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
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
        guard !isSuspended else { return }
        guard SettingsStore.shared.hotkeysEnabled else {
            Log.hotkey.info("Global hotkeys disabled in settings")
            return
        }

        var newFailures: [HotKeyAction: String] = [:]
        var ownerByBinding: [HotKeyBinding: HotKeyAction] = [:]
        for action in HotKeyAction.allCases {
            let binding = SettingsStore.shared.binding(for: action)
            if let error = binding.validationError {
                newFailures[action] = "快捷键 \(binding.displayString) 不可用：\(error)"
                continue
            }
            if let owner = ownerByBinding[binding] {
                newFailures[action] = "快捷键 \(binding.displayString) 与「\(owner.title)」重复"
                continue
            }
            ownerByBinding[binding] = action

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.registrationID)
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                HotKeyBridge.shared.actionForID[action.registrationID] = action
                Log.hotkey.info("Registered \(action.rawValue, privacy: .public) as \(binding.displayString, privacy: .public)")
            } else {
                newFailures[action] = "快捷键 \(binding.displayString) 可能已被其他应用占用"
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
        case .openClipboard:
            AppRouter.shared.openClipboardPicker()
        case .openMarkdown:
            AppRouter.shared.openMarkdown()
        }
    }
}
