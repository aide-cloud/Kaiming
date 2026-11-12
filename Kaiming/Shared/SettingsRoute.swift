import Combine
import Foundation

/// 设置窗口的分类。
///
/// 放在 `Shared/` 而不是 `SettingsView` 里，是为了让「权限中心」等共享入口
/// 能直接请求打开某一个设置页，而不必引用 Settings 模块的视图类型。
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case permissions
    case screenshot
    case clipboard
    case markdown
    case shortcuts
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .permissions: "权限"
        case .screenshot: "截图"
        case .clipboard: "剪贴板"
        case .markdown: "Markdown"
        case .shortcuts: "快捷键"
        case .about: "关于"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "lock.shield"
        case .screenshot: "crop"
        case .clipboard: "doc.on.clipboard"
        case .markdown: "doc.richtext"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }
}

/// 单例的设置页跳转请求。
///
/// `SettingsView` 观察 `pendingTab` 并在出现 / 变化时消费；其他模块只调用
/// `AppRouter.shared.openSettings(tab:)`，不直接操作设置窗口。
@MainActor
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()

    @Published private(set) var pendingTab: SettingsTab?

    private init() {}

    func request(_ tab: SettingsTab) {
        pendingTab = tab
    }

    /// 取走一次性请求；重复请求同一页面也能再次触发。
    func consume() -> SettingsTab? {
        defer { pendingTab = nil }
        return pendingTab
    }
}
