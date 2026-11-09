import Foundation

/// 截图模式。App 层（菜单栏 / 全局快捷键）与截图模块共享的唯一命令类型。
enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case region
    case window
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .region: "区域截图"
        case .window: "窗口截图"
        case .fullScreen: "全屏截图"
        }
    }

    var subtitle: String {
        switch self {
        case .region: "拖拽框选任意区域"
        case .window: "点选一个窗口"
        case .fullScreen: "截取当前整块屏幕"
        }
    }

    var symbolName: String {
        switch self {
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .fullScreen: "display"
        }
    }
}
