import AppKit

/// GitHub（Primer）内容配色：Markdown 编辑区与 WebView 渲染预览共用一份来源。
///
/// 颜色以 hex 字符串保存，方便直接拼进 WebView 的 CSS；原生侧再转成随系统
/// 外观自动切换的 `NSColor`。所有取值来自 GitHub 的 light / dark 主题：
/// - light：canvas `#ffffff`、正文 `#1f2328`、链接 `#0969da`、边框 `#d1d9e0`
/// - dark：canvas `#0d1117`、正文 `#e6edf3`、链接 `#4493f8`、边框 `#3d444d`
enum MarkdownGitHubTheme {
    struct Palette: Sendable {
        let canvas: String
        let canvasInset: String
        let text: String
        let muted: String
        let subtle: String
        let border: String
        let link: String
        let codeBackground: String
        let tableHeader: String
        let quoteText: String
        let accent: String
    }

    static let light = Palette(
        canvas: "#ffffff",
        canvasInset: "#f6f8fa",
        text: "#1f2328",
        muted: "#59636e",
        subtle: "#6e7781",
        border: "#d1d9e0",
        link: "#0969da",
        codeBackground: "#f6f8fa",
        tableHeader: "#f6f8fa",
        quoteText: "#59636e",
        accent: "#0969da"
    )

    static let dark = Palette(
        canvas: "#0d1117",
        canvasInset: "#151b23",
        text: "#e6edf3",
        muted: "#9198a1",
        subtle: "#6e7781",
        border: "#3d444d",
        link: "#4493f8",
        codeBackground: "#151b23",
        tableHeader: "#151b23",
        quoteText: "#9198a1",
        accent: "#4493f8"
    )

    // MARK: - 原生颜色

    static func color(_ hex: String) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return .labelColor
        }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// 同一个语义色在浅色/深色外观下各取一套 GitHub 值。
    static func dynamic(light lightHex: String, dark darkHex: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.aqua, .darkAqua])
            return color(best == .darkAqua ? darkHex : lightHex)
        }
    }

    // MARK: - 常用原生颜色

    static var canvas: NSColor { dynamic(light: light.canvas, dark: dark.canvas) }
    static var canvasInset: NSColor { dynamic(light: light.canvasInset, dark: dark.canvasInset) }
    static var text: NSColor { dynamic(light: light.text, dark: dark.text) }
    static var mutedText: NSColor { dynamic(light: light.muted, dark: dark.muted) }
    static var subtleText: NSColor { dynamic(light: light.subtle, dark: dark.subtle) }
    static var border: NSColor { dynamic(light: light.border, dark: dark.border) }
    static var link: NSColor { dynamic(light: light.link, dark: dark.link) }
    static var codeBackground: NSColor { dynamic(light: light.codeBackground, dark: dark.codeBackground) }
    static var tableHeader: NSColor { dynamic(light: light.tableHeader, dark: dark.tableHeader) }
    static var quoteText: NSColor { dynamic(light: light.quoteText, dark: dark.quoteText) }
}
