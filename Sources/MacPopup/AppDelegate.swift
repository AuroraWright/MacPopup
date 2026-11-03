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
    private var ocrItem: NSMenuItem!
    private var ocr: OCRController!
    private var clipboardMonitor: ClipboardMonitor!
    private var sentenceAudio: SentenceAudioController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        schemeHandler = WebAssetsSchemeHandler(root: WebViewFactory.webRoot)
        bridge.host = self

        // Both web views share one configuration, so they share the bridge and the asset scheme.
        let configuration = WebViewFactory.makeConfiguration(bridge: bridge, schemeHandler: schemeHandler)
        overlay = OverlayController(configuration: configuration)
        // From Settings → General: only the window is chosen, screen OCR mode stays as it is.
        settingsWindow = SettingsWindowController { [weak self] in self?.ocr.selectWindow(enableOCR: false) }
        overlay.onMouseButtonEvent = { [weak self] button, isDown in
            self?.settingsWindow.mouseButtonEvent(button: button, isDown: isDown)
            if isDown { self?.ocr.mouseClicked() }
        }

        ocr = OCRController(overlay: overlay)
        clipboardMonitor = ClipboardMonitor(overlay: overlay)
        sentenceAudio = SentenceAudioController(overlay: overlay)

        setUpStatusItem()
        setUpEditMenu()
        overlay.show()
    }

    /// The app has no menu bar of its own, but text fields in Settings need the Edit menu's key
    /// equivalents (copy, paste, select all, undo).
    private func setUpEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(NSMenuItem(title: "MacPopup", action: nil, keyEquivalent: ""))
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setConnectedWebsockets([])

        let menu = NSMenu()
        menu.delegate = self
        toggleItem = NSMenuItem(title: "Hide Overlays", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(toggleItem)
        ocrItem = NSMenuItem(title: "OCR Mode", action: #selector(toggleOCR), keyEquivalent: "")
        menu.addItem(ocrItem)
        menu.addItem(NSMenuItem(title: "Select Captured Window…", action: #selector(selectOCRWindow), keyEquivalent: ""))
        menu.addItem(.separator())
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
        toggleItem.title = overlay.isVisible ? "Hide Overlays" : "Show Overlays"
        ocrItem.state = ocr.isEnabled ? .on : .off
    }

    @objc private func toggleOverlay() {
        setOverlayVisible(!overlay.isVisible)
    }

    @objc private func toggleOCR() {
        ocr.setEnabled(!ocr.isEnabled)
    }

    @objc private func selectOCRWindow() {
        if !overlay.isVisible {
            setOverlayVisible(true)
        }
        ocr.selectWindow()
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

    func ocrMessage(_ body: [String: Any]) {
        ocr.handle(body)
    }

    func overlayDisplayID() -> CGDirectDisplayID? {
        overlay.displayID
    }

    func overlayMenuBarHeight() -> Double {
        overlay.menuBarHeight
    }

    func ocrWindowScreenshot(fullResolution: Bool) async throws -> CGImage? {
        try await ocr.windowScreenshot(fullResolution: fullResolution)
    }

    func snapshotOverlay() async throws -> Data {
        let image = try await overlay.webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw BridgeError("Snapshot failed")
        }
        return png
    }

    func pressSentenceAudioShortcut() {
        sentenceAudio.shortcutPressed()
    }

    func simulateMouse(x: Double, y: Double, shift: Bool) {
        overlay.simulateMouse(x: x, y: y, modifiers: shift ? .shift : [])
    }

    /// The menu bar icon is filled while a WebSocket is connected.
    func setConnectedWebsockets(_ urls: [String]) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: urls.isEmpty ? "text.bubble" : "text.bubble.fill",
            accessibilityDescription: urls.isEmpty ? "MacPopup" : "MacPopup, WebSocket connected"
        )
        button.toolTip = urls.isEmpty ? "MacPopup: no WebSocket connected" : "MacPopup: connected to " + urls.joined(separator: ", ")
    }

    func setOverlayCursor(_ cursor: String?) {
        overlay.setCursor(cursor)
    }

    func setHotkeys(_ combinations: [KeyCombination]) -> [Bool] {
        overlay.setHotkeys(combinations)
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
