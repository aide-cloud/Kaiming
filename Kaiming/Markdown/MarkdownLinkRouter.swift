import Foundation

enum MarkdownLinkDestination: Equatable {
    case external(URL)
    case internalFile(URL)
    case invalid(String)
}

/// 把引擎回调的链接 URL 解析成“应用内文件”或“交给系统打开”。
///
/// 引擎的 `.link` 属性可能带 scheme（http/file），也可能是相对路径
/// （docs/a.md、assets/pic.png、/abs/path、./x、../x、~/x）。相对路径
/// 一律以当前 Markdown 文件所在目录为基准；没有基准目录时返回可读错误。
enum MarkdownLinkRouter {
    static func route(_ url: URL, baseDirectory: URL?) -> MarkdownLinkDestination {
        if let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            switch scheme {
            case "http", "https":
                return .external(url)
            case "file":
                return .internalFile(URL(fileURLWithPath: url.path))
            default:
                return .external(url)
            }
        }

        var raw = url.relativeString.removingPercentEncoding ?? url.relativeString
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("<"), raw.hasSuffix(">"), raw.count > 2 {
            raw = String(raw.dropFirst().dropLast())
        }
        guard !raw.isEmpty else {
            return .invalid("链接为空。")
        }
        if raw.hasPrefix("#") {
            return .invalid("文档内锚点暂时不支持跳转。")
        }

        // 文件链接的 #fragment 只用于定位，当前不解析锚点。
        if let hashIndex = raw.firstIndex(of: "#") {
            raw = String(raw[..<hashIndex])
        }
        guard !raw.isEmpty else {
            return .invalid("链接只包含锚点，当前不支持跳转。")
        }

        if raw.hasPrefix("~/") {
            return .internalFile(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        if raw.hasPrefix("/") {
            return .internalFile(URL(fileURLWithPath: raw))
        }
        guard let baseDirectory else {
            return .invalid("当前文档还没有保存位置，无法解析相对路径。")
        }
        return .internalFile(baseDirectory.appendingPathComponent(raw).standardizedFileURL)
    }
}
