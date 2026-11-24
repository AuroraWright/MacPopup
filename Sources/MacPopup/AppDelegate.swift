import AppKit
import Transcription
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
    /// The status lines at the top of the menu (see updateStatusIcon).
    private var statusLines: [NSMenuItem] = []
    private var ocr: OCRController!
    private var clipboardMonitor: ClipboardMonitor!
    private var sentenceAudio: SentenceAudioController!
    private var audioTranscriber: AudioTranscriber!
    private var screenshots: ScreenshotHistory!
    /// The lines shown in the text box or read by OCR (see noteLine). `Info` is whether OCR read the line.
    private var lines = ShownLines<Bool>()
    private var connectedWebsockets: [String] = []
    private var yomitanAPI: YomitanAPIStatus!
    private var welcomeWindow: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        schemeHandler = WebAssetsSchemeHandler(root: WebViewFactory.webRoot)
        bridge.host = self

        // The overlay's web view, with the bridge and the asset scheme.
        let configuration = WebViewFactory.makeConfiguration(bridge: bridge, schemeHandler: schemeHandler)
        overlay = OverlayController(configuration: configuration)
        settingsWindow = SettingsWindowController(selectOCRWindow: { [weak self] in self?.ocr.selectWindow() }) { [weak self] in
            try self?.audioTranscriber.clearVideoTranscripts()
        }
        overlay.onMouseButtonEvent = { [weak self] button, isDown in
            self?.settingsWindow.mouseButtonEvent(button: button, isDown: isDown)
            if isDown { self?.ocr?.mouseButtonPressed(button) }
        }

        // First, so the log starts with its session record.
        DebugLog.start()
        ocr = OCRController(overlay: overlay)
        DebugLog.onSession = { [weak self] in self?.ocr.logWindow() }
        clipboardMonitor = ClipboardMonitor(overlay: overlay)
        sentenceAudio = SentenceAudioController(overlay: overlay)
        SpeechModel.registerModels()
        audioTranscriber = AudioTranscriber(overlay: overlay)
        screenshots = ScreenshotHistory { [weak self] fullResolution in try await self?.ocr.windowScreenshot(fullResolution: fullResolution) }
        GamepadController.shared.onSwitchAway = { [weak self] in self?.overlay.evaluate("window.__macpopupReleaseForGame?.()") }
        GamepadController.shared.onChange = { [weak self] pressed in
            guard let data = try? JSONSerialization.data(withJSONObject: pressed.sorted()), let json = String(data: data, encoding: .utf8) else { return }
            self?.overlay.evaluate("window.__macpopupGamepad?.(\(json))")
        }
        GamepadController.shared.onToast = { [weak self] message in self?.overlay.showToast(message) }
        GamePause.shared.onToast = { [weak self] message in self?.overlay.showToast(message) }
        GamePause.shared.onResume = { [weak self] in self?.ocr.gameResumed() }
        GamePause.shared.onShortcut = { [weak self] in self?.overlay.evaluate("window.__macpopupPauseShortcut?.()") }
        GamePause.shared.onSwitchAway = { [weak self] in self?.overlay.evaluate("window.__macpopupEndPausedScan?.()") }
        GamepadController.shared.onInput = { [weak self] in
            self?.ocr.inputUsed()
            if !GamepadController.shared.isHeld { self?.ocr.gameInput() }
        }
        yomitanAPI = .shared
        yomitanAPI.onChange = { [weak self] in self?.updateStatusIcon() }

        setUpStatusItem()
        setUpEditMenu()
        setOverlayVisible(true)
        hideShortcut.onPress = { [weak self] _ in self?.toggleOverlayVisible(from: "keyboard") }
        selectWindowShortcut.onPress = { [weak self] _ in
            if DebugLog.isOn { DebugLog.record(["type": "event", "event": "select window", "from": "keyboard"]) }
            self?.selectOCRWindow()
        }
        SettingsStore.shared.observe { [weak self] _ in self?.applyShortcuts() }
        applyShortcuts()

        if WelcomeWindowController.isFirstLaunch {
            welcomeWindow = WelcomeWindowController(yomitanAPI: yomitanAPI) { [weak self] section in
                guard let self else { return }
                settingsWindow.show(above: overlay.panel.level, section: section)
            }
            welcomeWindow?.show(above: overlay.panel.level)
        }
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

        let menu = NSMenu()
        menu.delegate = self
        // Below the status lines (see updateStatusIcon).
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Hide Overlays", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(toggleItem)
        ocrItem = NSMenuItem(title: "OCR Overlay", action: #selector(toggleOCR), keyEquivalent: "")
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
        updateStatusIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // The status line changes if the check finds something else while the menu is open.
        yomitanAPI.check()
        toggleItem.title = overlay.isVisible ? "Hide Overlays" : "Show Overlays"
        ocrItem.state = ocr.isOverlayOn ? .on : .off
        // Hidden when it would do nothing: with one display, or while the OCR overlay keeps the overlay on the
        // display of the window it reads.
        moveItem.isHidden = NSScreen.screens.count < 2 || overlay.preferredScreen != nil
    }

    @objc private func toggleOverlay() {
        setOverlayVisible(!overlay.isVisible)
    }

    /// Settings → General → Overlay hide key/buttons: the keyboard shortcut (the controller buttons are matched by
    /// overlay.js).
    private let hideShortcut = HotkeyController(signature: 0x4D50_4F48) // "MPOH"
    /// Settings → General → Select captured window key, as Select Captured Window… in the menu bar.
    private let selectWindowShortcut = HotkeyController(signature: 0x4D50_5357) // "MPSW"

    private func applyShortcuts() {
        let settings = SettingsStore.shared.dictionary
        hideShortcut.set(KeyCombination(setting: settings["overlayHideShortcut"])) { [weak self] taken in
            self?.overlay.showToast("The overlay hide shortcut \(taken.displayName) is used by another app or shortcut")
        }
        selectWindowShortcut.set(KeyCombination(setting: settings["selectWindowShortcut"])) { [weak self] taken in
            self?.overlay.showToast("The select captured window key \(taken.displayName) is used by another app or shortcut")
        }
    }

    /// Hides the overlays or shows them again, from the overlay hide key/buttons (`source`).
    func toggleOverlayVisible(from source: String) {
        if DebugLog.isOn { DebugLog.record(["type": "event", "event": "overlay hide", "from": source, "visible": !overlay.isVisible]) }
        toggleOverlay()
    }

    @objc private func toggleOCR() {
        ocr.setOverlayOn(!ocr.isOverlayOn)
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

    func ocrMessage(_ body: [String: Any]) -> Bool {
        // The page tells OCR when it has (re)loaded.
        if body["action"] as? String == "ready" {
            overlay.pageReady()
            audioTranscriber.pageReady()
        }
        return ocr.handle(body)
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
            throw AppError("Snapshot failed")
        }
        return png
    }

    func snapshotOverlay(rect: CGRect, fullResolution: Bool) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        let image = try await overlay.webView.takeSnapshot(configuration: configuration)
        // At the display's scale, or else in points.
        let size = fullResolution ? nil : NSRect(origin: .zero, size: rect.size)
        guard let full = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AppError("Snapshot failed") }
        guard let size, full.width != Int(size.width),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return full }
        context.interpolationQuality = .high
        context.draw(full, in: size)
        return context.makeImage() ?? full
    }

    func pressSentenceAudioShortcut(note: Int64?) {
        sentenceAudio.shortcutPressed(note: note)
    }

    func switchOverlay(from source: String) {
        ocr.switchOverlay(from: source)
    }

    func cardAdded(note: Int64, line: Int?, nested: Bool, withAudio: Bool) {
        sentenceAudio.cardAdded(note: note, line: line, nested: nested, withAudio: withAudio)
    }

    /// A line was shown `age` seconds ago: a WebSocket or clipboard line, or (`fromOCR`) a settled OCR reading of the
    /// dialogue with its `rows` of text, its `letters`' boxes and paragraph `breaks` (see ShownLines.note). It's noted for Anki Audio and
    /// Screenshot, and the reply tells the page the line's id ("id") and what to do with it in the Floating Window's
    /// text box (for "Read text from OCR"):
    /// - A reading either adds a new line ("add"), updates the last OCR line because it grew ("replace"), or does
    ///   nothing because it's already there. "segments" are where the reading's lines start, as [id, row, offset in the
    ///   row's UTF-16 code units].
    /// - A WebSocket or clipboard line with the same text as the last OCR line takes its place ("replacesOCR": the box
    ///   removes its last line before adding the new one).
    /// `replaces`: the id of the transcribed line this one grew from (see AudioTranscriber), which it takes the place of
    /// if it's still the last line.
    func noteLine(
        _ text: String, age: Double, fromOCR: Bool, transcribed: Bool, replaces: Int?, rows: [String], letters: [CGRect], breaks: Set<Int>
    ) -> [String: Any] {
        if lines.count >= 100 { lines.removeFirst(lines.count - 99) }
        // A sent line is the line before it again as the text box decides it (see transformLine in overlay.js).
        let settings = SettingsStore.shared.dictionary
        let sent = ShownLines<Bool>.SentLines(
            repeats: (settings["preventLastDuplicate"] as? NSNumber)?.intValue ?? 0 > 0 || settings["preventGlobalDuplicate"] as? Bool == true,
            grows: settings["mergeEqualLineStarts"] as? Bool == true,
            replaces: replaces
        )
        guard let noted = lines.note(text, page: fromOCR, breaks: breaks, rows: rows, letters: letters, sent: sent,
                                     language: settings["language"] as? String ?? "ja", info: { fromOCR }) else { return [:] }
        let line = lines[noted.index]
        sentenceAudio.noteLine(id: line.id, isNew: noted.isNew, text: line.text, age: age, transcribed: transcribed)
        screenshots.noteLine(id: line.id, isNew: noted.isNew, grew: noted.grew, settled: fromOCR)
        var reply: [String: Any] = ["id": line.id]
        if fromOCR {
            reply["segments"] = noted.starts.compactMap { start in
                ShownLines<Bool>.position(of: start.start, in: rows).map { [start.id, $0.row, $0.offset] }
            }
            if noted.isNew {
                reply["add"] = line.text
            } else if line.info, noted.grew {
                reply["replace"] = line.text
            }
        } else if !noted.isNew, line.info {
            lines[noted.index].info = false
            reply["replacesOCR"] = true
        }
        DebugLog.note(
            "line \(line.id) \(noted.isNew ? "new" : noted.grew ? "grew" : "again"), \(fromOCR ? "read with OCR" : "sent")"
                + (fromOCR && noted.starts.count > 1 ? ", lines from \(noted.starts.map { "\($0.id) at \($0.start)" }.joined(separator: ", "))" : "")
                + (reply["replacesOCR"] != nil ? ", in place of the OCR line" : "") + ": \(line.text)"
        )
        return reply
    }

    func bufferedScreenshot(line: Int, format: String, quality: Double, fullResolution: Bool) -> Data? {
        screenshots.screenshot(forLine: line, format: .init(format: format, quality: quality, fullResolution: fullResolution))
    }

    func simulateMouse(x: Double, y: Double, shift: Bool) {
        overlay.simulateMouse(x: x, y: y, modifiers: shift ? .shift : [])
    }

    func setConnectedWebsockets(_ urls: [String]) {
        connectedWebsockets = urls
        updateStatusIcon()
    }

    func iinaPlayerStatus(_ body: [String: Any]) {
        audioTranscriber.playerStatus(body)
    }

    func reportYomitanAPIRequest(succeeded: Bool) {
        yomitanAPI.reportRequest(succeeded: succeeded)
    }

    /// The menu bar icon is filled while the overlay is shown, has an exclamation mark instead of lines
    /// while the Yomitan API doesn't answer, and has a dot while a WebSocket is connected. Its tooltip and
    /// the status lines at the top of its menu say the same.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let visible = overlay?.isVisible ?? false
        let connected = !connectedWebsockets.isEmpty
        let yomitanStatus: String
        var yomitanUnreachable = false
        switch yomitanAPI?.state ?? .unknown {
        case .unknown:
            yomitanStatus = "Checking the Yomitan API…"
        case .reachable(let version):
            yomitanStatus = "Yomitan \(version) connected"
        case .unreachable:
            yomitanStatus = "Yomitan API not connected"
            yomitanUnreachable = true
        }
        let websocketLines = connected ? connectedWebsockets.map { "WebSocket: \($0) connected" } : ["No WebSocket connected"]

        // Lines that can't be chosen: the Yomitan API's, then one for each WebSocket.
        if let menu = statusItem.menu {
            for item in statusLines { menu.removeItem(item) }
            statusLines = ([yomitanStatus] + websocketLines).map { title in
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            }
            for (index, item) in statusLines.enumerated() { menu.insertItem(item, at: index) }
        }

        button.image = Self.statusIcon(filled: visible, warning: yomitanUnreachable, dot: connected)
        button.image?.accessibilityDescription = "MacPopup" + (visible ? "" : ", overlays hidden")
            + (yomitanUnreachable ? ", Yomitan API not connected" : "") + (connected ? ", WebSocket connected" : "")
        let websocketStatus = connected
            ? (connectedWebsockets.count > 1 ? "WebSockets: " : "WebSocket: ") + connectedWebsockets.joined(separator: ", ") + " connected"
            : "No WebSocket connected"
        button.toolTip = "MacPopup\n\(yomitanStatus)\n\(websocketStatus)"
    }

    private static func statusIcon(filled: Bool, warning: Bool, dot: Bool) -> NSImage? {
        let name = (warning ? "exclamationmark.bubble" : "text.bubble") + (filled ? ".fill" : "")
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
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
            // The popups close and the controller goes back to the game (else Game Pause would keep it paused).
            overlay.evaluate("window.__macpopupReleaseForGame?.()")
            overlay.hide()
        }
        GamepadController.shared.overlayVisible = visible
        updateStatusIcon()
    }
}
