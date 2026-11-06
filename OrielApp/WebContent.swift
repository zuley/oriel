import WebKit

@MainActor
final class WebContent: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onNavigationChanged: (() -> Void)?
    private let resourceDirectory: URL?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        resourceDirectory = Bundle.main.resourceURL
        super.init()
        webView.navigationDelegate = self
    }

    func loadFixture() {
        if let page = Bundle.main.url(forResource: "fixture", withExtension: "html"),
           let resourceDirectory {
            webView.loadFileURL(page, allowingReadAccessTo: resourceDirectory)
        } else {
            // The bundled fallback has no links. Let WebKit display its about:blank document.
            webView.navigationDelegate = nil
            webView.loadHTMLString("<h1>测试页面未找到</h1><p>请从完整的 Oriel.app 启动。</p>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onNavigationChanged?()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // M0's links stay in the bundled fixture. External browsing belongs to M1.
        guard let url = navigationAction.request.url, url.isFileURL,
              let resourceDirectory,
              url.deletingLastPathComponent().standardizedFileURL == resourceDirectory.standardizedFileURL,
              ["fixture.html", "detail.html"].contains(url.lastPathComponent),
              navigationAction.targetFrame?.isMainFrame != false else {
            return .cancel
        }
        return .allow
    }

    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }
}
