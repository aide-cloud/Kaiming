import Foundation

/// Markdown 内容区的页宽。`standard` 是默认阅读窄栏，`wide` 放宽，`full` 铺满窗口。
enum MarkdownPageWidth: String, CaseIterable, Identifiable, Sendable {
    case standard
    case wide
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "默认"
        case .wide: "较宽"
        case .full: "全宽"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "text.aligncenter"
        case .wide: "rectangle.expand.vertical"
        case .full: "rectangle.inset.filled"
        }
    }

    /// 编辑区与预览区的最大内容宽度（pt）；`nil` 表示铺满可用宽度。
    var maxContentWidth: CGFloat? {
        switch self {
        case .standard: 780
        case .wide: 1040
        case .full: nil
        }
    }

    /// WebView 预览用的 CSS `max-width`；与 ``maxContentWidth`` 同源。
    var cssMaxWidth: String {
        if let maxContentWidth {
            "\(Int(maxContentWidth))px"
        } else {
            "none"
        }
    }
}
