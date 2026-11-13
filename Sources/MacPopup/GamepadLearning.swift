import Foundation

// Learning where a controller's buttons are in its raw HID input reports. While MacPopup holds a controller (see
// Gamepads.swift), GameController doesn't get its presses either, so MacPopup reads the reports itself. To learn them,
// the controller is read without holding it while its controls are pressed: GameController names what's pressed, and
// its changes are matched with the reports that came with them.

/// Where a control is in a controller's input reports. Byte 0 is the report ID (0 for a device without IDs).
enum GamepadField: Equatable {
    /// A bit that's 1 while the control is pressed (0 when `inverted`).
    case bit(byte: Int, bit: Int, inverted: Bool)
    /// A nibble that has one of `values` while pressed: a direction of a D-pad sent as a hat switch.
    case values(byte: Int, high: Bool, values: Set<Int>)
    /// An analog value, `width` bits little-endian from bit `offset`, that's pressed from `limit` up (down to it when
    /// `below`): a trigger, or a stick's direction.
    case threshold(offset: Int, width: Int, limit: Int, below: Bool)

    func value(_ report: [UInt8]) -> Int? {
        switch self {
        case let .bit(byte, bit, _):
            return byte < report.count ? Int(report[byte] >> bit) & 1 : nil
        case let .values(byte, high, _):
            return byte < report.count ? Int(high ? report[byte] >> 4 : report[byte] & 0x0F) : nil
        case let .threshold(offset, width, _, _):
            return Self.bits(report, offset: offset, width: width)
        }
    }

    func isPressed(_ report: [UInt8]) -> Bool {
        guard let value = value(report) else { return false }
        switch self {
        case let .bit(_, _, inverted): return (value == 1) != inverted
        case let .values(_, _, values): return values.contains(value)
        case let .threshold(_, _, limit, below): return below ? value <= limit : value >= limit
        }
    }

    /// `width` bits from bit `offset`, the first one lowest (as HID reports pack their fields).
    static func bits(_ report: [UInt8], offset: Int, width: Int) -> Int? {
        guard (offset + width - 1) / 8 < report.count else { return nil }
        var value = 0
        for index in 0..<width {
            let bit = offset + index
            value |= Int(report[bit / 8] >> (bit % 8) & 1) << index
        }
        return value
    }

    var json: [String: Any] {
        switch self {
        case let .bit(byte, bit, inverted): ["type": "bit", "byte": byte, "bit": bit, "inverted": inverted]
        case let .values(byte, high, values): ["type": "values", "byte": byte, "high": high, "values": values.sorted()]
        case let .threshold(offset, width, limit, below): ["type": "threshold", "offset": offset, "width": width, "limit": limit, "below": below]
        }
    }

    init?(json: [String: Any]) {
        let int = { (key: String) in (json[key] as? NSNumber)?.intValue }
        switch json["type"] as? String {
        case "bit":
            guard let byte = int("byte"), let bit = int("bit") else { return nil }
            self = .bit(byte: byte, bit: bit, inverted: json["inverted"] as? Bool ?? false)
        case "values":
            guard let byte = int("byte"), let values = json["values"] as? [NSNumber] else { return nil }
            self = .values(byte: byte, high: json["high"] as? Bool ?? false, values: Set(values.map(\.intValue)))
        case "threshold":
            guard let offset = int("offset"), let width = int("width"), let limit = int("limit") else { return nil }
            self = .threshold(offset: offset, width: width, limit: limit, below: json["below"] as? Bool ?? false)
        default:
            return nil
        }
    }
}

/// A controller model's controls, by GameController's names ("Button A", "Direction Pad Up", "Left Thumbstick Left"),
/// in its reports with one ID (others, e.g. replies to the host, aren't read).
struct GamepadLayout {
    /// The controller's name when it was learned, for Settings.
    var name: String
    var reportID: Int
    var controls: [String: GamepadField]

    func pressed(_ report: [UInt8]) -> Set<String>? {
        guard let id = report.first, Int(id) == reportID else { return nil }
        return Set(controls.filter { $0.value.isPressed(report) }.keys)
    }

    var json: [String: Any] {
        ["name": name, "reportID": reportID, "controls": controls.mapValues(\.json)]
    }

    init(name: String, reportID: Int, controls: [String: GamepadField]) {
        self.name = name
        self.reportID = reportID
        self.controls = controls
    }

    init?(json: [String: Any]) {
        guard let reportID = (json["reportID"] as? NSNumber)?.intValue, let controls = json["controls"] as? [String: Any] else { return nil }
        name = json["name"] as? String ?? "Controller"
        self.reportID = reportID
        self.controls = controls.compactMapValues { ($0 as? [String: Any]).flatMap(GamepadField.init(json:)) }
    }
}

/// What a learning session saw: the controller's reports, and GameController's state of it, with the time each came.
struct GamepadRecording {
    struct State {
        let time: Double
        /// Pressed buttons, D-pad directions, and stick directions (see GamepadControls).
        let pressed: Set<String>
        /// Analog buttons' values (0 to 1) and stick axes (-1 to 1, "Left Thumbstick X").
        let analog: [String: Double]
    }

    var reports: [(time: Double, bytes: [UInt8])] = []
    var states: [State] = []
    /// Buttons GameController reads as analog (triggers).
    var analogButtons: Set<String> = []

    var json: [String: Any] {
        [
            "analogButtons": analogButtons.sorted(),
            "reports": reports.map { ["time": $0.time, "bytes": $0.bytes] as [String: Any] },
            "states": states.map { ["time": $0.time, "pressed": $0.pressed.sorted(), "analog": $0.analog] as [String: Any] },
        ]
    }

    init() {}

    init(json: [String: Any]) {
        analogButtons = Set(json["analogButtons"] as? [String] ?? [])
        reports = (json["reports"] as? [[String: Any]] ?? []).map {
            (($0["time"] as? NSNumber)?.doubleValue ?? 0, ($0["bytes"] as? [NSNumber] ?? []).map(\.uint8Value))
        }
        states = (json["states"] as? [[String: Any]] ?? []).map {
            State(
                time: ($0["time"] as? NSNumber)?.doubleValue ?? 0,
                pressed: Set($0["pressed"] as? [String] ?? []),
                analog: ($0["analog"] as? [String: NSNumber] ?? [:]).mapValues(\.doubleValue)
            )
        }
    }
}

/// GameController's names for controls, and which ones MacPopup treats as directions rather than buttons.
enum GamepadControls {
    static let directions = ["Up", "Down", "Left", "Right"]
    static let sticks = ["Left Thumbstick", "Right Thumbstick"]

    /// A D-pad or stick direction ("Direction Pad Up", "Left Thumbstick Left"): these move between words, and aren't
    /// part of combinations.
    static func isDirection(_ name: String) -> Bool {
        directions.contains { name.hasSuffix(" \($0)") } && (name.hasPrefix("Direction Pad") || sticks.contains { name.hasPrefix($0) })
    }

    /// A short name for Settings, e.g. "A", "LB", "L3".
    static func shortName(_ name: String) -> String {
        let names = [
            "Left Shoulder": "LB", "Right Shoulder": "RB", "Left Trigger": "LT", "Right Trigger": "RT",
            "Left Thumbstick Button": "L3", "Right Thumbstick Button": "R3", "Touchpad Button": "Touchpad",
        ]
        if let short = names[name] { return short }
        return name.hasPrefix("Button ") ? String(name.dropFirst(7)) : name
    }

    /// The controls of a controller GameController doesn't describe, for learning them one at a time.
    static let standard = [
        "Button A", "Button B", "Button X", "Button Y", "Left Shoulder", "Right Shoulder", "Left Trigger", "Right Trigger",
        "Button Menu", "Button Options", "Button Home", "Left Thumbstick Button", "Right Thumbstick Button",
    ] + directions.map { "Direction Pad \($0)" }
}

/// Learns a layout from a recording (see GamepadRecording).
///
/// Each stretch of at least 60 ms in which GameController's state stays the same gives a sample: the report from its
/// middle, with that state. GameController's update and the report it read can come in either order, tens of
/// milliseconds apart (an Xbox controller's especially), so the report right at an update can be the one before.
/// Then each control gets the field of the reports that best agrees with whether it's pressed: in at least 75% of the
/// samples where it's pressed (a press quicker than GameController's update leaves a sample labeled pressed with the
/// report released) and 97% of the others, each counted on its own (or a rarely pressed control would match a bit that
/// never changes).
enum GamepadLearning {
    struct Sample {
        let report: [UInt8]
        let pressed: Set<String>
        let analog: [String: Double]
    }

    /// The ID of the controller's input reports: the most common one. Others (e.g. a Switch controller's replies to the
    /// host) can have the same length and other bytes.
    static func mainReportID(_ reports: [(time: Double, bytes: [UInt8])]) -> UInt8? {
        let ids = Dictionary(reports.map { ($0.bytes.first ?? 0, 1) }, uniquingKeysWith: +)
        return ids.max(by: { $0.value < $1.value })?.key
    }

    static func samples(_ recording: GamepadRecording) -> [Sample] {
        guard let reportID = mainReportID(recording.reports) else { return [] }
        let reports = recording.reports.filter { $0.bytes.first == reportID }
        let lastTime = reports.last?.time ?? 0
        // Stick moves update the analog values all the time: stretches are where the pressed controls stay the same.
        var changes: [GamepadRecording.State] = []
        for state in recording.states where state.pressed != changes.last?.pressed { changes.append(state) }
        var samples: [Sample] = []
        var reportIndex = 0
        var stateIndex = 0
        for (index, change) in changes.enumerated() {
            let end = index + 1 < changes.count ? changes[index + 1].time : lastTime
            guard end - change.time >= 0.06 else { continue }
            let middle = (change.time + end) / 2
            while reportIndex + 1 < reports.count, reports[reportIndex + 1].time <= middle { reportIndex += 1 }
            while stateIndex + 1 < recording.states.count, recording.states[stateIndex + 1].time <= middle { stateIndex += 1 }
            guard reportIndex < reports.count, reports[reportIndex].time <= middle else { continue }
            samples.append(Sample(report: reports[reportIndex].bytes, pressed: change.pressed, analog: recording.states[stateIndex].analog))
        }
        return samples
    }

    /// The layout learned for `controls` (those that couldn't be are left out), or nil without samples.
    static func layout(_ recording: GamepadRecording, controls: [String]) -> GamepadLayout? {
        let samples = samples(recording)
        guard let reportID = samples.first?.report.first else { return nil }
        var learned: [String: GamepadField] = [:]
        // A D-pad sent as a hat switch, all four directions at once.
        if controls.contains(where: { $0.hasPrefix("Direction Pad ") }) {
            learned = hat("Direction Pad", samples) ?? [:]
        }
        // Sticks: an axis each, found by how it follows GameController's value, then a threshold for each direction.
        for stick in GamepadControls.sticks {
            for (axis, directions) in [("X", [("Right", true), ("Left", false)]), ("Y", [("Up", true), ("Down", false)])] {
                let names = directions.map { "\(stick) \($0.0)" }
                guard names.contains(where: controls.contains), let found = analogField("\(stick) \(axis)", samples) else { continue }
                for (direction, positive) in directions {
                    let name = "\(stick) \(direction)"
                    guard controls.contains(name) else { continue }
                    // Pressed toward the axis's high values when they go the same way as GameController's.
                    if let field = threshold(name, offset: found.offset, width: found.width, below: positive != found.increasing, samples) {
                        learned[name] = field
                    }
                }
            }
        }
        // Buttons, and D-pad directions that aren't a hat switch's (sticks only have their axes).
        for control in controls where learned[control] == nil && (!GamepadControls.isDirection(control) || control.hasPrefix("Direction Pad")) {
            // An analog trigger's low bits can agree by chance, so its value goes first.
            if recording.analogButtons.contains(control), let found = analogField(control, samples),
               let field = threshold(control, offset: found.offset, width: found.width, below: !found.increasing, samples) {
                learned[control] = field
            } else if let field = digitalField(control, samples) {
                learned[control] = field
            }
        }
        return GamepadLayout(name: "", reportID: Int(reportID), controls: learned)
    }

    /// How well a field agrees with whether `control` is pressed: the lower of its share of the pressed samples and of
    /// the others, or 0 if the first is under 75% or the second under 97% (see GamepadLearning).
    private static func agreement(_ control: String, _ samples: [Sample], _ isPressed: ([UInt8]) -> Bool) -> Double {
        var pressed = 0, hits = 0, released = 0, rejections = 0
        for sample in samples {
            let field = isPressed(sample.report)
            if sample.pressed.contains(control) {
                pressed += 1
                if field { hits += 1 }
            } else {
                released += 1
                if !field { rejections += 1 }
            }
        }
        guard pressed >= 3, released >= 3 else { return 0 }
        let hitRate = Double(hits) / Double(pressed), rejectionRate = Double(rejections) / Double(released)
        return hitRate >= 0.75 && rejectionRate >= 0.97 ? min(hitRate, rejectionRate) : 0
    }

    /// A bit, or else a nibble that takes few values (a counter or stick takes many): a button that isn't analog.
    private static func digitalField(_ control: String, _ samples: [Sample]) -> GamepadField? {
        guard let length = samples.map(\.report.count).min() else { return nil }
        var best: (field: GamepadField, agreement: Double)?
        func consider(_ field: GamepadField) {
            let score = agreement(control, samples, field.isPressed)
            if score > best?.agreement ?? 0 { best = (field, score) }
        }
        for byte in 1..<length {
            for bit in 0..<8 {
                for inverted in [false, true] { consider(.bit(byte: byte, bit: bit, inverted: inverted)) }
            }
        }
        for byte in 1..<length {
            for high in [false, true] {
                var counts: [Int: (pressed: Int, released: Int)] = [:]
                for sample in samples {
                    let value = Int(high ? sample.report[byte] >> 4 : sample.report[byte] & 0x0F)
                    if sample.pressed.contains(control) { counts[value, default: (0, 0)].pressed += 1 } else { counts[value, default: (0, 0)].released += 1 }
                }
                guard counts.count <= 9 else { continue }
                let values = Set(counts.filter { $0.value.pressed > $0.value.released }.keys)
                if !values.isEmpty { consider(.values(byte: byte, high: high, values: values)) }
            }
        }
        return best?.field
    }

    /// A D-pad sent as a hat switch: one nibble whose value, with one direction pressed, is mostly up u, right u + 2,
    /// down u + 4, left u + 6 (u 0 or 1, counting around 8). Each direction then also takes its two diagonals, whether
    /// or not they were pressed while learning.
    private static func hat(_ dpad: String, _ samples: [Sample]) -> [String: GamepadField]? {
        let directions = ["Up", "Right", "Down", "Left"]
        guard let length = samples.map(\.report.count).min() else { return nil }
        for byte in 1..<length {
            for high in [false, true] {
                var main: [Int] = []
                for direction in directions {
                    let alone = samples.filter { sample in
                        sample.pressed.contains("\(dpad) \(direction)") && directions.filter { sample.pressed.contains("\(dpad) \($0)") }.count == 1
                    }
                    let counts = Dictionary(alone.map { (Int(high ? $0.report[byte] >> 4 : $0.report[byte] & 0x0F), 1) }, uniquingKeysWith: +)
                    guard let (value, count) = counts.max(by: { $0.value < $1.value }), count >= 2 else { break }
                    main.append(value)
                }
                guard main.count == 4, main[0] <= 1, main == [0, 2, 4, 6].map({ main[0] + $0 }) else { continue }
                let base = main[0]
                var fields: [String: GamepadField] = [:]
                for (direction, value) in zip(directions, main) {
                    let around = [-1, 0, 1].map { base + (value - base + $0 + 8) % 8 }
                    fields["\(dpad) \(direction)"] = .values(byte: byte, high: high, values: Set(around))
                }
                return fields
            }
        }
        return nil
    }

    /// The field that best follows GameController's analog value `name` (a trigger's, or a stick axis'): the highest
    /// correlation, among fields starting on a nibble that are 8, 12 or 16 bits wide and whose lowest and highest nibble
    /// both change (a field reaching into bits that don't change, e.g. the report ID, would agree as well). Of fields
    /// that correlate about as well, the widest: a 10-bit trigger's low byte follows it too while it's pulled all the
    /// way or not at all, but goes around while it's pulled part of the way.
    private static func analogField(_ name: String, _ samples: [Sample]) -> (offset: Int, width: Int, increasing: Bool)? {
        let analog = samples.compactMap { sample in sample.analog[name].map { (sample.report, $0) } }
        guard analog.count >= 6, let length = analog.map(\.0.count).min() else { return nil }
        let targets = analog.map(\.1)
        var candidates: [(offset: Int, width: Int, correlation: Double)] = []
        for width in [8, 12, 16] {
            for offset in stride(from: 8, through: length * 8 - width, by: 4) {
                let values = analog.map { Double(GamepadField.bits($0.0, offset: offset, width: width)!) }
                let low = Set(analog.map { GamepadField.bits($0.0, offset: offset, width: 4)! })
                let high = Set(analog.map { GamepadField.bits($0.0, offset: offset + width - 4, width: 4)! })
                guard low.count > 1, high.count > 1, let correlation = correlation(values, targets) else { continue }
                candidates.append((offset, width, correlation))
            }
        }
        guard let best = candidates.map({ abs($0.correlation) }).max(), best >= 0.8 else { return nil }
        let chosen = candidates.filter { abs($0.correlation) >= best - 0.01 }.max { ($0.width, abs($0.correlation)) < ($1.width, abs($1.correlation)) }!
        return (chosen.offset, chosen.width, chosen.correlation > 0)
    }

    private static func correlation(_ xs: [Double], _ ys: [Double]) -> Double? {
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        return covariance / (varianceX * varianceY).squareRoot()
    }

    /// The limit on an analog field that best agrees with whether `control` is pressed: halfway between the values it
    /// should take and those it shouldn't, so a press a little lighter than any seen still counts.
    private static func threshold(_ control: String, offset: Int, width: Int, below: Bool, _ samples: [Sample]) -> GamepadField? {
        let values = Set(samples.compactMap { GamepadField.bits($0.report, offset: offset, width: width) }).sorted()
        var best: (limit: Int, agreement: Double)?
        for limit in values {
            let score = agreement(control, samples, GamepadField.threshold(offset: offset, width: width, limit: limit, below: below).isPressed)
            if score > best?.agreement ?? 0 { best = (limit, score) }
        }
        guard let best else { return nil }
        let next = below ? values.first { $0 > best.limit } : values.last { $0 < best.limit }
        let limit = next.map { below ? (best.limit + $0) / 2 : ($0 + best.limit + 1) / 2 } ?? best.limit
        return .threshold(offset: offset, width: width, limit: limit, below: below)
    }

    /// A control GameController doesn't report, learned from one press (see GamepadController.learnPress): the bits
    /// that changed from `before` to `during`, other than `noise` (bits that changed by themselves meanwhile, e.g. a
    /// stick's). A D-pad direction whose nibble was a hat switch's neutral value (8, or 0 or 15) takes that hat's
    /// diagonals too; otherwise the first byte that changed, its highest changed bit (an analog value's, past half).
    static func field(for control: String, before: [UInt8], during: [UInt8], noise: [UInt8]) -> GamepadField? {
        let length = min(before.count, during.count)
        guard let byte = (1..<length).first(where: { (before[$0] ^ during[$0]) & ~(noise.indices.contains($0) ? noise[$0] : 0) != 0 }) else { return nil }
        let changed = (before[byte] ^ during[byte]) & ~(noise.indices.contains(byte) ? noise[byte] : 0)
        if control.hasPrefix("Direction Pad "), changed & 0xF0 == 0 || changed & 0x0F == 0 {
            let high = changed & 0x0F == 0
            let neutral = Int(high ? before[byte] >> 4 : before[byte] & 0x0F)
            let value = Int(high ? during[byte] >> 4 : during[byte] & 0x0F)
            if [8, 0, 15].contains(neutral), value != neutral, value <= 8 {
                let base = neutral == 0 ? 1 : 0
                let around = [-1, 0, 1].map { base + (value - base + $0 + 8) % 8 }
                return .values(byte: byte, high: high, values: Set(around))
            }
        }
        let bit = 7 - changed.leadingZeroBitCount
        return .bit(byte: byte, bit: bit, inverted: before[byte] >> bit & 1 == 1)
    }
}
