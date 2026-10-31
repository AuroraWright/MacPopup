import AppKit
import WebKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let configuration: WKWebViewConfiguration
    private let uiDelegate = WebViewUIDelegate()
    private var window: NSWindow?
    private var webView: WKWebView?

    init(configuration: WKWebViewConfiguration) {
        self.configuration = configuration
        super.init()
        SettingsStore.shared.observe { [weak self] json in
            self?.webView?.evaluateJavaScript("window.__macpopupSettingsChanged?.(\(json))")
        }
    }

    /// Lets the scan input recorder see buttons that WebKit doesn't report, such as side buttons
    /// that send their press and release at the same instant.
    func mouseButtonEvent(button: Int, isDown: Bool) {
        webView?.evaluateJavaScript("window.__macpopupMouseButton?.(\(button), \(isDown))")
    }

    func show(above level: NSWindow.Level) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacPopup Settings"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            let webView = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
            webView.isInspectable = true
            webView.uiDelegate = uiDelegate
            webView.navigationDelegate = uiDelegate
            window.contentView = webView
            webView.load(URLRequest(url: WebViewFactory.url(for: "settings.html")))
            window.center()
            self.window = window
            self.webView = webView
        }
        window?.level = NSWindow.Level(rawValue: level.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
    }
}
