import AppKit
import GameController
import IOKit.hid

/// Game controllers, for looking words up with them (see web/src/overlay.js): which of their controls are held, and
/// holding them so the app in front doesn't get their presses meanwhile.
///
/// GameController reads controllers while another app is in front, but that app (the game) gets their presses too.
/// IOKit can instead open a controller and seize it: its presses then stop reaching other apps, GameController
/// included, until it's let go, without games seeing it disconnect and without asking for a permission. So MacPopup
/// reads each controller's reports itself, held or not, with the layout learned for its model in Settings (see
/// GamepadLearning.swift). A controller without a layout isn't used: GameController is only there to name the controls
/// while a layout is learned.
@MainActor
final class GamepadController: ObservableObject {
    static let shared = GamepadController()

    struct Connected: Identifiable, Equatable {
        /// The model, "vendor:product" in hex, which layouts are saved by.
        let id: String
        let name: String
        /// How many controllers of the model are connected. It's only learned with one, as their reports can't be
        /// told apart.
        let count: Int
        /// The IDs of the reports they've sent since they were opened (which a Joy-Con's depend on how it's connected).
        let reportIDs: Set<Int>
    }

    /// A learning session in Settings (see startLearning).
    struct Learning {
        let key: String
        let name: String
        /// The controls to learn, by GameController's names.
        let controls: [String]
        /// Whether GameController reads this controller: if not, controls are only learned one at a time.
        let hasGameController: Bool
        /// Whether that's because another connected controller has the same name (see startLearning).
        let sharesName: Bool
        var learned: [String: GamepadField] = [:]
        /// Controls learned from one press each (see learnPress).
        var pressedOnce: [String: GamepadField] = [:]
        /// The control whose next press is waited for (see learnPress).
        var waitingFor: String?
        /// What GameController says is held now.
        var held: Set<String> = []
    }

    @Published private(set) var connected: [Connected] = []
    /// The held controls of all controllers, by GameController's names.
    @Published private(set) var pressed: Set<String> = []
    @Published private(set) var learning: Learning?
    @Published private(set) var layouts: [String: GamepadLayout] = [:]

    /// Called with the held controls when they change, for the overlay (not while Settings records a combination or
    /// learns a controller).
    var onChange: ((Set<String>) -> Void)?
    /// Whether the overlay is shown: controllers are only held then.
    var overlayVisible = false {
        didSet { scheduleApply() }
    }

    private final class Pad {
        let device: IOHIDDevice
        let key: String
        let name: String
        let buffer: UnsafeMutablePointer<UInt8>
        let bufferSize: Int
        var mode: IOOptionBits?
        var pressed: Set<String> = []
        var lastReport: [UInt8] = []
        var reportIDs: Set<Int> = []

        init(device: IOHIDDevice) {
            self.device = device
            let int = { (key: String) in (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
            key = String(format: "%04x:%04x", int(kIOHIDVendorIDKey), int(kIOHIDProductIDKey))
            name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Controller"
            bufferSize = max(int(kIOHIDMaxInputReportSizeKey), 64)
            buffer = .allocate(capacity: bufferSize)
        }

        deinit { buffer.deallocate() }
    }

    private var manager: IOHIDManager?
    private var pads: [Pad] = []
    /// Whether the settings use controllers (a scan key, popup shortcuts, or Game Sentence Audio) and one is set up.
    private var wanted = false
    /// Settings views that read controllers (see retain).
    private var clients = 0
    /// Settings views recording a combination: the overlay doesn't get the presses meanwhile.
    private var recordings = 0
    /// Whether the overlay asked for the controllers to be held.
    private var holdRequested = false
    private var applyScheduled = false
    private var recording = GamepadRecording()
    private var learningStart = Date()
    private var learningTimer: Timer?
    /// The GameController controller of the model being learned, if it's known which one it is.
    private weak var learningController: GCController?
    /// The report a press is compared with (see learnPress), the bits that change by themselves, the first report that
    /// changed once the press was waited for, and when it started being waited for.
    private var pressBaseline: (report: [UInt8], noise: [UInt8], bitNoise: [UInt8], firstChange: [UInt8]?, since: TimeInterval)?
    /// The reports of each stick push learned one press at a time, from resting to pushed: a stick's pushes settle each
    /// other's fields (see GamepadLearning.pushedField).
    private var stickPushes: [String: [[UInt8]]] = [:]
    /// MACPOPUP_DEBUG_GAMEPAD=<folder> saves each learning session's recording there.
    private let debugFolder = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_GAMEPAD"]
    /// Whether this learning session's recording is saved without MACPOPUP_DEBUG_GAMEPAD (Set Up clicked with Option,
    /// for testers to send): to Application Support/MacPopup/Controller Recordings, then shown in Finder.
    private var savesRecording = false

    /// Test instances (MACPOPUP_TEST_SCRIPT) leave the user's controllers alone: their scripts send presses themselves.
    private let isTest = ProcessInfo.processInfo.environment["MACPOPUP_TEST_SCRIPT"] != nil

    private var active: Bool { (wanted || clients > 0) && !isTest }

    private init() {
        applySettings()
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { (note.object as? GCController).map { self?.watch($0) } }
        }
    }

    // MARK: Settings

    private func applySettings() {
        let settings = SettingsStore.shared.dictionary
        layouts = (settings["gamepadLayouts"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? [String: Any]).flatMap(GamepadLayout.init(json:)) }
        let scanButtons = settings["gamepadScanButtons"] as? [String] ?? []
        let hotkeyButtons = (settings["hotkeys"] as? [[String: Any]] ?? []).contains {
            $0["enabled"] as? Bool ?? true && !($0["buttons"] as? [String] ?? []).isEmpty
        }
        let sentenceAudioButtons = settings["sentenceAudioEnabled"] as? Bool == true && !(settings["sentenceAudioButtons"] as? [String] ?? []).isEmpty
        wanted = (!scanButtons.isEmpty || hotkeyButtons || sentenceAudioButtons) && !layouts.isEmpty
        scheduleApply()
    }

    /// While a Settings view shows controllers, they're read even if the settings don't use them yet.
    func retain() {
        clients += 1
        scheduleApply()
    }

    func release() {
        clients -= 1
        scheduleApply()
    }

    /// While a Settings view records a combination, its presses don't reach the overlay.
    func beginRecording() { recordings += 1 }
    func endRecording() { recordings -= 1 }

    /// Opens and closes controllers on the next turn of the main queue: closing one from its own report's callback
    /// (e.g. once a recorded combination's buttons are let go) crashes in IOKit.
    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            applyScheduled = false
            applyActive()
        }
    }

    private func applyActive() {
        if active, manager == nil {
            start()
        } else if !active, manager != nil {
            stop()
        }
        applyModes()
    }

    private func start() {
        GCController.shouldMonitorBackgroundEvents = true
        for controller in GCController.controllers() { watch(controller) }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        } as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            MainActor.assumeIsolated { GamepadController.shared.deviceAdded(device) }
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
            MainActor.assumeIsolated { GamepadController.shared.deviceRemoved(device) }
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
    }

    private func stop() {
        for pad in pads { setMode(pad, nil) }
        pads = []
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        connected = []
        update()
    }

    // MARK: Holding

    /// Asked by the overlay: held while it has controller focus, or a popup with controller shortcuts is open.
    func setHold(_ hold: Bool) {
        holdRequested = hold
        scheduleApply()
    }

    /// How each controller is opened: held while the overlay asks for it (if the overlay is shown and no controller is
    /// being learned), opened just to read it otherwise, and not at all without a layout unless it's being learned.
    private func applyModes() {
        let hold = holdRequested && overlayVisible && learning == nil
        for pad in pads {
            let mode: IOOptionBits?
            if learning?.key == pad.key {
                mode = IOOptionBits(kIOHIDOptionsTypeNone)
            } else if active, layouts[pad.key] != nil {
                mode = IOOptionBits(hold ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
            } else {
                mode = nil
            }
            setMode(pad, mode)
        }
    }

    private func setMode(_ pad: Pad, _ mode: IOOptionBits?) {
        guard pad.mode != mode else { return }
        if let current = pad.mode {
            IOHIDDeviceUnscheduleFromRunLoop(pad.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(pad.device, current)
        }
        pad.mode = nil
        // When it's reopened (to hold it or let it go), its controls stay held until its next report says otherwise:
        // the scan key that asked for the hold is still held at that point.
        if mode == nil { pad.pressed = [] }
        if let mode {
            var status = IOHIDDeviceOpen(pad.device, mode)
            if status != kIOReturnSuccess, mode != IOOptionBits(kIOHIDOptionsTypeNone) {
                NSLog("MacPopup: couldn't hold \(pad.name) (0x%08x), reading it without", UInt32(bitPattern: status))
                status = IOHIDDeviceOpen(pad.device, IOOptionBits(kIOHIDOptionsTypeNone))
                if status == kIOReturnSuccess { pad.mode = IOOptionBits(kIOHIDOptionsTypeNone) }
            } else if status == kIOReturnSuccess {
                pad.mode = mode
            }
            if pad.mode != nil {
                let context = Unmanaged.passUnretained(pad).toOpaque()
                IOHIDDeviceRegisterInputReportCallback(pad.device, pad.buffer, pad.bufferSize, { context, _, _, _, reportID, report, length in
                    guard let context else { return }
                    let pad = Unmanaged<Pad>.fromOpaque(context).takeUnretainedValue()
                    // Without report IDs, a 0 in their place, so byte numbers mean the same either way.
                    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                    let full = reportID == 0 ? [0] + bytes : bytes
                    MainActor.assumeIsolated { GamepadController.shared.report(full, from: pad) }
                }, context)
                IOHIDDeviceScheduleWithRunLoop(pad.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            }
        }
        update()
    }

    // MARK: Devices

    private func deviceAdded(_ device: IOHIDDevice) {
        guard !pads.contains(where: { $0.device === device }) else { return }
        let pad = Pad(device: device)
        pads.append(pad)
        // Another controller of the model being learned: their reports would mix (see Connected.count).
        if learning?.key == pad.key { stopLearning(save: false) }
        updateConnected()
        scheduleApply()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let index = pads.firstIndex(where: { $0.device === device }) else { return }
        let pad = pads.remove(at: index)
        pad.mode = nil
        if learning?.key == pad.key, !pads.contains(where: { $0.key == pad.key }) { stopLearning(save: false) }
        updateConnected()
        update()
    }

    private func updateConnected() {
        var seen = Set<String>()
        connected = pads.filter { seen.insert($0.key).inserted }.map { first in
            let model = pads.filter { $0.key == first.key }
            return Connected(id: first.key, name: first.name, count: model.count, reportIDs: model.reduce([]) { $0.union($1.reportIDs) })
        }
    }

    private func report(_ bytes: [UInt8], from pad: Pad) {
        guard pad.mode != nil, let id = bytes.first else { return }
        pad.lastReport = bytes
        if pad.reportIDs.insert(Int(id)).inserted { updateConnected() }
        if learning?.key == pad.key {
            recording.reports.append((Date().timeIntervalSince(learningStart), bytes))
            checkPress(bytes)
        }
        guard let layout = layouts[pad.key], let pressed = layout.pressed(bytes), pressed != pad.pressed else { return }
        pad.pressed = pressed
        update()
    }

    // MARK: GameController

    private func watch(_ controller: GCController) {
        controller.physicalInputProfile.valueDidChangeHandler = { [weak self, weak controller] profile, _ in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.gameControllerChanged(controller, profile)
            }
        }
    }

    private func gameControllerChanged(_ controller: GCController, _ profile: GCPhysicalInputProfile) {
        guard active, let learning, controller === learningController else { return }
        let state = Self.state(profile)
        recording.states.append(GamepadRecording.State(time: Date().timeIntervalSince(learningStart), pressed: state.pressed, analog: state.analog))
        if state.pressed != learning.held { self.learning?.held = state.pressed }
    }

    /// The controls a profile has: its buttons (but not those that are a D-pad's or a stick's directions), D-pad
    /// directions, and stick directions (stick axes are the stick's name with X or Y); touch surfaces are left out.
    static func controls(_ profile: GCPhysicalInputProfile) -> (names: [String], analog: Set<String>) {
        var names: [String] = []
        var analog = Set<String>()
        for (name, button) in profile.buttons where !isDirectionButton(button, profile) {
            names.append(name)
            if button.isAnalog { analog.insert(name) }
        }
        for name in profile.dpads.keys where !name.localizedCaseInsensitiveContains("touchpad") {
            names += GamepadControls.directions.map { "\(isStick(name) ? name : "Direction Pad") \($0)" }
        }
        return (names.sorted(), analog)
    }

    private static func isStick(_ dpadName: String) -> Bool {
        dpadName.localizedCaseInsensitiveContains("thumbstick")
    }

    private static func isDirectionButton(_ button: GCControllerButtonInput, _ profile: GCPhysicalInputProfile) -> Bool {
        profile.dpads.values.contains { dpad in [dpad.up, dpad.down, dpad.left, dpad.right].contains { $0 === button } }
    }

    /// What a profile has held (see controls): a stick direction counts from halfway.
    static func state(_ profile: GCPhysicalInputProfile) -> (pressed: Set<String>, analog: [String: Double]) {
        var pressed = Set<String>()
        var analog: [String: Double] = [:]
        for (name, button) in profile.buttons where !isDirectionButton(button, profile) {
            if button.isPressed { pressed.insert(name) }
            if button.isAnalog { analog[name] = Double(button.value) }
        }
        for (name, dpad) in profile.dpads where !name.localizedCaseInsensitiveContains("touchpad") {
            if isStick(name) {
                let x = Double(dpad.xAxis.value), y = Double(dpad.yAxis.value)
                analog["\(name) X"] = x
                analog["\(name) Y"] = y
                if x >= 0.5 { pressed.insert("\(name) Right") }
                if x <= -0.5 { pressed.insert("\(name) Left") }
                if y >= 0.5 { pressed.insert("\(name) Up") }
                if y <= -0.5 { pressed.insert("\(name) Down") }
            } else {
                for (direction, button) in zip(GamepadControls.directions, [dpad.up, dpad.down, dpad.left, dpad.right]) where button.isPressed {
                    pressed.insert("Direction Pad \(direction)")
                }
            }
        }
        return (pressed, analog)
    }

    // MARK: Held controls

    /// The held controls of the controllers that are set up.
    private func update() {
        var held = Set<String>()
        for pad in pads where pad.mode != nil && layouts[pad.key] != nil {
            held.formUnion(pad.pressed)
        }
        guard held != pressed else { return }
        pressed = held
        if recordings == 0, learning == nil { onChange?(held) }
    }

    // MARK: Learning

    /// Starts learning a connected model's layout: it's read (not held) meanwhile, and GameController's changes are
    /// matched with its reports (see GamepadLearning). Controls GameController doesn't report are learned one at a
    /// time (see learnPress).
    func startLearning(key: String, savingRecording: Bool = false) {
        stopLearning(save: false)
        savesRecording = savingRecording
        let models = pads.filter { $0.key == key }
        guard models.count == 1, let pad = models.first else { return }
        // GameController doesn't say which device a controller is, so it's matched by name: its changes are only
        // recorded when no other connected controller has that name (they would mix in the recording). Its controls
        // are the model's either way. A Joy-Con is half of a joined controller, with only its own controls (the other
        // half's presses don't change its reports, so they aren't learned from).
        let half = { (controller: GCController) in GamepadControls.halves[controller.vendorName ?? ""]?[pad.name] }
        let named = GCController.controllers().filter { $0.vendorName == pad.name || half($0) != nil }
        let sharesName = named.count > 1 || pads.filter({ $0.name == pad.name }).count > 1
        let isSilent = named.contains { GamepadControls.silent.contains($0.vendorName ?? "") }
        learningController = sharesName || isSilent ? nil : named.first
        let controls: (names: [String], analog: Set<String>)?
        if isSilent, let own = GamepadControls.halves.values.lazy.compactMap({ $0[pad.name] }).first {
            // GameController names a Joy-Con on its own as held sideways (its stick a D-pad), but it has the controls
            // it has in a pair: in its full report, it sends the same.
            controls = (own.sorted(), [])
        } else {
            controls = named.first.map { controller in
                let controls = Self.controls(controller.physicalInputProfile)
                guard let own = half(controller) else { return controls }
                return (names: controls.names.filter(own.contains), analog: controls.analog.intersection(own))
            }
        }
        recording = GamepadRecording()
        recording.analogButtons = controls?.analog ?? []
        stickPushes = [:]
        learningStart = Date()
        learning = Learning(key: key, name: pad.name, controls: controls?.names ?? GamepadControls.standard,
                            hasGameController: learningController != nil, sharesName: sharesName && !named.isEmpty)
        scheduleApply()
        learningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relearn() }
        }
    }

    private func relearn() {
        guard let learning, let layout = GamepadLearning.layout(recording, controls: learning.controls) else { return }
        self.learning?.learned = layout.controls
    }

    /// Learns `control` from its next press: whatever changes then in the controller's main report (see
    /// GamepadLearning.field), other than what changes by itself. That's the bits that changed in the half second
    /// before (e.g. a stick's; not longer, as the user may have pressed this very button just before), and all of any
    /// byte that changed in over a quarter of the reports of the two seconds before: a counter's top bit can stay the
    /// same for over a second (a Switch Pro Controller's timer, in byte 1). For a stick direction, only the bytes that
    /// changed in over 90% of the reports since learning started (a counter's, every time): the stick's own change in
    /// up to two thirds at rest (a Joy-Con's) and every time while it moves, and its push is told from them otherwise
    /// (see GamepadLearning.pushedField); a button's are kept too, for a stick direction that's a button.
    func learnPress(_ control: String) {
        guard learning != nil, let pad = pads.first(where: { $0.key == learning?.key }) else { return }
        learning?.waitingFor = control
        let now = Date().timeIntervalSince(learningStart)
        let recentReports = recording.reports.filter { $0.time >= now - 2 }
        let id = GamepadLearning.mainReportID(recentReports) ?? pad.lastReport.first ?? 0
        let timed = recentReports.filter { $0.bytes.first == id }
        guard let baseline = timed.last?.bytes ?? (pad.lastReport.first == id ? pad.lastReport : nil) else {
            pressBaseline = nil
            return
        }
        func noise(stick: Bool) -> [UInt8] {
            var noise = [UInt8](repeating: 0, count: baseline.count)
            var changes = [Int](repeating: 0, count: baseline.count)
            let compared = stick ? recording.reports.filter { $0.bytes.first == id } : timed
            let pairs = zip(compared, compared.dropFirst()).filter { $0.bytes.count == baseline.count && $1.bytes.count == baseline.count }
            for (previous, report) in pairs {
                for index in noise.indices where previous.bytes[index] != report.bytes[index] {
                    if report.time >= now - 0.5, !stick { noise[index] |= previous.bytes[index] ^ report.bytes[index] }
                    changes[index] += 1
                }
            }
            let share = stick ? 0.9 : 0.25
            for index in noise.indices where pairs.count >= 10 && Double(changes[index]) > share * Double(pairs.count) { noise[index] = 0xFF }
            return noise
        }
        let bitNoise = noise(stick: false)
        pressBaseline = (baseline, GamepadControls.isStickDirection(control) ? noise(stick: true) : bitNoise, bitNoise, nil, now)
    }

    func cancelPress() {
        learning?.waitingFor = nil
        pressBaseline = nil
    }

    /// Once a report changes something for the control being waited for, the reports since it was waited for decide its
    /// field 150 ms later (an analog value is still rising at first), or for a D-pad that first changed report if it
    /// was let go by then. A stick direction's is decided 0.4 s later, once the field it'd be has settled (that first
    /// change may be a nudge just before the push).
    private func checkPress(_ report: [UInt8]) {
        guard let control = learning?.waitingFor, let baseline = pressBaseline, baseline.firstChange == nil,
              report.count == baseline.report.count, report.first == baseline.report.first,
              GamepadLearning.field(for: control, before: baseline.report, during: report, noise: baseline.noise, bitNoise: baseline.bitNoise) != nil else { return }
        pressBaseline?.firstChange = report
        decidePress(control, after: GamepadControls.isStickDirection(control) ? 0.4 : 0.15)
    }

    private func decidePress(_ control: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.learning?.waitingFor == control, let baseline = self.pressBaseline, let first = baseline.firstChange else { return }
            // The reports since it was waited for, for a stick's push (see GamepadLearning.pushedField), but not over
            // a few seconds' worth.
            let now = Date().timeIntervalSince(self.learningStart)
            let reports = self.recording.reports.filter {
                $0.time >= max(baseline.since, now - 3) && $0.bytes.first == baseline.report.first && $0.bytes.count == baseline.report.count
            }
            let path = reports.map(\.bytes)
            // A press is all in the path (even one let go by now), which a single report would only be part of. A
            // stick's push is weighed with the stick's other pushes so far, which can rule out what moved before it.
            let stick = GamepadControls.sticks.first(where: control.hasPrefix)
            let earlier = stick.map { stick in self.stickPushes.filter { $0.key.hasPrefix(stick) } } ?? [:]
            guard let field = GamepadLearning.field(for: control, before: baseline.report, during: path.last ?? first, between: path.dropLast(),
                                                    pushes: earlier, noise: baseline.noise, bitNoise: baseline.bitNoise) else {
                self.pressBaseline?.firstChange = nil
                return
            }
            if case let .threshold(offset, width, _, _) = field, now < baseline.since + 5 {
                let recent = reports.filter { $0.time > now - 0.1 }.compactMap { GamepadField.bits($0.bytes, offset: offset, width: width) }
                if let low = recent.min(), let high = recent.max(), high - low > (1 << width) / 32 {
                    self.decidePress(control, after: 0.1)
                    return
                }
            }
            self.learning?.pressedOnce[control] = field
            if case .threshold = field, let stick {
                self.stickPushes[control] = [baseline.report] + path
                let pushes = self.stickPushes.filter { $0.key.hasPrefix(stick) }
                for direction in pushes.keys {
                    GamepadLearning.pushedField(direction, pushes: pushes, noise: baseline.noise).map { self.learning?.pressedOnce[direction] = $0 }
                }
            }
            self.learning?.waitingFor = nil
            self.pressBaseline = nil
        }
    }

    /// Ends learning, saving what was learned over the model's earlier layout (for the kind of report it sent).
    func stopLearning(save: Bool) {
        learningTimer?.invalidate()
        learningTimer = nil
        guard let learning else { return }
        relearn()
        let final = self.learning ?? learning
        self.learning = nil
        learningController = nil
        pressBaseline = nil
        let shared = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPopup").appendingPathComponent("Controller Recordings")
        if let folder = debugFolder.map(URL.init(fileURLWithPath:)) ?? (savesRecording ? shared : nil) {
            let url = folder.appendingPathComponent("gamepad-\(final.key.replacingOccurrences(of: ":", with: "-"))-\(Int(Date().timeIntervalSince1970)).json")
            var json = recording.json
            json["controls"] = final.controls
            json["name"] = final.name
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: json), (try? data.write(to: url)) != nil, debugFolder == nil {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        savesRecording = false
        if save {
            let controls = final.learned.merging(final.pressedOnce) { _, once in once }
            // Controls learned one press at a time (without GameController's state, so without samples) were too.
            let reportID = (GamepadLearning.mainReportID(recording.reports) ?? pads.first { $0.key == final.key }?.lastReport.first)
                .map(Int.init) ?? 0
            var layout = layouts[final.key] ?? GamepadLayout(name: final.name, reportID: reportID, controls: [:])
            layout.name = final.name
            layout.add(controls, reportID: reportID)
            setLayout(layout, for: final.key)
        }
        recording = GamepadRecording()
        scheduleApply()
    }

    /// Saves (or removes, with nil) a model's layout.
    func setLayout(_ layout: GamepadLayout?, for key: String) {
        var settings = SettingsStore.shared.dictionary
        var saved = settings["gamepadLayouts"] as? [String: Any] ?? [:]
        saved[key] = layout?.json
        settings["gamepadLayouts"] = saved
        guard let data = try? JSONSerialization.data(withJSONObject: settings), let json = String(data: data, encoding: .utf8) else { return }
        SettingsStore.shared.update(json: json)
    }
}
