import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BridgeHost, NSMenuDelegate {
    private let bridge = NativeBridge()
    private var schemeHandler: WebAssetsSchemeHandler!
    private var overlay: OverlayController!
    private var settingsWindow: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        schemeHandler = WebAssetsSchemeHandler(root: WebViewFactory.webRoot)
        bridge.host = self

        // Both web views share one configuration, so they share the bridge and the asset scheme.
        let configuration = WebViewFactory.makeConfiguration(bridge: bridge, schemeHandler: schemeHandler)
        overlay = OverlayController(configuration: configuration)
        settingsWindow = SettingsWindowController(configuration: configuration)
        overlay.onMouseButtonEvent = { [weak self] button, isDown in
            self?.settingsWindow.mouseButtonEvent(button: button, isDown: isDown)
        }

        setUpStatusItem()
        overlay.show()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "MacPopup")

        let menu = NSMenu()
        menu.delegate = self
        toggleItem = NSMenuItem(title: "Hide Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Move to Next Display", action: #selector(moveToNextDisplay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacPopup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleItem.title = overlay.isVisible ? "Hide Overlay" : "Show Overlay"
    }

    @objc private func toggleOverlay() {
        setOverlayVisible(!overlay.isVisible)
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func moveToNextDisplay() {
        overlay.moveToNextDisplay()
    }

    @objc private func reload() {
        overlay.reload()
    }

    // MARK: BridgeHost

    func setHitRects(_ rects: [CGRect]) {
        overlay.setHitRects(rects)
    }

    func openSettings() {
        settingsWindow.show(above: overlay.panel.level)
    }

    func overlayDisplayID() -> CGDirectDisplayID? {
        overlay.displayID
    }

    func overlayMenuBarHeight() -> Double {
        overlay.menuBarHeight
    }

    func snapshotOverlay() async throws -> Data {
        let image = try await overlay.webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw BridgeError("Snapshot failed")
        }
        return png
    }

    func simulateMouse(x: Double, y: Double, shift: Bool) {
        overlay.simulateMouse(x: x, y: y, modifiers: shift ? .shift : [])
    }

    var overlayIgnoresMouseEvents: Bool {
        overlay.panel.ignoresMouseEvents
    }

    func setOverlayVisible(_ visible: Bool) {
        if visible {
            overlay.show()
        } else {
            overlay.hide()
        }
    }
}
