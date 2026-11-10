import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Markdown 的 UTI 约定。
///
/// `.md` 在系统里通常映射到 `net.daringfireball.markdown`；
/// 若当前系统没有注册该类型，则退化为纯文本，保证打开/保存面板始终可用。
enum MarkdownFileTypes {
    static var markdown: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    static var importable: [UTType] {
        let markdown = markdown
        return markdown == .plainText ? [.plainText] : [markdown, .plainText]
    }

    /// 侧边栏只展示 Markdown 文件（扩展名大小写不敏感）。
    static func isMarkdownFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return true
        default:
            return false
        }
    }
}

/// 供 `.fileExporter` 使用的纯文本文件文档。
struct MarkdownFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { MarkdownFileTypes.importable }
    static var writableContentTypes: [UTType] { [MarkdownFileTypes.markdown] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 文件读写。读取时优先 UTF-8，失败后按系统探测的编码回退，并去掉 BOM。
enum MarkdownFileIO {
    static func read(from url: URL) throws -> String {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            return normalize(try String(contentsOf: url, encoding: .utf8))
        } catch {
            var usedEncoding = String.Encoding.utf8
            do {
                return normalize(try String(contentsOf: url, usedEncoding: &usedEncoding))
            } catch {
                throw MarkdownFileError.unreadable(url: url, underlying: error)
            }
        }
    }

    static func write(text: String, to url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func normalize(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}

enum MarkdownFileError: LocalizedError {
    case unreadable(url: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url, let underlying):
            return "“\(url.lastPathComponent)”不是可识别的文本文件：\(underlying.localizedDescription)"
        }
    }
}
