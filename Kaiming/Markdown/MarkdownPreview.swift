import AppKit
import Foundation

/// 非 Markdown 文件的只读预览状态。
struct MarkdownPreview: Identifiable {
    enum Content {
        case text(String, isTruncated: Bool)
        case image(NSImage?)
        case binary
    }

    let url: URL
    let kind: MarkdownFileKind
    var fileSize: Int64
    var content: Content?
    var isLoading: Bool
    var errorMessage: String?

    var id: URL { url }
    var displayName: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

private enum MarkdownPreviewLimits {
    static let maxTextBytes = 1_048_576
    static let maxImageBytes = 20 * 1_048_576
    /// 解码前的像素上限，避免超大尺寸图片在预览时占用过多内存。
    static let maxImagePixels: Int64 = 20_000_000
}

private enum MarkdownPreviewPayload: Sendable {
    case text(String, isTruncated: Bool)
    case image(Data)
    case binary
    case failure(String)
}

/// 读取非 Markdown 文件的前缀内容并生成预览。
///
/// 文件读取在后台线程完成，`NSImage` 解码回到主线程；二进制/超大文件不会
/// 阻塞界面，也不会把原始字节塞进文本视图。
@MainActor
enum MarkdownPreviewLoader {

    static func load(url: URL) async -> MarkdownPreview {
        let kind = MarkdownFileTypes.kind(of: url)
        let fileSize = Self.fileSize(of: url)
        var preview = MarkdownPreview(
            url: url,
            kind: kind,
            fileSize: fileSize,
            content: nil,
            isLoading: true,
            errorMessage: nil
        )

        guard kind != .folder else {
            preview.isLoading = false
            preview.content = .binary
            preview.errorMessage = "文件夹不能作为文件预览。"
            return preview
        }

        let payload = await Task.detached(priority: .userInitiated) { () -> MarkdownPreviewPayload in
            Self.readPayload(url: url, kind: kind, fileSize: fileSize)
        }.value

        preview.isLoading = false
        switch payload {
        case .text(let text, let truncated):
            preview.content = .text(text, isTruncated: truncated)
        case .image(let data):
            if let image = NSImage(data: data), image.isValid {
                if Self.pixelCount(of: image) > MarkdownPreviewLimits.maxImagePixels {
                    preview.content = .binary
                    preview.errorMessage = "图片尺寸过大，未内嵌预览；可用默认应用打开。"
                } else {
                    preview.content = .image(image)
                }
            } else {
                preview.content = .binary
                preview.errorMessage = "无法解码此图片，可尝试用默认应用打开。"
            }
        case .binary:
            preview.content = .binary
        case .failure(let message):
            preview.content = .binary
            preview.errorMessage = message
        }
        return preview
    }

    // MARK: - 后台读取

    private nonisolated static func readPayload(
        url: URL,
        kind: MarkdownFileKind,
        fileSize: Int64
    ) -> MarkdownPreviewPayload {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            switch kind {
            case .markdown, .text:
                let (data, truncated) = try readPrefix(from: url, maxBytes: MarkdownPreviewLimits.maxTextBytes)
                return .text(decodeText(data, truncated: truncated), isTruncated: truncated)

            case .image:
                guard fileSize <= Int64(MarkdownPreviewLimits.maxImageBytes) else {
                    return .failure("图片超过 20 MB，未内嵌预览；可用默认应用打开。")
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return .image(data)

            case .other:
                let (data, truncated) = try readPrefix(from: url, maxBytes: MarkdownPreviewLimits.maxTextBytes)
                guard looksLikeText(data) else { return .binary }
                return .text(decodeText(data, truncated: truncated), isTruncated: truncated)

            case .folder:
                return .binary
            }
        } catch {
            return .failure("无法读取文件：\(error.localizedDescription)")
        }
    }

    private nonisolated static func readPrefix(
        from url: URL,
        maxBytes: Int
    ) throws -> (Data, Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        if data.count > maxBytes {
            return (Data(data.prefix(maxBytes)), true)
        }
        return (data, false)
    }

    private nonisolated static func decodeText(_ data: Data, truncated: Bool) -> String {
        if truncated {
            // 截断可能切断多字节字符，用替换解码保证不丢整段内容。
            return String(decoding: data, as: UTF8.self)
        }
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return string
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 无扩展名或未知扩展名的文件：无 NUL、UTF-8 可解码或控制字符极少时按文本预览。
    private nonisolated static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard !data.contains(0) else { return false }
        if String(data: data, encoding: .utf8) != nil {
            return true
        }

        let sample = data.prefix(4096)
        var controlBytes = 0
        for byte in sample where byte < 9 || (byte > 13 && byte < 32) {
            controlBytes += 1
        }
        return controlBytes * 100 <= sample.count
    }

    private static func pixelCount(of image: NSImage) -> Int64 {
        let fromRepresentations = image.representations.reduce(Int64(0)) { partial, rep in
            max(partial, Int64(rep.pixelsWide) * Int64(rep.pixelsHigh))
        }
        if fromRepresentations > 0 { return fromRepresentations }
        return Int64(max(0, image.size.width * image.size.height))
    }

    private static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
