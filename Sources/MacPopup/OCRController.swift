import AppKit
import LiveText
import OCREngines
import os
import ScreenCaptureKit
import UniformTypeIdentifiers

/// OCR: MacPopup reads the text of another app's window
/// with the engine chosen in Settings → OCR (Live Text by default) and lays an invisible copy of it
/// over the window (see web/src/lib/ocr-layer.js), so hovering the window's own text opens popups.
/// Without a captured window (Settings → General), it reads the whole screen the overlay is on instead,
/// apart from MacPopup's own windows; "window" below then means that screen.
///
/// The window is captured with ScreenCaptureKit and watched for changes: all the time, or, with "Only
/// check for changes after input activity", while the mouse, keyboard or a controller is used and, for the
/// dialogue, for a while after each reading that changed its text. With a WebSocket connected, each new line is also the cue to read the window
/// again; it doesn't replace watching, since the dialogue can go away (e.g. a menu opened) or show the
/// line in parts, a click at a time. Recognition waits until the text has stopped changing, since games
/// often draw text gradually after the hooked line arrives.
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
        var thumbnails: [[UInt8]]
        /// The width of each thumbnail.
        var widths: [Int]
    }

    private let overlay: OverlayController
    /// Whether text is being read, for the OCR overlay or for the Floating Window's "Read text from OCR".
    private(set) var isEnabled = false
    /// Whether text is read for the OCR overlay. Otherwise it's for the Floating Window, which only uses the dialogue's
    /// settled readings as lines (like a text hooker) and reads the window all the time, even when it isn't visible.
    private var showsOverlay = false
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
    /// The dialogue is watched until then, for "Keep checking after activity for" after each reading that changed its
    /// text, whether there was input or not (a line read as soon as it was still may not have been fully drawn).
    private var watchUntil = Date.distantPast
    /// The dialogue's text when watchUntil was last set by a reading (see noteReading).
    private var watchedTexts: [String]?
    /// One or two characters at the end of a dialogue row that went away while the rest stayed the same, and how many
    /// times (see noteTail): from twice (so they came back), something OCR reads as letters, like a blinking "next"
    /// icon read as a kanji. Left out like the marks rows end with (see coreAndEnds), and of the lines the page gets.
    private var flickeringTail: (rows: [String], row: Int, text: String, gone: Int)?
    /// The dialogue's rows (see rowCores) in the last reading.
    private var lastRowCores: [String]?
    private var lastCursorPoint: CGPoint?
    /// With "Only check for changes after input activity", the window is only read until a while after the
    /// mouse, keyboard or a controller was last used, not while they rest.
    private var inputActiveUntil = Date.distantPast
    /// When the mouse or keyboard was last used, as macOS last told (see checkInput).
    private var lastInput = Date.distantPast
    /// Input started: check for changes right away.
    private var checkSoon = false
    private var waitingForInput = false
    /// A thumbnail block seen changing while the text stayed the same (e.g. a blinking or spinning "next" icon, or an
    /// animation beside the text).
    private struct AnimatedBlock {
        /// How it looked meanwhile (see blockPixels), and when it last looked so: changing to one of these again
        /// isn't the window changing, changing to another look is (e.g. text drawn there).
        var looks: [(pixels: [UInt8], seen: Date)] = []
        /// It had more looks than are kept (e.g. a continuous animation): any change there is left out until then, or
        /// until input meant for the game (see gameInput), which could bring up text there.
        var ignoredUntil: Date?

        func isIgnored(at now: Date) -> Bool {
            ignoredUntil.map { $0 > now } == true
        }
    }
    /// Per area, the thumbnail blocks learned as animated, by index (see changedBlocks).
    private var animatedBlocks: [[Int: AnimatedBlock]] = []
    /// The looks kept of an animated block.
    private static let animatedLooks = 8
    /// How long changes in an animated block with too many looks are left out without input.
    private static let animatedIgnoreTime: TimeInterval = 5
    /// When a click, key press or scroll was last seen (see checkInput).
    private var lastPress = Date.distantPast
    /// The mouse buttons pressed (Yomitan's numbers) and when, from the overlay's button events (see mouseButtonPressed).
    private var buttonPresses: [(button: Int, at: Date)] = []
    /// Per area, the lines last read there: an area is read on its own, and sent with the others.
    private var areaLines: [[[String: Any]]] = []
    /// Where the dialogue's text would go on, in its thumbnail's pixels (see thumbnails): a character's room after the
    /// end of each line read, and the start of a line after the last one. A reading can be taken before a line is
    /// complete (its last character still fading in, or a line drawn for longer than "Max wait"), and the rest of a
    /// line can be too little of a busy picture to count as the window changing (see differs), so these spots are
    /// watched on their own (see textContinues).
    private var continuationRects: [CGRect] = []
    /// Readings started by a change at those spots that read the same text: after a few, the spots are left alone
    /// until the text changes (something there that isn't text, like a blinking "next" icon, would keep them busy).
    private var continuationRereads = 0
    /// Per area, the lines last left out there (by the language or as furigana), for the page's debug log.
    private var areaRemoved: [[[String: Any]]] = []
    /// The areas after the first may have changed unseen (e.g. while the window was away): read them
    /// with the next reading.
    private var otherAreasOutdated = false

    private var isInputActive: Bool {
        OCRClock.now < inputActiveUntil
    }

    /// Whether the window is watched for changes now: all the time, or (with
    /// "Only check for changes after input activity") only for a while after input.
    private var isWatching: Bool {
        !showsOverlay || !(settings["ocrMouseWatch"] as? Bool ?? true) || isInputActive
    }

    /// The dialogue is also watched for a while after each reading that changed its text.
    private var isWatchingDialogue: Bool {
        isWatching || OCRClock.now < watchUntil
    }

    /// How long the window is watched after input or a change (Settings → OCR Overlay → Keep checking after activity
    /// for), in seconds.
    private var watchTime: Double { number("ocrMouseWatchTime", 2000) / 1000 }

    /// The game was paused (see GamePause) and goes on: like after input, the dialogue is watched for a
    /// while, e.g. for the rest of a line it was drawing when it was read while paused.
    func gameResumed() {
        log("game resumed")
        watchUntil = max(watchUntil, OCRClock.now.addingTimeInterval(watchTime))
        checkSoon = true
    }

    /// The window is watched for a while after input (e.g. a click, key or controller button advancing a game's
    /// text, or the cursor moving to it), since the text that brings up takes a moment to appear.
    func inputUsed() {
        let duration = watchTime
        if !isInputActive {
            checkSoon = true
            log("input (\(duration)s)")
        }
        inputActiveUntil = max(inputActiveUntil, OCRClock.now.addingTimeInterval(duration))
    }

    /// Notes mouse and keyboard input (moves, clicks, scrolls, key presses), whichever app it went to, from when macOS
    /// last saw any (from the devices: not events apps make). Controllers aren't in it: Gamepads.swift tells those.
    private func checkInput() {
        // A simulated run has no input (the system's would be whatever happens meanwhile, at its own times).
        guard Simulation.shared == nil else { return }
        let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let input = OCRClock.now.addingTimeInterval(-since)
        // A little later each time it's asked while nothing happens (it's measured to the nearest moment).
        guard input.timeIntervalSince(lastInput) > 0.02 else { return }
        lastInput = input
        inputUsed()
        // Not the cursor moving (e.g. to hover the text) nor modifier keys (e.g. the scan modifier).
        let presses: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        let times = presses.map { OCRClock.now.addingTimeInterval(-CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)) }
        let pressed = times.max() ?? .distantPast
        guard pressed.timeIntervalSince(lastPress) > 0.02 else { return }
        // Which mouse buttons, when they were all there was since the last press seen (no key press or scroll).
        let mouseOnly = zip(presses, times).allSatisfy { type, time in
            [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) || time.timeIntervalSince(lastPress) <= 0.02
        }
        let buttons = Set(buttonPresses.filter { $0.at.timeIntervalSince(lastPress) > -0.05 }.map(\.button)).sorted()
        buttonPresses = []
        lastPress = pressed
        if !overlay.showsPopups, NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            gameInput(buttons: mouseOnly && !buttons.isEmpty ? buttons : nil)
        }
    }

    /// A mouse button was pressed (Yomitan's number), anywhere: which one, for the press checkInput sees.
    func mouseButtonPressed(_ button: Int) {
        buttonPresses.append((button, OCRClock.now))
        if buttonPresses.count > 16 { buttonPresses.removeFirst() }
    }

    /// A click, key press, scroll or controller press that may have gone to the game (not to MacPopup or its popups),
    /// whether or not reading waits for input: it can bring up text anywhere, also where an animation was learned
    /// that changes too much to be left out by its looks (see AnimatedBlock), so those are watched again. They're
    /// learned again from the next reading of the same text. The page is told too: a hover made while the text was
    /// changing isn't looked up once it's current (it may be the next line's), unless `buttons`, the mouse buttons it
    /// was all of (Yomitan's numbers), are scan inputs' (a game is taken not to use those).
    func gameInput(buttons: [Int]? = nil) {
        send(["type": "input", "buttons": buttons.map { $0.map { "mouse\($0)" } } ?? []])
        let now = OCRClock.now
        var watched = 0
        for area in animatedBlocks.indices {
            for (index, block) in animatedBlocks[area] where block.isIgnored(at: now) {
                animatedBlocks[area][index]?.ignoredUntil = nil
                watched += 1
            }
        }
        if watched > 0 { log("input: \(watched) animated blocks watched again") }
    }

    /// The window state last sent to the page, so that it's only sent when it changes.
    private var lastSentWindowState = ""
    /// Whether the overlay was last logged as shown over the window (nil: not yet, it's in the window's record, see logWindow).
    private var loggedVisible: Bool?

    private var trackTimer: Timer?
    private var loopTask: Task<Void, Never>?
    private var pendingCue: Cue?
    private var lastRecognizedFrame: Frame?
    private var isPicking = false
    /// MACPOPUP_DEBUG_OCR_DIR=<directory> saves what the engine read in each area there (read-N-areaI.json), and with
    /// MACPOPUP_DEBUG_OCR_PICTURES=1 each area read (read-N-areaI.png; encoding them took most of a test run's CPU time
    /// when the whole window was read).
    private let debugDirectory = DevelopmentEnvironment["MACPOPUP_DEBUG_OCR_DIR"]
    private let savesDebugPictures = DevelopmentEnvironment["MACPOPUP_DEBUG_OCR_PICTURES"] == "1"
    private var debugReadings = 0

    private var scWindow: SCWindow?
    /// The display the window lies within, if it does (the screen that's read without a window).
    private var scDisplay: SCDisplay?
    /// MacPopup itself, left out when the whole screen is read.
    private var scOwnApps: [SCRunningApplication] = []
    private var captureFailures = 0
    /// How many times in a row a round's cue was kept for the next one, as a capture failed (see settleAndRecognize).
    private var keptCues = 0
    /// What a capture stream is for: the checks for changes (at comparisonScale), or the readings (at the scale read at).
    private enum StreamUse { case comparison, reading }
    /// Where the checks for changes and the readings take their pictures from (see streamImage).
    private var streams: [StreamUse: CaptureStream] = [:]
    /// When a check for changes last asked for a picture: the streams stop a while after.
    private var lastComparison = Date.distantPast
    /// After a stream failed, screenshots are taken instead until then.
    private var streamRetryAt: [StreamUse: Date] = [:]
    /// Streams being started (pictures meanwhile are screenshots).
    private var startingStreams: Set<StreamUse> = []
    /// Readings taken from the readings' stream, and as screenshots, while it ran (for the debug log).
    private var readingsFromStream = 0
    private var readingScreenshots = 0
    /// The window bounds `scWindow` and `scDisplay` were looked up for.
    private var scBounds: CGRect = .null
    /// The scale the window is read at: 1 when it's drawn at 1x (e.g. a VM or game that isn't Retina
    /// aware, enlarged by macOS), since then a higher one adds no detail and only slows Live Text down.
    /// Nil until a reading has shown which, and again when the window is resized, moved (e.g. to another display) or
    /// picked again: it doesn't change otherwise. Unused when the resolution is set in Settings.
    private var readingScale: CGFloat?
    private var lastCoverCheck = Date.distantPast
    /// The last list of windows in front of the target (see windows(inFrontOf:)).
    private var windowsInFront: (window: CGWindowID, time: Date, list: [WindowInfo])?
    private var isCursorCovered = false
    /// The apps whose windows cover what's read of the window: it's not read until it can be seen (see coveringApps).
    /// Nil when it's not covered.
    private var coveredBy: [String]?
    /// The window that was last checked for that, and when.
    private var coverageCheck: (window: CGWindowID, time: Date)?
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
        /// Read the window as it is now, without waiting for it to settle: the game is paused (see GamePause), so it
        /// won't change.
        case now
    }

    init(overlay: OverlayController) {
        self.overlay = overlay
        Simulation.shared?.page = overlay.webView
        overlay.onCursorMoved = { [weak self] point in self?.cursorMoved(to: point) }
        switchShortcut.onPress = { [weak self] _ in self?.switchOverlay(from: "keyboard") }
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        applySettings()
    }

    // MARK: Settings

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private func number(_ key: String, _ fallback: Double) -> Double {
        (settings[key] as? NSNumber)?.doubleValue ?? fallback
    }

    private func applySettings() {
        switchShortcut.set(KeyCombination(setting: settings["overlaySwitchShortcut"])) { [weak self] taken in
            self?.overlay.showToast("The overlay switch shortcut \(taken.displayName) is already in use by another app or shortcut")
        }
        let overlayMode = settings["ocrMode"] as? Bool ?? false
        let enabled = overlayMode || settings["floatingWindowOCR"] as? Bool ?? false
        let switched = enabled && isEnabled && overlayMode != showsOverlay
        showsOverlay = overlayMode
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
        if switched {
            // Switched between the overlay and the Floating Window, which differ in when the window can be read (see
            // trackWindow).
            log(showsOverlay ? "for the OCR overlay" : "for the Floating Window")
            coveredBy = nil
            readAgain()
        }
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
        } else if let target, !Self.isSaved(target, saved) {
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
        stopStreams()
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
        // (A reading as it is reads it all the same.)
        if hasSource, pendingCue != .now {
            pendingCue = .immediate
        }
    }

    /// Whether the OCR overlay is the overlay type (Settings → General → Overlay type).
    var isOverlayOn: Bool { settings["ocrMode"] as? Bool ?? false }

    func setOverlayOn(_ on: Bool) {
        SettingsStore.shared.update(["ocrMode": on])
    }

    /// Settings → General → Overlay switch key/buttons: the keyboard shortcut (the controller buttons are matched by
    /// overlay.js).
    private let switchShortcut = HotkeyController(signature: 0x4D50_4F53) // "MPOS"

    /// Switches between the OCR overlay and the Floating Window, from the overlay switch's keyboard shortcut or
    /// controller buttons (`source`).
    func switchOverlay(from source: String) {
        let on = !isOverlayOn
        if DebugLog.isOn { DebugLog.record(["type": "event", "event": "overlay switch", "from": source, "ocrMode": on]) }
        setOverlayOn(on)
    }

    // MARK: Lifecycle

    private func start() {
        if CGPreflightScreenCaptureAccess() == false {
            CGRequestScreenCaptureAccess()
        }
        // Another window may have been saved while OCR was off.
        if let target, !Self.isSaved(target, settings["ocrWindow"] as? [String: Any]) {
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
        loggedVisible = nil
        trackWindow()
        logWindow()
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
        stopStreams()
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
        guard let match = Self.savedWindow(ownerName: ownerName, title: saved["title"] as? String ?? "") else { return }
        target = Target(windowID: match.id, ownerName: match.ownerName, title: match.title)
        regions = Self.decodeRegions(settings["ocrRegions"])
    }

    /// The saved window: its app's window with its title (or any of its app's normal windows, or floating ones when it
    /// has none, e.g. a player kept on top playing another file), preferably on screen, and the largest. An app can have hidden windows too, with the same title (e.g. a Windows app in Parallels'
    /// Coherence mode has several untitled ones off screen besides its window). Also windows that aren't on screen now,
    /// e.g. a game in its own full screen space.
    static func savedWindow(ownerName: String, title: String) -> WindowInfo? {
        let windows = windows(onScreenOnly: false).filter { $0.ownerName == ownerName }
        let titled = windows.filter { $0.title == title }
        let normal = windows.filter { $0.layer == 0 }
        return (!titled.isEmpty ? titled : !normal.isEmpty ? normal : windows).max { a, b in
            (a.isOnScreen ? 1 : 0, a.bounds.width * a.bounds.height) < (b.isOnScreen ? 1 : 0, b.bounds.width * b.bounds.height)
        }
    }

    /// The captured window saved in the settings (Settings → General), found as savedWindow(ownerName:title:) does.
    static func savedWindow() -> WindowInfo? {
        guard let saved = SettingsStore.shared.dictionary["ocrWindow"] as? [String: Any], let owner = saved["ownerName"] as? String
        else { return nil }
        return savedWindow(ownerName: owner, title: saved["title"] as? String ?? "")
    }

    /// Reads `window` instead of the window being read, as a window found again.
    private func switchTarget(to window: Target) {
        target = window
        bounds = nil
        isWindowAvailable = false
        scWindow = nil
        readingScale = nil
        animatedBlocks = []
        areaLines = []
        areaRemoved = []
        lastRecognizedFrame = nil
        pendingCue = .immediate
    }

    /// Whether `target` is the window saved in the settings (`saved`, the "ocrWindow" setting).
    private static func isSaved(_ target: Target, _ saved: [String: Any]?) -> Bool {
        saved?["ownerName"] as? String == target.ownerName && saved?["title"] as? String ?? "" == target.title
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

    /// Lets the user pick the captured window and its areas. OCR stays as it is: the window is also what
    /// screenshots for cards capture.
    func selectWindow() {
        guard !isPicking else { return }
        isPicking = true
        send(["type": "window", "visible": false])
        // Start from the window being read. When it isn't on screen (in another space, or minimized), it's brought
        // here first, and the picker waits for it to show where it is (it slides in while macOS switches spaces),
        // up to 2 seconds.
        guard let id = target?.windowID, !Self.onScreenWindows().contains(where: { $0.id == id }),
              let window = Self.windows(onScreenOnly: false).first(where: { $0.id == id }) else {
            pickWindow()
            return
        }
        Self.raise(window)
        Task { @MainActor in
            for _ in 0..<40 where !Self.onScreenWindows().contains(where: { $0.id == id && $0.bounds == window.bounds }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            pickWindow()
        }
    }

    private func pickWindow() {
        let selection = target.flatMap { target in
            Self.onScreenWindows().first { $0.id == target.windowID }.map { (window: $0, regions: regions) }
        }
        WindowPicker.pick(above: overlay.panel.level, selection: selection) { [weak self] choice in
            guard let self else { return }
            self.isPicking = false
            var changes: [String: Any]
            switch choice {
            case nil:
                self.lastSentWindowState = ""
                self.trackWindow()
                return
            case .wholeScreen:
                self.target = nil
                self.readsScreen = true
                self.regions = []
                changes = ["ocrWindow": NSNull(), "ocrRegions": [Any]()]
            case let .window(result):
                self.target = Target(windowID: result.windowID, ownerName: result.ownerName, title: result.title)
                self.readsScreen = false
                self.regions = result.regions
                changes = [
                    "ocrWindow": ["ownerName": result.ownerName, "title": result.title],
                    "ocrRegions": result.regions.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
                ]
            }
            self.readAgain()
            SettingsStore.shared.update(changes)
        }
    }

    // MARK: Messages from the page

    private func log(_ message: @autoclosure () -> String) {
        DebugLog.note(message())
    }

    /// The window read, in the debug log: as OCR starts (or once the saved window is found, e.g. a game started later),
    /// and after each session record (see DebugLog.onSession).
    func logWindow() {
        guard isEnabled, DebugLog.isOn, var window = windowForLog else { return }
        window["overlayShown"] = loggedVisible
        DebugLog.record(["type": "ocr", "window": window])
    }

    /// The window read (or the screen), for the debug log.
    private var windowForLog: [String: Any]? {
        var window: [String: Any] = readsScreen ? ["screen": true] : [:]
        if let target { window.merge(["owner": target.ownerName, "title": target.title]) { $1 } }
        if let bounds {
            window["bounds"] = [bounds.minX, bounds.minY, bounds.width, bounds.height]
            let screen = NSScreen.screens.first { Self.globalFrame(of: $0).contains(CGPoint(x: bounds.midX, y: bounds.midY)) }
            window["scale"] = screen?.backingScaleFactor
        }
        return window.isEmpty ? nil : window
    }

    /// Returns whether it's done: for readNow, whether the window will be read.
    func handle(_ body: [String: Any]) -> Bool {
        log("page: \(body["action"] ?? "")\(body["connected"].map { " \($0)" } ?? "")")
        switch body["action"] as? String {
        case "readNow":
            // The game was paused (only with the overlay): stop any reading in progress and read the window as it is
            // now.
            guard isEnabled, showsOverlay, !isPicking, hasSource, bounds != nil, isWindowAvailable else { return false }
            pendingCue = .now
            dropCloudRequest()
        case "websocket":
            websocketConnected = body["connected"] as? Bool ?? false
        case "cue":
            // Read when the window is available, which may be later (e.g. it's in another space). A reading as it
            // is that's waiting reads it too (the page waits for that one, see readOcrNow in web/src/overlay.js).
            if pendingCue != .now { pendingCue = .newLine }
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
            if let crashNotice {
                send(["type": "error", "message": crashNotice])
                self.crashNotice = nil
            }
        default:
            break
        }
        return true
    }

    private func send(_ message: [String: Any]) {
        if message["type"] as? String == "error" { log("error shown: \(message["message"] ?? "")") }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__macpopupOcr?.(\(json))"
        overlay.evaluate(Simulation.shared?.pageMessage(js) ?? js)
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
        var alpha: Double
    }

    private static func windowInfo(_ dictionary: [String: Any]) -> WindowInfo? {
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
            isOnScreen: dictionary[kCGWindowIsOnscreen as String] as? Bool ?? false,
            alpha: dictionary[kCGWindowAlpha as String] as? Double ?? 1
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

    /// Other apps' normal and floating windows (see pickableLayers), front to back.
    static func onScreenWindows() -> [WindowInfo] {
        windows(onScreenOnly: true)
    }

    private static func windows(onScreenOnly: Bool) -> [WindowInfo] {
        windows(onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements])
    }

    /// The window levels a captured window can be at: normal windows and floating ones (floating panels, players
    /// kept on top), below the Dock, the menu bar and menus. A floating window that's entirely transparent isn't one,
    /// nor a see-through one over a whole display (an overlay such as a screen dimmer would otherwise be picked
    /// wherever the picker points), while an opaque one is (a player kept on top in full screen).
    private static let pickableLayers = 0..<Int(CGWindowLevelForKey(.dockWindow))

    private static func coversDisplay(_ bounds: CGRect) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { bounds.contains(CGDisplayBounds($0)) }
    }

    /// Whether a floating window over a whole display is see-through: drawn with the window's own transparency, or
    /// mostly in see-through colors, as a small screenshot of it shows. That's taken in the background: until it's
    /// known, the window counts as see-through (left out). A failed one is tried again after 5 s, and a see-through
    /// one after 10 s (it may have been taken before the window was drawn); an opaque one is kept for the window.
    private static func isSeeThroughOverlay(_ window: WindowInfo) -> Bool {
        if window.alpha < 0.9 { return true }
        let (known, start) = overlayChecks.withLock { checks -> (Bool?, Bool) in
            switch checks[window.id] {
            case .known(let seeThrough, let at) where !seeThrough || Date().timeIntervalSince(at) < 10:
                return (seeThrough, false)
            case .checking:
                return (nil, false)
            case .failed(let at) where Date().timeIntervalSince(at) < 5:
                return (nil, false)
            default:
                checks[window.id] = .checking
                return (nil, true)
            }
        }
        if start {
            Task.detached {
                let seeThrough = try? await screenshotSeeThrough(windowID: window.id)
                overlayChecks.withLock { $0[window.id] = seeThrough.map { .known($0, Date()) } ?? .failed(Date()) }
            }
        }
        return known ?? true
    }

    private enum OverlayCheck: Sendable {
        case checking
        case known(Bool, Date)
        case failed(Date)
    }

    nonisolated private static let overlayChecks = OSAllocatedUnfairLock<[CGWindowID: OverlayCheck]>(initialState: [:])

    nonisolated private static func screenshotSeeThrough(windowID: CGWindowID) async throws -> Bool {
        let content = try await ScreenCapture.shareableContent(onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { throw AppError("The captured window is no longer available") }
        let configuration = SCStreamConfiguration()
        // The whole window in 64×40, whatever its shape (not letterboxed with the clear background).
        configuration.width = 64
        configuration.height = 40
        configuration.preservesAspectRatio = false
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.backgroundColor = .clear
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        return isSeeThrough(try await ScreenCapture.image(filter: filter, configuration: configuration))
    }

    /// Whether most of `image` is see-through (under 90% opaque).
    nonisolated static func isSeeThrough(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return false }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let seeThrough = stride(from: 3, to: data.count, by: 4).count { data[$0] < 230 }
        return seeThrough * 2 > width * height
    }

    /// Other apps' windows of at least 40×40 points: normal and floating ones, or with `normalOnly` normal ones. The
    /// Dock's are left out: Mission Control's, over the whole screen and over each window's thumbnail, are at floating
    /// levels (one at the normal level as it closes).
    private static func windows(
        _ options: CGWindowListOption, relativeTo window: CGWindowID = kCGNullWindowID, normalOnly: Bool = false
    ) -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo(options, window) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        // (The screenshot check last: only for other apps' windows that would be picked otherwise.)
        return list.compactMap(windowInfo).filter {
            $0.ownerPID != ownPID && $0.ownerPID != dockPID && $0.bounds.width >= 40 && $0.bounds.height >= 40
                && (normalOnly ? $0.layer == 0
                    : pickableLayers.contains($0.layer)
                        && ($0.layer == 0 || $0.alpha > 0 && !(coversDisplay($0.bounds) && isSeeThroughOverlay($0))))
        }
    }

    private func trackWindow() {
        if !streams.isEmpty, OCRClock.now.timeIntervalSince(lastComparison) > 1 { stopStreams() }
        guard isEnabled, !isPicking else { return }
        if readsScreen {
            trackScreen()
            return
        }
        guard let target else {
            sendWindowState(visible: false)
            // The saved window may not exist yet (e.g. the game isn't running): keep looking.
            if OCRClock.now.timeIntervalSince(lastRefind) > 2 {
                lastRefind = OCRClock.now
                restoreSavedTarget()
                if self.target != nil {
                    log("found the saved window: \(windowForLog ?? [:])")
                    readAgain()
                    // Its state (the overlay shown over it) for the window record, as when OCR starts.
                    trackWindow()
                    logWindow()
                }
            }
            return
        }
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], target.windowID) as? [[String: Any]] ?? []
        guard let info = list.first.flatMap(Self.windowInfo), info.id == target.windowID else {
            // Closed: wait for the app to open a window again (e.g. a restarted game).
            if bounds != nil { log("window closed") }
            bounds = nil
            isWindowAvailable = false
            sendWindowState(visible: false)
            if OCRClock.now.timeIntervalSince(lastRefind) > 2 {
                lastRefind = OCRClock.now
                self.target = nil
                restoreSavedTarget()
                if let found = self.target {
                    switchTarget(to: found)
                } else {
                    self.target = target
                }
            }
            return
        }
        // Not on screen while another window of the saved one's app (and title) is: that's the one, e.g. after MacPopup
        // found one of the app's hidden windows first.
        if !info.isOnScreen, Self.isSaved(target, settings["ocrWindow"] as? [String: Any]), OCRClock.now.timeIntervalSince(lastRefind) > 2 {
            lastRefind = OCRClock.now
            if let window = Self.savedWindow(ownerName: target.ownerName, title: target.title), window.id != target.windowID, window.isOnScreen {
                log("the window isn't on screen but another of its app's is: reading that one")
                switchTarget(to: Target(windowID: window.id, ownerName: window.ownerName, title: window.title))
                return
            }
        }
        if let old = bounds, old.size != info.bounds.size, lastResult != nil {
            log("resized \(old.size) -> \(info.bounds.size)")
            // Resized: the text moved, so read it again (a cue waiting already reads it).
            if pendingCue == nil { pendingCue = .retry }
            otherAreasOutdated = true
        }
        if bounds != info.bounds {
            boundsChangedAt = OCRClock.now
        }
        let onDisplay = NSScreen.screens.contains { Self.globalFrame(of: $0).intersects(info.bounds) }
        if !info.isOnScreen || !showsOverlay {
            coveredBy = nil
        } else if coverageCheck?.window != target.windowID || OCRClock.now.timeIntervalSince(coverageCheck?.time ?? .distantPast) > 0.3 {
            coverageCheck = (target.windowID, OCRClock.now)
            coveredBy = coveringApps(info.bounds)
        }
        // The Floating Window reads the window even when it isn't visible. Most apps keep drawing a window that's
        // covered or in another space; a minimized or hidden one doesn't update, so its readings just time out.
        let canBeRead = !showsOverlay || (info.isOnScreen && onDisplay && coveredBy == nil)
        let available = canBeRead && OCRClock.now.timeIntervalSince(boundsChangedAt) >= 0.3
        if !available, isWindowAvailable {
            let reasons = [info.isOnScreen || !showsOverlay ? nil : "not on screen (e.g. another space, minimized)", onDisplay || !showsOverlay ? nil : "off the displays",
                           coveredBy.map { "covered by other windows (\($0.joined(separator: ", ")))" }, OCRClock.now.timeIntervalSince(boundsChangedAt) < 0.3 ? "moving" : nil]
            log("window unavailable: \(reasons.compactMap { $0 }.joined(separator: ", "))")
        }
        if available, !isWindowAvailable, lastResult != nil {
            // Back (e.g. from another space): it may have changed or been drawn again differently.
            log("available again at \(info.bounds)")
            if pendingCue == nil { pendingCue = .retry }
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
            boundsChangedAt = OCRClock.now
            if bounds != nil, lastResult != nil, pendingCue == nil { pendingCue = .retry }
            if bounds != nil { otherAreasOutdated = true }
        }
        bounds = frame
        isWindowAvailable = OCRClock.now.timeIntervalSince(boundsChangedAt) >= 0.3
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
        // "available": whether it's read now (see isWindowAvailable): the page doesn't draw its text meanwhile.
        var message: [String: Any] = ["type": "window", "visible": visible && bounds != nil, "available": isWindowAvailable]
        if let bounds {
            let origin = overlay.globalOrigin
            message["x"] = bounds.minX - origin.x
            message["y"] = bounds.minY - origin.y
            message["width"] = bounds.width
            message["height"] = bounds.height
        }
        let key = message.keys.sorted().map { "\($0)=\(message[$0]!)" }.joined(separator: ",")
        guard key != lastSentWindowState else { return }
        // Only when it's shown or hidden (moves are seen as "window unavailable: moving" and "available again").
        let visible = message["visible"] as? Bool == true
        if let loggedVisible, loggedVisible != visible {
            log(visible ? "overlay shown over the window" : "overlay hidden: the window can't be seen")
        }
        loggedVisible = visible
        lastSentWindowState = key
        send(message)
    }

    /// Whether another window is in front of the target where the cursor is, so its text can't be hovered.
    private func cursorMoved(to point: CGPoint) {
        let moved = point != lastCursorPoint
        if moved {
            lastCursorPoint = point
        }
        guard isEnabled, showsOverlay, let target, let bounds, bounds.contains(point) else {
            setCursorCovered(false)
            return
        }
        // Windows can also come and go under a resting cursor, but that's checked less often (each check is a round
        // trip to the window server).
        guard OCRClock.now.timeIntervalSince(lastCoverCheck) > (moved ? 0.1 : 0.5) else { return }
        lastCoverCheck = OCRClock.now
        setCursorCovered(windows(inFrontOf: target.windowID).contains { $0.bounds.contains(point) })
    }

    /// Other apps' normal windows in front of the window, except ones that are entirely transparent. (Not floating
    /// ones: an app's overlay kept on top of everything, like the screen dimmers', would count as covering every
    /// game.) The list is kept for a tenth of a second, as the coverage check and the cursor's ask for it in the same
    /// tick.
    private func windows(inFrontOf window: CGWindowID) -> [WindowInfo] {
        if let known = windowsInFront, known.window == window, OCRClock.now.timeIntervalSince(known.time) < 0.1 { return known.list }
        let list = Self.windows([.optionOnScreenAboveWindow, .excludeDesktopElements], relativeTo: window, normalOnly: true)
            .filter { $0.alpha > 0 }
        windowsInFront = (window, OCRClock.now, list)
        return list
    }

    /// When other windows cover all but a sliver of the window's part that's read (its areas), so it can't be seen,
    /// their apps: it's then not read until it can, as when it's in another space. Its text can't be hovered meanwhile
    /// anyway, and covered by a window for another app, it would be read for nothing.
    private func coveringApps(_ windowBounds: CGRect) -> [String]? {
        guard let target else { return nil }
        let part = capturedPart
        let read = CGRect(x: windowBounds.minX + part.minX * windowBounds.width, y: windowBounds.minY + part.minY * windowBounds.height,
                          width: part.width * windowBounds.width, height: part.height * windowBounds.height)
        guard read.width > 0, read.height > 0 else { return nil }
        let covering = windows(inFrontOf: target.windowID).filter { !$0.bounds.intersection(read).isEmpty }
        guard !covering.isEmpty,
              Self.uncoveredArea(of: read, by: covering.map { $0.bounds.intersection(read) }) < read.width * read.height * 0.05 else { return nil }
        return covering.reduce(into: []) { apps, window in if !apps.contains(window.ownerName) { apps.append(window.ownerName) } }
    }

    /// The area of `rect` outside all of `covers` (each within it).
    static func uncoveredArea(of rect: CGRect, by covers: [CGRect]) -> CGFloat {
        let xs = Set(covers.flatMap { [$0.minX, $0.maxX] } + [rect.minX, rect.maxX]).sorted()
        let ys = Set(covers.flatMap { [$0.minY, $0.maxY] } + [rect.minY, rect.maxY]).sorted()
        var area: CGFloat = 0
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            for (y0, y1) in zip(ys, ys.dropFirst()) {
                let center = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                if !covers.contains(where: { $0.contains(center) }) { area += (x1 - x0) * (y1 - y0) }
            }
        }
        return area
    }

    private func setCursorCovered(_ covered: Bool) {
        guard covered != isCursorCovered else { return }
        isCursorCovered = covered
        log(covered ? "another window is in front under the pointer" : "nothing in front under the pointer")
        send(["type": "covered", "value": covered])
    }

    // MARK: Reading the window

    private func runLoop() async {
        while !Task.isCancelled {
            guard isEnabled, !isPicking, hasSource, bounds != nil, isWindowAvailable else {
                await OCRClock.sleep(for: .milliseconds(200))
                continue
            }
            checkInput()
            if !websocketConnected, !isWatchingDialogue, pendingCue != .immediate, pendingCue != .now {
                // Without WebSocket lines, wait for input (or the dialogue was read, which watches it for a
                // while). Readings that were asked for (e.g. after coming back from another space) wait too,
                // but not the first one of a newly chosen window or screen.
                if !waitingForInput {
                    waitingForInput = true
                    log("waiting for input\(pendingCue.map { " (\($0) pending)" } ?? "")")
                }
                await OCRClock.sleep(for: .milliseconds(50))
                continue
            }
            waitingForInput = false
            if let cue = pendingCue {
                pendingCue = nil
                await settleAndRecognize(cue: cue)
                continue
            }
            let watchesDialogue = isWatchingDialogue
            let watchesOthers = areas.count > 1 && isWatching
            if !watchesDialogue && !watchesOthers {
                await OCRClock.sleep(for: .milliseconds(50))
                continue
            }
            let pollUntil = OCRClock.now.addingTimeInterval(checkSoon ? 0 : number("ocrPollInterval", 500) / 1000)
            checkSoon = false
            while pendingCue == nil, OCRClock.now < pollUntil, !Task.isCancelled {
                await OCRClock.sleep(for: .milliseconds(50))
            }
            guard pendingCue == nil, isWindowAvailable, websocketConnected || isWatchingDialogue, let (_, frame) = await capture(scale: Self.comparisonScale) else { continue }
            if watchesDialogue, lastRecognizedFrame.map({ differs(frame, $0, only: [0]) || textContinues(frame, $0) }) ?? true {
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
    /// When the current round of readings (settleAndRecognize) started, which is about when the text began to change.
    private var roundStarted: Date?

    /// Reads right away and again until the dialogue's text stays the same, instead of first waiting for
    /// the picture to be still (which an animated background can keep it from being). Each reading goes
    /// to the page as provisional: shown meanwhile, and taken as the dialogue's as soon as it matches the
    /// WebSocket line.
    /// - Parameter cue: For a new line, the text only counts as settled once the picture changed, unless
    ///   that doesn't happen within "Max wait for screen update" (the line may already be on screen):
    ///   until then it's the previous line's.
    private func settleAndRecognize(cue: Cue?) async {
        log("reading until settled for \(cue.map { "\($0)" } ?? "change")")
        roundStarted = OCRClock.now
        defer { roundStarted = nil }
        // The window changed: a cloud reading on its way is outdated, and the local reading it was for is shown, as it
        // would be without a cloud engine (e.g. a line drawn in bursts shows as it's drawn, not only once complete).
        dropCloudRequest(showingLocal: cue == nil)
        if cue == .newLine || cue == .retry {
            send(["type": "changing"])
        }
        let maxWait = number("ocrMaxWait", 8000) / 1000
        // The text has to stay the same for the settle time, as the picture does otherwise: text drawn a
        // character at a time looks the same between characters, and once read too early, the rest of
        // the line may change too little of the picture to be noticed.
        let settleTime = number("ocrSettleTime", 400) / 1000
        var start = OCRClock.now
        var sawChange = cue != .newLine
        // The text's settle key (see settleKey; its rows' keys joined, as OCR may split a row in two one time and not the
        // next, or read dots or an icon as a row of their own) when it was first read, and the most characters a reading
        // of it had.
        var previous: (key: String, time: Date, longest: Int)?
        // The reading of the dialogue's text being drawn with the most of it, taken as the line if the text is cleared
        // or replaced before it settles (e.g. a game that goes on by itself while OCR keeps misreading a character);
        // since when that text is there, how many readings in a row since were of other text, and when the first was.
        // Kept when a new line's cue starts the round over: the text drawn before it may still be the one replaced.
        var fullest: (key: String, lines: [[String: Any]], removed: [[String: Any]], image: CGImage, frame: Frame?, started: Date, since: Date)?
        var otherReadings = 0, otherSince = OCRClock.now
        // The window as it was read since the text last changed, to learn animated spots from (see
        // learnAnimatedBlocks). When the text is still what was read before the round (e.g. the round is for a
        // blinking icon), from before the change too.
        // Kept while the text is the same but for the marks its rows end with (see OCRText.isEndMark, and
        // flickeringTail), which may be an icon read as one.
        var frames: [Frame] = []
        let watched = watchedTexts.map(coreAndEnds)
        let textBefore = (key: watchedTexts.map { $0.map(Self.settleKey).joined() }, core: watched?.core,
                          ends: watched?.ends, frame: lastRecognizedFrame)
        var framesKey: String?
        // Where the dialogue's text was read during the round (see textBlocks): not learned as animated, unless the
        // marks its rows end with came and went or changed meanwhile (see endsVary). Those are then something OCR reads
        // as marks, like a blinking "next" icon read as a bracket, often too close to the text to be told apart in
        // blocks: what changed there is learned by its looks.
        var roundTextBlocks = Set<Int>()
        // The marks the rows ended with in each reading kept in `frames`.
        var ends: [String] = []
        // Near it: where the text read before it was, which may be going away during the round (fading out, or
        // replaced by text elsewhere), and where the text would go on (the rest of a line still fading in). Only
        // learned by their looks, so that the next line drawn there is still noticed.
        var nearTextBlocks = textBlocks(areaLines.first ?? [], goingOn: true)
        acceptedReading = false
        // The picture of the latest reading, which the page may take, and the window as it was then (see readFrame).
        var lastImage: CGImage?
        var lastImageFrame: Frame?
        // The areas read from it.
        var lastImageAreas: [Int] = []
        // What the round is for: its cue, or a new line's that came meanwhile. A capture that fails (e.g. while windows
        // change) ends the round with it kept for the next one, so that the line is still read.
        var roundCue = cue
        let keepCue = { [self] in
            // A few times (it would start over at once otherwise, e.g. while the window can't be captured).
            if keptCues < 2 {
                keptCues += 1
                if pendingCue == nil || roundCue == .now { pendingCue = roundCue }
            } else {
                keptCues = 0
                // The page waits for it.
                if roundCue == .now { send(["type": "error", "message": "Couldn’t capture the window"]) }
            }
        }
        // How the round waited before the next reading (see waitForChange), for the page's debug log.
        var waited: [String: Any] = [:]
        while !Task.isCancelled {
            guard isWindowAvailable else {
                log("window left while reading")
                if roundCue == .now {
                    pendingCue = .now
                } else if pendingCue == nil {
                    pendingCue = .retry
                }
                return
            }
            if pendingCue == .now {
                log("reading as it is instead")
                return
            }
            if pendingCue == .newLine {
                // Another line arrived: start over.
                pendingCue = nil
                roundCue = .newLine
                start = OCRClock.now
                sawChange = false
                previous = nil
                framesKey = nil
                acceptedReading = false
                send(["type": "changing"])
            }
            let read = cue == .immediate || cue == .now || otherAreasOutdated || areaLines.count != areas.count ? Array(areas.indices) : [0]
            if acceptedReading {
                log("the page took a reading")
                // The areas read from that picture (the others may have been outdated since).
                if lastImageAreas.count == areas.count { otherAreasOutdated = false }
                finishReading(lastImage, frame: lastImageFrame, areas: lastImageAreas, started: OCRClock.now, extra: waited.merging(["accepted": true]) { $1 })
                return
            }
            // The window as it looks now, captured once for both checks below.
            var current: Frame?
            if !sawChange {
                guard let (_, frame) = await capture(scale: Self.comparisonScale) else {
                    keepCue()
                    return
                }
                current = frame
                if let last = lastRecognizedFrame, differs(frame, last, only: [0]) {
                    sawChange = true
                    previous = nil
                    framesKey = nil
                } else if lastRecognizedFrame == nil || OCRClock.now.timeIntervalSince(start) > number("ocrNewLineWait", 1500) / 1000 {
                    sawChange = true
                }
            }
            // The reference for changes once the round ends: the window as it was read, not as it is after (a reading
            // can take a while), so that what changes meanwhile (e.g. the next line appearing as the old one's gone) is
            // still read.
            var readFrame = current
            if readFrame == nil { readFrame = await capture(scale: Self.comparisonScale)?.1 }
            // How the window looked before this reading, to wait for it to change after it (see below).
            let before = sawChange ? readFrame : nil
            let started = OCRClock.now
            guard let image = await captureForReading() else {
                keepCue()
                return
            }
            keptCues = 0
            guard await readAreas(image, areas: read) else {
                // Dropped for a reading again (not after an error, which the page is told about).
                if roundCue == .now, pendingCue != nil { pendingCue = .now }
                return
            }
            lastImage = image
            lastImageFrame = readFrame
            lastImageAreas = read
            if cue == .now {
                log("read as it is")
                otherAreasOutdated = false
                finishReading(image, frame: readFrame, areas: read, started: started, extra: ["now": true])
                return
            }
            let covered = textBlocks(areaLines.first ?? [])
            roundTextBlocks.formUnion(covered)
            nearTextBlocks.formUnion(textBlocks(areaLines.first ?? [], goingOn: true))
            let texts = (areaLines.first ?? []).map { $0["text"] as? String ?? "" }
            let (core, end) = coreAndEnds(texts)
            // Only for new text: the same text read again where an icon next to it was learned says nothing about it.
            if core != textBefore.core { unlearnAnimatedBlocks(covered) }
            let key = texts.map(Self.settleKey).joined(), length = texts.joined().count
            if previous?.key != key {
                previous = (key, started, length)
            } else if let longest = previous?.longest, length > longest {
                previous?.longest = length
            }
            if framesKey != core {
                framesKey = core
                let before = core == textBefore.core ? textBefore.frame : nil
                frames = before.map { [$0] } ?? []
                ends = before != nil ? textBefore.ends.map { [$0] } ?? [] : []
            }
            // As compared with later (see comparisonScale), rather than thumbnails of the image read.
            if let readFrame {
                frames.append(readFrame)
                ends.append(end)
            }
            if sawChange, read == [0] {
                // Still the same text (growing as it's drawn, fading, or read a little differently or in another order),
                // or other text: twice in a row, as one reading may be of a passing effect, or misread.
                let same = fullest.map { OCRText.isLongAndSame($0.key, key) || OCRText.sharesMost($0.key, key) } ?? true
                otherReadings = same ? 0 : otherReadings + 1
                if otherReadings == 1 { otherSince = started }
                var since = started
                if let gone = fullest, otherReadings >= 2 {
                    // It's gone without having settled, though it was on screen long enough to: the fullest reading of it
                    // is taken. Not when it's mostly the text read before the round going away (text that goes on from
                    // that is, as the round before may have ended early).
                    if gone.key.count >= OCRText.shortLength, otherSince.timeIntervalSince(gone.since) >= settleTime * 2,
                       Double(OCRText.commonLength(gone.key, textBefore.key ?? "")) < 2.0 / 3.0 * Double(gone.key.count) {
                        log("replaced before it settled: taking the reading with the most of it")
                        areaLines[0] = gone.lines
                        areaRemoved[0] = gone.removed
                        finishReading(gone.image, frame: gone.frame, areas: [0], started: gone.started, extra: waited.merging(["replaced": true]) { $1 })
                        return
                    }
                    fullest = nil
                    otherReadings = 0
                    // The new text is there since its first reading.
                    since = otherSince
                }
                if otherReadings == 0, key.count >= fullest?.key.count ?? 0 {
                    fullest = (key, areaLines.first ?? [], areaRemoved.first ?? [], image, readFrame, started, fullest?.since ?? since)
                }
            }
            // Preferably on a reading with all the dashes and dots read meanwhile (the next one is taken right away), but
            // not for long: one of them may have been a misreading.
            if sawChange, let previous, started.timeIntervalSince(previous.time) >= settleTime,
               length >= previous.longest || started.timeIntervalSince(previous.time) >= settleTime * 2 {
                log("settled after \(String(format: "%.2f", OCRClock.now.timeIntervalSince(start)))s")
                // What changed while the text stayed the same (e.g. a blinking "next" icon) doesn't count as
                // the window changing later.
                if Self.endsVary(ends) {
                    // With its edges when it's a flickering tail (letters drawn: a glyph's edges spill into the blocks
                    // around it); marks are learned without them, as more often next to text being drawn.
                    learnAnimatedBlocks(from: frames, text: [], nearText: nearTextBlocks.union(roundTextBlocks),
                                        edges: ends.contains { $0.contains("\u{1}") })
                } else {
                    learnAnimatedBlocks(from: frames, text: roundTextBlocks, nearText: nearTextBlocks)
                }
                otherAreasOutdated = false
                finishReading(image, frame: readFrame, areas: read, started: started, extra: waited.merging(["settled": true]) { $1 })
                return
            }
            if OCRClock.now.timeIntervalSince(start) > maxWait {
                log("still changing after \(String(format: "%.2f", maxWait))s")
                otherAreasOutdated = false
                finishReading(image, frame: readFrame, areas: read, started: started, extra: waited)
                return
            }
            sendResult(frame: nil, areas: read, started: started, extra: waited.merging(["provisional": true]) { $1 })
            waited = [:]
            // The same text as the reading before: no reading can settle before the settle time has passed since it was
            // first read, so until then only the picture is watched, to read again as soon as it changes (e.g. the next
            // character drawn). The reading at the end still compares the text, which catches changes too small for the
            // picture to show.
            if let previous, previous.time < started, let before, previous.time.addingTimeInterval(settleTime) > OCRClock.now {
                waited = await waitForChange(from: before, until: previous.time.addingTimeInterval(settleTime))
            }
        }
    }

    /// A line's text as compared to tell whether it's still changing, leaving out what OCR reads inconsistently (see
    /// OCRText): dots and whitespace are dropped (some engines put spaces between words, and a row of dots may be read
    /// on its own or with the text after it, a space between), a run of dashes counts as one, and dashes or the "next"
    /// icon at the end are dropped.
    nonisolated static func settleKey(_ text: String) -> String {
        var key = ""
        var last: Character?
        for character in text where !OCRText.isDot(character) && !character.isWhitespace {
            let mark: Character? = OCRText.isDash(character) ? "—" : nil
            if let mark {
                if last != mark { key.append(mark) }
                last = mark
            } else {
                key.append(character)
                last = character
            }
        }
        while let end = key.last, end == "—" || OCRText.isNextIcon(end) { key.removeLast() }
        return key
    }

    /// The settle key (see settleKey) of a reading's rows without the marks they end with (see OCRText.isEndMark).
    nonisolated static func coreKey(_ texts: [String]) -> String {
        rowCores(texts).joined()
    }

    /// Each row's settle key without the marks it ends with (see coreKey).
    nonisolated static func rowCores(_ texts: [String]) -> [String] {
        texts.map { settleKey(String($0.reversed().drop(while: OCRText.isEndMark).reversed())) }
    }

    /// When the rows `longer` are `shorter` but for one or two characters more at the end of one of them, a letter
    /// among them (and otherwise marks, see OCRText.isEndMark, e.g. an icon read as い after a 」): which row, and those
    /// characters. (Marks alone are end marks; sentence ends and dots that OCR misses at times stay.)
    nonisolated static func tail(of longer: [String], over shorter: [String]) -> (row: Int, text: String)? {
        guard longer.count == shorter.count else { return nil }
        let differing = longer.indices.filter { longer[$0] != shorter[$0] }
        guard differing.count == 1, let row = differing.first, !shorter[row].isEmpty, longer[row].hasPrefix(shorter[row]),
              (1...2).contains(longer[row].count - shorter[row].count) else { return nil }
        let text = String(longer[row].dropFirst(shorter[row].count))
        return text.contains(where: OCRText.isLetter) && text.allSatisfy({ OCRText.isLetter($0) || OCRText.isEndMark($0) }) ? (row, text) : nil
    }

    /// The flickering tail (see flickeringTail) once it went twice.
    private var knownTail: (rows: [String], row: Int, text: String)? {
        flickeringTail.flatMap { $0.gone >= 2 ? ($0.rows, $0.row, $0.text) : nil }
    }

    /// Whether `rows` (see rowCores) are the known tail's rows with it.
    private func hasKnownTail(_ rows: [String]) -> Bool {
        guard let tail = knownTail, let found = Self.tail(of: rows, over: tail.rows) else { return false }
        return found.row == tail.row && found.text == tail.text
    }

    /// The core key (see coreKey) and end marks (see endMarks) of a reading, the known flickering tail moved from the
    /// one to the other.
    private func coreAndEnds(_ texts: [String]) -> (core: String, ends: String) {
        let rows = Self.rowCores(texts), ends = Self.endMarks(texts)
        guard hasKnownTail(rows), let tail = knownTail else { return (rows.joined(), ends) }
        return (tail.rows.joined(), ends + "\u{1}" + tail.text)
    }

    /// Follows the dialogue's rows from reading to reading for a flickering tail (see flickeringTail).
    private func noteTail(_ lines: [[String: Any]]) {
        let rows = Self.rowCores(lines.map { $0["text"] as? String ?? "" })
        defer { lastRowCores = rows }
        if let last = lastRowCores, let gone = Self.tail(of: last, over: rows) {
            if let tail = flickeringTail, tail.rows == rows, tail.row == gone.row, tail.text == gone.text {
                flickeringTail?.gone += 1
            } else {
                flickeringTail = (rows, gone.row, gone.text, 1)
            }
        } else if let tail = flickeringTail, rows != tail.rows,
                  Self.tail(of: rows, over: tail.rows).map({ $0.row == tail.row && $0.text == tail.text }) != true {
            flickeringTail = nil
        }
    }

    /// The dialogue's lines without the known flickering tail where it was learned as animated, for the page.
    private func withoutKnownTail(_ lines: [[String: Any]]) -> [[String: Any]] {
        let texts = lines.map { $0["text"] as? String ?? "" }
        guard hasKnownTail(Self.rowCores(texts)), let tail = knownTail, lines.indices.contains(tail.row) else { return lines }
        var line = Self.decode(lines[tail.row])
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(tail.text) else { return lines }
        line.text = String(text.dropLast(tail.text.count))
        var chars = line.chars
        var left = Substring(tail.text)
        while let last = chars.last, !left.isEmpty {
            if last.text.allSatisfy(\.isWhitespace) {
                chars.removeLast()
            } else if left.hasSuffix(last.text), !last.text.isEmpty {
                left = left.dropLast(last.text.count)
                chars.removeLast()
            } else {
                break
            }
        }
        guard left.isEmpty, let first = chars.first, !line.text.isEmpty else { return lines }
        // Only where the picture changed as it came and went (learned as animated): OCR missing a character that's
        // there now and then (e.g. the last of a row the line goes on from) isn't an icon.
        let gone = line.chars[chars.count...].filter { !$0.text.allSatisfy(\.isWhitespace) }.map { char in
            let center = CGPoint(x: char.box.midX, y: char.box.midY)
            return Self.encode(OCRLayout.Line(text: char.text, box: CGRect(origin: center, size: CGSize(width: 0.1, height: 0.1)),
                                              vertical: line.vertical, chars: []))
        }
        guard let animated = animatedBlocks.first, gone.allSatisfy({ !textBlocks([$0]).isDisjoint(with: animated.keys) }) else {
            return lines
        }
        line.chars = chars
        line.box = chars.dropFirst().reduce(first.box) { $0.union($1.box) }
        var result = lines
        result[tail.row] = Self.encode(line).merging(lines[tail.row].filter { !["text", "x", "y", "width", "height", "chars"].contains($0.key) }) { $1 }
        return result
    }

    /// The marks a reading's rows end with (see OCRText.endMarks), a row's apart from the next's.
    nonisolated static func endMarks(_ texts: [String]) -> String {
        texts.map(OCRText.endMarks).joined(separator: "\n")
    }

    /// Whether the marks the rows ended with, in readings one after another, came and went or changed, rather than
    /// staying or being added to (as the line's last characters drawn).
    nonisolated static func endsVary(_ ends: [String]) -> Bool {
        ends.indices.contains { i in ends[(i + 1)...].contains { !$0.hasPrefix(ends[i]) } }
    }

    /// Waits until `deadline`, or until the dialogue looks different from `frame` (checked at the check interval; any
    /// clear change counts, as a character is often under the minimum, and reading again early costs little), something
    /// else is to be read, or the page took a reading. Returns how long it waited and what ended the wait (a change,
    /// the settle time, or something else), for the page's debug log.
    private func waitForChange(from frame: Frame, until deadline: Date) async -> [String: Any] {
        let interval = number("ocrPollInterval", 500) / 1000
        let start = OCRClock.now
        let waited = { (until: String) -> [String: Any] in
            ["waited": ["ms": Int(OCRClock.now.timeIntervalSince(start) * 1000), "until": until]]
        }
        log("waiting \(Int(deadline.timeIntervalSince(OCRClock.now) * 1000)) ms for a change")
        while OCRClock.now < deadline {
            let check = min(deadline, OCRClock.now.addingTimeInterval(interval))
            while OCRClock.now < check {
                guard !Task.isCancelled, pendingCue == nil, !acceptedReading, isWindowAvailable else { return waited("other") }
                await OCRClock.sleep(for: .milliseconds(20))
            }
            guard OCRClock.now < deadline else { break }
            if let (_, now) = await capture(scale: Self.comparisonScale), differs(now, frame, only: [0], threshold: 0) {
                log("changed while waiting")
                return waited("change")
            }
        }
        return waited("settle time")
    }

    /// The cloud engine (Settings → OCR → Cloud recognition (second pass)), if one is chosen.
    private var cloudEngine: CloudOCR? {
        CloudOCR(rawValue: settings["ocrCloudEngine"] as? String ?? "")
    }

    /// The cloud engine's last reading of the dialogue, with the local engine's text it replaced.
    private var cloudReading: (engine: CloudOCR, localTexts: [String], bounds: CGRect, lines: [[String: Any]], removed: [[String: Any]])?
    /// The local reading a cloud request is on its way for (see finishReading), shown if the request is given up on as
    /// the window changes (see dropCloudRequest).
    private var awaitingCloud: (lines: [[String: Any]], removed: [[String: Any]], areas: [Int], started: Date, extra: [String: Any],
                                roundStart: Date?, bounds: CGRect, reading: Int)?
    /// The cloud engine whose requests fail (e.g. offline), since that was shown: it's shown once, not at each reading.
    private var failingCloudEngine: CloudOCR?
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
    /// cloud engine found nothing are kept. When the cloud engine fails or reads nothing, the local reading is sent
    /// instead; when the dialogue was read again meanwhile, neither is. A local reading with the same text as the one
    /// the last cloud reading replaced gets that cloud reading again right away.
    private func finishReading(_ image: CGImage?, frame: Frame?, areas indices: [Int], started: Date, extra: [String: Any] = [:]) {
        guard let engine = cloudEngine, let image, let frame, let bounds, let local = areaLines.first, !local.isEmpty,
              let crop = image.cropping(to: pixelRect(of: areas[0], in: image)) else {
            sendResult(frame: frame, areas: indices, started: started, extra: extra)
            return
        }
        let localTexts = local.map { $0["text"] as? String ?? "" }
        // Its lines are in window points: only while the window is where it was.
        if let cloudReading, cloudReading.engine == engine, cloudReading.localTexts == localTexts, cloudReading.bounds == bounds {
            areaLines[0] = cloudReading.lines
            areaRemoved[0] = cloudReading.removed
            sendResult(frame: frame, areas: indices, started: started, extra: extra.merging(["cloud": engine.rawValue]) { $1 })
            return
        }
        let localRemoved = areaRemoved[0]
        // The window is compared with what was read now (otherwise the text that's being read would count as a
        // change), and the local text watched for (see noteReading).
        noteReading(frame: frame, areas: indices)
        // Readings of the other areas meanwhile leave the dialogue out.
        areaLines[0] = []
        areaRemoved[0] = []
        let reading = dialogueReadings
        let debugReading = debugReadings
        let language = language
        // Sent after the round ended (see sendResult).
        let roundStart = roundStarted
        cloudTask?.cancel()
        awaitingCloud = (local, localRemoved, indices, started, extra, roundStart, bounds, reading)
        cloudTask = Task { [weak self] in
            let requested = OCRClock.now
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
            guard let self, isCurrent(self) else { return }
            guard let (_, now) = await self.capture(scale: Self.comparisonScale), isCurrent(self), !self.differs(now, frame, only: [0]) else {
                self.log("\(engine.rawValue): dropped, the dialogue may have changed since")
                self.awaitingCloud = nil
                // The dialogue was left out of readings meanwhile: it's read again, rather than when the window is next
                // watched (e.g. after input), as it is if that's what the page waits for.
                guard !Task.isCancelled, reading == self.dialogueReadings else { return }
                if extra["now"] as? Bool == true {
                    self.pendingCue = .now
                } else if self.pendingCue == nil {
                    self.pendingCue = .retry
                    self.watchUntil = max(self.watchUntil, OCRClock.now.addingTimeInterval(self.watchTime))
                }
                return
            }
            var (lines, removed, extra) = (local, localRemoved, extra)
            extra["roundAge"] = roundStart.map { OCRClock.now.timeIntervalSince($0) } ?? 0
            var failure: Error?
            switch result {
            case let .success(items):
                self.log("\(engine.rawValue): \(String(format: "%.2f", OCRClock.now.timeIntervalSince(requested)))s for \(crop.width)x\(crop.height)")
                if self.failingCloudEngine == engine { self.failingCloudEngine = nil }
                if debugReading == self.debugReadings { self.saveForDebugging(items, area: 0, engine: "-\(engine.rawValue)") }
                // Both engines' boxes are where the words are: Google Lens' are the reference the local engines' are
                // measured against, and Bing's are a cloud version of OneOCR's.
                let cloud = self.lines(from: items, in: crop, area: 0, bounds: bounds, exactBoxes: true)
                // It may miss text the local engine read, but not all of it.
                if !cloud.lines.isEmpty {
                    // Marked for the overlay's outlines (shown with Settings → General → Debug on).
                    let cloudLines = cloud.lines.map { line in line.merging(["cloud": true]) { $1 } }
                    (lines, removed) = (Self.adding(local, to: cloudLines), cloud.removed)
                    self.cloudReading = (engine, localTexts, bounds, lines, removed)
                    extra["cloud"] = engine.rawValue
                }
            case let .failure(error):
                failure = error
            }
            self.awaitingCloud = nil
            self.areaLines[0] = lines
            self.areaRemoved[0] = removed
            self.sendResult(frame: nil, areas: indices, started: started, extra: extra)
            // After the local reading, which the page may be waiting for (see readOcrNow in web/src/overlay.js).
            if let failure {
                // (Its message starts with the engine's name.)
                self.log("\(failure)")
                if self.failingCloudEngine != engine {
                    self.failingCloudEngine = engine
                    self.send(["type": "error", "message": failure.localizedDescription])
                }
            }
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
        return inParagraphs(cloud + missing, line: decode) { $0 }
    }

    /// A cloud reading on its way is dropped, and the last one isn't reused.
    private func forgetCloudReading() {
        dropCloudRequest()
        cloudReading = nil
    }

    /// The dialogue may change: a cloud reading on its way is dropped.
    private func dropCloudRequest(showingLocal: Bool = false) {
        // Only while its boxes are where the text is (and the areas as they were read).
        if showingLocal, let held = awaitingCloud, held.reading == dialogueReadings, held.bounds == bounds, areaLines.count == areas.count {
            log("cloud request given up on: the local reading is shown")
            areaLines[0] = held.lines
            areaRemoved[0] = held.removed
            sendResult(frame: nil, areas: held.areas, started: held.started,
                       extra: held.extra.merging(["roundAge": held.roundStart.map { OCRClock.now.timeIntervalSince($0) } ?? 0]) { $1 })
        }
        awaitingCloud = nil
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
            // Until a reading shows which (e.g. while there's too little text to tell), at full resolution.
            checkScale = Self.captureScale > 1 && readingScale == nil
            scale = checkScale ? Self.captureScale : readingScale ?? Self.captureScale
        }
        guard let image = await captureImage(scale: scale) else { return nil }
        if checkScale, let detail = GrayImage(image)?.hasFineDetail {
            readingScale = detail ? Self.captureScale : 1
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

    /// Where an area is in a captured image (of `capturedPart`), in pixels. The image may be a pixel or so short of
    /// `capturedPart` on the right and bottom (see evenPixels): what's beyond it is cropped off.
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
        let started = OCRClock.now
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
                if savesDebugPictures, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, crop, nil)
                    CGImageDestinationFinalize(destination)
                }
                log(savesDebugPictures ? "saved \(url.lastPathComponent)" : "read read-\(debugReadings)-area\(index)")
            }
            let items: [RecognizedLine]
            let recognizeStarted = OCRClock.now
            do {
                items = try await recognizeText(crop)
                log("\(engine.rawValue): \(String(format: "%.2f", OCRClock.now.timeIntervalSince(recognizeStarted)))s for \(crop.width)x\(crop.height)")
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
            let layoutStarted = OCRClock.now
            (areaLines[index], areaRemoved[index]) = lines(from: items, in: crop, area: index, bounds: bounds, exactBoxes: engine.hasExactBoxes)
            if index == 0 { noteTail(areaLines[0]) }
            log("layout: \(String(format: "%.2f", OCRClock.now.timeIntervalSince(layoutStarted)))s")
        }
        return true
    }

    /// With MACPOPUP_DEBUG_OCR_DIR, what an engine read in an area, before the layout (boxes normalized to the crop).
    private func saveForDebugging(_ items: [RecognizedLine], area index: Int, engine suffix: String = "") {
        guard let debugDirectory else { return }
        let rect = { (box: CGRect) in [box.minX, box.minY, box.width, box.height] }
        let raw = items.map { line -> [String: Any] in
            var item: [String: Any] = ["text": line.text, "box": rect(line.box), "words": line.words.map { [$0.text] + rect($0.box).map { $0 as Any } }]
            item["corners"] = line.savedCorners
            return item
        }
        let url = URL(fileURLWithPath: debugDirectory).appendingPathComponent("read-\(debugReadings)-area\(index)\(suffix).json")
        try? JSONSerialization.data(withJSONObject: raw).write(to: url)
    }

    /// The lines an engine read in an area's picture (`crop`), as the page gets them (in reading order, see
    /// OCRLayout.inParagraphs), and the lines left out (by the language or as furigana) for its debug log.
    /// - Parameter exactBoxes: The engine's boxes for words are where they are (see OCRLayout.layOut).
    private func lines(
        from items: [RecognizedLine], in crop: CGImage, area index: Int, bounds: CGRect, exactBoxes: Bool = false
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
        // The lines left out, for the page's debug log (with Settings → General → Debug on).
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
        let encoded = Self.inParagraphs(lines, line: { $0 }) { line in
            var encoded = Self.encode(line)
            encoded["area"] = index
            return encoded
        }
        return (encoded, removed)
    }

    /// Sends what `readAreas` read to the page.
    /// - Parameters:
    ///   - frame: The low resolution frame the reading was taken after, the reference for changes.
    ///   - extra: More for the page: "provisional" for a reading while the text may still change (shown,
    ///     but only taken as the dialogue's if it matches the WebSocket line, see settleAndRecognize),
    ///     "settled" for one of text that stopped changing.
    private func sendResult(frame: Frame?, areas indices: [Int], started: Date, extra: [String: Any] = [:]) {
        guard let bounds else { return }
        let lines = areaLines.enumerated().flatMap { $0.offset == 0 ? withoutKnownTail($0.element) : $0.element }
        var result: [String: Any] = [
            "type": "result",
            "lines": lines,
            "removed": areaRemoved.flatMap { $0 },
            // Whether the dialogue was read (the page checks it against the WebSocket line), or only others.
            "dialogue": indices.contains(0),
            "elapsed": OCRClock.now.timeIntervalSince(started),
            // How long ago the text began to change, for Anki Audio.
            "roundAge": roundStarted.map { OCRClock.now.timeIntervalSince($0) } ?? 0,
            "width": bounds.width,
            "height": bounds.height,
        ]
        result.merge(extra) { $1 }
        log("read \(lines.count) lines in \(String(format: "%.2f", OCRClock.now.timeIntervalSince(started)))s\(extra.isEmpty ? "" : " \(extra.keys.sorted())")")
        send(result)
        if extra["provisional"] as? Bool == true { return }
        lastResult = result
        noteReading(frame: frame, areas: indices)
    }

    /// The window is compared with `frame` for changes from now on, and the dialogue watched for a while if it was read.
    private func noteReading(frame: Frame?, areas indices: [Int]) {
        updateReference(frame, areas: indices)
        guard indices.contains(0) else { return }
        continuationRects = continuationRects(areaLines.first ?? [])
        // Only when its text changed: a line may still be being drawn then, while an animation behind the same text
        // (more than is learned as animated spots) would otherwise keep the window watched for good.
        let texts = (areaLines.first ?? []).map { $0["text"] as? String ?? "" }
        guard texts != watchedTexts else { return }
        watchedTexts = texts
        continuationRereads = 0
        watchUntil = OCRClock.now.addingTimeInterval(watchTime)
    }

    /// What reads the text (Settings → OCR → Text recognition engine).
    enum Engine: String {
        case liveText
        case meikiocr
        case screenAI = "screenai"
        case oneOCR = "oneocr"
        case ppocrManga = "ppocrmanga"
        case midaVOCR6 = "midavocr6"

        /// Whether its boxes for words are where they are: Live Text's are often a cell off, so its lines are snapped to
        /// their cells (see OCRLayout.layOut).
        var hasExactBoxes: Bool { self != .liveText }

        /// As Settings shows it.
        var name: String {
            switch self {
            case .liveText: "Live Text"
            case .meikiocr: "meikiocr"
            case .screenAI: "Screen AI"
            case .oneOCR: "OneOCR"
            case .ppocrManga: "PP-OCRv6 Manga"
            case .midaVOCR6: "mida + VOCR6"
            }
        }
    }

    /// The engine when OCR started or it last changed.
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

    /// The language, stripsFurigana and cloud engine when OCR started or they last changed.
    private var startedLanguage: String?
    private var startedStripsFurigana: Bool?
    private var startedCloudEngine: CloudOCR??

    private func recognizeText(_ image: CGImage) async throws -> [RecognizedLine] {
        if let simulation = Simulation.shared {
            return try await simulation.recognize(image, engine: "\(engine) \(language) \(languages)") { try await recognizeEngine(image) }
        }
        return try await recognizeEngine(image)
    }

    private func recognizeEngine(_ image: CGImage) async throws -> [RecognizedLine] {
        switch engine {
        case .liveText:
            try await Self.recognizeText(image, locales: languages).map(RecognizedLine.init)
        case .meikiocr:
            try await MeikiOCR.shared.recognize(image)
        case .screenAI:
            try await ScreenAIOCR.shared.recognize(image, language: language)
        case .oneOCR:
            try await OneOCROCR.shared.recognize(image)
        case .ppocrManga:
            try await PPOCRManga.shared.recognize(image)
        case .midaVOCR6:
            try await MidaVOCR6.shared.recognize(image)
        }
    }

    /// The engine whose models are loading, saved until they've loaded (see guardLoading).
    private static let loadingKey = "ocrEngineLoading"
    /// The engines that run on the CPU since they crashed MacPopup while loading on the GPU, with the macOS version
    /// then.
    private static let onCPUKey = "ocrEnginesOnCPU"
    /// What guardLoading did, shown again once the page has loaded: at launch, it may not have yet.
    private var crashNotice: String?

    /// Loading an engine's models can crash MacPopup (on macOS 27, PP-OCRv6 Manga's detector made Apple's GPU code
    /// abort), and since the engine loads as OCR starts, it would crash at every launch. So the engine is saved
    /// while it loads: if it's still saved at the next warm-up, it crashed, and it's loaded on the CPU from then on
    /// (until macOS is updated; every engine with models can run there); if it did so on the CPU too, OCR switches
    /// to Live Text. Returns false when the engine is switched.
    private func guardLoading(_ engine: Engine) -> Bool {
        let defaults = SettingsStore.shared.defaults
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        var onCPU = (defaults.dictionary(forKey: Self.onCPUKey) as? [String: String] ?? [:]).filter { $0.value == system }
        if let crashed = defaults.dictionary(forKey: Self.loadingKey), crashed["engine"] as? String == engine.rawValue {
            defaults.removeObject(forKey: Self.loadingKey)
            if crashed["cpu"] as? Bool != true {
                onCPU[engine.rawValue] = system
                showCrashNotice("\(engine.name) crashed MacPopup while loading, so it now runs on the CPU, which is slower.")
            } else {
                SettingsStore.shared.update(["ocrEngine": Engine.liveText.rawValue])
                showCrashNotice("\(engine.name) crashed MacPopup while loading, so OCR now uses Live Text.")
                return false
            }
        }
        defaults.set(onCPU, forKey: Self.onCPUKey)
        OCRCompute.cpuOnly = onCPU[engine.rawValue] != nil
        defaults.set(["engine": engine.rawValue, "cpu": OCRCompute.cpuOnly], forKey: Self.loadingKey)
        return true
    }

    private func showCrashNotice(_ message: String) {
        crashNotice = message
        send(["type": "error", "message": message])
    }

    /// The first reading takes longer (Live Text's by about a second, the others load their models), so the engine is
    /// prepared before the window needs reading.
    private func warmUp() async {
        let started = OCRClock.now
        let engine = engine
        func prepare(_ body: () async throws -> Void) async {
            guard guardLoading(engine) else { return }
            do {
                try await body()
            } catch {
                send(["type": "error", "message": error.localizedDescription])
            }
            SettingsStore.shared.defaults.removeObject(forKey: Self.loadingKey)
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
        case .midaVOCR6:
            await prepare(MidaVOCR6.shared.prepare)
        }
        log("\(engine.rawValue) ready in \(String(format: "%.2f", OCRClock.now.timeIntervalSince(started)))s")
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
                    continuation.resume(throwing: error ?? AppError("Live Text recognition failed"))
                }
            }
        }
    }

    /// Items for the page in reading order (see OCRLayout.paragraphs), encoded by `encode`, each with its paragraph's
    /// number and, when it's turned, how (see OCRLayout.Line.turn): the page draws a turned line turned, and groups
    /// turned lines by their paragraphs, since their upright boxes don't show which rows go on from one another.
    private static func inParagraphs<Item>(
        _ items: [Item], line: (Item) -> OCRLayout.Line, encode: (Item) -> [String: Any]
    ) -> [[String: Any]] {
        OCRLayout.paragraphs(items, line: line).enumerated().flatMap { number, paragraph in
            paragraph.items.map { item -> [String: Any] in
                var encoded = encode(item)
                encoded["paragraph"] = number
                encoded["turn"] = line(item).turn(paragraphTilt: paragraph.tilt).map { turn -> [String: Any] in
                    ["angle": turn.angle, "box": [turn.box.minX, turn.box.minY, turn.box.width, turn.box.height]]
                }
                return encoded
            }
        }
    }

    /// A line as the page gets it, as a layout line: a turned one's corners are its turned-back box turned back again.
    private static func decode(_ line: [String: Any]) -> OCRLayout.Line {
        let rect = { (values: [Any]) in
            let numbers = values.map { $0 as? CGFloat ?? 0 }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        let corners = (line["turn"] as? [String: Any]).flatMap { turn -> [CGPoint]? in
            guard let angle = turn["angle"] as? CGFloat, let values = turn["box"] as? [Any], values.count == 4 else { return nil }
            let box = rect(values)
            let (c, s) = (cos(angle), sin(angle))
            return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map { point in
                let (x, y) = (point.x - box.midX, point.y - box.midY)
                return CGPoint(x: box.midX + x * c - y * s, y: box.midY + x * s + y * c)
            }
        }
        return OCRLayout.Line(
            text: line["text"] as? String ?? "",
            box: rect([line["x"] as Any, line["y"] as Any, line["width"] as Any, line["height"] as Any]),
            vertical: line["vertical"] as? Bool ?? false,
            chars: (line["chars"] as? [[Any]] ?? []).filter { $0.count == 5 }.map {
                OCRLayout.Char(text: $0[0] as? String ?? "", box: rect(Array($0[1...])))
            },
            corners: corners
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
        guard let image = await captureImage(scale: scale), let (thumbnails, widths) = thumbnails(of: image) else { return nil }
        return (image, Frame(thumbnails: thumbnails, widths: widths))
    }

    /// The capture of `capture(scale:)`, without thumbnails (for reading it).
    private func captureImage(scale: CGFloat) async -> CGImage? {
        do {
            guard let image = try await captureImage(part: capturedPart, scale: scale) else { return nil }
            captureFailures = 0
            return image
        } catch {
            log("capture failed: \(error)")
            // A single failure can happen while windows change (e.g. switching spaces); report it
            // only if it keeps failing.
            captureFailures += 1
            // Not reported for the Floating Window, which keeps reading even when the window can't be captured (e.g.
            // while minimized).
            if captureFailures == 3, showsOverlay {
                send(["type": "error", "message": "Screen capture failed: \(error.localizedDescription)"])
            }
            scWindow = nil
            await OCRClock.sleep(for: .seconds(1))
            return nil
        }
    }

    /// Captures `part` of the window (normalized to its bounds) at `scale` pixels per point, as described
    /// for `capture(scale:)`. Nil when the window isn't known.
    private func captureImage(part: CGRect, scale: CGFloat) async throws -> CGImage? {
        guard let bounds else { return nil }
        if let simulation = Simulation.shared {
            let (rect, width, height) = Self.evenPixels(Self.partRect(part, of: bounds), scale: scale)
            return await simulation.capture(rect, windowSize: bounds.size, width: width, height: height, forReading: scale != Self.comparisonScale)
        }
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
            let (partRect, width, height) = Self.evenPixels(Self.partRect(part, of: bounds), scale: scale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = partRect
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            if let image = await streamImage(for: scale, filter, configuration, key: "screen \(scDisplay.displayID) \(bounds) \(part) \(scale)") {
                return image
            }
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
        let (filter, configuration) = Self.captureSetup(scWindow, display: scDisplay, bounds: bounds, part: part, scale: scale)
        if let image = await streamImage(for: scale, filter, configuration, key: "window \(scWindow.windowID) \(bounds) \(part) \(scale)") {
            return image
        }
        return try await ScreenCapture.image(filter: filter, configuration: configuration)
    }

    /// The latest picture of a stream (see CaptureStream) of what the checks for changes capture, or of what's read:
    /// screenshots now and then take a whole second, and a stream's picture is there at once. The checks' stream is
    /// started by the first check and stopped a second after the last (see trackWindow), or when what's captured
    /// changes; the readings' only runs along with it. Nil, for a screenshot instead (as for Anki's screenshots), until
    /// its first picture comes, and for a while after it failed.
    private func streamImage(for scale: CGFloat, _ filter: SCContentFilter, _ configuration: SCStreamConfiguration, key: String) async -> CGImage? {
        let use: StreamUse = scale == Self.comparisonScale ? .comparison : .reading
        let name = use == .comparison ? "capture stream" : "reading stream"
        if use == .comparison { lastComparison = OCRClock.now }
        if let stream = streams[use], stream.key == key {
            if !stream.hasStopped {
                guard use == .reading else { return stream.latest }
                let picture = await readingPicture(stream)
                if picture == nil { readingScreenshots += 1 } else { readingsFromStream += 1 }
                return picture
            }
            log("\(name) stopped" + (stream.stopError.map { ": \($0)" } ?? ""))
            streamRetryAt[use] = OCRClock.now.addingTimeInterval(2)
        }
        stopStream(use)
        guard OCRClock.now >= streamRetryAt[use] ?? .distantPast, !startingStreams.contains(use),
              use == .comparison || streams[.comparison] != nil else { return nil }
        startingStreams.insert(use)
        defer { startingStreams.remove(use) }
        // Pictures as often as the loop checks at most (only when it changed), so they lag behind by little.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        do {
            let stream = try CaptureStream(filter: filter, configuration: configuration, key: key)
            try await stream.start()
            // OCR may have stopped meanwhile (then nothing would stop the stream).
            guard isEnabled, !Task.isCancelled else {
                stream.stop()
                return nil
            }
            streams[use] = stream
            log("\(name) started")
        } catch {
            log("\(name) failed: \(error)")
            streamRetryAt[use] = OCRClock.now.addingTimeInterval(10)
        }
        // Its first picture comes a moment later: a screenshot until then.
        if use == .reading, streams[use] != nil { readingScreenshots += 1 }
        return use == .comparison ? streams[use]?.latest : nil
    }

    /// The readings' stream's picture, once it's at least as recent as the last the checks for changes saw (the two
    /// streams send theirs separately), waiting for one at most a tenth of a second. Nil, for a screenshot instead,
    /// if none comes, or if it hasn't sent any (a window that isn't on screen, e.g. moved off it or minimized, isn't
    /// streamed, though screenshots of it may still work).
    private func readingPicture(_ stream: CaptureStream) async -> CGImage? {
        guard stream.latestTime != 0 else { return nil }
        let seen = streams[.comparison]?.latestTime ?? 0
        let deadline = OCRClock.now.addingTimeInterval(0.1)
        while stream.latestTime < seen {
            guard OCRClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return stream.latestCopy
    }

    private func stopStream(_ use: StreamUse) {
        guard let stream = streams.removeValue(forKey: use) else { return }
        stream.stop()
        if use == .comparison {
            log("capture stream ended (\(stream.frameCount) pictures)")
        } else {
            log("reading stream ended (\(stream.frameCount) pictures; \(readingsFromStream) readings from it, \(readingScreenshots) as screenshots)")
            readingsFromStream = 0
            readingScreenshots = 0
        }
    }

    private func stopStreams() {
        stopStream(.reading)
        stopStream(.comparison)
    }

    /// `rect` (in points) made a little smaller where needed to be an even number of pixels each way at `scale`, with
    /// those numbers. A stream (see CaptureStream) of an odd width or height sends nothing (screenshots don't mind, and
    /// take the same size so that both can be compared); a size rounded without the rectangle would scale the picture,
    /// blurring it a little.
    private static func evenPixels(_ rect: CGRect, scale: CGFloat) -> (rect: CGRect, width: Int, height: Int) {
        let width = max(2, Int(rect.width * scale) / 2 * 2), height = max(2, Int(rect.height * scale) / 2 * 2)
        return (CGRect(x: rect.minX, y: rect.minY, width: CGFloat(width) / scale, height: CGFloat(height) / scale), width, height)
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
        let (filter, configuration) = captureSetup(scWindow, display: scDisplay, bounds: bounds, part: part, scale: scale)
        return try await ScreenCapture.image(filter: filter, configuration: configuration)
    }

    /// What `captureWindow` captures.
    private static func captureSetup(
        _ scWindow: SCWindow, display scDisplay: SCDisplay?, bounds: CGRect, part: CGRect, scale: CGFloat
    ) -> (SCContentFilter, SCStreamConfiguration) {
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        // In window points.
        let (partRect, width, height) = evenPixels(Self.partRect(part, of: bounds), scale: scale)
        if let scDisplay {
            filter = SCContentFilter(display: scDisplay, including: [scWindow])
            configuration.sourceRect = partRect.offsetBy(dx: bounds.minX - scDisplay.frame.minX, dy: bounds.minY - scDisplay.frame.minY)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.sourceRect = partRect
        }
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        return (filter, configuration)
    }

    /// The captured window (Settings → General), whole, at its display's resolution or at 1x, for the
    /// `{screenshot}` Anki marker: only that window, without other windows in front of it or the overlay.
    /// Also when OCR is off. Nil when no window is set or it isn't on screen.
    func windowScreenshot(fullResolution: Bool) async throws -> CGImage? {
        guard let saved = settings["ocrWindow"] as? [String: Any], let ownerName = saved["ownerName"] as? String else { return nil }
        let title = saved["title"] as? String ?? ""
        let windows = Self.windows(onScreenOnly: true).filter { $0.ownerName == ownerName }
        let match = windows.first { $0.id == target?.windowID } ?? windows.first { $0.title == title } ?? windows.first { $0.layer == 0 }
            ?? windows.first
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
        guard let bounds else { return nil }
        var result: [[UInt8]] = []
        var widths: [Int] = []
        for area in areas {
            guard let crop = image.cropping(to: pixelRect(of: area, in: image)) else { return nil }
            let pointSize = CGSize(width: area.width * bounds.width, height: area.height * bounds.height)
            let factor = Self.thumbnailLongSide / max(pointSize.width, pointSize.height, 1)
            let width = max(1, Int(pointSize.width * factor)), height = max(1, Int(pointSize.height * factor))
            if let pixels = GrayImage.scaledCapture(crop, width: width, height: height) {
                result.append(pixels)
                widths.append(width)
                continue
            }
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
        lastRecognizedFrame = reference
    }

    private static let block = 8
    /// How many gray levels a thumbnail pixel must differ by to count as changed.
    private static let clearChange = 40
    /// The thumbnails' long side, in pixels (see thumbnails).
    private static let thumbnailLongSide: CGFloat = 320

    /// How many pixels of two thumbnails of an area are drawn on its background in either: clearly lighter or darker
    /// than the commonest shade of each.
    private static func drawnPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        func background(_ pixels: [UInt8]) -> Int {
            var counts = [Int](repeating: 0, count: 256)
            for value in pixels { counts[Int(value)] += 1 }
            return counts.indices.max { counts[$0] < counts[$1] } ?? 0
        }
        let (first, second) = (background(a), background(b))
        var drawn = 0
        for index in a.indices where abs(Int(a[index]) - first) > Self.clearChange || abs(Int(b[index]) - second) > Self.clearChange {
            drawn += 1
        }
        return drawn
    }

    /// The blocks of each thumbnail (`block` pixels square) in which `a` and `b` differ in detail (one
    /// character of text drawn changes a few dense blocks). Noise spread thinly is ignored, and so are
    /// faint changes, like the end of a character's fade-in (a game's text can take half a second to
    /// reach full brightness).
    /// - Parameter only: The areas to compare (the others count as unchanged), or all.
    /// - Parameter edges: Also the blocks next to them where fewer pixels changed (an icon's edges, which would add up
    ///   to a change otherwise).
    private func changedBlocks(_ a: Frame, _ b: Frame, only: [Int]? = nil, edges: Bool = false) -> [Set<Int>]? {
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
                    guard abs(Int(x[index]) - Int(y[index])) > Self.clearChange else { continue }
                    let cell = (row / block) * columns + column / block
                    counts[cell] += 1
                    if counts[cell] == 5 { changed.insert(cell) }
                }
            }
            if edges {
                for cell in counts.indices where counts[cell] > 0 && !changed.contains(cell) {
                    let row = cell / columns, column = cell % columns
                    let near = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)].contains { dy, dx in
                        let r = row + dy, c = column + dx
                        return r >= 0 && c >= 0 && c < columns && changed.contains(r * columns + c)
                    }
                    if near { changed.insert(cell) }
                }
            }
            result.append(changed)
        }
        return result
    }

    /// Learns the spots that changed while the text stayed the same (e.g. a blinking "next" icon) and their looks,
    /// so that later they don't count as the window changing while they look as they did. Not where the dialogue's
    /// text was read (`text`, see textBlocks): text that moves while it's read the same would be learned otherwise.
    /// A spot with more looks than are kept is left out whatever it looks like (see AnimatedBlock), for a while, but
    /// not near the text (`nearText`: where the previous text was, or where the text would go on), nor when there
    /// are many (that's an animated background, not an icon).
    /// - Parameter edges: With the edges of what changed (see changedBlocks).
    private func learnAnimatedBlocks(from frames: [Frame], text: Set<Int>, nearText: Set<Int>, edges: Bool = false) {
        guard frames.count > 1, let first = frames.first else { return }
        var found = first.thumbnails.map { _ in Set<Int>() }
        for (a, b) in zip(frames, frames.dropFirst()) {
            // Only the dialogue is read until settled; the other areas are read whenever they change.
            guard let changed = changedBlocks(a, b, only: [0], edges: edges) else { return }
            for (area, blocks) in changed.enumerated() { found[area].formUnion(blocks) }
        }
        if !found.isEmpty { found[0].subtract(text) }
        if animatedBlocks.count != found.count { animatedBlocks = found.map { _ in [:] } }
        let now = OCRClock.now
        for (area, blocks) in found.enumerated() where !blocks.isEmpty {
            let width = first.widths[area], height = first.thumbnails[area].count / max(width, 1)
            let total = ((width + Self.block - 1) / Self.block) * ((height + Self.block - 1) / Self.block)
            var ignored = animatedBlocks[area].values.filter { $0.isIgnored(at: now) }.count
            var (added, newlyIgnored) = (0, 0)
            // In order, so that which are left out when there are more than may be is the same each time.
            for index in blocks.sorted() {
                var block = animatedBlocks[area][index] ?? AnimatedBlock()
                if block.looks.isEmpty { added += 1 }
                // Looks not seen for a while (e.g. another scene's) make room.
                block.looks.removeAll { now.timeIntervalSince($0.seen) > 30 }
                var overflowed = false
                for frame in frames where frame.widths == first.widths {
                    let pixels = Self.blockPixels(frame.thumbnails[area], width: width, block: index)
                    if let same = block.looks.firstIndex(where: { Self.looksAlike($0.pixels, pixels) }) {
                        block.looks[same].seen = now
                    } else {
                        block.looks.append((pixels, now))
                        if block.looks.count > Self.animatedLooks {
                            block.looks.removeFirst()
                            overflowed = true
                        }
                    }
                }
                if overflowed, !block.isIgnored(at: now), !nearText.contains(index),
                   Double(ignored + 1) <= Double(total) * 0.1 {
                    block.ignoredUntil = now.addingTimeInterval(Self.animatedIgnoreTime)
                    ignored += 1
                    newlyIgnored += 1
                }
                animatedBlocks[area][index] = block
            }
            if added > 0 || newlyIgnored > 0 {
                log("learned \(animatedBlocks[area].count) animated blocks (\(added) new), \(ignored) left out for \(Int(Self.animatedIgnoreTime))s")
            }
        }
    }

    /// The pixels of thumbnail block `block` (see changedBlocks), row by row.
    private static func blockPixels(_ thumbnail: [UInt8], width: Int, block: Int) -> [UInt8] {
        let size = Self.block, columns = (width + size - 1) / size, height = thumbnail.count / max(width, 1)
        let x = (block % columns) * size, y = (block / columns) * size
        var pixels: [UInt8] = []
        pixels.reserveCapacity(size * size)
        for row in y..<min(y + size, height) {
            pixels.append(contentsOf: thumbnail[(row * width + x)..<(row * width + min(x + size, width))])
        }
        return pixels
    }

    /// Whether two looks of a block are the same: too few pixels differ clearly for the block to count as changed (see
    /// changedBlocks).
    private static func looksAlike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var different = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > Self.clearChange {
            different += 1
            if different >= 5 { return false }
        }
        return true
    }

    /// For an area of `frame`, whether a change in a block is animation, to be left out (see AnimatedBlock): the block
    /// is left out whatever it looks like for now, or looks as it was seen before. Each block is looked at once.
    private func animation(in frame: Frame, area: Int) -> (Int) -> Bool {
        guard area < animatedBlocks.count, !animatedBlocks[area].isEmpty, area < frame.widths.count else { return { _ in false } }
        let now = OCRClock.now, width = frame.widths[area], thumbnail = frame.thumbnails[area]
        var decided: [Int: Bool] = [:]
        return { [self] index in
            if let known = decided[index] { return known }
            var result = false
            if let block = animatedBlocks[area][index] {
                if block.isIgnored(at: now) {
                    result = true
                } else {
                    let pixels = Self.blockPixels(thumbnail, width: width, block: index)
                    if let same = block.looks.firstIndex(where: { Self.looksAlike($0.pixels, pixels) }) {
                        animatedBlocks[area][index]?.looks[same].seen = now
                        result = true
                    }
                }
            }
            decided[index] = result
            return result
        }
    }

    /// Text was read on `blocks` (see textBlocks): they aren't animated after all, they change with the text.
    private func unlearnAnimatedBlocks(_ blocks: Set<Int>) {
        guard let animated = animatedBlocks.first, !blocks.isDisjoint(with: animated.keys) else { return }
        animatedBlocks[0] = animated.filter { !blocks.contains($0.key) }
        log("unlearned \(animated.count - animatedBlocks[0].count) animated blocks: text was read there")
    }

    /// The blocks of the dialogue's thumbnails (see thumbnails and changedBlocks) that `lines` (as sent to the
    /// page, in window points) are on, and those around them.
    /// - Parameter goingOn: Also the blocks where they would go on (see continuationRects).
    private func textBlocks(_ lines: [[String: Any]], goingOn: Bool = false) -> Set<Int> {
        guard let bounds, let area = areas.first, !lines.isEmpty else { return [] }
        let pointSize = CGSize(width: area.width * bounds.width, height: area.height * bounds.height)
        let factor = Self.thumbnailLongSide / max(pointSize.width, pointSize.height, 1)
        let width = max(1, Int(pointSize.width * factor)), height = max(1, Int(pointSize.height * factor))
        let block = Self.block, columns = (width + block - 1) / block, rows = (height + block - 1) / block
        let origin = CGPoint(x: area.minX * bounds.width, y: area.minY * bounds.height)
        var blocks = Set<Int>()
        let rects = lines.compactMap { line -> CGRect? in
            let decoded = Self.decode(line)
            var box = decoded.box
            // Leave out a symbol at the end (the page's "next" icon), so its blinking can be learned as animation.
            let chars = decoded.chars
            let kept = chars.reversed().drop { $0.text.allSatisfy(OCRText.isNextIcon) }
            if !chars.isEmpty, kept.count < chars.count {
                guard let first = kept.first else { return nil }
                box = kept.dropFirst().reduce(first.box) { $0.union($1.box) }
            }
            return CGRect(x: (box.minX - origin.x) * factor, y: (box.minY - origin.y) * factor,
                          width: box.width * factor, height: box.height * factor)
        } + (goingOn ? continuationRects(lines) : [])
        for rect in rects.map({ $0.insetBy(dx: -CGFloat(block) / 2, dy: -CGFloat(block) / 2) }) {
            let firstColumn = max(0, Int(rect.minX) / block), lastColumn = min(columns - 1, Int(rect.maxX) / block)
            let firstRow = max(0, Int(rect.minY) / block), lastRow = min(rows - 1, Int(rect.maxY) / block)
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn { blocks.insert(row * columns + column) }
            }
        }
        return blocks
    }

    /// Where `lines` (as sent to the page, in window points) would go on, in the dialogue's thumbnail pixels (see
    /// continuationRects).
    private func continuationRects(_ lines: [[String: Any]]) -> [CGRect] {
        guard let bounds, let area = areas.first, !lines.isEmpty else { return [] }
        let pointSize = CGSize(width: area.width * bounds.width, height: area.height * bounds.height)
        let factor = Self.thumbnailLongSide / max(pointSize.width, pointSize.height, 1)
        let origin = CGPoint(x: area.minX * bounds.width, y: area.minY * bounds.height)
        let boxes = lines.map { line -> (rect: CGRect, vertical: Bool) in
            let value = { (key: String) in line[key] as? CGFloat ?? 0 }
            let rect = CGRect(x: (value("x") - origin.x) * factor, y: (value("y") - origin.y) * factor,
                              width: value("width") * factor, height: value("height") * factor)
            return (rect, line["vertical"] as? Bool ?? false)
        }
        var rects: [CGRect] = []
        // A character's room after each line's end (its size is about the line's thickness).
        for (rect, vertical) in boxes {
            let size = vertical ? rect.width : rect.height
            rects.append(vertical ? CGRect(x: rect.minX, y: rect.maxY, width: size, height: size)
                                  : CGRect(x: rect.maxX, y: rect.minY, width: size, height: size))
        }
        // Where a line after the last one would start: below it (to its left for vertical text), one and a half
        // lines' room.
        let vertical = boxes.filter(\.vertical).count * 2 > boxes.count
        if let (last, _) = vertical ? boxes.min(by: { $0.rect.minX < $1.rect.minX }) : boxes.max(by: { $0.rect.maxY < $1.rect.maxY }) {
            let size = vertical ? last.width : last.height
            rects.append(vertical ? CGRect(x: last.minX - size * 1.5, y: last.minY, width: size * 1.5, height: size)
                                  : CGRect(x: last.minX, y: last.maxY, width: size, height: size * 1.5))
        }
        return rects
    }

    /// Whether the dialogue's text seems to go on where it was read (see continuationRects): a few pixels there
    /// changed clearly since `reference`, outside spots known to be animated.
    private func textContinues(_ frame: Frame, _ reference: Frame) -> Bool {
        guard continuationRereads < 3, !continuationRects.isEmpty, let x = frame.thumbnails.first, let y = reference.thumbnails.first,
              let width = frame.widths.first, x.count == y.count, width > 0, width == reference.widths.first else { return false }
        let height = x.count / width, block = Self.block, columns = (width + block - 1) / block
        let animated = animation(in: frame, area: 0)
        for rect in continuationRects {
            let firstColumn = max(0, Int(rect.minX.rounded(.down))), lastColumn = min(width - 1, Int(rect.maxX.rounded(.up)))
            let firstRow = max(0, Int(rect.minY.rounded(.down))), lastRow = min(height - 1, Int(rect.maxY.rounded(.up)))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            var changed = 0
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    let index = row * width + column
                    guard abs(Int(x[index]) - Int(y[index])) > Self.clearChange, !animated((row / block) * columns + column / block) else { continue }
                    changed += 1
                }
            }
            if changed >= 3 {
                continuationRereads += 1
                log("the text may go on: \(changed) pixels changed at \(Int(rect.minX)),\(Int(rect.minY))")
                return true
            }
        }
        return false
    }

    /// Whether two frames differ by more than the threshold: the share of pixels that changed clearly,
    /// in any watched area. Small changes (a blinking cursor, slight animation) stay under it, and
    /// spots known to be animated are left out while `a` shows them as they were seen (see AnimatedBlock).
    /// - Parameters:
    ///   - only: The areas to compare, or all.
    ///   - threshold: The share of pixels, instead of the one in Settings.
    private func differs(_ a: Frame, _ b: Frame, only: [Int]? = nil, threshold: Double? = nil) -> Bool {
        guard a.thumbnails.count == b.thumbnails.count, a.widths == b.widths else { return true }
        let threshold = threshold ?? number("ocrChangeThreshold", 0.3) / 100
        let block = Self.block
        for (area, ((x, y), width)) in zip(zip(a.thumbnails, b.thumbnails), a.widths).enumerated() {
            if let only, !only.contains(area) { continue }
            guard x.count == y.count, !x.isEmpty, width > 0 else { return true }
            let animated = animation(in: a, area: area)
            let columns = (width + block - 1) / block
            var changed = 0
            for index in x.indices where abs(Int(x[index]) - Int(y[index])) > Self.clearChange {
                if animated((index / width / block) * columns + (index % width) / block) { continue }
                changed += 1
            }
            // A share of what's drawn rather than of the whole area, so that a short line on an otherwise empty screen
            // counts as much as a page of text does on a busy one; but of at least a twentieth of the area, so that a
            // few pixels don't.
            let drawn = max(Self.drawnPixels(x, y), x.count / 20)
            if Double(changed) / Double(drawn) > threshold {
                log("area \(area): \(changed) of \(drawn) drawn pixels changed (\(x.count) in all)")
                return true
            }
        }
        return false
    }
}
