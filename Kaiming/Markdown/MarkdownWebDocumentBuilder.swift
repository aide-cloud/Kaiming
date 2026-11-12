import AppKit
import Foundation

// MARK: - 主题与选项

/// WebView 预览/PDF 使用的配色策略。
enum MarkdownWebDocumentTheme: String, Sendable {
    /// 跟随系统外观（CSS `prefers-color-scheme`，WKWebView 会自动响应 NSApp.effectiveAppearance）。
    case system
    case light
    case dark
}

/// 整篇 HTML 文档的生成选项。
struct MarkdownWebDocumentOptions: Sendable {
    var title: String = "Kaiming 渲染预览"
    var theme: MarkdownWebDocumentTheme = .system
    var pageWidth: MarkdownPageWidth = .standard
    var fontSize: CGFloat = 14
    /// PDF 导出用：去掉页宽限制/内边距，代码换行，页面底色固定为白色。
    var isPrint: Bool = false
    /// 是否把远程图片下载后内联成 `data:` URL。
    ///
    /// - 预览建议传 `false`：远程图保留原始 https URL，由 WKWebView 并行加载，
    ///   构建不再被网络阻塞（本地图片仍然内联，保持离线可见）。
    /// - PDF 导出保持默认 `true`：需要离线完整内容，下载改由
    ///   `MarkdownRenderedPreviewBuilder` 做有界并发（≤6）+ 超时。
    var inlineRemoteImages: Bool = true
}

// MARK: - HTML 文档构建

/// 把 Markdown 渲染出的 HTML 片段拼成一份 HTML 文档：
/// GitHub Markdown 样式 + 离线 Mermaid + highlight.js + 等待渲染完成的 JS 协议。
///
/// 本地图片始终在 `MarkdownRenderedPreviewBuilder` 中内联为 `data:` URL；
/// 远程图片默认内联（PDF 需要离线完整内容），预览模式可保留原始 https URL，
/// 交给 WKWebView 自行并行加载。文档本身不加载任何外部脚本/CSS。
enum MarkdownWebDocumentBuilder {

    // MARK: 公开入口

    /// `bodyHTML` 是已经清洗、图片已内联、Mermaid 围栏已转换的正文片段。
    static func document(bodyHTML: String, options: MarkdownWebDocumentOptions) -> String {
        let needsMermaid = bodyHTML.contains("mermaid-figure")
        let needsHighlight = bodyHTML.contains("<pre")
        let htmlAttributes = htmlTagAttributes(for: options)
        let bodyClass = options.isPrint ? "print-mode" : ""

        let mermaidScript = needsMermaid
            ? "<script>\n\(bundledScript(named: "mermaid.min"))\n</script>\n"
            : ""
        let highlightScript = needsHighlight
            ? "<script>\n\(bundledScript(named: "highlight.min"))\n</script>\n"
            : ""

        return """
        <!doctype html>
        <html lang="zh-Hans"\(htmlAttributes)>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(options.isPrint ? "light" : "light dark")">
        <title>\(escape(options.title))</title>
        <style>
        \(styleSheet(options: options))
        </style>
        </head>
        <body class="\(bodyClass)">
        <article class="markdown-body">
        \(bodyHTML)
        </article>
        \(mermaidScript)\(highlightScript)<script>
        \(runtimeScript(forPrint: options.isPrint))
        </script>
        </body>
        </html>
        """
    }

    /// 把 ```mermaid / ~~~mermaid 代码围栏转换成图形容器。
    ///
    /// `MarkdownHTMLRenderer` 输出 `<pre><code class="language-mermaid">转义源码</code></pre>`；
    /// 这里把它替换成「画布 + 隐藏源码」结构，渲染失败时展示源码与错误信息。
    static func transformMermaidFences(in html: String) -> String {
        guard html.contains("mermaid") else { return html }
        guard let regex = mermaidFenceRegex else { return html }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }

        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            let inner = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let container = """
            <figure class="mermaid-figure" data-mermaid-state="pending">\
            <div class="mermaid-canvas"><div class="mermaid"></div></div>\
            <pre class="mermaid-source" style="display:none"><code>\(inner)</code></pre>\
            <div class="mermaid-error" hidden></div>\
            </figure>
            """
            mutable.replaceCharacters(in: match.range, with: container)
        }
        return mutable as String
    }

    /// HTML 正文里 Mermaid 图形容器数量。
    static func mermaidFigureCount(in html: String) -> Int {
        guard !html.isEmpty, let regex = try? NSRegularExpression(
            pattern: #"class="mermaid-figure""#
        ) else { return 0 }
        return regex.numberOfMatches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: (html as NSString).length)
        )
    }

    // MARK: 私有

    private static let mermaidFenceRegex = try? NSRegularExpression(
        pattern: #"(?is)<pre>\s*<code\s+class="language-mermaid"\s*>(.*?)</code>\s*</pre>"#
    )

    private static func htmlTagAttributes(for options: MarkdownWebDocumentOptions) -> String {
        var attributes = ""
        switch options.theme {
        case .system:
            break
        case .light:
            attributes += #" data-theme="light""#
        case .dark:
            attributes += #" data-theme="dark""#
        }
        if options.isPrint {
            attributes += #" data-print="true""#
        }
        return attributes
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 读取随包脚本。资源在 app bundle 里被 Xcode 拍平到 Contents/Resources/，
    /// 同时兼容以后把 Resources/Markdown 作为文件夹引用保留的情况。
    private static let scriptCacheLock = NSLock()
    nonisolated(unsafe) private static var scriptCache: [String: String] = [:]

    static func bundledScript(named name: String) -> String {
        scriptCacheLock.lock()
        if let cached = scriptCache[name] {
            scriptCacheLock.unlock()
            return cached
        }
        scriptCacheLock.unlock()

        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "js"),
            Bundle.main.resourceURL?
                .appendingPathComponent("Markdown", isDirectory: true)
                .appendingPathComponent("\(name).js"),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).js")
        ]
        var contents = ""
        for candidate in candidates {
            guard let url = candidate,
                  FileManager.default.fileExists(atPath: url.path),
                  let loaded = try? String(contentsOf: url, encoding: .utf8) else { continue }
            contents = loaded
            break
        }
        if contents.isEmpty {
            Log.markdown.error("Bundled script missing: \(name, privacy: .public).js")
        } else {
            scriptCacheLock.lock()
            scriptCache[name] = contents
            scriptCacheLock.unlock()
        }
        return contents
    }

    // MARK: - CSS

    private static func styleSheet(options: MarkdownWebDocumentOptions) -> String {
        let maxWidth = options.isPrint ? "none" : options.pageWidth.cssMaxWidth
        let fontSize = options.isPrint ? "13px" : "\(Int(options.fontSize.rounded()))px"
        return """
        /* ===== 设计变量：GitHub 浅色 / 深色（与 MarkdownContentTheme 同源） ===== */
        :root {
          color-scheme: light dark;
          --canvas: #ffffff;
          --canvas-inset: #f6f8fa;
          --text: #1f2328;
          --muted: #59636e;
          --subtle: #6e7781;
          --border: #d1d9e0;
          --link: #0969da;
          --code-bg: #f6f8fa;
          --table-header: #f6f8fa;
          --quote-text: #59636e;
          --accent: #0969da;
          --content-max-width: \(maxWidth);
          --font-size: \(fontSize);
          --sans: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Helvetica Neue", Arial, sans-serif;
          --mono: "SFMono-Regular", "SF Mono", ui-monospace, Menlo, Consolas, "Liberation Mono", monospace;
          --mermaid-canvas: #090d12;
          --mermaid-cluster: #141c25;
          --mermaid-text: #dce7ee;
          --mermaid-accent: #13c2c2;
          --mermaid-border: #30363d;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --canvas: #0d1117;
            --canvas-inset: #151b23;
            --text: #e6edf3;
            --muted: #9198a1;
            --subtle: #6e7781;
            --border: #3d444d;
            --link: #4493f8;
            --code-bg: #151b23;
            --table-header: #151b23;
            --quote-text: #9198a1;
            --accent: #4493f8;
            --mermaid-border: #30363d;
          }
        }
        html[data-theme="light"] {
          color-scheme: light;
          --canvas: #ffffff;
          --canvas-inset: #f6f8fa;
          --text: #1f2328;
          --muted: #59636e;
          --subtle: #6e7781;
          --border: #d1d9e0;
          --link: #0969da;
          --code-bg: #f6f8fa;
          --table-header: #f6f8fa;
          --quote-text: #59636e;
          --accent: #0969da;
        }
        html[data-theme="dark"] {
          color-scheme: dark;
          --canvas: #0d1117;
          --canvas-inset: #151b23;
          --text: #e6edf3;
          --muted: #9198a1;
          --subtle: #6e7781;
          --border: #3d444d;
          --link: #4493f8;
          --code-bg: #151b23;
          --table-header: #151b23;
          --quote-text: #9198a1;
          --accent: #4493f8;
        }

        /* ===== 基础排版（GitHub Markdown CSS 等价实现） ===== */
        * { box-sizing: border-box; }
        html { -webkit-text-size-adjust: 100%; }
        body {
          margin: 0;
          background: var(--canvas);
          color: var(--text);
          font-family: var(--sans);
          font-size: var(--font-size);
          line-height: 1.6;
          -webkit-font-smoothing: antialiased;
          word-wrap: break-word;
        }
        .markdown-body {
          max-width: var(--content-max-width);
          margin: 0 auto;
          padding: 28px 32px 64px;
          overflow-wrap: break-word;
        }
        .markdown-body > :first-child { margin-top: 0 !important; }
        .markdown-body > :last-child { margin-bottom: 0 !important; }

        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          margin-top: 24px;
          margin-bottom: 16px;
          font-weight: 600;
          line-height: 1.25;
        }
        .markdown-body h1 {
          font-size: 2em;
          padding-bottom: .3em;
          border-bottom: 1px solid var(--border);
        }
        .markdown-body h2 {
          font-size: 1.5em;
          padding-bottom: .3em;
          border-bottom: 1px solid var(--border);
        }
        .markdown-body h3 { font-size: 1.25em; }
        .markdown-body h4 { font-size: 1em; }
        .markdown-body h5 { font-size: .875em; }
        .markdown-body h6 { font-size: .85em; color: var(--muted); }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          scroll-margin-top: 16px;
        }
        @keyframes kaiming-heading-flash {
          0% {
            background-color: rgba(19, 194, 194, .30);
            box-shadow: 0 0 0 6px rgba(19, 194, 194, .14);
          }
          100% {
            background-color: transparent;
            box-shadow: 0 0 0 0 rgba(19, 194, 194, 0);
          }
        }
        .kaiming-heading-flash {
          border-radius: 4px;
          animation: kaiming-heading-flash 1.4s ease-out;
        }

        .markdown-body p { margin-top: 0; margin-bottom: 16px; }
        .markdown-body a { color: var(--link); text-decoration: none; }
        .markdown-body a:hover { text-decoration: underline; }
        .markdown-body strong { font-weight: 600; }
        .markdown-body del { text-decoration: line-through; }
        .markdown-body mark { background: rgba(255, 213, 79, .45); color: inherit; border-radius: 3px; padding: 0 .15em; }

        .markdown-body blockquote {
          margin: 0 0 16px;
          padding: 0 1em;
          color: var(--quote-text);
          border-left: .25em solid var(--border);
        }
        .markdown-body blockquote > :first-child { margin-top: 0; }
        .markdown-body blockquote > :last-child { margin-bottom: 0; }

        .markdown-body ul, .markdown-body ol { margin-top: 0; margin-bottom: 16px; padding-left: 2em; }
        .markdown-body li + li { margin-top: .25em; }
        .markdown-body li > p { margin-top: 16px; }
        .markdown-body ul ul, .markdown-body ul ol, .markdown-body ol ol, .markdown-body ol ul { margin-top: 0; margin-bottom: 0; }
        .markdown-body ul.contains-task-list, .markdown-body ol.contains-task-list { padding-left: 2em; }
        .markdown-body .task-list-item { list-style-type: none; }
        .markdown-body .task-list-item input[type="checkbox"] {
          margin: 0 .35em .25em -1.4em;
          vertical-align: middle;
        }

        .markdown-body hr {
          height: .25em;
          margin: 24px 0;
          padding: 0;
          background-color: var(--border);
          border: 0;
          border-radius: 2px;
        }

        .markdown-body code, .markdown-body kbd, .markdown-body pre, .markdown-body samp {
          font-family: var(--mono);
        }
        .markdown-body code {
          padding: .2em .4em;
          margin: 0;
          font-size: 85%;
          white-space: break-spaces;
          background-color: var(--code-bg);
          border-radius: 6px;
        }
        .markdown-body pre {
          margin: 0 0 16px;
          padding: 16px;
          overflow: auto;
          font-size: 85%;
          line-height: 1.45;
          background-color: var(--code-bg);
          border-radius: 6px;
        }
        .markdown-body pre code {
          display: inline;
          padding: 0;
          margin: 0;
          overflow: visible;
          font-size: 100%;
          line-height: inherit;
          word-wrap: normal;
          white-space: pre;
          background: transparent;
          border: 0;
        }
        .markdown-body kbd {
          display: inline-block;
          padding: 3px 5px;
          font-size: 11px;
          line-height: 10px;
          color: var(--text);
          vertical-align: middle;
          background-color: var(--canvas-inset);
          border: 1px solid var(--border);
          border-radius: 6px;
          box-shadow: inset 0 -1px 0 var(--border);
        }

        .markdown-body table {
          display: block;
          width: max-content;
          max-width: 100%;
          overflow: auto;
          margin: 0 0 16px;
          border-spacing: 0;
          border-collapse: collapse;
        }
        .markdown-body table th { font-weight: 600; }
        .markdown-body table th, .markdown-body table td {
          padding: 6px 13px;
          border: 1px solid var(--border);
        }
        .markdown-body table tr { background-color: var(--canvas); border-top: 1px solid var(--border); }
        .markdown-body table tr:nth-child(2n) { background-color: var(--canvas-inset); }
        .markdown-body table thead tr { background-color: var(--table-header); }

        .markdown-body img {
          max-width: 100%;
          height: auto;
          box-sizing: content-box;
          background-color: var(--canvas);
        }
        .markdown-body img[align="right"] { padding-left: 20px; }
        .markdown-body img[align="left"] { padding-right: 20px; }
        .markdown-body .kaiming-missing-image {
          display: inline-block;
          padding: 2px 8px;
          font-size: .92em;
          color: var(--muted);
          background: var(--canvas-inset);
          border: 1px dashed var(--border);
          border-radius: 6px;
        }

        .markdown-body details { margin-bottom: 16px; }
        .markdown-body summary { cursor: pointer; font-weight: 600; }
        .markdown-body summary > :first-child { display: inline; }

        /* ===== Mermaid：深色画布 + 青绿 accent（参考 Crescent mermaid-theme） ===== */
        .mermaid-figure {
          position: relative;
          margin: 18px 0;
          padding: 18px;
          overflow-x: auto;
          background: var(--mermaid-canvas);
          border: 1px solid var(--mermaid-border);
          border-radius: 10px;
        }
        .mermaid-canvas {
          display: flex;
          justify-content: center;
          align-items: center;
          min-height: 36px;
        }
        .mermaid-canvas svg {
          display: block;
          max-width: 100%;
          height: auto;
          font-family: var(--sans);
        }
        .mermaid-figure[data-mermaid-state="pending"] .mermaid-canvas::before {
          content: "正在渲染 Mermaid 图表…";
          font-size: 12px;
          color: #8795a5;
        }
        .mermaid-figure .mermaid-source {
          margin: 10px 0 0;
          padding: 12px 14px;
          overflow: auto;
          font-family: var(--mono);
          font-size: 12px;
          line-height: 1.5;
          color: #dce7ee;
          background: #0d1117;
          border: 1px solid #30363d;
          border-radius: 6px;
        }
        .mermaid-figure .mermaid-source code {
          color: inherit;
          background: transparent;
        }
        .mermaid-error {
          margin: 0 0 10px;
          padding: 8px 10px;
          font-size: 12px;
          line-height: 1.5;
          color: #ffb4a8;
          white-space: pre-wrap;
          background: rgba(248, 81, 73, .12);
          border: 1px solid rgba(248, 81, 73, .5);
          border-radius: 6px;
        }

        /* ===== highlight.js 配色（GitHub 风格） ===== */
        .hljs-comment, .hljs-quote { color: #6e7781; font-style: italic; }
        .hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-doctag { color: #cf222e; }
        .hljs-string, .hljs-regexp, .hljs-addition, .hljs-attribute, .hljs-meta .hljs-string { color: #0a3069; }
        .hljs-number, .hljs-variable, .hljs-template-variable, .hljs-type, .hljs-built_in { color: #0550ae; }
        .hljs-title, .hljs-section, .hljs-title.class_, .hljs-title.function_ { color: #8250df; }
        .hljs-attr, .hljs-selector-attr, .hljs-selector-class, .hljs-selector-id { color: #116329; }
        .hljs-symbol, .hljs-bullet, .hljs-link { color: #953800; }
        .hljs-deletion { color: #82071e; }
        .hljs-emphasis { font-style: italic; }
        .hljs-strong { font-weight: 600; }
        @media (prefers-color-scheme: dark) {
          html:not([data-theme="light"]) .hljs-comment, html:not([data-theme="light"]) .hljs-quote { color: #8b949e; }
          html:not([data-theme="light"]) .hljs-keyword, html:not([data-theme="light"]) .hljs-selector-tag,
          html:not([data-theme="light"]) .hljs-literal, html:not([data-theme="light"]) .hljs-doctag { color: #ff7b72; }
          html:not([data-theme="light"]) .hljs-string, html:not([data-theme="light"]) .hljs-regexp,
          html:not([data-theme="light"]) .hljs-addition, html:not([data-theme="light"]) .hljs-attribute { color: #a5d6ff; }
          html:not([data-theme="light"]) .hljs-number, html:not([data-theme="light"]) .hljs-variable,
          html:not([data-theme="light"]) .hljs-template-variable, html:not([data-theme="light"]) .hljs-type,
          html:not([data-theme="light"]) .hljs-built_in { color: #79c0ff; }
          html:not([data-theme="light"]) .hljs-title, html:not([data-theme="light"]) .hljs-section { color: #d2a8ff; }
          html:not([data-theme="light"]) .hljs-attr, html:not([data-theme="light"]) .hljs-selector-attr,
          html:not([data-theme="light"]) .hljs-selector-class, html:not([data-theme="light"]) .hljs-selector-id { color: #7ee787; }
        }
        html[data-theme="dark"] .hljs-comment, html[data-theme="dark"] .hljs-quote { color: #8b949e; }
        html[data-theme="dark"] .hljs-keyword, html[data-theme="dark"] .hljs-selector-tag,
        html[data-theme="dark"] .hljs-literal, html[data-theme="dark"] .hljs-doctag { color: #ff7b72; }
        html[data-theme="dark"] .hljs-string, html[data-theme="dark"] .hljs-regexp,
        html[data-theme="dark"] .hljs-addition, html[data-theme="dark"] .hljs-attribute { color: #a5d6ff; }
        html[data-theme="dark"] .hljs-number, html[data-theme="dark"] .hljs-variable,
        html[data-theme="dark"] .hljs-template-variable, html[data-theme="dark"] .hljs-type,
        html[data-theme="dark"] .hljs-built_in { color: #79c0ff; }
        html[data-theme="dark"] .hljs-title, html[data-theme="dark"] .hljs-section { color: #d2a8ff; }
        html[data-theme="dark"] .hljs-attr, html[data-theme="dark"] .hljs-selector-attr,
        html[data-theme="dark"] .hljs-selector-class, html[data-theme="dark"] .hljs-selector-id { color: #7ee787; }

        /* ===== 选中 / 滚动条（隐藏滚动条，但保留滚动能力） ===== */
        ::selection { background: rgba(9, 105, 218, .22); }
        html[data-theme="dark"] ::selection { background: rgba(68, 147, 248, .30); }
        html, body { scrollbar-width: none; }
        ::-webkit-scrollbar {
          display: none;
          width: 0;
          height: 0;
          background: transparent;
        }
        html::-webkit-scrollbar,
        body::-webkit-scrollbar,
        .markdown-body::-webkit-scrollbar,
        .markdown-body pre::-webkit-scrollbar,
        .markdown-body table::-webkit-scrollbar,
        .mermaid-figure::-webkit-scrollbar,
        .mermaid-figure .mermaid-source::-webkit-scrollbar {
          display: none;
          width: 0;
          height: 0;
        }

        /* ===== 打印 / PDF ===== */
        @page { size: A4; margin: 18mm 16mm; }
        html.print-mode body { background: #ffffff; }
        html.print-mode .markdown-body {
          max-width: none;
          padding: 0 0 12px;
          font-size: var(--font-size);
        }
        html.print-mode .markdown-body pre {
          white-space: pre-wrap;
          overflow-wrap: anywhere;
        }
        html.print-mode .markdown-body pre code { white-space: pre-wrap; }
        html.print-mode .markdown-body table {
          display: table;
          width: 100%;
          max-width: 100%;
          table-layout: auto;
        }
        html.print-mode .markdown-body table th,
        html.print-mode .markdown-body table td { overflow-wrap: anywhere; }
        html.print-mode .markdown-body img { max-width: 100%; }
        html.print-mode .mermaid-figure { break-inside: avoid; }
        """
    }

    // MARK: - JS 运行时

    private static func runtimeScript(forPrint: Bool) -> String {
        """
        (function () {
          'use strict';
          var isPrint = \(forPrint ? "true" : "false");
          var mermaidConfig = \(mermaidConfigurationJSON());

          function figures() {
            return Array.prototype.slice.call(document.querySelectorAll('.mermaid-figure'));
          }
          function sourceOf(figure) {
            var node = figure.querySelector('.mermaid-source code') || figure.querySelector('.mermaid-source');
            return node ? node.textContent : '';
          }
          function cleanupTemp(id) {
            ['d' + id, id].forEach(function (candidate) {
              var node = document.getElementById(candidate);
              if (node && !(node.closest && node.closest('.mermaid-figure'))) {
                node.parentNode.removeChild(node);
              }
            });
          }
          function showError(figure, message) {
            figure.setAttribute('data-mermaid-state', 'error');
            var errorNode = figure.querySelector('.mermaid-error');
            if (errorNode) {
              errorNode.hidden = false;
              errorNode.textContent = 'Mermaid 渲染失败：' + message;
            }
            var sourceNode = figure.querySelector('.mermaid-source');
            if (sourceNode) { sourceNode.style.display = ''; }
          }
          async function renderAllMermaid() {
            var list = figures();
            if (!list.length) { return; }
            if (typeof mermaid === 'undefined') {
              list.forEach(function (figure) {
                showError(figure, 'mermaid.min.js 未随包加载，无法渲染图表（图表源码已保留）。');
              });
              return;
            }
            try { mermaid.initialize(mermaidConfig); } catch (error) { /* 保持默认配置继续尝试 */ }
            for (var index = 0; index < list.length; index++) {
              var figure = list[index];
              var source = sourceOf(figure).trim();
              if (!source) { continue; }
              var canvas = figure.querySelector('.mermaid');
              if (!canvas) { continue; }
              var id = 'kaiming-mermaid-' + index;
              try {
                var result = await mermaid.render(id, source);
                var svg = result && typeof result === 'object' ? result.svg : result;
                if (!svg) { throw new Error('mermaid.render 未返回 SVG'); }
                canvas.innerHTML = svg;
                figure.setAttribute('data-mermaid-state', 'ok');
                var errorNode = figure.querySelector('.mermaid-error');
                if (errorNode) { errorNode.hidden = true; errorNode.textContent = ''; }
                var sourceNode = figure.querySelector('.mermaid-source');
                if (sourceNode) { sourceNode.style.display = 'none'; }
                if (result && typeof result.bindFunctions === 'function') {
                  try { result.bindFunctions(canvas); } catch (bindError) { /* 交互增强失败不致命 */ }
                }
              } catch (error) {
                showError(figure, (error && error.message) ? error.message : String(error));
              }
              cleanupTemp(id);
            }
          }
          function highlightCodeBlocks() {
            if (typeof hljs === 'undefined') { return 0; }
            var blocks = Array.prototype.slice.call(document.querySelectorAll('.markdown-body pre code'));
            var count = 0;
            blocks.forEach(function (block) {
              if (block.closest && block.closest('.mermaid-source')) { return; }
              try { hljs.highlightElement(block); count += 1; } catch (error) { /* 未注册语言时跳过 */ }
            });
            return count;
          }
          function waitForImages() {
            var pending = Array.prototype.slice.call(document.images).filter(function (image) {
              return !image.complete;
            });
            if (!pending.length) { return Promise.resolve(); }
            return Promise.all(pending.map(function (image) {
              return new Promise(function (resolve) {
                var finished = false;
                function finish() {
                  if (finished) { return; }
                  finished = true;
                  resolve();
                }
                image.addEventListener('load', finish, { once: true });
                image.addEventListener('error', finish, { once: true });
                setTimeout(finish, 8000);
              });
            }));
          }
          function metrics() {
            var root = document.documentElement;
            return {
              clientWidth: root.clientWidth,
              scrollHeight: Math.max(root.scrollHeight, document.body ? document.body.scrollHeight : 0),
              mermaidCount: document.querySelectorAll('.mermaid-figure[data-mermaid-state="ok"]').length,
              mermaidFailures: document.querySelectorAll('.mermaid-figure[data-mermaid-state="error"]').length,
              imageCount: document.images.length,
              isPrint: isPrint
            };
          }

          window.__kaimingPreviewReady = (async function () {
            var runtimeError = null;
            try { await renderAllMermaid(); } catch (error) { runtimeError = String(error); }
            var highlighted = 0;
            try { highlighted = highlightCodeBlocks(); } catch (error) { }
            try { await waitForImages(); } catch (error) { }
            try {
              if (document.fonts && document.fonts.ready) {
                await Promise.race([
                  document.fonts.ready,
                  new Promise(function (resolve) { setTimeout(resolve, 2000); })
                ]);
              }
            } catch (error) { }
            var result = metrics();
            result.highlighted = highlighted;
            result.runtimeError = runtimeError;
            return result;
          })();

          window.KaimingPreview = {
            ready: function () { return window.__kaimingPreviewReady; },
            metrics: metrics,
            scrollToHeading: function (headingID) {
              if (typeof headingID !== 'string' || !headingID.length) { return false; }
              var element = document.getElementById(headingID);
              if (!element) { return false; }
              element.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'auto' });
              element.classList.remove('kaiming-heading-flash');
              void element.offsetWidth;
              element.classList.add('kaiming-heading-flash');
              window.setTimeout(function () {
                element.classList.remove('kaiming-heading-flash');
              }, 1600);
              return true;
            },
            applyStyle: function (maxWidth, fontSize) {
              var root = document.documentElement;
              if (typeof maxWidth === 'string' && maxWidth.length) {
                root.style.setProperty('--content-max-width', maxWidth);
              }
              if (typeof fontSize === 'number' && isFinite(fontSize) && fontSize > 0) {
                root.style.setProperty('--font-size', fontSize + 'px');
              }
            },
            setTheme: function (theme) {
              if (theme === 'light' || theme === 'dark') {
                document.documentElement.setAttribute('data-theme', theme);
              } else {
                document.documentElement.removeAttribute('data-theme');
              }
            },
            pageCuts: function (maxSlice) {
              var body = document.querySelector('.markdown-body') || document.body;
              var root = document.documentElement;
              var total = Math.max(root.scrollHeight, body ? body.scrollHeight : 0);
              if (!maxSlice || maxSlice < 96) { return [0, total]; }
              var blocks = Array.prototype.slice.call(body.children).filter(function (element) {
                if (!element.offsetHeight) { return false; }
                var style = getComputedStyle(element);
                if (style.display === 'none' || style.visibility === 'hidden' || style.position === 'fixed') { return false; }
                return true;
              }).map(function (element) {
                var rect = element.getBoundingClientRect();
                var top = Math.max(0, rect.top + window.scrollY);
                return { top: top, height: element.offsetHeight };
              }).sort(function (a, b) { return a.top - b.top; });
              var cuts = [0];
              var pageStart = 0;
              blocks.forEach(function (block) {
                var top = block.top;
                var bottom = top + block.height;
                if (bottom - pageStart <= maxSlice) { return; }
                if (top - pageStart > maxSlice) {
                  // 两块之间的空白比一页还高：在空白处强行分页，避免切到内容。
                  pageStart = pageStart + maxSlice;
                  cuts.push(pageStart);
                } else if (top - pageStart > 8) {
                  // 正常情况下在块与块之间分页，不切断正文行。
                  cuts.push(top);
                  pageStart = top;
                }
                while (bottom - pageStart > maxSlice) {
                  pageStart = pageStart + maxSlice;
                  cuts.push(pageStart);
                }
              });
              if (total - pageStart > 0.5) { cuts.push(total); }
              var normalized = [];
              cuts.forEach(function (value) {
                var clamped = Math.min(Math.max(value, 0), total);
                if (!normalized.length || clamped - normalized[normalized.length - 1] > 1) {
                  normalized.push(clamped);
                }
              });
              if (!normalized.length || normalized[0] !== 0) { normalized.unshift(0); }
              return normalized;
            }
          };
        })();
        """
    }

    /// Crescent `mermaid-theme.ts` 的流程图配色：深色画布、青绿 accent、圆角 7、流动虚线边。
    private static func mermaidConfigurationJSON() -> String {
        """
        {
          startOnLoad: false,
          securityLevel: 'strict',
          suppressErrorRendering: true,
          htmlLabels: false,
          theme: 'base',
          fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif',
          flowchart: { htmlLabels: false, curve: 'rounded', useMaxWidth: true, nodeSpacing: 40, rankSpacing: 46, padding: 12 },
          sequence: { useMaxWidth: true, actorMargin: 46, boxMargin: 8 },
          themeVariables: {
            darkMode: true,
            background: '#090d12',
            mainBkg: '#5fd6a51f',
            secondBkg: '#141c25',
            tertiaryColor: '#090d12',
            primaryColor: '#5fd6a51f',
            primaryTextColor: '#dce7ee',
            primaryBorderColor: '#5fd6a5',
            secondaryColor: '#141c25',
            secondaryTextColor: '#dce7ee',
            secondaryBorderColor: '#94a3b833',
            tertiaryTextColor: '#dce7ee',
            tertiaryBorderColor: '#94a3b833',
            lineColor: '#8795a5',
            arrowheadColor: '#8795a5',
            textColor: '#dce7ee',
            nodeTextColor: '#dce7ee',
            titleColor: '#dce7ee',
            edgeLabelBackground: '#141c25',
            clusterBkg: '#141c25',
            clusterBorder: '#94a3b8',
            noteBkgColor: '#f4c96b1f',
            noteTextColor: '#dce7ee',
            noteBorderColor: '#f4c96b',
            actorBkg: '#141c25',
            actorTextColor: '#dce7ee',
            actorBorder: '#5fd6a5',
            signalColor: '#dce7ee',
            signalTextColor: '#dce7ee',
            labelTextColor: '#dce7ee',
            loopTextColor: '#dce7ee',
            activationBkgColor: '#141c25',
            activationBorderColor: '#5fd6a5',
            sequenceNumberColor: '#090d12'
          },
          themeCSS: [
            '@keyframes kaiming-mermaid-edge-flow{from{stroke-dashoffset:0}to{stroke-dashoffset:-32}}',
            '.node > rect.basic,.cluster > rect{rx:7px;ry:7px;}',
            '.node > rect.basic{fill:#5fd6a51f !important;stroke:#5fd6a5 !important;}',
            '.node > path.basic{fill:#c084fc1f !important;stroke:#c084fc !important;}',
            '.node > polygon{fill:#f4c96b1f !important;stroke:#f4c96b !important;}',
            '.node > circle,.node > ellipse{fill:#94a3b81f !important;stroke:#94a3b8 !important;}',
            '.cluster > rect{fill:#141c25 !important;stroke:#94a3b8 !important;}',
            '.edgePaths path{stroke-linecap:round;stroke-linejoin:round;}',
            '.edgePaths path.edge-pattern-solid{stroke-dasharray:6 10;animation:kaiming-mermaid-edge-flow 1.6s linear infinite;}',
            '.edgeLabel,.edgeLabel p,.nodeLabel{color:#dce7ee !important;}',
            '.edgeLabel rect{fill:#141c25 !important;}'
          ].join('')
        }
        """
    }
}
