import Foundation

/// 剪贴板列表的展示分区，对应面板与快捷选择窗口里的两个 tab。
///
/// - `favorites`：用户手动收藏的条目，**永久保留**，不计入实时历史的条数上限，
///   也不会被「清空实时历史」删掉；只有用户主动取消收藏或删除才会消失。
/// - `live`：随系统剪贴板自动累积的实时历史，按复制时间倒序，超过上限时淘汰最旧的记录。
///   收藏项同样出现在实时列表里（带星标），避免收藏后「历史里找不到」的困惑。
enum ClipboardScope: String, CaseIterable, Identifiable, Sendable {
    case favorites
    case live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "收藏"
        case .live: return "实时"
        }
    }

    var symbolName: String {
        switch self {
        case .favorites: return "star.fill"
        case .live: return "clock.arrow.circlepath"
        }
    }
}
