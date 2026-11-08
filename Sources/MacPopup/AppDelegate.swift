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
    private var moveItem: NSMenuItem!
    private var ocr: OCRController!
    private var clipboardMonitor: ClipboardMonitor!
    private var sentenceAudio: SentenceAudioController!
    private var connectedWebsockets: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        schemeHandler = WebAssetsSchemeHandler(root: WebViewFactory.webRoot)
        bridge.host = self

        // Both web views share one configuration, so they share the bridge and the asset scheme.
        let configuration = WebViewFactory.makeConfiguration(bridge: bridge, schemeHandler: schemeHandler)
        overlay = OverlayController(configuration: configuration)
        settingsWindow = SettingsWindowController { [weak self] in self?.ocr.selectWindow() }
        overlay.onMouseButtonEvent = { [weak self] button, isDown in
            self?.settingsWindow.mouseButtonEvent(button: button, isDown: isDown)
            if isDown { self?.ocr.mouseClicked() }
        }

        ocr = OCRController(overlay: overlay)
        clipboardMonitor = ClipboardMonitor(overlay: overlay)
        sentenceAudio = SentenceAudioController(overlay: overlay)

        setUpStatusItem()
        setUpEditMenu()
        setOverlayVisible(true)
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
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self
        toggleItem = NSMenuItem(title: "Hide Overlays", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(toggleItem)
        ocrItem = NSMenuItem(title: "OCR Mode", action: #selector(toggleOCR), keyEquivalent: "")
        menu.addItem(ocrItem)
        moveItem = NSMenuItem(title: "Move to Next Display", action: #selector(moveToNextDisplay), keyEquivalent: "")
        menu.addItem(moveItem)
        menu.addItem(NSMenuItem(title: "Select Captured Window…", action: #selector(selectOCRWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
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
        // Hidden when it would do nothing: with one display, or while screen OCR mode keeps the overlay on the
        // display of the window it reads.
        moveItem.isHidden = NSScreen.screens.count < 2 || overlay.preferredScreen != nil
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

    func setConnectedWebsockets(_ urls: [String]) {
        connectedWebsockets = urls
        updateStatusIcon()
    }

    /// The menu bar icon is filled while the overlay is shown, and has a dot while a WebSocket is connected.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let visible = overlay?.isVisible ?? false
        let connected = !connectedWebsockets.isEmpty
        button.image = Self.statusIcon(filled: visible, dot: connected)
        button.image?.accessibilityDescription = "MacPopup" + (visible ? "" : ", overlays hidden") + (connected ? ", WebSocket connected" : "")
        button.toolTip = connected ? "MacPopup: connected to " + connectedWebsockets.joined(separator: ", ") : "MacPopup: no WebSocket connected"
    }

    private static func statusIcon(filled: Bool, dot: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: filled ? "text.bubble.fill" : "text.bubble", accessibilityDescription: nil) else {
            return nil
        }
        guard dot else { return symbol }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            let diameter = 5.0
            let dot = NSRect(x: rect.maxX - diameter, y: rect.minY, width: diameter, height: diameter)
            // A gap around the dot, so that it stands apart from the bubble.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
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
        updateStatusIcon()
    }
}
