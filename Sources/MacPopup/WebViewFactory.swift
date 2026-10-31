import AppKit
import WebKit

enum WebViewFactory {
    static var webRoot: URL {
        Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
    }

    @MainActor
    static func makeConfiguration(bridge: NativeBridge, schemeHandler: WebAssetsSchemeHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WebAssetsSchemeHandler.scheme)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: NativeBridge.handlerName)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        enableMasonryLayout(configuration.preferences)
        // Development hook: MACPOPUP_TEST_SCRIPT=<file.js> is injected into every top-level page.
        if let path = ProcessInfo.processInfo.environment["MACPOPUP_TEST_SCRIPT"],
           let source = try? String(contentsOfFile: path, encoding: .utf8) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        return configuration
    }

    /// Turns on WebKit's masonry layout, which is still a preview feature (off outside Safari Technology
    /// Preview), so popup CSS can lay out entries in columns of uneven height like in Chrome and Firefox.
    /// Current WebKit only has the older `grid-template-rows: masonry` syntax; `display: grid-lanes` is
    /// covered by the key match in case it gets a flag of its own.
    @MainActor
    private static func enableMasonryLayout(_ preferences: WKPreferences) {
        let setEnabled = NSSelectorFromString("_setEnabled:forFeature:")
        guard let features = WKPreferences.perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject],
              preferences.responds(to: setEnabled) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let function = unsafeBitCast(preferences.method(for: setEnabled), to: SetEnabled.self)
        for feature in features {
            guard let key = feature.value(forKey: "key") as? String,
                  key.contains("Masonry") || key.contains("GridLanes") else { continue }
            function(preferences, setEnabled, true, feature)
        }
    }

    static func url(for page: String) -> URL {
        WebAssetsSchemeHandler.baseURL.appendingPathComponent(page)
    }
}

/// Opens external links in the default browser and supports `<input type=file>`.
final class WebViewUIDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           url.scheme != WebAssetsSchemeHandler.scheme,
           url.scheme != "about",
           navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
