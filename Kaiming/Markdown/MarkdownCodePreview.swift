import AppKit
import MarkdownEngine
import SwiftUI

/// 非 Markdown 文本预览的代码语法高亮支持。
///
/// - `language(for:)` 把扩展名（以及 Makefile / Dockerfile 这类无扩展名的常见文件）
///   映射到 highlight.js 的语言名；未知类型返回 `nil`，预览继续用纯文本。
/// - 复用引擎的 ``HighlightJSBridge``（GitHub light/dark token 配色、自动跟随外观），
///   不引入新的第三方依赖；桥接内部自带 JavaScriptCore 与 token 缓存。
/// - 超过 ``maxHighlightBytes`` 的文本不进入 JavaScriptCore，避免高亮阻塞主线程。
enum MarkdownCodePreview {
    /// 约 256 KB：更大的文本直接纯文本显示（文件预览本身最多读取 1 MB）。
    static let maxHighlightBytes = 256 * 1024

    /// 全 App 共享一个桥接：`HighlightJSBridge` 持有 JavaScriptCore 上下文，
    /// 每次打开预览都重建会重复加载 highlight.js。
    static let highlighter = HighlightJSBridge(
        lightBackground: MarkdownGitHubTheme.codeBackground,
        darkBackground: MarkdownGitHubTheme.codeBackground
    )

    /// 该 URL 对应的 highlight.js 语言名；`nil` 表示未知类型，走纯文本预览。
    static func language(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if let filenameLanguage = languageByFilename[name] {
            return filenameLanguage
        }
        if name.hasPrefix("dockerfile.") {
            return "dockerfile"
        }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return languageByExtension[ext]
    }

    /// 是否对这段文本做语法高亮（已知语言且未超过体积上限）。
    static func shouldHighlight(_ text: String, for url: URL) -> Bool {
        guard language(for: url) != nil else { return false }
        return text.utf8.count <= maxHighlightBytes
    }

    /// 等宽字体（优先 SF Mono / Menlo），与引擎代码块保持一致。
    static func codeFont(size: CGFloat = 13) -> NSFont {
        highlighter.codeFont(size: size)
    }

    // MARK: - 映射表

    private static let languageByFilename: [String: String] = [
        "makefile": "makefile",
        "gnumakefile": "makefile",
        "dockerfile": "dockerfile",
        "cmakelists.txt": "cmake",
        "podfile": "ruby",
        "gemfile": "ruby",
        "rakefile": "ruby",
        ".editorconfig": "ini"
    ]

    /// 扩展名 → highlight.js 语言名（highlight.js 11 支持 192 种语言）。
    private static let languageByExtension: [String: String] = [
        // Apple / 系统
        "swift": "swift",
        "m": "objectivec",
        "mm": "objectivec",
        "h": "c",
        "hh": "cpp",
        "hpp": "cpp",
        "hxx": "cpp",
        "c": "c",
        "cc": "cpp",
        "cpp": "cpp",
        "cxx": "cpp",
        "cs": "csharp",
        // JVM / 移动端
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "scala": "scala",
        "sc": "scala",
        "groovy": "groovy",
        "gradle": "groovy",
        "dart": "dart",
        // Web / 脚本
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "vue": "xml",
        "svelte": "xml",
        "astro": "xml",
        "py": "python",
        "pyw": "python",
        "pyi": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "php": "php",
        "pl": "perl",
        "pm": "perl",
        "lua": "lua",
        "r": "r",
        "jl": "julia",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "bash",
        "ps1": "powershell",
        "psm1": "powershell",
        "bat": "dos",
        "cmd": "dos",
        // 数据 / 配置
        "sql": "sql",
        "graphql": "graphql",
        "gql": "graphql",
        "json": "json",
        "jsonc": "json",
        "ndjson": "json",
        "jsonl": "json",
        "yml": "yaml",
        "yaml": "yaml",
        "toml": "ini",
        "ini": "ini",
        "cfg": "ini",
        "conf": "ini",
        "properties": "ini",
        "env": "ini",
        "xcconfig": "ini",
        "xml": "xml",
        "html": "xml",
        "htm": "xml",
        "xhtml": "xml",
        "svg": "xml",
        "plist": "xml",
        "entitlements": "xml",
        "strings": "xml",
        "stringsdict": "xml",
        "storyboard": "xml",
        "xib": "xml",
        "css": "css",
        "scss": "scss",
        "sass": "scss",
        "less": "less",
        // 文档 / 构建 / 补丁
        "md": "markdown",
        "markdown": "markdown",
        "mdown": "markdown",
        "mkd": "markdown",
        "diff": "diff",
        "patch": "diff",
        "mk": "makefile",
        "mak": "makefile",
        "cmake": "cmake",
        "dockerfile": "dockerfile",
        "tex": "latex",
        "latex": "latex",
        "proto": "protobuf",
        "vim": "vim"
    ]
}

// MARK: - 高亮文本视图

/// 只读、可选中、按 highlight.js token 着色的代码预览视图。
///
/// 背景保持透明，由 `MarkdownPreviewView` 铺 GitHub canvas；滚动条隐藏但保留滚动。
/// 系统外观切换时通过 `HighlightJSBridge` 发出的
/// `.markdownEngineHighlighterDidChangeAppearance` 重新高亮
///（桥接返回的 token 颜色是具体 NSColor，不会自己跟随动态外观）。
struct MarkdownCodeTextView: NSViewRepresentable {
    let text: String
    let language: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        if let textView = scrollView.documentView as? NSTextView {
            configure(textView)
            context.coordinator.attach(textView)
            context.coordinator.update(text: text, language: language)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(text: text, language: language)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configure(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.font = MarkdownCodePreview.codeFont()
        textView.textColor = MarkdownGitHubTheme.text
        textView.insertionPointColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
    }

    @MainActor
    final class Coordinator {
        private weak var textView: NSTextView?
        private var text = ""
        private var language = ""
        private var lastDarkAppearance: Bool?
        private var appearanceObserver: NSObjectProtocol?

        func attach(_ textView: NSTextView) {
            self.textView = textView
            appearanceObserver = NotificationCenter.default.addObserver(
                forName: .markdownEngineHighlighterDidChangeAppearance,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.apply()
                }
            }
        }

        func detach() {
            if let appearanceObserver {
                NotificationCenter.default.removeObserver(appearanceObserver)
            }
            appearanceObserver = nil
            textView = nil
        }

        func update(text: String, language: String) {
            let changed = self.text != text || self.language != language
            self.text = text
            self.language = language
            if changed || lastDarkAppearance != Self.isDarkAppearance() {
                apply()
            }
        }

        private func apply() {
            guard let textView else { return }
            let dark = Self.isDarkAppearance()

            if let highlighted = MarkdownCodePreview.highlighter.highlight(
                code: text,
                language: language
            ) {
                textView.textStorage?.setAttributedString(highlighted)
                // 桥接只负责 token 前景色，字体统一由预览视图控制。
                textView.font = MarkdownCodePreview.codeFont()
            } else {
                textView.string = text
                textView.font = MarkdownCodePreview.codeFont()
                textView.textColor = MarkdownGitHubTheme.text
            }
            lastDarkAppearance = dark
        }

        /// 与 ``HighlightJSBridge`` 保持一致：优先使用当前窗口的实际外观。
        private static func isDarkAppearance() -> Bool {
            let appearance = NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}
