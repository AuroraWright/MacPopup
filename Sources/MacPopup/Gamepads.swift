import AppKit
import GameController
import IOKit.hid

/// Game controllers, for looking words up with them (see web/src/overlay.js): which of their controls are held, and
/// holding them so the app in front doesn't get their presses meanwhile.
///
/// GameController reads controllers while another app is in front, but that app (the game) gets their presses too.
/// IOKit can open a controller to seize it: it then stops reaching other apps, GameController included, until it's let
/// go, without games seeing it disconnect, and without asking for a permission. MacPopup reads a held controller's
/// reports itself, with the layout learned for its model in Settings (see GamepadLearning.swift), and reads it that way
/// while it isn't held too. A controller without a layout isn't used: GameController only names the controls while one
/// is learned.
@MainActor
final class GamepadController: ObservableObject {
    static let shared = GamepadController()

    struct Connected: Identifiable, Equatable {
        /// The model, "vendor:product" in hex, which layouts are saved by.
        let id: String
        let name: String
    }

    /// A learning session in Settings (see startLearning).
    struct Learning {
        let key: String
        let name: String
        /// The controls to learn, by GameController's names.
        let controls: [String]
        /// Whether GameController reads this controller: if not, controls are only learned one at a time.
        let hasGameController: Bool
        var learned: [String: GamepadField] = [:]
        /// Controls learned from one press each (see learnPress).
        var pressedOnce: [String: GamepadField] = [:]
        /// The control a press is waited for.
        var waitingFor: String?
        /// What GameController says is held now.
        var held: Set<String> = []
    }

    @Published private(set) var connected: [Connected] = []
    /// The held controls of all controllers, by GameController's names.
    @Published private(set) var pressed: Set<String> = []
    @Published private(set) var learning: Learning?
    @Published private(set) var layouts: [String: GamepadLayout] = [:]

    /// Called with the held controls when they change, for the overlay (not while Settings records them).
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
    /// The report a press is compared with (see learnPress), the bits that change by themselves, and the first report
    /// that changed once the press was waited for.
    private var pressBaseline: (report: [UInt8], noise: [UInt8], firstChange: [UInt8]?)?
    /// MACPOPUP_DEBUG_GAMEPAD=<folder> saves each learning session's recording there.
    private let debugFolder = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_GAMEPAD"]

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

    /// How each controller is opened: held while asked (and the overlay is shown, and no controller is being
    /// learned), shared to read it otherwise, and not at all without a layout (GameController reads it then).
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
        // Reopened (to hold it or let it go), its controls stay held until its next report says otherwise: the
        // scan key that asked for the hold is still held then.
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
        pads.append(Pad(device: device))
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
        connected = pads.filter { seen.insert($0.key).inserted }.map { Connected(id: $0.key, name: $0.name) }
    }

    private func report(_ bytes: [UInt8], from pad: Pad) {
        guard pad.mode != nil else { return }
        let previous = pad.lastReport
        pad.lastReport = bytes
        if learning?.key == pad.key {
            recording.reports.append((Date().timeIntervalSince(learningStart), bytes))
            checkPress(bytes, previous: previous)
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
        guard active else { return }
        let state = Self.state(profile)
        guard let learning, learning.name == controller.vendorName else { return }
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
    func startLearning(key: String) {
        stopLearning(save: false)
        guard let pad = pads.first(where: { $0.key == key }) else { return }
        let controller = GCController.controllers().first { $0.vendorName == pad.name }
        let controls = controller.map { Self.controls($0.physicalInputProfile) }
        recording = GamepadRecording()
        recording.analogButtons = controls?.analog ?? []
        learningStart = Date()
        learning = Learning(key: key, name: pad.name, controls: controls?.names ?? GamepadControls.standard, hasGameController: controller != nil)
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
    /// before (e.g. a stick's; not longer, as the user may have pressed this very button just before), and the whole of
    /// a byte that changed in many of the reports of the two seconds before: a counter's top bit can stay the same for
    /// over a second (a Switch Pro Controller's timer, in byte 1).
    func learnPress(_ control: String) {
        guard learning != nil, let pad = pads.first(where: { $0.key == learning?.key }) else { return }
        learning?.waitingFor = control
        let now = Date().timeIntervalSince(learningStart)
        let recentReports = recording.reports.filter { $0.time >= now - 2 }
        // Other reports (e.g. a Switch controller's replies to the host) can have the same length and other bytes.
        let ids = Dictionary(recentReports.map { ($0.bytes.first ?? 0, 1) }, uniquingKeysWith: +)
        let id = ids.max { $0.value < $1.value }?.key ?? pad.lastReport.first ?? 0
        let timed = recentReports.filter { $0.bytes.first == id }
        let reports = timed.map(\.bytes)
        guard let baseline = reports.last ?? (pad.lastReport.first == id ? pad.lastReport : nil) else {
            pressBaseline = nil
            return
        }
        var noise = [UInt8](repeating: 0, count: baseline.count)
        var changes = [Int](repeating: 0, count: baseline.count)
        let pairs = zip(timed, timed.dropFirst()).filter { $0.bytes.count == baseline.count && $1.bytes.count == baseline.count }
        for (previous, report) in pairs {
            for index in noise.indices where previous.bytes[index] != report.bytes[index] {
                if report.time >= now - 0.5 { noise[index] |= previous.bytes[index] ^ report.bytes[index] }
                changes[index] += 1
            }
        }
        for index in noise.indices where pairs.count >= 10 && changes[index] * 4 > pairs.count { noise[index] = 0xFF }
        pressBaseline = (baseline, noise, nil)
    }

    func cancelPress() {
        learning?.waitingFor = nil
        pressBaseline = nil
    }

    /// Once something changed for the control waited for, the report 150 ms later decides (an analog value is still
    /// rising at first), or the first one that changed if the button was already let go.
    private func checkPress(_ report: [UInt8], previous: [UInt8]) {
        guard let control = learning?.waitingFor, let baseline = pressBaseline, baseline.firstChange == nil,
              report.count == baseline.report.count, report.first == baseline.report.first,
              GamepadLearning.field(for: control, before: baseline.report, during: report, noise: baseline.noise) != nil else { return }
        pressBaseline?.firstChange = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.learning?.waitingFor == control, let baseline = self.pressBaseline, let first = baseline.firstChange else { return }
            let latest = self.recording.reports.last { $0.bytes.first == baseline.report.first && $0.bytes.count == baseline.report.count }?.bytes ?? first
            guard let field = GamepadLearning.field(for: control, before: baseline.report, during: latest, noise: baseline.noise)
                ?? GamepadLearning.field(for: control, before: baseline.report, during: first, noise: baseline.noise)
            else {
                self.pressBaseline?.firstChange = nil
                return
            }
            self.learning?.pressedOnce[control] = field
            self.learning?.waitingFor = nil
            self.pressBaseline = nil
        }
    }

    /// Ends learning, saving what was learned over the model's earlier layout.
    func stopLearning(save: Bool) {
        learningTimer?.invalidate()
        learningTimer = nil
        guard let learning else { return }
        relearn()
        let final = self.learning ?? learning
        self.learning = nil
        pressBaseline = nil
        if let debugFolder {
            let url = URL(fileURLWithPath: debugFolder).appendingPathComponent("gamepad-\(final.key.replacingOccurrences(of: ":", with: "-"))-\(Int(Date().timeIntervalSince1970)).json")
            var json = recording.json
            json["controls"] = final.controls
            json["name"] = final.name
            if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: url) }
        }
        if save {
            let controls = final.learned.merging(final.pressedOnce) { _, once in once }
            let reportID = GamepadLearning.samples(recording).first?.report.first.map(Int.init)
                ?? pads.first { $0.key == final.key }?.lastReport.first.map(Int.init) ?? 0
            var layout = layouts[final.key].flatMap { $0.reportID == reportID ? $0 : nil } ?? GamepadLayout(name: final.name, reportID: reportID, controls: [:])
            layout.name = final.name
            layout.controls.merge(controls) { _, new in new }
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
