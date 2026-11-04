import AppKit
import LiveText
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screen OCR mode: instead of showing the text box, MacPopup reads the text of another app's window
/// with Live Text and lays an invisible copy of it over the window (see web/src/lib/ocr-layer.js), so
/// hovering the window's own text opens popups. Without a captured window (Settings → General), it reads
/// the whole screen the overlay is on instead, apart from MacPopup's own windows; "window" below then
/// means that screen.
///
/// The window is captured with ScreenCaptureKit and watched for changes (all the time, or with "Watch
/// after mouse use" while the mouse is used and, for the dialogue, after each reading of it). With a WebSocket connected, each new line is also the
/// cue to read the window again; it doesn't replace watching, since the dialogue can go away (e.g. a
/// menu opened) or show the line in parts, a click at a time. Recognition waits until the picture has
/// stopped changing, since games often draw text gradually after the hooked line arrives.
///
/// With several regions, only the first is the dialogue that works that way. The others (e.g. menus or
/// names) are assumed to appear at once: they're read as soon as they change.
@MainActor
final class OCRController {
    struct Target {
        var windowID: CGWindowID
        var ownerName: String
        var title: String
    }

    /// Thumbnails of the watched areas, used to tell whether the window changed.
    private struct Frame {
        var time: Date
        var thumbnails: [[UInt8]]
        /// The width of each thumbnail.
        var widths: [Int]
    }

    private let overlay: OverlayController
    private(set) var isEnabled = false
    private var target: Target?
    /// No window is set: the whole screen is read.
    private var readsScreen = false
    /// Areas to read, normalized to the window (0–1, origin top left). Empty means the whole window.
    private var regions: [CGRect] = []
    /// Window bounds in global screen coordinates (points, origin top left of the main display).
    private var bounds: CGRect?
    /// The window is on screen and has stayed in place (not sliding in or out while switching spaces).
    /// It's only read then; cues wait until it is.
    private var isWindowAvailable = false
    private var boundsChangedAt = Date.distantPast
    /// A WebSocket is connected and its lines are used: each is a cue to read the window.
    private var websocketConnected = false
    /// The dialogue is watched until then, for "Watch for" after each reading of it, mouse used or not
    /// (a line read as soon as it's still may not have been finished being drawn).
    private var watchUntil = Date.distantPast
    private var lastCursorPoint: CGPoint?
    /// With "Only check for changes after mouse activity", the window is only read until a while after the mouse was last used
    /// (moved or clicked), not while it rests.
    private var mouseActiveUntil = Date.distantPast
    /// The mouse started being used: check for changes right away.
    private var checkSoon = false
    private var waitingForMouse = false
    /// Per area, thumbnail blocks that were seen animating while the text stayed the same.
    private var animatedBlocks: [Set<Int>] = []
    /// Per area, the lines last read there: an area is read on its own, and sent with the others.
    private var areaLines: [[[String: Any]]] = []
    /// Per area, the lines last left out there (by the language or as furigana), for the page's debug log.
    private var areaRemoved: [[[String: Any]]] = []
    /// The areas after the first may have changed unseen (e.g. while the window was away): read them
    /// with the next reading.
    private var otherAreasOutdated = false

    private var isCursorActive: Bool {
        Date() < mouseActiveUntil
    }

    /// Whether the window is watched for changes now: all the time, or (with
    /// "Only check for changes after mouse activity") only for a while after the mouse was used.
    private var isWatching: Bool {
        !(settings["ocrMouseWatch"] as? Bool ?? true) || isCursorActive
    }

    /// The dialogue is also watched for a while after each reading of it.
    private var isWatchingDialogue: Bool {
        isWatching || Date() < watchUntil
    }

    func mouseClicked() {
        mouseUsed()
    }

    /// The window is watched for a while after the mouse was used (e.g. a click advancing a game's text,
    /// or the cursor moving to it), since the text that brings up takes a moment to appear.
    private func mouseUsed() {
        let duration = number("ocrMouseWatchTime", 2000) / 1000
        if !isCursorActive {
            checkSoon = true
            log("mouse used (\(duration)s)")
        }
        mouseActiveUntil = max(mouseActiveUntil, Date().addingTimeInterval(duration))
    }
    private var lastSentWindowState = ""

    private var trackTimer: Timer?
    private var loopTask: Task<Void, Never>?
    private var pendingCue: Cue?
    private var lastRecognizedFrame: Frame?
    private var isPicking = false
    /// MACPOPUP_DEBUG_OCR=1 logs what triggers readings to stderr.
    private let debug = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_OCR"] != nil
    /// MACPOPUP_DEBUG_OCR_DIR=<directory> saves each area read there (read-N-areaI.png).
    private let debugDirectory = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_OCR_DIR"]
    private var debugReadings = 0

    private var scWindow: SCWindow?
    /// The display the window lies within, if it does (the screen that's read without a window).
    private var scDisplay: SCDisplay?
    /// MacPopup itself, left out when the whole screen is read.
    private var scOwnApps: [SCRunningApplication] = []
    private var captureFailures = 0
    /// The window bounds `scWindow` and `scDisplay` were looked up for.
    private var scBounds: CGRect = .null
    /// The scale the window is read at: 1 when it's drawn at 1x (e.g. a VM or game that isn't Retina
    /// aware, enlarged by macOS), since then a higher one adds no detail and only slows Live Text down.
    /// Nil until a reading has shown which; checked again now and then. Unused when the resolution is
    /// set in Settings.
    private var readingScale: CGFloat?
    private var readingScaleCheckedAt = Date.distantPast
    private var lastCoverCheck = Date.distantPast
    private var isCursorCovered = false
    private var lastRefind = Date.distantPast
    /// The last reading, sent again when the page reloads.
    private var lastResult: [String: Any]?

    private enum Cue {
        /// A new line arrived over a WebSocket: the window is about to change.
        case newLine
        /// Read again, e.g. because the window was resized or came back from another space.
        case retry
        /// Read right away (e.g. after choosing the window).
        case immediate
    }

    init(overlay: OverlayController) {
        self.overlay = overlay
        overlay.onCursorMoved = { [weak self] point in self?.cursorMoved(to: point) }
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        applySettings()
    }

    // MARK: Settings

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private func number(_ key: String, _ fallback: Double) -> Double {
        (settings[key] as? NSNumber)?.doubleValue ?? fallback
    }

    private func applySettings() {
        let enabled = settings["ocrMode"] as? Bool ?? false
        if enabled != isEnabled {
            isEnabled = enabled
            if enabled {
                start()
            } else {
                stop()
            }
            return
        }
        guard isEnabled, !isPicking else { return }
        if engine != startedEngine || language != startedLanguage || stripsFurigana != startedStripsFurigana || cloudEngine != startedCloudEngine {
            if engine != startedEngine {
                startedEngine = engine
                Task { [weak self] in await self?.warmUp() }
            }
            startedLanguage = language
            startedStripsFurigana = stripsFurigana
            startedCloudEngine = cloudEngine
            readAgain()
        }
        // The window or areas were changed elsewhere (e.g. the settings were reset or imported, or the
        // window was cleared).
        let saved = settings["ocrWindow"] as? [String: Any]
        if (saved == nil) != readsScreen {
            target = nil
            restoreSavedTarget()
            readAgain()
        } else if readsScreen {
            return
        } else if let target, saved?["ownerName"] as? String != target.ownerName || saved?["title"] as? String ?? "" != target.title {
            self.target = nil
            restoreSavedTarget()
            readAgain()
        } else if target == nil {
            restoreSavedTarget()
            if target != nil { readAgain() }
        } else {
            let newRegions = Self.decodeRegions(settings["ocrRegions"])
            if newRegions != regions {
                regions = newRegions
                readAgain()
            }
        }
    }

    /// There's something to read: the window, or the screen.
    private var hasSource: Bool {
        target != nil || readsScreen
    }

    private func readAgain() {
        forgetCloudReading()
        scWindow = nil
        scDisplay = nil
        readingScale = nil
        animatedBlocks = []
        areaLines = []
        areaRemoved = []
        lastRecognizedFrame = nil
        lastResult = nil
        lastSentWindowState = ""
        send(["type": "changing"])
        trackWindow()
        if hasSource {
            pendingCue = .immediate
        }
    }

    private func updateSettings(_ changes: [String: Any]) {
        var dictionary = SettingsStore.shared.dictionary
        for (key, value) in changes {
            dictionary[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let json = String(data: data, encoding: .utf8) else { return }
        SettingsStore.shared.update(json: json)
    }

    func setEnabled(_ enabled: Bool) {
        updateSettings(["ocrMode": enabled])
    }

    // MARK: Lifecycle

    private func start() {
        if CGPreflightScreenCaptureAccess() == false {
            CGRequestScreenCaptureAccess()
        }
        // Another window may have been saved while OCR mode was off.
        let saved = settings["ocrWindow"] as? [String: Any]
        if let target, saved?["ownerName"] as? String != target.ownerName || saved?["title"] as? String ?? "" != target.title {
            self.target = nil
        }
        restoreSavedTarget()
        if target != nil {
            regions = Self.decodeRegions(settings["ocrRegions"])
        }
        trackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackWindow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
        trackWindow()
        startedEngine = engine
        startedLanguage = language
        startedStripsFurigana = stripsFurigana
        startedCloudEngine = cloudEngine
        loopTask = Task { [weak self] in
            await self?.warmUp()
            await self?.runLoop()
        }
        if hasSource {
            pendingCue = .immediate
        }
    }

    private func stop() {
        trackTimer?.invalidate()
        trackTimer = nil
        loopTask?.cancel()
        loopTask = nil
        forgetCloudReading()
        overlay.preferredScreen = nil
        lastRecognizedFrame = nil
        lastResult = nil
        areaLines = []
        areaRemoved = []
        lastSentWindowState = ""
        send(["type": "window", "visible": false])
        send(["type": "changing"])
    }

    /// Picks the saved window again by its app and title (window numbers change when apps restart), or
    /// the screen when there's none.
    private func restoreSavedTarget() {
        guard target == nil else { return }
        guard let saved = settings["ocrWindow"] as? [String: Any], let ownerName = saved["ownerName"] as? String else {
            readsScreen = true
            regions = []
            return
        }
        readsScreen = false
        let title = saved["title"] as? String ?? ""
        // Also windows that aren't on screen now, e.g. a game in its own full screen space.
        let windows = Self.windows(onScreenOnly: false).filter { $0.ownerName == ownerName }
        guard let match = windows.first(where: { $0.title == title }) ?? windows.first else { return }
        target = Target(windowID: match.id, ownerName: match.ownerName, title: match.title)
        regions = Self.decodeRegions(settings["ocrRegions"])
    }

    private static func decodeRegions(_ value: Any?) -> [CGRect] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let x = (item["x"] as? NSNumber)?.doubleValue, let y = (item["y"] as? NSNumber)?.doubleValue,
                  let width = (item["width"] as? NSNumber)?.doubleValue, let height = (item["height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    // MARK: Choosing the window

    /// Lets the user pick the captured window and its areas. `enableOCR` also turns screen OCR mode on.
    func selectWindow(enableOCR: Bool = true) {
        guard !isPicking else { return }
        isPicking = true
        send(["type": "window", "visible": false])
        // Start from the window being read. When it isn't on screen (in another space, or minimized), it's brought
        // here first, and the picker waits for it to show where it is (it slides in while macOS switches spaces),
        // up to 2 seconds.
        guard let id = target?.windowID, !Self.onScreenWindows().contains(where: { $0.id == id }),
              let window = Self.windows(onScreenOnly: false).first(where: { $0.id == id }) else {
            pickWindow(enableOCR: enableOCR)
            return
        }
        Self.raise(window)
        Task { @MainActor in
            for _ in 0..<40 where !Self.onScreenWindows().contains(where: { $0.id == id && $0.bounds == window.bounds }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            pickWindow(enableOCR: enableOCR)
        }
    }

    private func pickWindow(enableOCR: Bool) {
        let selection = target.flatMap { target in
            Self.onScreenWindows().first { $0.id == target.windowID }.map { (window: $0, regions: regions) }
        }
        WindowPicker.pick(above: overlay.panel.level, selection: selection) { [weak self] result in
            guard let self else { return }
            self.isPicking = false
            guard let result else {
                self.lastSentWindowState = ""
                self.trackWindow()
                return
            }
            self.target = Target(windowID: result.windowID, ownerName: result.ownerName, title: result.title)
            self.readsScreen = false
            self.regions = result.regions
            self.readAgain()
            var changes: [String: Any] = [
                "ocrWindow": ["ownerName": result.ownerName, "title": result.title],
                "ocrRegions": result.regions.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
            ]
            if enableOCR { changes["ocrMode"] = true }
            self.updateSettings(changes)
        }
    }

    // MARK: Messages from the page

    private func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        let time = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write("[ocr \(time)] \(message())\n".data(using: .utf8)!)
    }

    func handle(_ body: [String: Any]) {
        log("page: \(body["action"] ?? "")\(body["connected"].map { " \($0)" } ?? "")")
        switch body["action"] as? String {
        case "websocket":
            websocketConnected = body["connected"] as? Bool ?? false
        case "cue":
            // Read when the window is available, which may be later (e.g. it's in another space).
            pendingCue = .newLine
            dropCloudRequest()
        case "accept":
            acceptedReading = true
        case "select":
            selectWindow()
        case "cancelSelect":
            WindowPicker.cancel()
        case "ready":
            // The page (re)loaded: send everything again.
            lastSentWindowState = ""
            isCursorCovered = false
            trackWindow()
            if let lastResult {
                send(lastResult)
            }
        default:
            break
        }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        overlay.evaluate("window.__macpopupOcr?.(\(json))")
    }

    // MARK: Window tracking

    struct WindowInfo {
        var id: CGWindowID
        var ownerName: String
        var ownerPID: pid_t
        var title: String
        var bounds: CGRect
        var layer: Int
        var isOnScreen: Bool
    }

    static func windowInfo(_ dictionary: [String: Any]) -> WindowInfo? {
        guard let id = dictionary[kCGWindowNumber as String] as? CGWindowID,
              let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
        return WindowInfo(
            id: id,
            ownerName: dictionary[kCGWindowOwnerName as String] as? String ?? "",
            ownerPID: dictionary[kCGWindowOwnerPID as String] as? pid_t ?? 0,
            title: dictionary[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            layer: dictionary[kCGWindowLayer as String] as? Int ?? 0,
            isOnScreen: dictionary[kCGWindowIsOnscreen as String] as? Bool ?? false
        )
    }

    /// Brings the window to the front: raises it above its app's others (unminimized) and makes the app frontmost,
    /// with Accessibility permission (the window found by its title and frame, or either), which also switches to
    /// its space. Without it, the app is activated, which macOS can refuse while MacPopup isn't the active app.
    static func raise(_ window: WindowInfo) {
        guard AXIsProcessTrusted() else {
            NSRunningApplication(processIdentifier: window.ownerPID)?.activate()
            return
        }
        let app = AXUIElementCreateApplication(window.ownerPID)
        defer { AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            var origin = CGPoint.zero, size = CGSize.zero
            guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute),
                  AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size)
            else { return nil }
            return CGRect(origin: origin, size: size)
        }
        let titled = axWindows.filter { attribute($0, kAXTitleAttribute) as? String == window.title }
        let placed = { (element: AXUIElement) in frame(element) == window.bounds }
        guard let match = titled.first(where: placed) ?? axWindows.first(where: placed) ?? titled.first else { return }
        AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
    }

    /// Normal windows of other apps, front to back.
    static func onScreenWindows() -> [WindowInfo] {
        windows(onScreenOnly: true)
    }

    private static func windows(onScreenOnly: Bool) -> [WindowInfo] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap(windowInfo).filter {
            $0.layer == 0 && $0.ownerPID != ownPID && $0.bounds.width >= 40 && $0.bounds.height >= 40
        }
    }

    private func trackWindow() {
        guard isEnabled, !isPicking else { return }
        if readsScreen {
            trackScreen()
            return
        }
        guard let target else {
            sendWindowState(visible: false)
            // The saved window may not exist yet (e.g. the game isn't running): keep looking.
            if Date().timeIntervalSince(lastRefind) > 2 {
                lastRefind = Date()
                restoreSavedTarget()
                if self.target != nil {
                    log("found the saved window")
                    readAgain()
                }
            }
            return
        }
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], target.windowID) as? [[String: Any]] ?? []
        guard let info = list.first.flatMap(Self.windowInfo), info.id == target.windowID else {
            // Closed: wait for the app to open a window again (e.g. a restarted game).
            bounds = nil
            isWindowAvailable = false
            sendWindowState(visible: false)
            if Date().timeIntervalSince(lastRefind) > 2 {
                lastRefind = Date()
                self.target = nil
                restoreSavedTarget()
                if self.target != nil {
                    scWindow = nil
                    readingScale = nil
                    animatedBlocks = []
                    areaLines = []
                    areaRemoved = []
                    lastRecognizedFrame = nil
                    pendingCue = .immediate
                } else {
                    self.target = target
                }
            }
            return
        }
        if let old = bounds, old.size != info.bounds.size, lastResult != nil {
            log("resized \(old.size) -> \(info.bounds.size)")
            // Resized: the text moved, so read it again (a new line waiting to be read will be).
            if pendingCue != .newLine { pendingCue = .retry }
            otherAreasOutdated = true
        }
        if bounds != info.bounds {
            boundsChangedAt = Date()
        }
        let onDisplay = NSScreen.screens.contains { Self.globalFrame(of: $0).intersects(info.bounds) }
        let available = info.isOnScreen && onDisplay && Date().timeIntervalSince(boundsChangedAt) >= 0.3
        if available, !isWindowAvailable, lastResult != nil {
            // Back (e.g. from another space): it may have changed or been drawn again differently.
            log("available again")
            if pendingCue != .newLine { pendingCue = .retry }
            otherAreasOutdated = true
        }
        bounds = info.bounds
        isWindowAvailable = available
        cursorMoved(to: WindowPicker.globalPoint(NSEvent.mouseLocation))
        followWindowScreen(info.bounds)
        sendWindowState(visible: info.isOnScreen)
    }

    /// Without a window: the screen the overlay is on (Settings → General → Display).
    private func trackScreen() {
        overlay.preferredScreen = nil
        guard let screen = overlay.panel.screen ?? NSScreen.main else { return }
        let frame = Self.globalFrame(of: screen)
        if bounds != frame {
            boundsChangedAt = Date()
            if bounds != nil, lastResult != nil, pendingCue != .newLine { pendingCue = .retry }
            if bounds != nil { otherAreasOutdated = true }
        }
        bounds = frame
        isWindowAvailable = Date().timeIntervalSince(boundsChangedAt) >= 0.3
        cursorMoved(to: WindowPicker.globalPoint(NSEvent.mouseLocation))
        sendWindowState(visible: true)
    }

    /// Keeps the overlay on the display that shows the window.
    private func followWindowScreen(_ windowBounds: CGRect) {
        let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        guard let screen = NSScreen.screens.first(where: { Self.globalFrame(of: $0).contains(center) }) else { return }
        if overlay.preferredScreen != screen {
            overlay.preferredScreen = screen
        }
    }

    /// A screen's frame in global coordinates with the origin at the top left of the main display.
    static func globalFrame(of screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    private func sendWindowState(visible: Bool) {
        var message: [String: Any] = ["type": "window", "visible": visible && bounds != nil]
        if let bounds {
            let origin = overlay.globalOrigin
            message["x"] = bounds.minX - origin.x
            message["y"] = bounds.minY - origin.y
            message["width"] = bounds.width
            message["height"] = bounds.height
        }
        let key = message.keys.sorted().map { "\($0)=\(message[$0]!)" }.joined(separator: ",")
        guard key != lastSentWindowState else { return }
        lastSentWindowState = key
        send(message)
    }

    /// Whether another window is in front of the target where the cursor is, so its text can't be hovered.
    private func cursorMoved(to point: CGPoint) {
        if point != lastCursorPoint {
            mouseUsed()
            lastCursorPoint = point
        }
        guard isEnabled, let target, let bounds, bounds.contains(point) else {
            setCursorCovered(false)
            return
        }
        guard Date().timeIntervalSince(lastCoverCheck) > 0.1 else { return }
        lastCoverCheck = Date()
        var covered = false
        for window in Self.onScreenWindows() {
            if window.id == target.windowID { break }
            if window.bounds.contains(point) {
                covered = true
                break
            }
        }
        setCursorCovered(covered)
    }

    private func setCursorCovered(_ covered: Bool) {
        guard covered != isCursorCovered else { return }
        isCursorCovered = covered
        send(["type": "covered", "value": covered])
    }

    // MARK: Reading the window

    private func runLoop() async {
        while !Task.isCancelled {
            guard isEnabled, !isPicking, hasSource, bounds != nil, isWindowAvailable else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            if !websocketConnected, !isWatchingDialogue, pendingCue != .immediate {
                // Without WebSocket lines, wait until the mouse is used (or the dialogue was read, which
                // watches it for a while). Readings that were asked for
                // (e.g. after coming back from another space) wait too, but not the first one of a newly
                // chosen window or screen.
                if !waitingForMouse {
                    waitingForMouse = true
                    log("waiting for the mouse\(pendingCue.map { " (\($0) pending)" } ?? "")")
                }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            waitingForMouse = false
            if let cue = pendingCue {
                pendingCue = nil
                await settleAndRecognize(cue: cue)
                continue
            }
            let watchesDialogue = isWatchingDialogue
            let watchesOthers = areas.count > 1 && isWatching
            if !watchesDialogue && !watchesOthers {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let pollUntil = Date().addingTimeInterval(checkSoon ? 0 : number("ocrPollInterval", 500) / 1000)
            checkSoon = false
            while pendingCue == nil, Date() < pollUntil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard pendingCue == nil, isWindowAvailable, websocketConnected || isWatchingDialogue, let (_, frame) = await capture(scale: Self.comparisonScale) else { continue }
            if watchesDialogue, lastRecognizedFrame.map({ differs(frame, $0, only: [0]) }) ?? true {
                log("window changed")
                send(["type": "changing"])
                await settleAndRecognize(cue: nil)
                continue
            }
            guard watchesOthers, let last = lastRecognizedFrame else { continue }
            let changed = otherAreas.filter { differs(frame, last, only: [$0]) }
            if !changed.isEmpty {
                log("areas \(changed) changed")
                await readNow(changed, frame: frame)
            }
        }
    }

    /// The page took a provisional reading (it matched the WebSocket line).
    private var acceptedReading = false

    /// Reads right away and again until the dialogue's text stays the same, instead of first waiting for
    /// the picture to be still (which an animated background can keep it from being). Each reading goes
    /// to the page as provisional, which takes it as soon as it matches the WebSocket line.
    /// - Parameter cue: For a new line, the text only counts as settled once the picture changed, unless
    ///   that doesn't happen within "Wait for a new line to appear" (the line may already be on screen):
    ///   until then it's the previous line's.
    private func settleAndRecognize(cue: Cue?) async {
        log("reading until settled for \(cue.map { "\($0)" } ?? "change")")
        dropCloudRequest()
        if cue == .newLine || cue == .retry {
            send(["type": "changing"])
        }
        let maxWait = number("ocrMaxWait", 8000) / 1000
        // The text has to stay the same for the settle time, as the picture does otherwise: text drawn a
        // character at a time looks the same between characters, and once read too early, the rest of
        // the line may change too little of the picture to be noticed.
        let settleTime = number("ocrSettleTime", 400) / 1000
        var start = Date()
        var sawChange = cue != .newLine
        var previous: (texts: [String], time: Date)?
        // The images read since the text last changed, to learn animated spots from.
        var frames: [Frame] = []
        acceptedReading = false
        // The picture of the latest reading, which the page may take.
        var lastImage: CGImage?
        while !Task.isCancelled {
            guard isWindowAvailable else {
                log("window left while reading")
                if pendingCue == nil { pendingCue = .retry }
                return
            }
            if pendingCue == .newLine {
                // Another line arrived: start over.
                pendingCue = nil
                start = Date()
                sawChange = false
                previous = nil
                acceptedReading = false
                send(["type": "changing"])
            }
            let read = cue == .immediate || otherAreasOutdated || areaLines.count != areas.count ? Array(areas.indices) : [0]
            if acceptedReading {
                log("the page took a reading")
                otherAreasOutdated = false
                finishReading(lastImage, frame: await capture(scale: Self.comparisonScale)?.1, areas: read, started: Date(), extra: ["accepted": true])
                return
            }
            if !sawChange {
                guard let (_, frame) = await capture(scale: Self.comparisonScale) else { return }
                if let last = lastRecognizedFrame, differs(frame, last, only: [0]) {
                    sawChange = true
                    previous = nil
                } else if lastRecognizedFrame == nil || Date().timeIntervalSince(start) > number("ocrNewLineWait", 1500) / 1000 {
                    sawChange = true
                }
            }
            let started = Date()
            guard let image = await captureForReading() else { return }
            // Thumbnails of the image itself rather than another capture (they're only compared with each
            // other, so their scale doesn't matter), made while it's read.
            let thumbnailAreas = thumbnailAreas(in: image)
            let thumbnailing = Task.detached { thumbnailAreas.flatMap { Self.thumbnails(of: image, areas: $0) } }
            guard await readAreas(image, areas: read) else { return }
            lastImage = image
            let texts = (areaLines.first ?? []).map { $0["text"] as? String ?? "" }
            if previous?.texts != texts {
                previous = (texts, started)
                frames = []
            }
            if let (thumbnails, widths) = await thumbnailing.value {
                frames.append(Frame(time: started, thumbnails: thumbnails, widths: widths))
            }
            if sawChange, let previous, started.timeIntervalSince(previous.time) >= settleTime {
                log("settled after \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
                // What changed while the text stayed the same (e.g. a blinking "next" icon) doesn't count as
                // the window changing later.
                learnAnimatedBlocks(from: frames)
                otherAreasOutdated = false
                finishReading(image, frame: await capture(scale: Self.comparisonScale)?.1, areas: read, started: started, extra: ["settled": true])
                return
            }
            if Date().timeIntervalSince(start) > maxWait {
                log("still changing after \(String(format: "%.2f", maxWait))s")
                otherAreasOutdated = false
                finishReading(image, frame: await capture(scale: Self.comparisonScale)?.1, areas: read, started: started)
                return
            }
            sendResult(frame: nil, areas: read, started: started, extra: ["provisional": true])
        }
    }

    /// The cloud engine (Settings → OCR Mode → Cloud recognition (second pass)), if one is chosen.
    private var cloudEngine: CloudOCR? {
        CloudOCR(rawValue: settings["ocrCloudEngine"] as? String ?? "")
    }

    /// The cloud engine's last reading of the dialogue, with the local engine's text it replaced.
    private var cloudReading: (engine: CloudOCR, localTexts: [String], lines: [[String: Any]], removed: [[String: Any]])?
    private var cloudTask: Task<Void, Never>?
    /// Counts the times the dialogue was read until settled: a cloud reading only replaces the one it was asked for.
    private var dialogueReadings = 0

    /// Sends the reading that ends settleAndRecognize: settled, taken by the page (it matched the WebSocket line), or
    /// taken after "Show reading anyway after".
    ///
    /// With a cloud engine, that one reads the dialogue once more first, and its reading is sent instead: a request
    /// often takes a second or more, too long for each reading while the text changes, which the local engine reads.
    /// Nothing of the dialogue is shown meanwhile. The page corrects the cloud reading with the WebSocket line as it
    /// would the local one, so the line's text gets the cloud reading's boxes. Lines the local engine read where the
    /// cloud engine found nothing are kept. The local reading is sent when the cloud engine fails or reads nothing; neither is when the dialogue was read again since. A local reading with the text
    /// of the one the last cloud reading replaced gets that one again right away.
    private func finishReading(_ image: CGImage?, frame: Frame?, areas indices: [Int], started: Date, extra: [String: Any] = [:]) {
        guard let engine = cloudEngine, let image, let frame, let bounds, let local = areaLines.first, !local.isEmpty,
              let crop = image.cropping(to: pixelRect(of: areas[0], in: image)) else {
            sendResult(frame: frame, areas: indices, started: started, extra: extra)
            return
        }
        let localTexts = local.map { $0["text"] as? String ?? "" }
        if let cloudReading, cloudReading.engine == engine, cloudReading.localTexts == localTexts {
            areaLines[0] = cloudReading.lines
            areaRemoved[0] = cloudReading.removed
            sendResult(frame: frame, areas: indices, started: started, extra: extra.merging(["cloud": engine.rawValue]) { $1 })
            return
        }
        let localRemoved = areaRemoved[0]
        // Readings of the other areas meanwhile leave the dialogue out. The window is compared with what was read now
        // (otherwise the text that's being read would count as a change).
        areaLines[0] = []
        areaRemoved[0] = []
        noteReading(frame: frame, areas: indices)
        let reading = dialogueReadings
        let debugReading = debugReadings
        let language = language
        cloudTask?.cancel()
        cloudTask = Task { [weak self] in
            let requested = Date()
            let result: Result<[RecognizedLine], Error>
            do {
                result = .success(try await engine.recognize(crop, language: language))
            } catch {
                result = .failure(error)
            }
            // The dialogue may have changed before that was noticed: a new line's cue waits for the run loop,
            // and a change for its next check.
            let isCurrent = { (self: OCRController) in
                !Task.isCancelled && reading == self.dialogueReadings && self.pendingCue == nil && engine == self.cloudEngine
                    && self.areaLines.count == self.areas.count
            }
            guard let self else { return }
            guard isCurrent(self), let (_, now) = await self.capture(scale: Self.comparisonScale),
                  isCurrent(self), !self.differs(now, frame, only: [0]) else {
                self.log("\(engine.rawValue): dropped, the dialogue may have changed since")
                return
            }
            var (lines, removed, extra) = (local, localRemoved, extra)
            switch result {
            case let .success(items):
                self.log("\(engine.rawValue): \(String(format: "%.2f", Date().timeIntervalSince(requested)))s for \(crop.width)x\(crop.height)")
                if debugReading == self.debugReadings { self.saveForDebugging(items, area: 0, engine: "-\(engine.rawValue)") }
                // Both engines' boxes are where the words are: Google Lens' are the reference the local engines' are
                // measured against, and Bing's are a cloud version of OneOCR's.
                let cloud = self.lines(from: items, in: crop, area: 0, bounds: bounds, ordered: false, exactBoxes: true)
                // It may miss text the local engine read, but not all of it.
                if !cloud.lines.isEmpty {
                    // Marked for the overlay's outlines (with Highlight recognized text boxes on).
                    let cloudLines = cloud.lines.map { line in line.merging(["cloud": true]) { $1 } }
                    (lines, removed) = (Self.adding(local, to: cloudLines), cloud.removed)
                    self.cloudReading = (engine, localTexts, lines, removed)
                    extra["cloud"] = engine.rawValue
                }
            case let .failure(error):
                self.send(["type": "error", "message": error.localizedDescription])
            }
            self.areaLines[0] = lines
            self.areaRemoved[0] = removed
            self.sendResult(frame: nil, areas: indices, started: started, extra: extra)
        }
    }

    /// The cloud engine's lines, with the local engine's lines where it found none, in reading order: it may leave out
    /// some text (Google Lens misses white text with a dark outline on a pale picture, which Bing reads).
    private static func adding(_ local: [[String: Any]], to cloud: [[String: Any]]) -> [[String: Any]] {
        let cloudLines = cloud.map(decode)
        let area = { (box: CGRect) in box.width * box.height }
        let missing = local.filter { line in
            let box = decode(line).box
            return !cloudLines.contains { other in
                let overlap = box.intersection(other.box)
                return !overlap.isNull && area(overlap) >= min(area(box), area(other.box)) / 4
            }
        }
        guard !missing.isEmpty else { return cloud }
        return OCRLayout.inReadingOrder(cloud + missing, line: decode)
    }

    /// A cloud reading on its way is dropped, and the last one isn't reused.
    private func forgetCloudReading() {
        dropCloudRequest()
        cloudReading = nil
    }

    /// The dialogue may change: a cloud reading on its way is dropped.
    private func dropCloudRequest() {
        cloudTask?.cancel()
        cloudTask = nil
        dialogueReadings += 1
    }

    /// Reads areas after the first right away, without waiting for them to be still.
    private func readNow(_ indices: [Int], frame: Frame) async {
        guard let image = await captureForReading() else { return }
        await recognize(image, frame: frame, areas: indices)
    }

    /// Captures the window at the scale it's read at.
    private func captureForReading() async -> CGImage? {
        let scale: CGFloat
        var checkScale = false
        switch settings["ocrResolution"] as? String {
        case "full":
            scale = Self.captureScale
        case "1x":
            scale = 1
        default:
            checkScale = Self.captureScale > 1 && (readingScale == nil || Date().timeIntervalSince(readingScaleCheckedAt) > 120)
            scale = checkScale ? Self.captureScale : readingScale ?? Self.captureScale
        }
        guard let (image, _) = await capture(scale: scale) else { return nil }
        if checkScale, let detail = GrayImage(image)?.hasFineDetail {
            readingScale = detail ? Self.captureScale : 1
            readingScaleCheckedAt = Date()
            log("drawn at \(detail ? "full" : "1x") resolution: reading at \(readingScale!)x")
        }
        return image
    }

    /// Frames are compared at a low resolution, always the same one (scaling changes edges).
    private static let comparisonScale: CGFloat = 0.5

    private static var captureScale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    /// The watched areas, as fractions of the window. The first is the dialogue.
    private var areas: [CGRect] {
        regions.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : regions
    }

    /// The indexes of the areas after the first.
    private var otherAreas: [Int] {
        Array(areas.indices.dropFirst())
    }

    /// The part of the window that's captured: just what covers the areas.
    private var capturedPart: CGRect {
        areas.reduce(CGRect.null) { $0.union($1) }.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Where an area is in a captured image (of `capturedPart`), in pixels.
    private func pixelRect(of area: CGRect, in image: CGImage) -> CGRect {
        let part = capturedPart
        let scaleX = CGFloat(image.width) / part.width, scaleY = CGFloat(image.height) / part.height
        return CGRect(
            x: (area.minX - part.minX) * scaleX, y: (area.minY - part.minY) * scaleY,
            width: area.width * scaleX, height: area.height * scaleY
        ).integral
    }

    /// - Parameters:
    ///   - frame: The low resolution frame `image` was taken after, the reference for changes in `areas`.
    ///   - areas: The indexes of the areas to read; the others keep their last lines.
    private func recognize(_ image: CGImage, frame: Frame?, areas indices: [Int]) async {
        let started = Date()
        guard await readAreas(image, areas: indices) else { return }
        sendResult(frame: frame, areas: indices, started: started)
    }

    /// Reads the areas into `areaLines`. False if it failed (the page was told), or if the window is to be read again
    /// (see readAgain) since.
    private func readAreas(_ image: CGImage, areas indices: [Int]) async -> Bool {
        guard let bounds, indices.allSatisfy(areas.indices.contains) else { return false }
        if areaLines.count != areas.count { areaLines = areas.map { _ in [] } }
        if areaRemoved.count != areas.count { areaRemoved = areas.map { _ in [] } }
        debugReadings += 1
        for index in indices {
            let area = areas[index]
            guard let crop = image.cropping(to: pixelRect(of: area, in: image)) else { continue }
            if let debugDirectory {
                let url = URL(fileURLWithPath: debugDirectory).appendingPathComponent("read-\(debugReadings)-area\(index).png")
                if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, crop, nil)
                    CGImageDestinationFinalize(destination)
                }
                log("saved \(url.lastPathComponent)")
            }
            let items: [RecognizedLine]
            let recognizeStarted = Date()
            do {
                items = try await recognizeText(crop)
                log("\(engine.rawValue): \(String(format: "%.2f", Date().timeIntervalSince(recognizeStarted)))s for \(crop.width)x\(crop.height)")
            } catch {
                send(["type": "error", "message": error.localizedDescription])
                return false
            }
            // Read again meanwhile (e.g. the engine or the cloud engine was changed): this reading is outdated, and
            // the lines were cleared.
            guard areaLines.count == areas.count, areaRemoved.count == areas.count, areas.indices.contains(index) else {
                log("reading dropped: the window is read again")
                return false
            }
            saveForDebugging(items, area: index)
            let layoutStarted = Date()
            // Screen AI's lines come in its own layout analysis' reading order (paragraphs and columns included).
            (areaLines[index], areaRemoved[index]) = lines(
                from: items, in: crop, area: index, bounds: bounds, ordered: engine == .screenAI, exactBoxes: engine.hasExactBoxes
            )
            log("layout: \(String(format: "%.2f", Date().timeIntervalSince(layoutStarted)))s")
        }
        return true
    }

    /// With MACPOPUP_DEBUG_OCR_DIR, what an engine read in an area, before the layout (boxes normalized to the crop).
    private func saveForDebugging(_ items: [RecognizedLine], area index: Int, engine suffix: String = "") {
        guard let debugDirectory else { return }
        let rect = { (box: CGRect) in [box.minX, box.minY, box.width, box.height] }
        let raw = items.map { ["text": $0.text, "box": rect($0.box), "words": $0.words.map { [$0.text] + rect($0.box).map { $0 as Any } }] as [String: Any] }
        let url = URL(fileURLWithPath: debugDirectory).appendingPathComponent("read-\(debugReadings)-area\(index)\(suffix).json")
        try? JSONSerialization.data(withJSONObject: raw).write(to: url)
    }

    /// The lines an engine read in an area's picture (`crop`), as the page gets them, and the lines left out (by the
    /// language or as furigana) for its debug log.
    /// - Parameters:
    ///   - ordered: The engine gives the lines in reading order; otherwise they're put in it.
    ///   - exactBoxes: The engine's boxes for words are where they are (see OCRLayout.layOut).
    private func lines(
        from items: [RecognizedLine], in crop: CGImage, area index: Int, bounds: CGRect, ordered: Bool, exactBoxes: Bool = false
    ) -> (lines: [[String: Any]], removed: [[String: Any]]) {
        let area = areas[index]
        // The boxes are normalized to the crop; convert them to window points.
        let toWindow = { (box: CGRect) -> CGRect in
            CGRect(
                x: (area.minX + box.minX * area.width) * bounds.width,
                y: (area.minY + box.minY * area.height) * bounds.height,
                width: box.width * area.width * bounds.width,
                height: box.height * area.height * bounds.height
            )
        }
        let gray = GrayImage(crop)
        let size = CGSize(width: crop.width, height: crop.height)
        // The lines left out, for the page's debug log (with Highlight recognized text boxes on).
        let recordsRemoved = settings["ocrShowBoxes"] as? Bool ?? false
        var removed: [[String: Any]] = []
        let box = { (box: CGRect) in [box.minX, box.minY, box.width, box.height] }
        var kept: [RecognizedLine] = []
        for item in items {
            if OCRLanguage.contains(item.text, language: language) {
                kept.append(item)
            } else if recordsRemoved {
                removed.append(["text": item.text, "box": box(toWindow(item.box)), "reason": "language", "area": index])
            }
        }
        var lines = kept.map { OCRLayout.layOut($0, image: gray, size: size, exactBoxes: exactBoxes, toWindow: toWindow) }
        if stripsFurigana {
            let bases = OCRLayout.furigana(in: lines)
            if recordsRemoved {
                removed += bases.sorted { $0.key < $1.key }.map { ruby, base in
                    ["text": lines[ruby].text, "box": box(lines[ruby].box), "reason": "furigana", "base": lines[base].text, "area": index]
                }
            }
            lines = lines.indices.filter { bases[$0] == nil }.map { lines[$0] }
        }
        let encoded = (ordered ? OCRLayout.keepingRowsTogether(lines) : OCRLayout.inReadingOrder(lines)).map {
            var line = Self.encode($0)
            line["area"] = index
            return line
        }
        return (encoded, removed)
    }

    /// Sends what `readAreas` read to the page.
    /// - Parameters:
    ///   - frame: The low resolution frame the reading was taken after, the reference for changes.
    ///   - extra: More for the page: "provisional" for a reading while the text may still change (only
    ///     shown if it matches the WebSocket line, see settleAndRecognize), "settled" for one of text that
    ///     stopped changing.
    private func sendResult(frame: Frame?, areas indices: [Int], started: Date, extra: [String: Any] = [:]) {
        guard let bounds else { return }
        let lines = areaLines.flatMap { $0 }
        var result: [String: Any] = [
            "type": "result",
            "lines": lines,
            "removed": areaRemoved.flatMap { $0 },
            // Whether the dialogue was read (the page checks it against the WebSocket line), or only others.
            "dialogue": indices.contains(0),
            "elapsed": Date().timeIntervalSince(started),
            "width": bounds.width,
            "height": bounds.height,
        ]
        result.merge(extra) { $1 }
        log("read \(lines.count) lines in \(String(format: "%.2f", Date().timeIntervalSince(started)))s\(extra.isEmpty ? "" : " \(extra.keys.sorted())")")
        send(result)
        if extra["provisional"] as? Bool == true { return }
        lastResult = result
        noteReading(frame: frame, areas: indices)
    }

    /// The window is compared with `frame` for changes from now on, and the dialogue watched for a while if it was read.
    private func noteReading(frame: Frame?, areas indices: [Int]) {
        updateReference(frame, areas: indices)
        if indices.contains(0) { watchUntil = Date().addingTimeInterval(number("ocrMouseWatchTime", 2000) / 1000) }
    }

    /// What reads the text (Settings → OCR Mode → Text recognition engine).
    enum Engine: String {
        case liveText
        case meikiocr
        case screenAI = "screenai"
        case oneOCR = "oneocr"
        case ppocrManga = "ppocrmanga"

        /// Whether its boxes for words are where they are: Live Text's are often a cell off, so its lines are snapped to
        /// their cells (see OCRLayout.layOut).
        var hasExactBoxes: Bool { self != .liveText }
    }

    /// The engine when OCR mode started or it last changed.
    private var startedEngine: Engine?

    private var engine: Engine {
        Engine(rawValue: settings["ocrEngine"] as? String ?? "") ?? .liveText
    }

    /// The language (Settings → General): lines in other languages are left out of readings (see OCRLanguage.contains).
    private var language: String {
        settings["language"] as? String ?? "ja"
    }

    /// Whether furigana are left out of readings (see OCRLayout.removingFurigana); only in Japanese.
    private var stripsFurigana: Bool {
        language == "ja" && settings["ocrStripFurigana"] as? Bool ?? true
    }

    /// The language, stripsFurigana and cloud engine when OCR mode started or they last changed.
    private var startedLanguage: String?
    private var startedStripsFurigana: Bool?
    private var startedCloudEngine: CloudOCR??

    private func recognizeText(_ image: CGImage) async throws -> [RecognizedLine] {
        switch engine {
        case .liveText:
            try await Self.recognizeText(image, locales: languages).map { line in
                RecognizedLine(text: line.text, box: line.box, words: line.words.map { ($0.text, $0.box) })
            }
        case .meikiocr:
            try await MeikiOCR.shared.recognize(image)
        case .screenAI:
            try await ScreenAIOCR.shared.recognize(image)
        case .oneOCR:
            try await OneOCROCR.shared.recognize(image)
        case .ppocrManga:
            try await PPOCRManga.shared.recognize(image)
        }
    }

    /// The first reading takes longer (Live Text's by about a second, the others load their models), so the engine is
    /// prepared before the window needs reading.
    private func warmUp() async {
        let started = Date()
        func prepare(_ body: () async throws -> Void) async {
            do {
                try await body()
            } catch {
                send(["type": "error", "message": error.localizedDescription])
            }
        }
        switch engine {
        case .liveText:
            await warmUpLiveText()
        case .meikiocr:
            await prepare(MeikiOCR.shared.prepare)
        case .screenAI:
            await prepare(ScreenAIOCR.shared.prepare)
        case .oneOCR:
            await prepare(OneOCROCR.shared.prepare)
        case .ppocrManga:
            await prepare(PPOCRManga.shared.prepare)
        }
        log("\(engine.rawValue) ready in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }

    /// Live Text reads a small blank picture.
    private func warmUpLiveText() async {
        guard let context = CGContext(
            data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = context.makeImage() else { return }
        _ = try? await Self.recognizeText(image, locales: languages)
    }

    /// Live Text's languages: the language's (Settings → General), or only English when it doesn't read it. English
    /// is always read too.
    private var languages: [String] {
        let locales = OCRLanguage.liveTextLocales(for: language)
        return locales.contains { $0.hasPrefix("en") } ? locales : locales + ["en"]
    }

    private static func recognizeText(_ image: CGImage, locales: [String]) async throws -> [MPLiveTextItem] {
        try await withCheckedThrowingContinuation { continuation in
            MPLiveText.recognizeImage(image, locales: locales) { lines, error in
                if let lines {
                    continuation.resume(returning: lines)
                } else {
                    continuation.resume(throwing: error ?? BridgeError("Live Text failed"))
                }
            }
        }
    }

    /// A line as the page gets it.
    private static func decode(_ line: [String: Any]) -> OCRLayout.Line {
        let rect = { (values: [Any]) in
            let numbers = values.map { $0 as? CGFloat ?? 0 }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        return OCRLayout.Line(
            text: line["text"] as? String ?? "",
            box: rect([line["x"] as Any, line["y"] as Any, line["width"] as Any, line["height"] as Any]),
            vertical: line["vertical"] as? Bool ?? false,
            chars: (line["chars"] as? [[Any]] ?? []).filter { $0.count == 5 }.map {
                OCRLayout.Char(text: $0[0] as? String ?? "", box: rect(Array($0[1...])))
            }
        )
    }

    private static func encode(_ line: OCRLayout.Line) -> [String: Any] {
        [
            "text": line.text,
            "x": line.box.minX, "y": line.box.minY, "width": line.box.width, "height": line.box.height,
            "vertical": line.vertical,
            "chars": line.chars.map { [$0.text, $0.box.minX, $0.box.minY, $0.box.width, $0.box.height] as [Any] },
        ]
    }

    // MARK: Capture and change detection

    /// Captures the window as it appears on screen, without other windows in front of it, over its
    /// reported bounds. `scale` is pixels per point (lower for change detection).
    ///
    /// The display is captured with only this window in it, rather than the window by itself: some
    /// windows draw more than their reported frame (Parallels' full screen window reaches under the
    /// menu bar), and a capture of the window alone squeezes all of it into the frame's size, so
    /// positions in the image wouldn't match the screen. A window that isn't entirely within a display
    /// (moved partly off screen) is captured by itself, since there's no part of a display to capture.
    private func capture(scale: CGFloat) async -> (CGImage, Frame)? {
        do {
            guard let image = try await captureImage(part: capturedPart, scale: scale),
                  let (thumbnails, widths) = thumbnails(of: image) else { return nil }
            captureFailures = 0
            return (image, Frame(time: Date(), thumbnails: thumbnails, widths: widths))
        } catch {
            log("capture failed: \(error)")
            // A single failure can happen while windows change (e.g. switching spaces); report it
            // only if it keeps failing.
            captureFailures += 1
            if captureFailures == 3 {
                send(["type": "error", "message": "Screen capture failed: \(error.localizedDescription)"])
            }
            scWindow = nil
            try? await Task.sleep(for: .seconds(1))
            return nil
        }
    }

    /// Captures `part` of the window (normalized to its bounds) at `scale` pixels per point, as described
    /// for `capture(scale:)`. Nil when the window isn't known.
    private func captureImage(part: CGRect, scale: CGFloat) async throws -> CGImage? {
        guard let bounds else { return nil }
        if readsScreen {
            if scDisplay == nil || scBounds != bounds {
                if scBounds != bounds { readingScale = nil }
                let content = try await ScreenCapture.shareableContent(onScreenWindowsOnly: true)
                let displayID = (overlay.panel.screen ?? NSScreen.main)?.displayID
                scDisplay = content.displays.first { $0.displayID == displayID }
                scOwnApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                scBounds = bounds
            }
            guard let scDisplay else { return nil }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: scOwnApps, exceptingWindows: [])
            let partRect = Self.partRect(part, of: bounds)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = partRect
            configuration.width = max(1, Int(partRect.width * scale))
            configuration.height = max(1, Int(partRect.height * scale))
            configuration.showsCursor = false
            return try await ScreenCapture.image(filter: filter, configuration: configuration)
        }
        guard let target else { return nil }
        if scWindow == nil || scBounds != bounds {
            if scBounds != bounds { readingScale = nil }
            let content = try await ScreenCapture.shareableContent(onScreenWindowsOnly: false)
            scWindow = content.windows.first { $0.windowID == target.windowID }
            scDisplay = content.displays.first { $0.frame.contains(bounds) }
            scBounds = bounds
        }
        guard let scWindow else { return nil }
        return try await Self.captureWindow(scWindow, display: scDisplay, bounds: bounds, part: part, scale: scale)
    }

    /// `part` (normalized) of a rectangle, relative to it.
    private static func partRect(_ part: CGRect, of bounds: CGRect) -> CGRect {
        CGRect(
            x: part.minX * bounds.width, y: part.minY * bounds.height,
            width: part.width * bounds.width, height: part.height * bounds.height
        )
    }

    /// Captures `part` of a window as described for `capture(scale:)`; `display` is the one it lies within, if any.
    private static func captureWindow(
        _ scWindow: SCWindow, display scDisplay: SCDisplay?, bounds: CGRect, part: CGRect, scale: CGFloat
    ) async throws -> CGImage {
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        // In window points.
        let partRect = Self.partRect(part, of: bounds)
        if let scDisplay {
            filter = SCContentFilter(display: scDisplay, including: [scWindow])
            configuration.sourceRect = partRect.offsetBy(dx: bounds.minX - scDisplay.frame.minX, dy: bounds.minY - scDisplay.frame.minY)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.sourceRect = partRect
        }
        configuration.width = max(1, Int(partRect.width * scale))
        configuration.height = max(1, Int(partRect.height * scale))
        configuration.showsCursor = false
        return try await ScreenCapture.image(filter: filter, configuration: configuration)
    }

    /// The captured window (Settings → General), whole, at its display's resolution or at 1x, for the
    /// `{screenshot}` Anki marker: only that window, without other windows in front of it or the overlay.
    /// Also when screen OCR mode is off. Nil when no window is set or it isn't on screen.
    func windowScreenshot(fullResolution: Bool) async throws -> CGImage? {
        guard let saved = settings["ocrWindow"] as? [String: Any], let ownerName = saved["ownerName"] as? String else { return nil }
        let title = saved["title"] as? String ?? ""
        let windows = Self.windows(onScreenOnly: true).filter { $0.ownerName == ownerName }
        let match = windows.first { $0.id == target?.windowID } ?? windows.first { $0.title == title } ?? windows.first
        guard let match else { return nil }
        let content = try await ScreenCapture.shareableContent(onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == match.id }) else { return nil }
        let display = content.displays.first { $0.frame.contains(match.bounds) }
        let displayScale = NSScreen.screens.first { $0.displayID == (display?.displayID ?? overlay.displayID) }?.backingScaleFactor ?? 2
        let scale = fullResolution ? displayScale : 1
        return try await Self.captureWindow(window, display: display, bounds: match.bounds, part: CGRect(x: 0, y: 0, width: 1, height: 1), scale: scale)
    }

    /// Small grayscale copies of the watched areas, the same size whatever the capture scale.
    private func thumbnails(of image: CGImage) -> ([[UInt8]], [Int])? {
        thumbnailAreas(in: image).flatMap { Self.thumbnails(of: image, areas: $0) }
    }

    /// Each area's rectangle in `image`, in pixels, and its size in points.
    private func thumbnailAreas(in image: CGImage) -> [(rect: CGRect, pointSize: CGSize)]? {
        guard let bounds else { return nil }
        return areas.map {
            (pixelRect(of: $0, in: image), CGSize(width: $0.width * bounds.width, height: $0.height * bounds.height))
        }
    }

    /// - Parameter areas: As given by `thumbnailAreas(in:)`.
    nonisolated private static func thumbnails(of image: CGImage, areas: [(rect: CGRect, pointSize: CGSize)]) -> ([[UInt8]], [Int])? {
        var result: [[UInt8]] = []
        var widths: [Int] = []
        for (rect, pointSize) in areas {
            guard let crop = image.cropping(to: rect) else { return nil }
            let longSide: CGFloat = 320
            let factor = longSide / max(pointSize.width, pointSize.height, 1)
            let width = max(1, Int(pointSize.width * factor)), height = max(1, Int(pointSize.height * factor))
            var pixels = [UInt8](repeating: 0, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .low
                context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            result.append(pixels)
            widths.append(width)
        }
        return (result, widths)
    }

    /// Makes `frame` the reference for changes in the areas that were read from it.
    private func updateReference(_ frame: Frame?, areas indices: [Int]) {
        guard let frame else { return }
        guard var reference = lastRecognizedFrame, reference.widths.count == frame.widths.count else {
            lastRecognizedFrame = frame
            return
        }
        for index in indices {
            reference.thumbnails[index] = frame.thumbnails[index]
            reference.widths[index] = frame.widths[index]
        }
        reference.time = frame.time
        lastRecognizedFrame = reference
    }

    private static let block = 8

    /// The blocks of each thumbnail (`block` pixels square) in which `a` and `b` differ in detail (one
    /// character of text drawn changes a few dense blocks). Noise spread thinly is ignored, and so are
    /// faint changes, like the end of a character's fade-in (a game's text can take half a second to
    /// reach full brightness).
    /// - Parameter only: The areas to compare (the others count as unchanged), or all.
    private func changedBlocks(_ a: Frame, _ b: Frame, only: [Int]? = nil) -> [Set<Int>]? {
        guard a.thumbnails.count == b.thumbnails.count, a.widths == b.widths else { return nil }
        let block = Self.block
        var result: [Set<Int>] = []
        for (area, ((x, y), width)) in zip(zip(a.thumbnails, b.thumbnails), a.widths).enumerated() {
            guard x.count == y.count, width > 0 else { return nil }
            if let only, !only.contains(area) {
                result.append([])
                continue
            }
            let height = x.count / width
            let columns = (width + block - 1) / block
            var counts = [Int](repeating: 0, count: columns * ((height + block - 1) / block))
            var changed: Set<Int> = []
            for row in 0..<height {
                for column in 0..<width {
                    let index = row * width + column
                    guard abs(Int(x[index]) - Int(y[index])) > 40 else { continue }
                    let cell = (row / block) * columns + column / block
                    counts[cell] += 1
                    if counts[cell] == 5 { changed.insert(cell) }
                }
            }
            result.append(changed)
        }
        return result
    }

    /// Learns the spots that changed while the text stayed the same (e.g. a blinking "next" icon), so that
    /// later they don't count as the window changing. Not when there are many (that's an animated
    /// background, not an icon).
    private func learnAnimatedBlocks(from frames: [Frame]) {
        guard frames.count > 1, let first = frames.first else { return }
        var found = first.thumbnails.map { _ in Set<Int>() }
        for (a, b) in zip(frames, frames.dropFirst()) {
            // Only the dialogue is read until settled; the other areas are read whenever they change.
            guard let changed = changedBlocks(a, b, only: [0]) else { return }
            for (area, blocks) in changed.enumerated() { found[area].formUnion(blocks) }
        }
        if animatedBlocks.count != found.count { animatedBlocks = found.map { _ in [] } }
        for (area, blocks) in found.enumerated() where !blocks.isSubset(of: animatedBlocks[area]) {
            let width = first.widths[area], height = first.thumbnails[area].count / max(width, 1)
            let total = ((width + Self.block - 1) / Self.block) * ((height + Self.block - 1) / Self.block)
            let learned = animatedBlocks[area].union(blocks)
            guard Double(learned.count) <= Double(total) * 0.1 else { continue }
            log("learned \(learned.count) animated blocks")
            animatedBlocks[area] = learned
        }
    }

    /// Whether two frames differ by more than the threshold: the share of pixels that changed clearly,
    /// in any watched area. Small changes (a blinking cursor, slight animation) stay under it, and
    /// spots known to be animated are left out.
    /// - Parameter only: The areas to compare, or all.
    private func differs(_ a: Frame, _ b: Frame, only: [Int]? = nil) -> Bool {
        guard a.thumbnails.count == b.thumbnails.count, a.widths == b.widths else { return true }
        let threshold = number("ocrChangeThreshold", 0.3) / 100
        let block = Self.block
        for (area, ((x, y), width)) in zip(zip(a.thumbnails, b.thumbnails), a.widths).enumerated() {
            if let only, !only.contains(area) { continue }
            guard x.count == y.count, !x.isEmpty, width > 0 else { return true }
            let animated = area < animatedBlocks.count ? animatedBlocks[area] : []
            let columns = (width + block - 1) / block
            var changed = 0
            for index in x.indices where abs(Int(x[index]) - Int(y[index])) > 40 {
                if !animated.isEmpty, animated.contains((index / width / block) * columns + (index % width) / block) { continue }
                changed += 1
            }
            if Double(changed) / Double(x.count) > threshold {
                return true
            }
        }
        return false
    }
}
