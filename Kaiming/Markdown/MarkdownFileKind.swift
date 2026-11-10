import Foundation

/// 项目树中一个条目的类型。用于选择图标，以及决定点击后是编辑、只读预览还是交给系统打开。
enum MarkdownFileKind: String, Sendable {
    case folder
    case markdown
    case text
    case image
    case other

    var title: String {
        switch self {
        case .folder: "文件夹"
        case .markdown: "Markdown"
        case .text: "文本"
        case .image: "图片"
        case .other: "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .folder: "folder"
        case .markdown: "doc.text"
        case .text: "doc.plaintext"
        case .image: "photo"
        case .other: "doc"
        }
    }
}

extension MarkdownFileTypes {
    private static let markdownExtensions: Set<String> = [
        "md", "markdown"
    ]

    /// 可在只读纯文本预览中打开的文件类型。未列出的扩展名会在读取时按内容嗅探。
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "diff", "patch",
        "swift", "m", "mm", "h", "hh", "hpp", "c", "cc", "cpp", "cxx",
        "java", "kt", "kts", "scala", "groovy", "dart",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "astro",
        "py", "pyw", "rb", "go", "rs", "php", "pl", "lua", "r", "jl",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "sql", "graphql", "gql", "json", "jsonc", "ndjson", "jsonl",
        "yml", "yaml", "toml", "ini", "cfg", "conf", "properties", "env",
        "xml", "html", "htm", "xhtml", "css", "scss", "sass", "less",
        "svg", "plist", "entitlements", "xcconfig", "pbxproj", "strings",
        "stringsdict", "storyboard", "xib", "tex", "gradle", "cmake",
        "mk", "makefile", "dockerfile", "gitignore", "gitattributes",
        "editorconfig", "lock", "sum", "mod", "swiftformat"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
        "tif", "tiff", "bmp", "icns", "ico"
    ]

    static func kind(of url: URL) -> MarkdownFileKind {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        return .other
    }

    static func isTextFile(_ url: URL) -> Bool {
        kind(of: url) == .text
    }
}
