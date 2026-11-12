import AppKit
import Foundation
import MarkdownEngine
import PDFKit
import UniformTypeIdentifiers
import WebKit

// MARK: - 错误

enum MarkdownPDFExportError: LocalizedError {
    case renderFailed(String)
    case pdfGenerationFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let message):
            return "PDF 渲染失败：\(message)"
        case .pdfGenerationFailed:
            return "PDF 生成失败：无法读取 WebKit 输出的页面。"
        case .writeFailed(let message):
            return "PDF 写入失败：\(message)"
        }
    }
}

// MARK: - 导出

/// 把 Markdown 文档导出为 A4 分页 PDF。
///
/// 实现要点：
/// - 用同一套 WebView HTML 渲染管线，打印模式固定浅色配色；
/// - `WKWebView.createPDF` 先抓取整篇内容，再用 JS 按块级元素边界计算分页位置；
/// - 分页位置落在块与块之间的空白处（不切断正文行），再用 CoreGraphics 把长页
///   裁切、缩放到 A4 页面（页边距 18mm / 16mm）；
/// - 不依赖预览窗口是否打开：自己创建离屏 WKWebView 完成渲染。
@MainActor
enum MarkdownPDFExporter {

    struct Result {
        let data: Data
        let pageCount: Int
        let mermaidCount: Int
        let imageCount: Int
        let suggestedFileName: String
    }

    /// A4：595.28 × 841.89 pt。
    static let a4Size = CGSize(width: 595.28, height: 841.89)
    /// 与 CSS `@page { margin: 18mm 16mm }` 对应。
    static let pageMargins = NSEdgeInsets(top: 51.02, left: 45.35, bottom: 51.02, right: 45.35)

    // MARK: 公开 API

    /// 只生成 PDF 数据，不弹保存面板（可测试/可预览）。
    static func makePDF(
        markdown: String,
        baseURL: URL?,
        configuration: MarkdownEditorConfiguration,
        title: String = "文档",
        fileName: String? = nil
    ) async throws -> Result {
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = MarkdownWebDocumentOptions(
            title: displayTitle.isEmpty ? "文档" : displayTitle,
            theme: .light,
            pageWidth: .full,
            fontSize: 13,
            isPrint: true
        )

        let html: String
        do {
            html = try await MarkdownRenderedPreviewBuilder.buildHTML(
                markdown: markdown,
                baseURL: baseURL,
                configuration: configuration,
                options: options
            )
        } catch {
            throw MarkdownPDFExportError.renderFailed(error.localizedDescription)
        }

        let contentWidth = a4Size.width - pageMargins.left - pageMargins.right
        let contentHeight = a4Size.height - pageMargins.top - pageMargins.bottom
        let renderer = MarkdownOffscreenWebRenderer(width: contentWidth, height: contentHeight)
        defer { renderer.tearDown() }

        let metrics = try await renderer.load(html: html)
        let captureRect = CGRect(
            x: 0,
            y: 0,
            width: max(metrics.clientWidth, 1),
            height: max(metrics.scrollHeight, 1)
        )
        let sourceData = try await renderer.pdfData(in: captureRect)
        guard let sourceDocument = PDFDocument(data: sourceData),
              let sourcePage = sourceDocument.page(at: 0),
              let pageRef = sourcePage.pageRef else {
            throw MarkdownPDFExportError.pdfGenerationFailed
        }

        let sourceBox = pageRef.getBoxRect(.mediaBox)
        let sourceHeight = max(sourceBox.height, 1)
        let sourceWidth = max(sourceBox.width, 1)
        // 源页面（CSS 像素）映射到 A4 内容宽度；1 CSS px ≈ 1 pt。
        let scale = contentWidth / sourceWidth
        let maxSlice = contentHeight / max(scale, 0.01)
        let rawCuts = await renderer.pageCuts(maxSlice: maxSlice)
        let cuts = normalizedCuts(rawCuts, totalHeight: sourceHeight)

        let data = composePDF(
            sourcePage: pageRef,
            sourceHeight: sourceHeight,
            cuts: cuts,
            scale: scale,
            contentWidth: contentWidth
        )

        let pageCount = PDFDocument(data: data)?.pageCount ?? 0
        guard pageCount > 0 else { throw MarkdownPDFExportError.pdfGenerationFailed }
        return Result(
            data: data,
            pageCount: pageCount,
            mermaidCount: metrics.mermaidCount,
            imageCount: metrics.imageCount,
            suggestedFileName: normalizedFileName(fileName ?? (displayTitle.isEmpty ? "文档" : displayTitle))
        )
    }

    /// 弹 `NSSavePanel` 选择路径并写入 PDF；用户取消时返回 `nil`。
    ///
    /// 调用示例（窗口层按钮）：
    /// ```swift
    /// if let url = try await MarkdownPDFExporter.exportInteractively(
    ///     markdown: model.text,
    ///     baseURL: referenceBaseURL,
    ///     configuration: model.configuration,
    ///     fileName: model.displayName
    /// ) {
    ///     AppState.shared.flash("已导出 PDF：\(url.lastPathComponent)", kind: .success)
    /// }
    /// ```
    static func exportInteractively(
        markdown: String,
        baseURL: URL?,
        configuration: MarkdownEditorConfiguration,
        fileName: String? = nil,
        presentingWindow: NSWindow? = nil
    ) async throws -> URL? {
        let result = try await makePDF(
            markdown: markdown,
            baseURL: baseURL,
            configuration: configuration,
            title: fileName ?? "文档",
            fileName: fileName
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = result.suggestedFileName
        panel.title = "导出 PDF"
        panel.message = "A4 页面 · \(result.pageCount) 页"

        let response: NSApplication.ModalResponse
        if let window = presentingWindow ?? NSApp.keyWindow {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }

        do {
            try result.data.write(to: url, options: .atomic)
        } catch {
            throw MarkdownPDFExportError.writeFailed(error.localizedDescription)
        }
        Log.markdown.info(
            "Exported PDF \(url.lastPathComponent, privacy: .public) (\(result.pageCount) pages)"
        )
        return url
    }

    // MARK: - PDF 分页

    /// 过滤 JS 给出的切分点：单调递增、落在 `(0, totalHeight)`，并补齐首尾。
    static func normalizedCuts(_ cuts: [CGFloat], totalHeight: CGFloat) -> [CGFloat] {
        guard totalHeight > 1 else { return [0, max(totalHeight, 1)] }
        var result: [CGFloat] = [0]
        for cut in cuts {
            let clamped = min(max(cut, 0), totalHeight)
            guard clamped - (result.last ?? 0) > 1 else { continue }
            result.append(clamped)
        }
        if totalHeight - (result.last ?? 0) > 1 {
            result.append(totalHeight)
        } else if let last = result.last, last < totalHeight {
            result[result.count - 1] = totalHeight
        }
        if result.count < 2 {
            result = [0, totalHeight]
        }
        return result
    }

    private static func composePDF(
        sourcePage: CGPDFPage,
        sourceHeight: CGFloat,
        cuts: [CGFloat],
        scale: CGFloat,
        contentWidth: CGFloat
    ) -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: a4Size)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        for index in 0..<max(cuts.count - 1, 0) {
            let start = cuts[index]
            let end = min(cuts[index + 1], sourceHeight)
            let sliceHeight = end - start
            guard sliceHeight > 0.5 else { continue }

            context.beginPDFPage(nil)
            context.saveGState()

            // 把源长页的 top-down `start` 对齐到 A4 内容区左上角，clip 截取本页高度。
            let clipRect = CGRect(
                x: pageMargins.left,
                y: a4Size.height - pageMargins.top - sliceHeight * scale,
                width: contentWidth + 0.75,
                height: sliceHeight * scale + 0.75
            )
            context.clip(to: clipRect)
            context.translateBy(
                x: pageMargins.left,
                y: a4Size.height - pageMargins.top - (sourceHeight - start) * scale
            )
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(sourcePage)

            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private static func normalizedFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "文档" }
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        if !name.lowercased().hasSuffix(".pdf") {
            name += ".pdf"
        }
        return name
    }
}

// MARK: - 离屏渲染

/// 预览/PDF 共用的 WebKit 指标。
struct MarkdownWebPreviewMetrics {
    var clientWidth: CGFloat = 0
    var scrollHeight: CGFloat = 0
    var mermaidCount: Int = 0
    var mermaidFailures: Int = 0
    var imageCount: Int = 0

    init() {}

    init(value: Any?) {
        guard let dictionary = value as? [String: Any] else { return }
        if let value = dictionary["clientWidth"] as? NSNumber {
            clientWidth = CGFloat(value.doubleValue)
        }
        if let value = dictionary["scrollHeight"] as? NSNumber {
            scrollHeight = CGFloat(value.doubleValue)
        }
        if let value = dictionary["mermaidCount"] as? NSNumber {
            mermaidCount = value.intValue
        }
        if let value = dictionary["mermaidFailures"] as? NSNumber {
            mermaidFailures = value.intValue
        }
        if let value = dictionary["imageCount"] as? NSNumber {
            imageCount = value.intValue
        }
    }
}

/// 不依赖预览窗口的离屏 WKWebView：加载 HTML、等待 Mermaid/图片、createPDF。
@MainActor
private final class MarkdownOffscreenWebRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?

    init(width: CGFloat, height: CGFloat) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let frame = CGRect(x: 0, y: 0, width: max(width, 1), height: max(height, 1))
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        webView.navigationDelegate = self
        window.contentView = webView

        // 打印固定浅色：页面本身已设置 data-theme="light"。
        webView.appearance = NSAppearance(named: .aqua)
    }

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
    }

    func load(html: String) async throws -> MarkdownWebPreviewMetrics {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        let script = """
        function fallbackMetrics() {
          return {
            clientWidth: document.documentElement.clientWidth,
            scrollHeight: Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0),
            mermaidCount: document.querySelectorAll('.mermaid-figure[data-mermaid-state="ok"]').length,
            mermaidFailures: document.querySelectorAll('.mermaid-figure[data-mermaid-state="error"]').length,
            imageCount: document.images.length
          };
        }
        if (!window.__kaimingPreviewReady) {
          return fallbackMetrics();
        }
        var timeout = new Promise(function (resolve) {
          setTimeout(function () { resolve(fallbackMetrics()); }, 25000);
        });
        var result = await Promise.race([window.__kaimingPreviewReady, timeout]);
        return result || fallbackMetrics();
        """
        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            return MarkdownWebPreviewMetrics(value: value)
        } catch {
            throw MarkdownPDFExportError.renderFailed(error.localizedDescription)
        }
    }

    func pdfData(in rect: CGRect) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        do {
            return try await webView.pdf(configuration: configuration)
        } catch {
            throw MarkdownPDFExportError.pdfGenerationFailed
        }
    }

    func pageCuts(maxSlice: CGFloat) async -> [CGFloat] {
        let script = """
        if (!window.KaimingPreview) { return []; }
        return window.KaimingPreview.pageCuts(maxSlice);
        """
        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: ["maxSlice": Double(maxSlice)],
                in: nil,
                contentWorld: .page
            )
            guard let numbers = value as? [NSNumber] else { return [] }
            return numbers.map { CGFloat($0.doubleValue) }
        } catch {
            return []
        }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            self.finishLoading(nil)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            self.finishLoading(error)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            self.finishLoading(error)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            self.finishLoading(
                MarkdownPDFExportError.renderFailed("WebKit 内容进程异常退出。")
            )
        }
    }

    private func finishLoading(_ error: Error?) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
