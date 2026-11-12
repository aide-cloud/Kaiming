import AppKit
import SwiftUI
import WebKit

/// WKWebView 承载整篇 Markdown 预览。
///
/// - HTML 由 ``MarkdownWebDocumentBuilder`` 生成，自包含（图片是 `data:` URL），
///   用 `loadHTMLString` 直接加载，不写临时文件、不联网。
/// - 外观跟随系统：CSS 用 `prefers-color-scheme`，WKWebView 会随
///   `NSApp.effectiveAppearance` 自动切换，无需手动重载。
/// - 页宽/字号通过 JS 更新 CSS 变量，不重新加载文档（保留滚动位置）。
/// - 点击链接：页面内锚点放行，其余交给系统默认应用打开。
/// - `scrollRequest`：一次性滚动到标题锚点；文档尚未加载完成时保存为 pending，
///   加载完成后自动执行。
struct MarkdownWebPreviewView: NSViewRepresentable {
    let html: String
    var baseURL: URL?
    var pageWidth: MarkdownPageWidth = .standard
    var fontSize: CGFloat = 14
    var scrollRequest: MarkdownWebScrollRequest? = nil
    /// 查找请求（⌘F）：由窗口层的 `MarkdownFindController` 驱动。
    var searchRequest: MarkdownWebSearchRequest? = nil
    /// 查找结果回调（匹配数量/当前序号/正则错误）。
    var onSearchResult: ((MarkdownWebSearchResult) -> Void)? = nil
    /// 点击内容里的链接。返回 `true` 表示已由 App 内部处理（例如切换到另一个
    /// Markdown 文档的渲染预览）；返回 `false` 时交给系统默认应用打开。
    var onLinkActivated: ((URL) -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = MarkdownGitHubTheme.canvas

        context.coordinator.attach(webView)
        context.coordinator.updateCallbacks(
            onSearchResult: onSearchResult,
            onLinkActivated: onLinkActivated
        )
        context.coordinator.load(
            html: html,
            baseURL: baseURL,
            pageWidth: pageWidth,
            fontSize: fontSize
        )
        context.coordinator.updateScrollRequest(scrollRequest)
        context.coordinator.applySearchRequest(searchRequest)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateCallbacks(
            onSearchResult: onSearchResult,
            onLinkActivated: onLinkActivated
        )
        context.coordinator.load(
            html: html,
            baseURL: baseURL,
            pageWidth: pageWidth,
            fontSize: fontSize
        )
        context.coordinator.updateScrollRequest(scrollRequest)
        context.coordinator.applySearchRequest(searchRequest)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var webView: WKWebView?
        private var loadedHTML: String?
        private var loadedBaseURL: URL?
        private var pendingStyle: (maxWidth: String, fontSize: CGFloat)?
        private var isDocumentLoaded = false
        private var pendingScrollRequest: MarkdownWebScrollRequest?
        private var lastHandledScrollRequestID: UUID?
        private var readinessProbe: Task<Void, Never>?

        // 查找桥接
        private var onSearchResult: ((MarkdownWebSearchResult) -> Void)?
        private var onLinkActivated: ((URL) -> Bool)?
        private var pendingSearchRequest: MarkdownWebSearchRequest?
        private var lastSearchRequestID: UUID?

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func updateCallbacks(
            onSearchResult: ((MarkdownWebSearchResult) -> Void)?,
            onLinkActivated: ((URL) -> Bool)?
        ) {
            self.onSearchResult = onSearchResult
            self.onLinkActivated = onLinkActivated
        }

        func load(html: String, baseURL: URL?, pageWidth: MarkdownPageWidth, fontSize: CGFloat) {
            guard let webView else { return }
            let style = (pageWidth.cssMaxWidth, fontSize)
            if loadedHTML != html || loadedBaseURL != baseURL {
                loadedHTML = html
                loadedBaseURL = baseURL
                pendingStyle = style
                isDocumentLoaded = false
                webView.loadHTMLString(html, baseURL: baseURL)
                startReadinessProbe(webView)
            } else {
                pendingStyle = style
                if isDocumentLoaded {
                    applyStyle(style)
                }
            }
        }

        /// 幂等：didFinish 之前也可能由就绪探针先触发。
        func documentDidLoad() {
            guard !isDocumentLoaded else { return }
            isDocumentLoaded = true
            readinessProbe?.cancel()
            readinessProbe = nil
            if let pendingStyle {
                applyStyle(pendingStyle)
            }
            applyPendingScrollRequestIfPossible()
            applyPendingSearchRequestIfPossible()
            #if DEBUG
            simulateLinkClickIfRequested()
            #endif
        }

        #if DEBUG
        private var didSimulateLinkClick = false

        /// 仅调试/快照验收：自动点击正文里的第一个链接，用来验证内部链接是否
        /// 留在渲染预览中跳转。`KAIMING_PREVIEW_CLICK_LINK=1` 开启。
        private func simulateLinkClickIfRequested() {
            guard !didSimulateLinkClick,
                  ProcessInfo.processInfo.environment["KAIMING_PREVIEW_CLICK_LINK"] == "1",
                  let webView else { return }
            didSimulateLinkClick = true
            webView.evaluateJavaScript(
                "(function(){var a=document.querySelector('.markdown-body a[href]');if(!a){return null;}var href=a.getAttribute('href');a.click();return href;})();"
            ) { value, _ in
                NSLog("Kaiming debug: simulated preview link click href=\(String(describing: value))")
            }
        }
        #endif

        /// `didFinish` 会等所有子资源（远程图片）结束，图片慢或挂起时，
        /// 页宽/字号/标题跳转会被拖住。这里轮询运行时就绪（`window.KaimingPreview`
        /// 由 HTML 末尾的脚本定义），先于 didFinish 恢复交互；didFinish 仍是兜底。
        private func startReadinessProbe(_ webView: WKWebView) {
            readinessProbe?.cancel()
            readinessProbe = Task { @MainActor [weak self, weak webView] in
                for _ in 0..<120 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                    guard let self, let webView, !self.isDocumentLoaded else { return }
                    let ready: Bool = await withCheckedContinuation { continuation in
                        webView.evaluateJavaScript("!!window.KaimingPreview") { value, _ in
                            continuation.resume(returning: (value as? Bool) ?? false)
                        }
                    }
                    if ready {
                        self.documentDidLoad()
                        return
                    }
                }
            }
        }

        /// 每次点击内容导航都会带来新的 UUID；同一个 request 只执行一次。
        func updateScrollRequest(_ request: MarkdownWebScrollRequest?) {
            guard let request else { return }
            guard request.id != lastHandledScrollRequestID else { return }
            pendingScrollRequest = request
            applyPendingScrollRequestIfPossible()
        }

        private func applyPendingScrollRequestIfPossible() {
            guard isDocumentLoaded,
                  let webView,
                  let request = pendingScrollRequest else { return }
            guard request.id != lastHandledScrollRequestID else {
                pendingScrollRequest = nil
                return
            }
            guard let js = Self.scrollScript(for: request.headingID) else {
                // 非法 id 直接消费掉，避免反复尝试。
                lastHandledScrollRequestID = request.id
                pendingScrollRequest = nil
                return
            }
            lastHandledScrollRequestID = request.id
            pendingScrollRequest = nil
            webView.evaluateJavaScript(js) { _, _ in }
        }

        private static func scrollScript(for headingID: String) -> String? {
            // 只允许生成的锚点字符，避免把外部字符串拼进 JS。
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard !headingID.isEmpty,
                  headingID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                return nil
            }
            return """
            (function () {
              if (window.KaimingPreview) {
                return window.KaimingPreview.scrollToHeading('\(headingID)');
              }
              var element = document.getElementById('\(headingID)');
              if (!element) { return false; }
              element.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'auto' });
              return true;
            })();
            """
        }

        private func applyStyle(_ style: (maxWidth: String, fontSize: CGFloat)) {
            guard let webView, isDocumentLoaded else { return }
            let maxWidth = style.maxWidth
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = """
            if (window.KaimingPreview) {
              window.KaimingPreview.applyStyle('\(maxWidth)', \(Double(style.fontSize)));
            }
            true;
            """
            // 这里刻意用 completion 版本：WebKit 的 async 版本在 JS 返回 undefined 时
            // 会把 nil 隐式解包成 Any 并崩溃（快照模式 exit 133）。返回值忽略即可。
            webView.evaluateJavaScript(js) { _, _ in }
        }

        // MARK: - 查找

        /// 每次查找都带新的 UUID；同一个 request 只执行一次。文档尚未加载完成时
        /// 先挂起，`documentDidLoad` 后自动补执行。
        func applySearchRequest(_ request: MarkdownWebSearchRequest?) {
            guard let request else { return }
            guard request.id != lastSearchRequestID else { return }
            lastSearchRequestID = request.id
            guard isDocumentLoaded else {
                pendingSearchRequest = request
                return
            }
            runSearch(request)
        }

        private func applyPendingSearchRequestIfPossible() {
            guard isDocumentLoaded, let request = pendingSearchRequest else { return }
            pendingSearchRequest = nil
            runSearch(request)
        }

        private func runSearch(_ request: MarkdownWebSearchRequest) {
            guard let webView else { return }
            if request.clear || request.query.isEmpty {
                webView.evaluateJavaScript(
                    "window.KaimingPreview && window.KaimingPreview.clearFind();"
                ) { _, _ in }
                return
            }

            let payload: [String: Any] = [
                "query": request.query,
                "useRegex": request.useRegex,
                "caseSensitive": request.caseSensitive,
                "index": request.currentIndex,
                "requestID": request.id.uuidString
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.KaimingPreview && window.KaimingPreview.find(\(json));"
            webView.evaluateJavaScript(js) { [weak self] value, _ in
                // JS 返回普通对象，WebKit 桥接成 NSDictionary；只在拿到结果时采纳，
                // 避免文档切换瞬间的 nil 结果把界面清零。
                guard let self, let dictionary = value as? [String: Any] else { return }
                let count = (dictionary["count"] as? NSNumber)?.intValue ?? 0
                let index = (dictionary["index"] as? NSNumber)?.intValue ?? 0
                let error = dictionary["error"] as? String
                Task { @MainActor in
                    self.onSearchResult?(
                        MarkdownWebSearchResult(
                            requestID: request.id,
                            count: count,
                            index: index,
                            errorMessage: error
                        )
                    )
                }
            }
        }
    }
}

// MARK: - 导航与链接

extension MarkdownWebPreviewView.Coordinator: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            self.documentDidLoad()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // WKNavigationAction 只在主线程可读；是否放行/内跳/外开在这里同步决定。
        MainActor.assumeIsolated {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // 页面内锚点（#标题）继续由 WebView 自己滚动。
            if Self.isSameDocumentAnchor(url, baseURL: loadedBaseURL) {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            // 内部文件链接交给 App：在渲染预览里切换到目标文档，而不是
            // 让系统默认应用弹出一个新窗口。
            if let onLinkActivated, onLinkActivated(url) {
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            decisionHandler(.allow)
        }
    }

    /// `#anchor` 在 `loadHTMLString` 里会解析成 `about:blank#…` 或
    /// `<baseURL>#…`；只有“去掉 fragment 后仍是当前文档/base”才算页内锚点。
    /// `b.md#section` 必须走内链路由，不能被当成页内跳转放行。
    private static func isSameDocumentAnchor(_ url: URL, baseURL: URL?) -> Bool {
        guard url.fragment != nil else { return false }
        if url.scheme == "about" { return true }
        guard url.scheme == "file", let baseURL else { return false }
        func normalized(_ path: String) -> String {
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let targetPath = normalized(url.standardizedFileURL.path)
        let basePath = normalized(baseURL.standardizedFileURL.path)
        return !targetPath.isEmpty && targetPath == basePath
    }
}

// MARK: - 新窗口请求

/// `target="_blank"` 等新窗口请求：统一交给内跳/外开逻辑，绝不让 WebView
/// 自己创建第二个窗口。
extension MarkdownWebPreviewView.Coordinator: WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url else { return }
            if let onLinkActivated, onLinkActivated(url) { return }
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
