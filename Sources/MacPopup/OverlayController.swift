import AppKit
import WebKit

// Private window server calls (see OverlayController.allowCursorInBackground).
@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty") private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32
/// Changes whenever any app sets the cursor (see OverlayController.watchCursor).
@_silgen_name("CGSCurrentCursorSeed") private func CGSCurrentCursorSeed() -> Int32

/// Borderless, transparent panel covering a whole display. It never becomes key, so the
/// game (or whatever app is in front) keeps keyboard focus while the overlay is used with the mouse.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click even though its window is never key and the app is never active.
final class OverlayWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the overlay panel. The web page reports the rectangles that should receive the mouse
/// (text box, popups); everywhere else the panel is click-through. Mouse movement is polled and
/// forwarded to the page, because WebKit doesn't deliver mouse moves to windows that aren't key
/// (so CSS :hover doesn't apply while another app is focused).
@MainActor
final class OverlayController: NSObject {
    let panel: OverlayPanel
    let webView: OverlayWebView

    private let uiDelegate = WebViewUIDelegate()
    private var hitRects: [CGRect] = []
    private var timer: Timer?
    private var lastMouseLocation = NSPoint(x: -1, y: -1)
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var lastPressed: [String] = []
    private var globalMouseMonitor: Any?
    private var buttonMonitors: [Any] = []
    /// Called for every mouse button press and release anywhere, with Yomitan's button number.
    var onMouseButtonEvent: ((_ button: Int, _ isDown: Bool) -> Void)?
    /// MACPOPUP_DEBUG_INPUT=1 logs mouse button events and state to stderr.
    private let debugInput = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_INPUT"] != nil
    private var simulatedMouseUntil = Date.distantPast
    /// The cursor the page asked for over the box or a popup (see web/src/lib/cursor.js), nil elsewhere.
    private var cursor: NSCursor?
    /// A copy of `cursor`, set instead of it every other time (see restoreCursor).
    private var cursorCopy: NSCursor?
    /// The one of the two set last.
    private weak var lastSetCursor: NSCursor?
    /// Whether the pointer is over the box or a popup.
    private var pointerInside = false
    /// Watches for other apps setting the cursor while the pointer is over the box or a popup (see watchCursor).
    private var cursorTimer: Timer?
    private var cursorSeed: Int32 = 0
    private let hotkeys = HotkeyController()
    /// Called with the cursor position in global coordinates (origin at the top left of the main display).
    var onCursorMoved: ((CGPoint) -> Void)?
    /// Overrides the display chosen in the settings (screen OCR mode follows the window being read).
    var preferredScreen: NSScreen? {
        didSet { applySettings() }
    }

    init(configuration: WKWebViewConfiguration) {
        panel = OverlayPanel(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        webView = OverlayWebView(frame: panel.contentRect(forFrameRect: panel.frame), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.isInspectable = true
        webView.autoresizingMask = [.width, .height]

        super.init()

        webView.uiDelegate = uiDelegate
        webView.navigationDelegate = uiDelegate
        panel.contentView = webView
        hotkeys.onPress = { [weak self] index in
            self?.webView.evaluateJavaScript("window.__macpopupHotkey?.(\(index))")
        }

        applySettings()
        SettingsStore.shared.observe { [weak self] json in
            self?.applySettings()
            self?.webView.evaluateJavaScript("window.__macpopupSettingsChanged?.(\(json))")
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        webView.load(URLRequest(url: WebViewFactory.url(for: "overlay.html")))
    }

    func show() {
        panel.orderFrontRegardless()
        startTracking()
        webView.evaluateJavaScript("window.__macpopupUpdateHotkeys?.()")
    }

    func hide() {
        panel.orderOut(nil)
        stopTracking()
        hotkeys.set([])
    }

    var isVisible: Bool { panel.isVisible }

    func reload() {
        hotkeys.set([])
        webView.reload()
    }

    /// Popup keyboard shortcuts, set by the page while a popup shows. Returns whether each one could be registered.
    func setHotkeys(_ combinations: [KeyCombination]) -> [Bool] {
        hotkeys.set(isVisible ? combinations : [])
    }

    func moveToNextDisplay() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        let current = screens.firstIndex(where: { $0.frame == panel.frame }) ?? 0
        updateSetting("displayIndex", value: (current + 1) % screens.count)
    }

    var displayID: CGDirectDisplayID? {
        (panel.screen ?? NSScreen.main)?.displayID
    }

    /// Height of the menu bar at the top of the overlay's screen, or 0 while it's hidden (e.g. over
    /// fullscreen apps, or when set to hide automatically).
    var menuBarHeight: Double {
        guard let screen = panel.screen ?? NSScreen.main else { return 0 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// The top left of the overlay in global coordinates (origin at the top left of the main display).
    var globalOrigin: CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? panel.frame.height
        return CGPoint(x: panel.frame.minX, y: mainHeight - panel.frame.maxY)
    }

    func evaluate(_ js: String) {
        webView.evaluateJavaScript(js)
    }

    func setHitRects(_ rects: [CGRect]) {
        hitRects = rects
        updateMouse(force: true)
    }

    // MARK: Settings

    private func applySettings() {
        let store = SettingsStore.shared
        let screens = NSScreen.screens
        let index = store.int("displayIndex") ?? 0
        let screen = preferredScreen.flatMap { preferred in screens.first { $0 == preferred } }
            ?? (screens.indices.contains(index) ? screens[index] : (NSScreen.main ?? screens.first))
        if let screen, panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: true)
        }
        panel.level = Self.windowLevel(store.string("windowLevel"))
    }

    static func windowLevel(_ name: String?) -> NSWindow.Level {
        switch name {
        case "floating": return .floating
        case "statusBar": return .statusBar
        case "popUpMenu": return .popUpMenu
        case "shielding": return NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        default: return .screenSaver
        }
    }

    private func updateSetting(_ key: String, value: Any) {
        var dictionary = SettingsStore.shared.dictionary
        dictionary[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let json = String(data: data, encoding: .utf8) else { return }
        SettingsStore.shared.update(json: json)
    }

    @objc private func screenParametersChanged() {
        applySettings()
    }

    /// The overlay shows on every space, but its popups belong to what was looked up on the space left.
    @objc private func activeSpaceChanged() {
        webView.evaluateJavaScript("window.__macpopupSpaceChanged?.()")
    }

    // MARK: Mouse tracking

    private func startTracking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Fires only for clicks delivered to other apps, i.e. outside the overlay's interactive areas.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.webView.evaluateJavaScript("window.__macpopupOutsideClick?.()")
            }
        }

        // Button presses are handled as they happen, so presses shorter than a polling interval count too.
        let buttonEvents: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: buttonEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseButtonEvent(event, source: "local") }
            return event
        }) {
            buttonMonitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: buttonEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseButtonEvent(event, source: "global") }
        }) {
            buttonMonitors.append(monitor)
        }
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
        pointerInside = false
        watchCursor()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        globalMouseMonitor = nil
        buttonMonitors.forEach(NSEvent.removeMonitor)
        buttonMonitors = []
    }

    private func mouseButtonEvent(_ event: NSEvent, source: String) {
        let isDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        if debugInput {
            let window = event.window.map { "\(type(of: $0))" } ?? "none"
            logInput("\(source) \(isDown ? "down" : "up") button=\(event.buttonNumber) window=\(window) | \(buttonStateDescription())")
        }
        onMouseButtonEvent?(event.buttonNumber, isDown)
        updateMouse(force: false, alsoPressed: isDown ? event.buttonNumber : nil)
    }

    /// - Parameter alsoPressed: A button that was just pressed, counted even if the state queries miss it.
    private func updateMouse(force: Bool, alsoPressed: Int? = nil) {
        guard panel.isVisible, Date() >= simulatedMouseUntil else { return }
        var buttons = pressedMouseButtons()
        if let alsoPressed, (0..<6).contains(alsoPressed) {
            buttons.insert(alsoPressed)
        }
        processMouse(
            location: NSEvent.mouseLocation,
            modifiers: NSEvent.modifierFlags.intersection([.shift, .control, .option, .command]),
            pressed: buttons.sorted().map { "mouse\($0)" },
            force: force
        )
    }

    /// Shows the cursor for a CSS cursor value. WebKit doesn't, because the overlay is never key, and the
    /// active app sets its own for its window below, so it's also set again while polling (see
    /// processMouse). nil gives the cursor back to the app below.
    func setCursor(_ name: String?) {
        Self.allowCursorInBackground
        if debugInput { logInput("cursor \(name ?? "nil")") }
        let previous = cursor
        cursor = name.map(Self.cursor(forCSS:))
        cursorCopy = cursor.map { NSCursor(image: $0.image, hotSpot: $0.hotSpot) }
        if let cursor {
            cursor.set()
            lastSetCursor = cursor
        } else if previous != nil {
            NSCursor.arrow.set()
        }
        watchCursor()
    }

    /// Lets this app set the cursor while another app is active. Without it, the active app's cursor
    /// for its window below the overlay wins (e.g. a text cursor), whatever the overlay sets. A private
    /// window server property, as there's no public way; if it's ever refused, the cursor just doesn't change.
    private static let allowCursorInBackground: Void = {
        let connection = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }()

    /// Sets `cursor` again if the system shows another. NSCursor.set() does nothing for the cursor this app
    /// last set, even if another app changed it since, so it alternates with an identical copy (setting another
    /// cursor in between would show that one for a moment).
    private func restoreCursor() {
        guard let cursor, let cursorCopy, let shown = NSCursor.currentSystem,
              shown.hotSpot != cursor.hotSpot || shown.image.size != cursor.image.size else { return }
        let next = lastSetCursor === cursor ? cursorCopy : cursor
        next.set()
        lastSetCursor = next
    }

    /// The active app below the overlay sets its cursor again now and then (Terminal about twice a second, as
    /// its text cursor blinks), even while the pointer is over the box or a popup, and that cursor shows until
    /// it's set back: within a frame or two at the polling rate, often enough to see it flash. So meanwhile the
    /// window server's cursor seed, which changes whenever any app sets the cursor, is watched every 2 ms (reading
    /// it costs next to nothing), and the cursor set back as soon as it changes.
    private func watchCursor() {
        let watching = pointerInside && cursor != nil
        if watching == (cursorTimer != nil) { return }
        if watching {
            cursorSeed = CGSCurrentCursorSeed()
            let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let seed = CGSCurrentCursorSeed()
                    guard seed != self.cursorSeed else { return }
                    self.cursorSeed = seed
                    self.restoreCursor()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            cursorTimer = timer
        } else {
            cursorTimer?.invalidate()
            cursorTimer = nil
        }
    }

    private static func cursor(forCSS name: String) -> NSCursor {
        switch name {
        case "pointer": return .pointingHand
        case "text": return .iBeam
        case "vertical-text": return .iBeamCursorForVerticalLayout
        case "crosshair": return .crosshair
        case "grab": return .openHand
        case "grabbing", "move": return .closedHand
        case "not-allowed", "no-drop": return .operationNotAllowed
        case "copy": return .dragCopy
        case "alias": return .dragLink
        case "context-menu": return .contextualMenu
        case "ew-resize", "col-resize", "e-resize", "w-resize": return .resizeLeftRight
        case "ns-resize", "row-resize", "n-resize", "s-resize": return .resizeUpDown
        case "nwse-resize", "se-resize", "nw-resize":
            if #available(macOS 15, *) { return .frameResize(position: .bottomRight, directions: .all) }
            return .crosshair
        case "nesw-resize", "sw-resize", "ne-resize":
            if #available(macOS 15, *) { return .frameResize(position: .bottomLeft, directions: .all) }
            return .crosshair
        default: return .arrow
        }
    }

    /// Development hook (see NativeBridge "debugMouse"): runs the tracking logic for a point in page coordinates.
    func simulateMouse(x: Double, y: Double, modifiers: NSEvent.ModifierFlags) {
        let frame = panel.frame
        simulatedMouseUntil = Date().addingTimeInterval(5)
        processMouse(location: NSPoint(x: frame.minX + x, y: frame.maxY - y), modifiers: modifiers, pressed: [], force: true)
    }

    /// Held mouse buttons, numbered like Yomitan's scan inputs: by their bit in MouseEvent.buttons, which
    /// is also the AppKit order (0 left, 1 right, 2 middle, 3 back, 4 forward). Buttons above 2 don't
    /// always show up in NSEvent.pressedMouseButtons (forward often only appears in the HID system
    /// state), so all three sources are combined.
    private func pressedMouseButtons() -> Set<Int> {
        let mask = NSEvent.pressedMouseButtons
        return Set((0..<6).filter { index in
            if mask & (1 << index) != 0 { return true }
            guard let button = CGMouseButton(rawValue: UInt32(index)) else { return false }
            return CGEventSource.buttonState(.hidSystemState, button: button)
                || CGEventSource.buttonState(.combinedSessionState, button: button)
        })
    }

    private func buttonStateDescription() -> String {
        let bits = { (state: CGEventSourceStateID) in
            (0..<6).map { CGEventSource.buttonState(state, button: CGMouseButton(rawValue: UInt32($0))!) ? "1" : "0" }.joined()
        }
        let mask = NSEvent.pressedMouseButtons
        let appKit = (0..<6).map { mask & (1 << $0) != 0 ? "1" : "0" }.joined()
        return "appKit=\(appKit) hid=\(bits(.hidSystemState)) session=\(bits(.combinedSessionState)) (buttons 0-5)"
    }

    private func logInput(_ message: String) {
        let time = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write("[input \(time)] \(message)\n".data(using: .utf8)!)
    }

    private func processMouse(location: NSPoint, modifiers: NSEvent.ModifierFlags, pressed: [String], force: Bool) {
        let frame = panel.frame
        let point = CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y)

        let inside = hitRects.contains { $0.contains(point) }
        // Keep receiving events while a drag that started inside the overlay continues outside of it.
        let dragging = NSEvent.pressedMouseButtons != 0 && !panel.ignoresMouseEvents
        let ignore = !(inside || dragging)
        if panel.ignoresMouseEvents != ignore {
            panel.ignoresMouseEvents = ignore
        }

        if debugInput, pressed != lastPressed {
            logInput("pressed \(lastPressed) -> \(pressed) | \(buttonStateDescription())")
        }
        // The active app keeps setting the cursor for its window below the overlay, so it's set again
        // while the pointer is over the box or a popup (see watchCursor).
        if inside != pointerInside {
            pointerInside = inside
            watchCursor()
        }
        if inside { restoreCursor() }
        guard force || location != lastMouseLocation || modifiers != lastModifiers || pressed != lastPressed else { return }
        lastMouseLocation = location
        lastModifiers = modifiers
        lastPressed = pressed
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        onCursorMoved?(CGPoint(x: location.x, y: mainHeight - location.y))
        guard frame.contains(location) else { return }

        // Names are plain identifiers ("mouse3"), so they can be quoted directly.
        let pressedList = pressed.map { "\"\($0)\"" }.joined(separator: ",")
        let js = "window.__macpopupPointer?.(\(point.x), \(point.y), \(modifiers.contains(.shift)), "
            + "\(modifiers.contains(.control)), \(modifiers.contains(.option)), \(modifiers.contains(.command)), [\(pressedList)])"
        webView.evaluateJavaScript(js)
    }
}
