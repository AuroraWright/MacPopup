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
/// The window is captured with ScreenCaptureKit. With a WebSocket connected, each new line is the cue
/// to read the window again; otherwise the window (or the chosen regions) is watched for changes. In
/// both cases recognition waits until the picture has stopped changing, since games often draw text
/// gradually after the hooked line arrives.
///
/// With several regions, only the first is the dialogue that works that way. The others (e.g. menus or
/// names) are assumed to appear at once: they're read as soon as they change, which is checked while
/// the mouse is used (or all the time, without "Watch after mouse use"), WebSocket or not.
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
    /// A WebSocket is connected and its lines are used: they're the cue to read the window, so it's
    /// only watched for changes briefly after each reading.
    private var websocketConnected = false
    /// While a WebSocket is connected, the window is watched until then (a line read as soon as it's
    /// still may not have been finished being drawn).
    private var watchUntil = Date.distantPast
    private var lastCursorPoint: CGPoint?
    /// Without WebSocket lines, the window is only read until a while after the mouse was last used
    /// (moved or clicked), not while it rests.
    private var mouseActiveUntil = Date.distantPast
    /// The mouse started being used: check for changes right away.
    private var checkSoon = false
    private var waitingForMouse = false
    /// When the page asked for the window to be read again (the text didn't match its line yet), and
    /// when a reading of a still picture was last taken: one taken since makes the request moot.
    private var pageRetryAt: Date?
    private var lastStillReadingAt = Date.distantPast
    /// Per area, thumbnail blocks that were seen animating while the rest was still.
    private var animatedBlocks: [Set<Int>] = []
    /// Per area, the lines last read there: an area is read on its own, and sent with the others.
    private var areaLines: [[[String: Any]]] = []
    /// The areas after the first may have changed unseen (e.g. while the window was away): read them
    /// with the next reading.
    private var otherAreasOutdated = false

    private var isCursorActive: Bool {
        Date() < mouseActiveUntil
    }

    /// Without WebSocket lines, whether the window is watched for changes now: all the time, or (with
    /// "Watch after mouse use") only for a while after the mouse was used.
    private var isWatching: Bool {
        !(settings["ocrMouseWatch"] as? Bool ?? true) || isCursorActive
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
        /// The page wants another reading, e.g. because the text was still being drawn.
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
        scWindow = nil
        scDisplay = nil
        readingScale = nil
        animatedBlocks = []
        areaLines = []
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
        loopTask = Task { [weak self] in
            await self?.warmUpLiveText()
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
        overlay.preferredScreen = nil
        lastRecognizedFrame = nil
        lastResult = nil
        areaLines = []
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
        // Start from the window being read, when it's on screen.
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
        case "retry":
            if pendingCue == nil {
                pendingCue = .retry
                pageRetryAt = Date()
            }
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
            // The page checks the next reading against the last WebSocket line again.
            send(["type": "returned"])
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
            if !websocketConnected, !isWatching, pendingCue != .immediate {
                // Without WebSocket lines, wait until the mouse is used. Readings that were asked for
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
                let retryAt = pageRetryAt
                pageRetryAt = nil
                if cue == .retry, let retryAt, lastStillReadingAt > retryAt {
                    log("already read again since the page asked")
                    continue
                }
                await settleAndRecognize(cue: cue)
                continue
            }
            // With WebSocket lines, they're the cue for the dialogue, which is only watched briefly after
            // each reading; the other areas are watched as without them.
            let watchesDialogue = websocketConnected ? Date() < watchUntil : isWatching
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
            guard pendingCue == nil, isWindowAvailable, websocketConnected || isWatching, let (_, frame) = await capture(scale: Self.comparisonScale) else { continue }
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

    /// Captures until the picture has been still for the settle time, then reads it.
    /// - Parameter cue: For a new line, the picture has to change first, unless that doesn't happen
    ///   within a moment (the line may already be on screen).
    private func settleAndRecognize(cue: Cue?) async {
        log("settling for \(cue.map { "\($0)" } ?? "change")")
        if cue == .newLine || cue == .retry {
            send(["type": "changing"])
        }
        // A new line's reading is checked against the line on the page, which asks for another reading
        // (with the full settle time) if the text was still being drawn, so it's read sooner.
        var settleTime = cue == .newLine ? min(number("ocrSettleTime", 400) / 1000, 0.15) : number("ocrSettleTime", 400) / 1000
        var interval = cue == .newLine ? 50 : 100
        let maxWait = number("ocrMaxWait", 4000) / 1000
        var start = Date()
        var history: [Frame] = []
        var sawChange = cue != .newLine

        // A reading forced by the maximum wait may be of text that's still being drawn (e.g. slowly,
        // over several lines), so the picture is watched on and read again once it settles.
        for round in 0...3 {
            var stableFrame: Frame?
            var isStill = false
            while !Task.isCancelled {
                guard isWindowAvailable else {
                    // Left (e.g. to another space): read it once it's back.
                    log("window left while settling")
                    if pendingCue == nil { pendingCue = .retry }
                    return
                }
                guard let (_, frame) = await capture(scale: Self.comparisonScale) else { return }
                stableFrame = frame
                if let last = lastRecognizedFrame, differs(frame, last, only: [0]) {
                    sawChange = true
                }
                if !sawChange && Date().timeIntervalSince(start) > 1.5 {
                    sawChange = true
                }
                history.append(frame)
                history.removeAll { frame.time.timeIntervalSince($0.time) > settleTime + 1 }
                // Still: the picture is the same as at least the settle time ago, even in details like a
                // single character being drawn. Any earlier frame counts, so an animation that keeps
                // repeating (e.g. a blinking "next" icon) doesn't keep the window from being still.
                let references = history.filter { frame.time.timeIntervalSince($0.time) >= settleTime }
                if references.isEmpty {
                    isStill = cue == .immediate && round == 0
                } else if let same = references.first(where: { isSame(frame, $0, only: [0]) }) {
                    isStill = true
                    learnAnimatedBlocks(from: history.filter { $0.time >= same.time })
                } else {
                    isStill = false
                }
                if (sawChange && isStill) || Date().timeIntervalSince(start) > maxWait {
                    break
                }
                if pendingCue == .newLine {
                    // Another line arrived: start over.
                    pendingCue = nil
                    start = Date()
                    history = []
                    sawChange = false
                }
                try? await Task.sleep(for: .milliseconds(interval))
            }
            log("settled after \(String(format: "%.2f", Date().timeIntervalSince(start)))s, \(history.count) frames, sawChange \(sawChange), still \(isStill)")
            guard !Task.isCancelled, isWindowAvailable else {
                if pendingCue == nil { pendingCue = .retry }
                return
            }
            if isStill { lastStillReadingAt = Date() }
            // The other areas too when they haven't been read yet, or may have changed unseen.
            let read = cue == .immediate || otherAreasOutdated || areaLines.count != areas.count ? Array(areas.indices) : [0]
            otherAreasOutdated = false
            guard let image = await captureForReading() else { return }
            await recognize(image, frame: stableFrame, areas: read)
            guard !isStill, round < 3 else { return }
            log("still changing: reading again once it settles")
            settleTime = number("ocrSettleTime", 400) / 1000
            interval = 100
            start = Date()
            sawChange = true
        }
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
        guard let bounds else { return }
        let started = Date()
        if areaLines.count != areas.count { areaLines = areas.map { _ in [] } }
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
            let items: [MPLiveTextItem]
            let recognizeStarted = Date()
            do {
                items = try await Self.recognizeText(crop, locales: languages)
                log("Live Text: \(String(format: "%.2f", Date().timeIntervalSince(recognizeStarted)))s for \(crop.width)x\(crop.height)")
            } catch {
                send(["type": "error", "message": error.localizedDescription])
                return
            }
            // Live Text boxes are normalized to the crop; convert them to window points.
            let toWindow = { (box: CGRect) -> CGRect in
                CGRect(
                    x: (area.minX + box.minX * area.width) * bounds.width,
                    y: (area.minY + box.minY * area.height) * bounds.height,
                    width: box.width * area.width * bounds.width,
                    height: box.height * area.height * bounds.height
                )
            }
            let layoutStarted = Date()
            let gray = GrayImage(crop)
            let size = CGSize(width: crop.width, height: crop.height)
            areaLines[index] = items.map {
                var line = Self.encodeLine($0, image: gray, size: size, toWindow: toWindow)
                line["area"] = index
                return line
            }
            log("layout: \(String(format: "%.2f", Date().timeIntervalSince(layoutStarted)))s")
        }
        updateReference(frame, areas: indices)
        let lines = areaLines.flatMap { $0 }
        let result: [String: Any] = [
            "type": "result",
            "lines": lines,
            // Whether the dialogue was read (the page checks it against the WebSocket line), or only others.
            "dialogue": indices.contains(0),
            "elapsed": Date().timeIntervalSince(started),
            "width": bounds.width,
            "height": bounds.height,
        ]
        lastResult = result
        if indices.contains(0) { watchUntil = Date().addingTimeInterval(1.5) }
        log("read \(lines.count) lines in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        send(result)
    }

    /// Live Text takes about a second longer for its first reading, so it reads a small blank picture
    /// first, before the window needs reading.
    private func warmUpLiveText() async {
        guard let context = CGContext(
            data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = context.makeImage() else { return }
        let started = Date()
        _ = try? await Self.recognizeText(image, locales: languages)
        log("Live Text ready in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }

    private var languages: [String] {
        (settings["ocrLanguage"] as? String).map { [$0, "en"] } ?? ["ja", "en"]
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

    /// A line with one box per character. Live Text gives boxes per word (single characters for
    /// Japanese); longer words are divided evenly, and the spaces between words fill the gaps. Lines of
    /// evenly spaced full-width text are then snapped to their cells (see OCRLayout).
    /// - Parameters:
    ///   - image: The image Live Text read, whose pixels Live Text's normalized boxes refer to.
    ///   - toWindow: Converts a box normalized to `image` to window points.
    private static func encodeLine(_ line: MPLiveTextItem, image: GrayImage?, size: CGSize, toWindow: (CGRect) -> CGRect) -> [String: Any] {
        // Work in image pixels, which keep the aspect ratio.
        let toPixels = { (box: CGRect) in
            CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        let lineBox = toPixels(line.box)
        let wordBoxes = line.words.map { toPixels($0.box) }
        let isVertical: Bool = {
            if let first = wordBoxes.first, let last = wordBoxes.last, wordBoxes.count > 1 {
                return abs(last.midY - first.midY) > abs(last.midX - first.midX)
            }
            return lineBox.height > lineBox.width * 1.5
        }()
        var chars: [OCRLayout.Char] = []
        func add(_ text: String, in box: CGRect) {
            let characters = text.map(String.init)
            guard !characters.isEmpty else { return }
            let count = CGFloat(characters.count)
            for (index, character) in characters.enumerated() {
                let i = CGFloat(index)
                let rect = isVertical
                    ? CGRect(x: box.minX, y: box.minY + box.height * i / count, width: box.width, height: box.height / count)
                    : CGRect(x: box.minX + box.width * i / count, y: box.minY, width: box.width / count, height: box.height)
                chars.append(OCRLayout.Char(text: character, box: rect))
            }
        }
        if line.words.isEmpty {
            add(line.text, in: lineBox)
        } else {
            var remaining = Substring(line.text)
            var previous: CGRect?
            for (word, box) in zip(line.words, wordBoxes) {
                if let range = remaining.range(of: word.text) {
                    // Text between words (spaces) goes in the gap between their boxes.
                    let between = String(remaining[remaining.startIndex..<range.lowerBound])
                    if !between.isEmpty, let previous {
                        let gap = isVertical
                            ? CGRect(x: box.minX, y: previous.maxY, width: box.width, height: max(1, box.minY - previous.maxY))
                            : CGRect(x: previous.maxX, y: box.minY, width: max(1, box.minX - previous.maxX), height: box.height)
                        add(between, in: gap)
                    }
                    remaining = remaining[range.upperBound...]
                }
                add(word.text, in: box)
                previous = box
            }
        }
        if let image, let snapped = OCRLayout.snapToGrid(chars, line: lineBox, vertical: isVertical, image: image) {
            chars = snapped
        }
        func toWindowFromPixels(_ box: CGRect) -> CGRect {
            toWindow(CGRect(x: box.minX / size.width, y: box.minY / size.height, width: box.width / size.width, height: box.height / size.height))
        }
        let windowLine = toWindow(line.box)
        return [
            "text": chars.map(\.text).joined(),
            "x": windowLine.minX, "y": windowLine.minY, "width": windowLine.width, "height": windowLine.height,
            "vertical": isVertical,
            "chars": chars.map { char -> [Any] in
                let box = toWindowFromPixels(char.box)
                return [char.text, box.minX, box.minY, box.width, box.height]
            },
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
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        guard let target else { return nil }
        if scWindow == nil || scBounds != bounds {
            if scBounds != bounds { readingScale = nil }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The captured window (Settings → General), whole and at its display's resolution, for the
    /// `{screenshot}` Anki marker: only that window, without other windows in front of it or the overlay.
    /// Also when screen OCR mode is off. Nil when no window is set or it isn't on screen.
    func windowScreenshot() async throws -> CGImage? {
        guard let saved = settings["ocrWindow"] as? [String: Any], let ownerName = saved["ownerName"] as? String else { return nil }
        let title = saved["title"] as? String ?? ""
        let windows = Self.windows(onScreenOnly: true).filter { $0.ownerName == ownerName }
        let match = windows.first { $0.id == target?.windowID } ?? windows.first { $0.title == title } ?? windows.first
        guard let match else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == match.id }) else { return nil }
        let display = content.displays.first { $0.frame.contains(match.bounds) }
        let scale = NSScreen.screens.first { $0.displayID == (display?.displayID ?? overlay.displayID) }?.backingScaleFactor ?? 2
        return try await Self.captureWindow(window, display: display, bounds: match.bounds, part: CGRect(x: 0, y: 0, width: 1, height: 1), scale: scale)
    }

    /// Small grayscale copies of the watched areas, the same size whatever the capture scale.
    private func thumbnails(of image: CGImage) -> ([[UInt8]], [Int])? {
        var result: [[UInt8]] = []
        var widths: [Int] = []
        for area in areas {
            guard let crop = image.cropping(to: pixelRect(of: area, in: image)), let bounds else { return nil }
            let longSide: CGFloat = 320
            let pointSize = CGSize(width: area.width * bounds.width, height: area.height * bounds.height)
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
    /// - Parameter firstOnly: Stop at the first changed block that isn't in `ignoring`.
    /// - Parameter only: The areas to compare (the others count as unchanged), or all.
    private func changedBlocks(_ a: Frame, _ b: Frame, ignoring: [Set<Int>] = [], firstOnly: Bool = false, only: [Int]? = nil) -> [Set<Int>]? {
        guard a.thumbnails.count == b.thumbnails.count, a.widths == b.widths else { return nil }
        let block = Self.block
        let tolerance = Int(number("ocrStillTolerance", 40))
        var result: [Set<Int>] = []
        for (area, ((x, y), width)) in zip(zip(a.thumbnails, b.thumbnails), a.widths).enumerated() {
            guard x.count == y.count, width > 0 else { return nil }
            if let only, !only.contains(area) {
                result.append([])
                continue
            }
            let ignored = area < ignoring.count ? ignoring[area] : []
            let height = x.count / width
            let columns = (width + block - 1) / block
            var counts = [Int](repeating: 0, count: columns * ((height + block - 1) / block))
            var changed: Set<Int> = []
            for row in 0..<height {
                for column in 0..<width {
                    let index = row * width + column
                    guard abs(Int(x[index]) - Int(y[index])) > tolerance else { continue }
                    let cell = (row / block) * columns + column / block
                    counts[cell] += 1
                    if counts[cell] == 5, !ignored.contains(cell) {
                        changed.insert(cell)
                        if firstOnly { return result + [changed] }
                    }
                }
            }
            result.append(changed)
        }
        return result
    }

    /// Whether two frames look the same in detail, apart from spots known to be animated.
    private func isSame(_ a: Frame, _ b: Frame, only: [Int]? = nil) -> Bool {
        guard let changed = changedBlocks(a, b, ignoring: animatedBlocks, firstOnly: true, only: only) else { return false }
        return changed.allSatisfy(\.isEmpty)
    }

    /// Learns the spots that keep changing while the rest is still (e.g. a blinking "next" icon) from
    /// frames since one that's the same as the latest, so that later they don't keep the window from
    /// being still. Not when there are many (that's an animated background, not an icon).
    private func learnAnimatedBlocks(from frames: [Frame]) {
        guard frames.count > 1, let first = frames.first else { return }
        var found = first.thumbnails.map { _ in Set<Int>() }
        for (a, b) in zip(frames, frames.dropFirst()) {
            // Only the dialogue waits until still; the other areas are read whenever they change.
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
