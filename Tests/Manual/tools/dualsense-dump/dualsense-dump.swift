// dualsense-dump: records a Sony DualSense's raw HID input reports alongside GameController's view of the same
// controls, in MacPopup's GamepadRecording format (see Sources/MacPopup/GamepadLearning.swift), so its gamepad layout
// learning can be tested on a DualSense.
//
// The controller is opened without seizing it, exactly as MacPopup opens a controller it's learning (see
// GamepadController.setMode in Sources/MacPopup/Gamepads.swift): every input report is recorded, whatever its ID, with
// a 0 put first for a device without report IDs. GameController's state is recorded on every change of the profile,
// with the app's names (GamepadController.controls/state). Nothing is sent to the controller and no key or mouse events
// are posted.
//
// Build: swiftc -O -o dualsense-dump dualsense-dump.swift      (or run it directly: swift dualsense-dump.swift)
// Run:   ./dualsense-dump [--free] [--any[=<name part>]]
//   --free   no guided steps: just record until Ctrl-C.
//   --any    accept any gamepad instead of a DualSense (for testing the tool with another controller); with a name
//            part, the gamepad whose name contains it.
// Ctrl-C saves dualsense-<unixtime>.json in the current directory and prints its path.
import AppKit
import GameController
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Options

let arguments = Array(CommandLine.arguments.dropFirst())
let anyGamepad = arguments.contains { $0 == "--any" || $0.hasPrefix("--any=") }
let anyName = arguments.first { $0.hasPrefix("--any=") }.map { String($0.dropFirst("--any=".count)) } ?? ""
let guided = !arguments.contains("--free")
if let unknown = arguments.first(where: { $0 != "--free" && $0 != "--any" && !$0.hasPrefix("--any=") }) {
    print("Unknown option \(unknown). Usage: dualsense-dump [--free] [--any[=<name part>]]")
    exit(2)
}

let sonyVendor = 0x054C
let dualSenseProducts = [0x0CE6: "DualSense", 0x0DF2: "DualSense Edge"]
let isTTY = isatty(STDOUT_FILENO) != 0

// MARK: Output

var statusShown = false

/// Prints a line above the live status line.
func say(_ text: String) {
    if statusShown { print("\r\u{1B}[K", terminator: "") }
    print(text)
    statusShown = false
    fflush(stdout)
}

func hex(_ value: Int, _ digits: Int = 2) -> String { String(format: "0x%0\(digits)X", value) }

// MARK: Recording

var start = Date()
var reports: [(time: Double, bytes: [UInt8])] = []
var states: [(time: Double, pressed: Set<String>, analog: [String: Double])] = []
var steps: [(time: Double, step: String)] = []
var controls: [String] = []
var analogButtons = Set<String>()
var recording = false
var deviceName = "Controller"
var deviceInfo: [String: Any] = [:]

/// Report counts by ID and length, and the times of the last second's reports (for the rate).
var reportKinds: [String: Int] = [:]
var recentTimes: [Double] = []
var lastReport: [UInt8] = []
var gcPressed = Set<String>()

func elapsed() -> Double { Date().timeIntervalSince(start) }

// MARK: GameController's names (the same as GamepadController.controls/state in Gamepads.swift)

let directions = ["Up", "Down", "Left", "Right"]

func isStick(_ dpadName: String) -> Bool { dpadName.localizedCaseInsensitiveContains("thumbstick") }

func isDirectionButton(_ button: GCControllerButtonInput, _ profile: GCPhysicalInputProfile) -> Bool {
    profile.dpads.values.contains { dpad in [dpad.up, dpad.down, dpad.left, dpad.right].contains { $0 === button } }
}

/// The controls a profile has: its buttons (not a D-pad's or stick's directions), D-pad directions and stick
/// directions; touch surfaces are left out. And which buttons are analog.
func profileControls(_ profile: GCPhysicalInputProfile) -> (names: [String], analog: Set<String>) {
    var names: [String] = []
    var analog = Set<String>()
    for (name, button) in profile.buttons where !isDirectionButton(button, profile) {
        names.append(name)
        if button.isAnalog { analog.insert(name) }
    }
    for name in profile.dpads.keys where !name.localizedCaseInsensitiveContains("touchpad") {
        names += directions.map { "\(isStick(name) ? name : "Direction Pad") \($0)" }
    }
    return (names.sorted(), analog)
}

/// What a profile has held: a stick direction counts from halfway. Analog buttons' values (0 to 1) and stick axes
/// (-1 to 1, "Left Thumbstick X").
func profileState(_ profile: GCPhysicalInputProfile) -> (pressed: Set<String>, analog: [String: Double]) {
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
            for (direction, button) in zip(directions, [dpad.up, dpad.down, dpad.left, dpad.right]) where button.isPressed {
                pressed.insert("Direction Pad \(direction)")
            }
        }
    }
    return (pressed, analog)
}

// MARK: Saving

func save() {
    var json: [String: Any] = [
        "analogButtons": analogButtons.sorted(),
        "reports": reports.map { ["time": $0.time, "bytes": $0.bytes] as [String: Any] },
        "states": states.map { ["time": $0.time, "pressed": $0.pressed.sorted(), "analog": $0.analog] as [String: Any] },
    ]
    // As MacPopup's debug recordings (MACPOPUP_DEBUG_GAMEPAD) have them.
    json["controls"] = controls
    json["name"] = deviceName
    // Extra, for us: the device, and when each guided step started.
    var info = deviceInfo
    info["reportKinds"] = reportKinds
    json["device"] = info
    json["steps"] = steps.map { ["time": $0.time, "step": $0.step] as [String: Any] }
    let path = FileManager.default.currentDirectoryPath + "/dualsense-\(Int(Date().timeIntervalSince1970)).json"
    do {
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: URL(fileURLWithPath: path))
        say("Saved \(reports.count) reports and \(states.count) GameController states to:\n  \(path)")
        say("Please send us that file.")
    } catch {
        say("Couldn't save \(path): \(error.localizedDescription)")
    }
}

func finish(_ code: Int32) -> Never {
    if recording {
        recording = false
        say("")
        save()
    }
    exit(code)
}

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { finish(0) }
    source.resume()
    signalSources.append(source)
}

// MARK: GameController

NSApplication.shared.setActivationPolicy(.accessory)
// The tool runs behind Terminal: GameController only reports to an app in front unless asked to.
GCController.shouldMonitorBackgroundEvents = true

var chosenController: GCController?

func watch(_ controller: GCController) {
    controller.physicalInputProfile.valueDidChangeHandler = { profile, _ in
        guard recording, controller === chosenController else { return }
        let state = profileState(profile)
        states.append((elapsed(), state.pressed, state.analog))
        gcPressed = state.pressed
    }
}

NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
    (note.object as? GCController).map(watch)
}
NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
    guard recording, let controller = note.object as? GCController, controller === chosenController else { return }
    say("GameController lost the controller. Saving what was recorded.")
    finish(1)
}
for controller in GCController.controllers() { watch(controller) }

// MARK: HID

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(manager, [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
} as CFArray)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

var chosenDevice: IOHIDDevice?
var buffer: UnsafeMutablePointer<UInt8>?

IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
    guard recording, device === chosenDevice else { return }
    say("The controller disconnected. Saving what was recorded.")
    finish(1)
}, nil)

func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
}

func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
}

func describe(_ device: IOHIDDevice) -> String {
    String(format: "%@ (%04x:%04x, %@)", stringProperty(device, kIOHIDProductKey) ?? "?", intProperty(device, kIOHIDVendorIDKey),
           intProperty(device, kIOHIDProductIDKey), stringProperty(device, kIOHIDTransportKey) ?? "?")
}

func describe(_ controller: GCController) -> String {
    "\(controller.vendorName ?? "?") (\(controller.productCategory))"
}

/// Opens the device without seizing it, as MacPopup does while learning, and records every input report.
func open(_ device: IOHIDDevice) -> Bool {
    let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard status == kIOReturnSuccess else {
        say(String(format: "Couldn't open the controller (error 0x%08x).", UInt32(bitPattern: status)))
        if status == kIOReturnNotPermitted {
            say("""
                macOS didn't allow Terminal to read it. Open System Settings > Privacy & Security > Input Monitoring,
                turn on Terminal (add it with + if it isn't listed), then quit Terminal completely (Cmd-Q), open it
                again and run this tool again.
                """)
            // Shows macOS's own prompt, which adds Terminal to the list.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        return false
    }
    // The same buffer as MacPopup's: the device's largest input report, at least 64 bytes.
    let size = max(intProperty(device, kIOHIDMaxInputReportSizeKey), 64)
    buffer = .allocate(capacity: size)
    IOHIDDeviceRegisterInputReportCallback(device, buffer!, size, { _, _, _, _, reportID, report, length in
        guard recording else { return }
        // Without report IDs, a 0 in their place, so byte numbers mean the same either way.
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        let full = reportID == 0 ? [0] + bytes : bytes
        let time = elapsed()
        reports.append((time, full))
        lastReport = full
        recentTimes.append(time)
        let kind = "\(hex(Int(full.first ?? 0))) \(full.count) bytes"
        if reportKinds[kind] == nil {
            say("First report \(kind) (report ID \(hex(Int(full.first ?? 0))), \(full.count) bytes including the ID)")
        }
        reportKinds[kind, default: 0] += 1
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    return true
}

// MARK: Status line

func showStatus() {
    guard recording else { return }
    let now = elapsed()
    recentTimes.removeAll { $0 < now - 1 }
    let id = lastReport.first.map { hex(Int($0)) } ?? "-"
    let pressed = gcPressed.isEmpty ? "(none)" : gcPressed.sorted().joined(separator: ", ")
    var line = String(format: "[%5.1f s] report %@ len %d  %3d/s  total %d  |  held: %@", now, id, lastReport.count,
                      recentTimes.count, reports.count, pressed)
    if chosenController == nil { line = line.replacingOccurrences(of: "held: (none)", with: "held: (no GameController)") }
    if isTTY {
        var size = winsize()
        let width = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 20 ? Int(size.ws_col) : 120
        if line.count > width - 1 { line = String(line.prefix(width - 2)) + "…" }
        print("\r\u{1B}[K" + line, terminator: "")
        statusShown = true
        fflush(stdout)
    }
}

var lastPlainStatus = Date.distantPast
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if isTTY {
        showStatus()
    } else if recording, Date().timeIntervalSince(lastPlainStatus) >= 2 {
        // Not a terminal (e.g. piped to a file): a status line every 2 s instead.
        lastPlainStatus = Date()
        let now = elapsed()
        recentTimes.removeAll { $0 < now - 1 }
        print(String(format: "[%5.1f s] report %@ len %d  %d/s  total %d  held: %@", now, lastReport.first.map { hex(Int($0)) } ?? "-",
                     lastReport.count, recentTimes.count, reports.count, gcPressed.isEmpty ? "(none)" : gcPressed.sorted().joined(separator: ", ")))
    }
}

// MARK: Guided steps

struct Step {
    let title: String
    let seconds: Double
}

func buildSteps(edge: Bool) -> [Step] {
    var list: [Step] = []
    let press = { (name: String) in list.append(Step(title: "Press \(name) 3 times (press, let go, wait a moment), nothing else", seconds: 6)) }
    for name in ["Cross (X)", "Circle (O)", "Square", "Triangle", "L1", "R1"] { press(name) }
    list.append(Step(title: "Pull L2 all the way 3 times, quickly (pull, let go, wait a moment)", seconds: 6))
    list.append(Step(title: "Pull R2 all the way 3 times, quickly (pull, let go, wait a moment)", seconds: 6))
    press("L3 (click the left stick straight down, without tilting it)")
    press("R3 (click the right stick straight down, without tilting it)")
    press("Create (the small button left of the touchpad)")
    press("Options (the small button right of the touchpad)")
    list.append(Step(title: "Press PS (the logo button) 3 times. If macOS opens something (e.g. Launchpad), just ignore it", seconds: 6))
    press("the touchpad as a button (click it down in the middle)")
    press("Mute (the small button below the PS button)")
    if edge {
        press("the left back paddle (under the left grip)")
        press("the right back paddle (under the right grip)")
        press("the left Fn button (under the left stick)")
        press("the right Fn button (under the right stick)")
    }
    for direction in ["Up", "Down", "Left", "Right"] { press("D-pad \(direction)") }
    for stick in ["left", "right"] {
        for direction in ["up", "down", "left", "right"] {
            list.append(Step(title: "Push the \(stick) stick fully \(direction) and let it spring back, 3 times", seconds: 6))
        }
    }
    for stick in ["left", "right"] {
        list.append(Step(title: "Move the \(stick) stick in one slow full circle, pushed all the way out (about 4 seconds), then let go", seconds: 7))
    }
    for trigger in ["L2", "R2"] {
        list.append(Step(title: "Pull \(trigger) slowly all the way in (about 3 seconds), then let it out slowly (about 3 seconds)", seconds: 8))
    }
    return list
}

/// Runs the steps: each one is announced, then timed, with a 2.5 s pause with nothing held before the next one.
func runSteps(_ list: [Step], index: Int = 0) {
    guard recording else { return }
    guard index < list.count else {
        steps.append((elapsed(), "end"))
        say("\nAll steps done, thank you! Press Ctrl-C now to save the recording.")
        NSSound(named: "Glass")?.play()
        return
    }
    let step = list[index]
    steps.append((elapsed(), "pause"))
    say("\nNext (\(index + 1)/\(list.count)): \(step.title).")
    say("  Get ready, hold nothing...")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        guard recording else { return }
        steps.append((elapsed(), step.title))
        say(String(format: "  GO (%.0f s)", step.seconds))
        NSSound(named: "Tink")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + step.seconds) {
            guard recording else { return }
            say("  Stop. Let go of everything.")
            runSteps(list, index: index + 1)
        }
    }
}

// MARK: Start

func choose() {
    let devices = ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).sorted { describe($0) < describe($1) }
    let candidates = devices.filter { device in
        if anyGamepad {
            return anyName.isEmpty || (stringProperty(device, kIOHIDProductKey) ?? "").localizedCaseInsensitiveContains(anyName)
        }
        return intProperty(device, kIOHIDVendorIDKey) == sonyVendor && dualSenseProducts[intProperty(device, kIOHIDProductIDKey)] != nil
    }
    let wanted = anyGamepad ? "gamepad" + (anyName.isEmpty ? "" : " named like \"\(anyName)\"") : "DualSense"
    guard candidates.count == 1, let device = candidates.first else {
        if candidates.isEmpty {
            say("No \(wanted) found.")
            if !anyGamepad {
                say("Connect the DualSense with a USB cable, or pair it in System Settings > Bluetooth, and run this again.")
            }
        } else {
            say("\(candidates.count) \(wanted)s are connected; their reports can't be told apart. Leave only one connected and run this again:")
            for device in candidates { say("  \(describe(device))") }
        }
        if !devices.isEmpty, candidates.count != devices.count || candidates.isEmpty {
            say("Gamepads connected: " + devices.map(describe).joined(separator: "; "))
        }
        exit(1)
    }

    deviceName = stringProperty(device, kIOHIDProductKey) ?? "Controller"
    let product = intProperty(device, kIOHIDProductIDKey)
    deviceInfo = [
        "vendorID": intProperty(device, kIOHIDVendorIDKey), "productID": product, "product": deviceName,
        "transport": stringProperty(device, kIOHIDTransportKey) ?? "", "maxInputReportSize": intProperty(device, kIOHIDMaxInputReportSizeKey),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    say("Controller: \(describe(device)), largest input report \(intProperty(device, kIOHIDMaxInputReportSizeKey)) bytes")

    // GameController's controller for it: by the HID name as MacPopup does, else (for a DualSense) one whose name says
    // DualSense.
    let all = GCController.controllers()
    var named = all.filter { $0.vendorName == deviceName }
    if named.isEmpty, !anyGamepad { named = all.filter { $0.vendorName?.localizedCaseInsensitiveContains("DualSense") == true } }
    if named.isEmpty, anyGamepad, all.count == 1 { named = all }
    if named.count == 1 {
        chosenController = named[0]
        let profile = named[0].physicalInputProfile
        let found = profileControls(profile)
        controls = found.names
        analogButtons = found.analog
        say("GameController: \(describe(named[0]))")
        say("  controls: " + controls.joined(separator: ", "))
        say("  analog buttons: " + analogButtons.sorted().joined(separator: ", "))
        say("  all buttons in its profile: " + profile.buttons.keys.sorted().joined(separator: ", "))
        if !profile.dpads.isEmpty { say("  D-pads and surfaces: " + profile.dpads.keys.sorted().joined(separator: ", ")) }
    } else if named.isEmpty {
        say("WARNING: GameController doesn't see this controller, so only its raw reports are recorded."
            + " Controllers it sees: " + (all.isEmpty ? "none" : all.map(describe).joined(separator: "; ")))
    } else {
        say("WARNING: \(named.count) GameController controllers match (\(named.map(describe).joined(separator: "; "))),"
            + " so their states can't be told apart and only raw reports are recorded. Leave only one controller connected.")
    }

    start = Date()
    recording = true
    guard open(device) else { exit(1) }
    chosenDevice = device
    // Only changes are recorded, as in the app (no state for the start), but the status line shows what's held now.
    if let controller = chosenController { gcPressed = profileState(controller.physicalInputProfile).pressed }

    say("")
    say("Recording. Press Ctrl-C at any time to stop and save.")
    if guided {
        let list = buildSteps(edge: product == 0x0DF2)
        say("""

            Follow the steps below. Each one starts after a short pause: let go of everything during the pauses, and
            during a step touch only what it says. Put the controller on a table or hold it loosely so nothing else
            is pressed. Keep this Terminal window visible. The status line at the bottom shows what's being recorded
            and what's held. About \(Int(list.reduce(0) { $0 + $1.seconds + 2.5 } / 60) + 1) minutes in all.
            """)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { runSteps(list) }
    } else {
        say("Free recording: press each control a few times, one at a time, then press Ctrl-C.")
    }
}

say(anyGamepad ? "dualsense-dump (--any: accepting any gamepad)" : "dualsense-dump: looking for a DualSense...")
// HID devices and GameController's controllers show up within a moment of starting.
DispatchQueue.main.asyncAfter(deadline: .now() + 2) { choose() }
NSApplication.shared.run()
