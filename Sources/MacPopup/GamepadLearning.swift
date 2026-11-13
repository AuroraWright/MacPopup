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
/// in its reports with one ID, and in any other kind of report it was set up with: a Joy-Con sends a full report in a
/// pair but a simple one on its own. Other reports (e.g. replies to the host) aren't read.
struct GamepadLayout {
    /// The controller's name when it was learned, for Settings.
    var name: String
    var reportID: Int
    var controls: [String: GamepadField]
    /// The controls in the other kinds of report it was set up with, by their ID.
    var otherReports: [Int: [String: GamepadField]] = [:]

    func pressed(_ report: [UInt8]) -> Set<String>? {
        guard let id = report.first.map(Int.init), let controls = id == reportID ? controls : otherReports[id] else { return nil }
        return Set(controls.filter { $0.value.isPressed(report) }.keys)
    }

    func reads(reportID id: Int) -> Bool {
        id == reportID || otherReports[id] != nil
    }

    /// Adds controls learned in reports with `id`, over those learned before.
    mutating func add(_ learned: [String: GamepadField], reportID id: Int) {
        if id == reportID {
            controls.merge(learned) { _, new in new }
        } else if !learned.isEmpty {
            otherReports[id, default: [:]].merge(learned) { _, new in new }
        }
    }

    var json: [String: Any] {
        var json: [String: Any] = ["name": name, "reportID": reportID, "controls": controls.mapValues(\.json)]
        if !otherReports.isEmpty {
            json["otherReports"] = Dictionary(uniqueKeysWithValues: otherReports.map { (String($0.key), $0.value.mapValues(\.json)) })
        }
        return json
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
        self.controls = Self.controls(controls)
        for (id, controls) in json["otherReports"] as? [String: Any] ?? [:] {
            guard let id = Int(id), let controls = controls as? [String: Any] else { continue }
            otherReports[id] = Self.controls(controls)
        }
    }

    private static func controls(_ json: [String: Any]) -> [String: GamepadField] {
        json.compactMapValues { ($0 as? [String: Any]).flatMap(GamepadField.init(json:)) }
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

    static func isStickDirection(_ name: String) -> Bool {
        isDirection(name) && !name.hasPrefix("Direction Pad")
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

    /// The controls on each half of a controller that macOS joins from two devices: a pair of Joy-Cons is one
    /// controller, "Joy-Con (L/R)", in GameController, but each Joy-Con sends its own reports.
    static let halves: [String: [String: Set<String>]] = [
        "Joy-Con (L/R)": [
            "Joy-Con (L)": Set(["Left Shoulder", "Left Trigger", "Button Options", "Left Thumbstick Button"]
                + directions.map { "Direction Pad \($0)" } + directions.map { "Left Thumbstick \($0)" }),
            "Joy-Con (R)": Set(["Button A", "Button B", "Button X", "Button Y", "Right Shoulder", "Right Trigger", "Button Menu",
                                "Button Home", "Right Thumbstick Button"] + directions.map { "Right Thumbstick \($0)" }),
        ],
    ]

    /// Controllers GameController names but sends no changes for: a Joy-Con on its own (which macOS also leaves sending
    /// its simple report). They're learned one control at a time.
    static let silent: Set<String> = ["Joy-Con (L)", "Joy-Con (R)"]

    /// The controls of a controller GameController doesn't describe, for learning them one at a time.
    static let standard = [
        "Button A", "Button B", "Button X", "Button Y", "Left Shoulder", "Right Shoulder", "Left Trigger", "Right Trigger",
        "Button Menu", "Button Options", "Button Home", "Left Thumbstick Button", "Right Thumbstick Button",
    ] + directions.map { "Direction Pad \($0)" }
}

/// Learns a layout from a recording (see GamepadRecording).
///
/// Each stretch in which GameController's state stays the same gives a sample: the report from its middle, with that
/// state, and the reports of its middle half. GameController's update and the report it read can come in either order,
/// tens of milliseconds apart (an Xbox controller's especially), so the report right at an update can be the one
/// before. The last stretch, which may still be going on (its middle then being a press's start), is left out. Then
/// each control gets the field of the reports that best agrees with whether it's pressed: in at least 75% of the
/// samples where it's pressed, at least two (a press quicker than GameController's update leaves a sample labeled
/// pressed with the report released), and in 97% of the reports of the others, each counted on its own (or a rarely
/// pressed control would match a bit that never changes). All of their reports, not just one each, so that a field
/// changing by itself (a stick's low byte, which a thumbstick click moves too) shows it, even after one or two presses.
enum GamepadLearning {
    struct Sample {
        let report: [UInt8]
        let pressed: Set<String>
        let analog: [String: Double]
        /// The reports of the middle half of its stretch, `report` among them.
        let reports: [[UInt8]]
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
        // Stick moves update the analog values all the time: stretches are where the pressed controls stay the same.
        var changes: [GamepadRecording.State] = []
        for state in recording.states where state.pressed != changes.last?.pressed { changes.append(state) }
        var samples: [Sample] = []
        var reportIndex = 0
        var stateIndex = 0
        for (change, next) in zip(changes, changes.dropFirst()) {
            let middle = (change.time + next.time) / 2
            while reportIndex + 1 < reports.count, reports[reportIndex + 1].time <= middle { reportIndex += 1 }
            while stateIndex + 1 < recording.states.count, recording.states[stateIndex + 1].time <= middle { stateIndex += 1 }
            guard reportIndex < reports.count, reports[reportIndex].time <= middle else { continue }
            let quarter = (next.time - change.time) / 4
            let around = reports.indices.filter { $0 == reportIndex || abs(reports[$0].time - middle) <= quarter }.map { reports[$0].bytes }
            samples.append(Sample(report: reports[reportIndex].bytes, pressed: change.pressed, analog: recording.states[stateIndex].analog, reports: around))
        }
        return samples
    }

    /// The layout learned for `controls` (those that couldn't be are left out), or nil without samples.
    static func layout(_ recording: GamepadRecording, controls: [String]) -> GamepadLayout? {
        let samples = samples(recording)
        guard let reportID = samples.first?.report.first else { return nil }
        // A stick's moves with the reports a little later, as those come after GameController's (see stickThreshold).
        // Its field is found from them too, as one push gives a sample or two.
        let moves = stickMoves(recording, reportID: reportID, delay: 0.01)
        var learned: [String: GamepadField] = [:]
        // A D-pad sent as a hat switch, all four directions at once.
        if controls.contains(where: { $0.hasPrefix("Direction Pad ") }) {
            learned = hat("Direction Pad", samples) ?? [:]
        }
        // Sticks: an axis each, found by how it follows GameController's value, then a threshold for each direction.
        for stick in GamepadControls.sticks {
            for (axis, directions) in [("X", [("Right", true), ("Left", false)]), ("Y", [("Up", true), ("Down", false)])] {
                let names = directions.map { "\(stick) \($0.0)" }
                guard names.contains(where: controls.contains), let found = analogField("\(stick) \(axis)", moves.map { ($0.report, $0.analog) }) else { continue }
                for (direction, positive) in directions {
                    let name = "\(stick) \(direction)"
                    guard controls.contains(name) else { continue }
                    // Pressed toward the axis's high values when they go the same way as GameController's.
                    if let field = stickThreshold("\(stick) \(axis)", positive: positive, offset: found.offset, width: found.width,
                                                  below: positive != found.increasing, moves) {
                        learned[name] = field
                    }
                }
            }
        }
        // Buttons, and directions that aren't a hat switch's or an axis's (an N64 controller's C buttons, which
        // GameController calls a stick). D-pad directions only once each was pressed on its own: until then, a value
        // or bit of a hat switch passes for one (without its diagonals).
        let dpad = GamepadControls.directions.map { "Direction Pad \($0)" }
        let dpadPressed = dpad.allSatisfy { direction in samples.contains { $0.pressed.intersection(dpad) == [direction] } }
        for control in controls where learned[control] == nil && (dpadPressed || !dpad.contains(control)) {
            // An analog trigger's low bits can agree by chance, so its value goes first.
            if recording.analogButtons.contains(control), let found = analogField(control, samples.map { ($0.report, $0.analog) }),
               let field = threshold(control, offset: found.offset, width: found.width, below: !found.increasing, samples) {
                learned[control] = field
            } else if let field = digitalField(control, samples) {
                learned[control] = field
            }
        }
        return GamepadLayout(name: "", reportID: Int(reportID), controls: learned)
    }

    /// How well a field agrees with whether a control is pressed (`held`, for each sample): the lower of its share of
    /// the pressed samples and of the others' reports, or 0 if the first is under 75% or the second under 97% (see
    /// GamepadLearning). The pressed samples go first, as most fields don't pass them, and the others' reports stop
    /// being counted once too many are pressed.
    private static func agreement(_ held: [Bool], _ samples: [Sample], _ isPressed: ([UInt8]) -> Bool) -> Double {
        var pressed = 0, hits = 0
        for (sample, isHeld) in zip(samples, held) where isHeld {
            pressed += 1
            if isPressed(sample.report) { hits += 1 }
        }
        let released = zip(samples, held).reduce(0) { $0 + ($1.1 ? 0 : $1.0.reports.count) }
        guard pressed >= 2, Double(hits) >= 0.75 * Double(pressed), released >= 3 else { return 0 }
        var misses = 0
        for (sample, isHeld) in zip(samples, held) where !isHeld {
            for report in sample.reports where isPressed(report) {
                misses += 1
                if Double(misses) > 0.03 * Double(released) { return 0 }
            }
        }
        return min(Double(hits) / Double(pressed), 1 - Double(misses) / Double(released))
    }

    /// A bit, or else a nibble that takes few values (a counter or stick takes many): a button that isn't analog.
    private static func digitalField(_ control: String, _ samples: [Sample]) -> GamepadField? {
        guard let length = samples.map(\.report.count).min() else { return nil }
        let held = samples.map { $0.pressed.contains(control) }
        var best: (field: GamepadField, agreement: Double)?
        func consider(_ field: GamepadField) {
            let score = agreement(held, samples, field.isPressed)
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
                for (sample, isHeld) in zip(samples, held) {
                    let value = Int(high ? sample.report[byte] >> 4 : sample.report[byte] & 0x0F)
                    if isHeld { counts[value, default: (0, 0)].pressed += 1 } else { counts[value, default: (0, 0)].released += 1 }
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
                    guard let value = counts.max(by: { $0.value < $1.value })?.key else { break }
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
    /// way or not at all, but goes around while it's pulled part of the way. But not a field with a part that follows
    /// another control's value: on a DS4, an axis's byte and the axis before it agree about as well as the byte alone,
    /// and so does an Xbox trigger pulled only all the way with the top of the axis before it.
    private static func analogField(_ name: String, _ samples: [(report: [UInt8], analog: [String: Double])]) -> (offset: Int, width: Int, increasing: Bool)? {
        let analog = samples.compactMap { sample in sample.analog[name].map { (sample.report, $0) } }
        guard analog.count >= 6, let length = analog.map(\.0.count).min() else { return nil }
        let targets = analog.map(\.1)
        let others = Set(samples.flatMap(\.analog.keys)).subtracting([name])
        func followsAnother(offset: Int, width: Int) -> Bool {
            guard width > 8 else { return false }
            // Every part of it on nibbles: another axis can end anywhere in it (on a Pro Controller, a 12-bit axis's
            // lowest nibble shares a byte with the top of the one before it).
            let parts = stride(from: 4, to: width, by: 4).flatMap { partWidth in
                stride(from: offset, through: offset + width - partWidth, by: 4).map { ($0, partWidth) }
            }
            return parts.contains { partOffset, partWidth in
                let part = { (report: [UInt8]) in GamepadField.bits(report, offset: partOffset, width: partWidth).map(Double.init) }
                let own = correlation(analog.compactMap { part($0.0) }, targets).map(abs) ?? 0
                return others.contains { other in
                    let pairs = samples.compactMap { sample in sample.analog[other].flatMap { value in part(sample.report).map { ($0, value) } } }
                    guard pairs.count >= 6, let match = correlation(pairs.map(\.0), pairs.map(\.1)).map(abs) else { return false }
                    // (A stick's lowest bits are noise, which can follow another control about half as well by chance.)
                    return match >= 0.7 && match > own
                }
            }
        }
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
        // The best and those about as good, best first, leaving out those that follow another control (checked only
        // for these few, as it's slow).
        var good: [(offset: Int, width: Int, correlation: Double)] = []
        for candidate in candidates.sorted(by: { abs($0.correlation) > abs($1.correlation) }) {
            if let best = good.first, abs(candidate.correlation) < abs(best.correlation) - 0.01 { break }
            if !followsAnother(offset: candidate.offset, width: candidate.width) { good.append(candidate) }
        }
        guard let best = good.first, abs(best.correlation) >= 0.8 else { return nil }
        let chosen = good.max { ($0.width, abs($0.correlation)) < ($1.width, abs($1.correlation)) }!
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

    /// The limit on an analog field that best agrees with whether `control` is pressed (see midway).
    private static func threshold(_ control: String, offset: Int, width: Int, below: Bool, _ samples: [Sample]) -> GamepadField? {
        let values = Set(samples.compactMap { GamepadField.bits($0.report, offset: offset, width: width) }).sorted()
        let held = samples.map { $0.pressed.contains(control) }
        var best: (limit: Int, agreement: Double)?
        for limit in values {
            let score = agreement(held, samples, GamepadField.threshold(offset: offset, width: width, limit: limit, below: below).isPressed)
            if score > best?.agreement ?? 0 { best = (limit, score) }
        }
        guard let best else { return nil }
        return .threshold(offset: offset, width: width, limit: midway(best.limit, values, below: below), below: below)
    }

    /// A GameController state with the report then, and how many reports came while it lasted.
    private typealias Move = (report: [UInt8], analog: [String: Double], reports: Int)

    /// Each of GameController's states with the report `delay` seconds later: a stick's every move, where samples only
    /// have a push's one or two steady stretches.
    private static func stickMoves(_ recording: GamepadRecording, reportID: UInt8, delay: Double) -> [Move] {
        let reports = recording.reports.filter { $0.bytes.first == reportID }
        let states = recording.states
        var index = 0
        return states.indices.compactMap { n in
            let time = states[n].time + delay
            while index + 1 < reports.count, reports[index + 1].time <= time { index += 1 }
            guard index < reports.count, reports[index].time <= time else { return nil }
            let end = n + 1 < states.count ? states[n + 1].time + delay : .infinity
            var last = index
            while last + 1 < reports.count, reports[last + 1].time < end { last += 1 }
            return (reports[index].bytes, states[n].analog, last - index + 1)
        }
    }

    /// The limit on a stick axis's field where GameController's value reaches halfway, where it counts the direction
    /// as pressed (`positive`: toward 1): the one the fewest of its moves disagree with. Not by agreement with the
    /// pressed samples, as for buttons: one push gives only a sample or two, GameController gets a move before its
    /// report comes (10 ms for a DS4 over Bluetooth, so `moves` pair each state with a later report), and samples
    /// rarely fall between a light push and halfway, so a limit a tenth of the way out would agree as well.
    private static func stickThreshold(_ axis: String, positive: Bool, offset: Int, width: Int, below: Bool,
                                       _ moves: [Move]) -> GamepadField? {
        let pairs = moves.compactMap { move in
            move.analog[axis].flatMap { value in
                GamepadField.bits(move.report, offset: offset, width: width).map { ($0, positive ? value >= 0.5 : value <= -0.5, move.reports) }
            }
        }
        // Pressed for 3 reports or more, however many states: GameController only sends changes, so a Joy-Con's stick
        // pushed all the way and back can give two.
        guard pairs.filter(\.1).map(\.2).reduce(0, +) >= 3 else { return nil }
        let values = Set(pairs.map(\.0)).sorted()
        let errors = values.map { limit in pairs.filter { (below ? $0.0 <= limit : $0.0 >= limit) != $0.1 }.count }
        guard let fewest = errors.min() else { return nil }
        // Of the limits as good as the best, the middle one: the first would be the lightest push.
        let best = zip(values, errors).filter { $0.1 == fewest }.map(\.0)
        let limit = best[best.count / 2]
        return .threshold(offset: offset, width: width, limit: midway(limit, values, below: below), below: below)
    }

    /// Halfway between a limit and the next value seen beyond it, so a press a little lighter than any seen still
    /// counts.
    private static func midway(_ limit: Int, _ values: [Int], below: Bool) -> Int {
        let next = below ? values.first { $0 > limit } : values.last { $0 < limit }
        return next.map { below ? (limit + $0) / 2 : ($0 + limit + 1) / 2 } ?? limit
    }

    /// A control GameController doesn't report, learned from one press (see GamepadController.learnPress): the bits
    /// that changed from `before` to `during` (with the reports `between`), other than `noise` (bits that changed by
    /// themselves meanwhile, e.g. a stick's). A stick direction is an analog field that moved (see pushedField: with
    /// the stick's other `pushes` so far), or else a hat switch's like a D-pad direction: one whose nibble was a hat
    /// switch's neutral value (8, or 0 or 15) and became the direction's value (any, for a stick's: a Joy-Con's turns
    /// with it) takes that hat's diagonals too. Otherwise it's the first byte where one bit changed, and only ever that
    /// one, or else an analog value's highest changed bit (past half), if it rested at an end and moved through values
    /// in between. A stick direction can be a bit too (an N64 controller's C buttons, which GameController calls a
    /// stick), told from `bitNoise` (a button's noise: a stick's only has what changes nearly always) if it was all
    /// that changed in its byte and, once held in two reports or more, let go again (a nudged stick's low bit stays).
    static func field(for control: String, before: [UInt8], during: [UInt8], between: [[UInt8]] = [], pushes: [String: [[UInt8]]] = [:],
                      noise: [UInt8], bitNoise: [UInt8]? = nil) -> GamepadField? {
        let isStick = GamepadControls.isStickDirection(control)
        if isStick, let field = pushedField(control, pushes: pushes.merging([control: [before] + between + [during]]) { $1 }, noise: noise) {
            return field
        }
        let length = min(before.count, during.count)
        let changes = { (report: [UInt8], index: Int) -> UInt8 in
            index < report.count ? (before[index] ^ report[index]) & ~(noise.indices.contains(index) ? noise[index] : 0) : 0
        }
        // The press as it was last held (it may be let go by now): its first changed byte, and how.
        let held: [UInt8] = ([during] + between.reversed()).first { report in (1..<length).contains { changes(report, $0) != 0 } } ?? during
        let byte = (1..<length).first { changes(held, $0) != 0 }
        let changed = byte.map { changes(held, $0) } ?? 0
        if let byte, GamepadControls.isDirection(control), changed & 0xF0 == 0 || changed & 0x0F == 0 {
            let high = changed & 0x0F == 0
            let neutral = Int(high ? before[byte] >> 4 : before[byte] & 0x0F)
            let value = Int(high ? held[byte] >> 4 : held[byte] & 0x0F)
            let base = neutral == 0 ? 1 : 0
            // A D-pad's hat gives a direction's own value (clockwise from Up); D-pad buttons that are bits of their own
            // (a Joy-Con's: 1, 2, 4, 8) give others.
            let cardinal = ["Up": 0, "Right": 2, "Down": 4, "Left": 6].first { control.hasSuffix(" \($0.key)") }.map { base + $0.value }
            if [8, 0, 15].contains(neutral), value != neutral, value <= 8, isStick || value == cardinal {
                let around = Set([-1, 0, 1].map { base + (value - base + $0 + 8) % 8 })
                // A stick's hat is all that changes in its push (an analog stick's low bits move with the rest of it).
                let alone = (between + [during]).allSatisfy { report in
                    (1..<length).allSatisfy { changes(report, $0) & ($0 == byte ? (high ? 0x0F : 0xF0) : 0xFF) == 0 }
                }
                if !isStick || alone { return .values(byte: byte, high: high, values: around) }
            }
        }
        // A button (maybe let go by now): a byte where one bit changed, and only ever that one all through (or until
        // another of its bits did, once it was held: a second button pressed right after), and on its own: not with the
        // bits just under it (even ones that change by themselves), as an analog value's does when it crosses over (a
        // stick that the press nudged, as clicking it does before the click counts).
        let path = between + [during]
        let bitNoise = bitNoise ?? noise
        let button = (1..<length).lazy.compactMap { index -> (byte: Int, bit: Int)? in
            let differences = path.map { (before[index] ^ $0[index]) & ~(bitNoise.indices.contains(index) ? bitNoise[index] : 0) }
            guard let first = differences.firstIndex(where: { $0 != 0 }), differences[first].nonzeroBitCount == 1 else { return nil }
            let only = differences[first]
            let end: Int = differences[first...].firstIndex(where: { $0 != 0 && $0 != only }) ?? path.count
            let reports = differences[first..<end].filter { $0 != 0 }.count
            guard isStick ? end == path.count && (path.count == 1 || reports >= 2 && differences.last == 0) : end == path.count || reports >= 2
            else { return nil }
            let pressed = Array(path[..<end])
            let bit = index * 8 + only.trailingZeroBitCount
            let alone = zip([before] + pressed, pressed).allSatisfy { previous, report in
                GamepadField.bits(previous, offset: bit, width: 1) == GamepadField.bits(report, offset: bit, width: 1)
                    || GamepadField.bits(previous, offset: max(8, bit - 4), width: bit - max(8, bit - 4)) == GamepadField.bits(report, offset: max(8, bit - 4), width: bit - max(8, bit - 4))
            }
            return alone ? (index, only.trailingZeroBitCount) : nil
        }.first
        if let button { return .bit(byte: button.byte, bit: button.bit, inverted: before[button.byte] >> button.bit & 1 == 1) }
        // A stick's other bits would only be part of its value.
        guard !isStick else { return nil }
        // Else an analog value's highest changed bit (past half), if it rested at an end and went past values in between
        // (a trigger's; a stick's rests in the middle, and a motion sensor's top byte around 0 jumps from end to end).
        guard let byte, [0x00, 0xFF].contains(before[byte]), path.contains(where: { ![0x00, 0xFF].contains($0[byte]) }) else { return nil }
        let bit = 7 - changed.leadingZeroBitCount
        return .bit(byte: byte, bit: bit, inverted: before[byte] >> bit & 1 == 1)
    }

    /// A stick direction from pushes of its stick (each direction's reports, from resting to pushed, and maybe back):
    /// of the 8-, 12- and 16-bit fields on nibbles whose lowest nibble changed in its push, with no byte that's all
    /// `noise` (a counter's), that moved at least 10% of their range one way in its push (a stick pushed all the way
    /// moves 15–30%; 15% if the opposite push isn't known) and the other way in the opposite one's, and less than 25%
    /// in pushes across (which needn't be straight), the one that moved furthest. It's pressed from halfway between
    /// where it was and where its push took it.
    static func pushedField(_ direction: String, pushes: [String: [[UInt8]]], noise: [UInt8]) -> GamepadField? {
        guard let name = GamepadControls.directions.first(where: { direction.hasSuffix(" \($0)") }),
              let own = pushes[direction], let before = own.first else { return nil }
        let stick = direction.dropLast(name.count + 1)
        let opposite = ["Up": "Down", "Down": "Up", "Left": "Right", "Right": "Left"][name].flatMap { pushes["\(stick) \($0)"] }
        let across = (["Up", "Down"].contains(name) ? ["Left", "Right"] : ["Up", "Down"]).compactMap { pushes["\(stick) \($0)"] }
        let length = pushes.values.joined().map(\.count).min().map { min($0, noise.count) } ?? 0
        // The report where a push went furthest on a field (a quick one may be on its way back by the time it's
        // learned).
        func furthest(_ path: [[UInt8]], offset: Int, width: Int) -> Int {
            let values = path.map { GamepadField.bits($0, offset: offset, width: width)! }
            return values.indices.max { abs(values[$0] - values[0]) < abs(values[$1] - values[0]) } ?? 0
        }
        // How far a field moved over a push, to its furthest, as a share of its range (negative if down), if it started
        // in the middle quarter (a resting stick's centre; motion sensors, which a push moves too, rest near 0 or
        // gravity's value, and an axis's low byte, which a nudge swings as far as a push, anywhere), went the other way
        // by no more than a thumb's wobble, and from where it last turned moved one way all along (back by no more than
        // a stick's jitter, or a thumb slowing down, at each step): one whose top bits are another axis's middle ones
        // goes around. Nor anywhere in the push did it step over half its range from one report to the next (a stick's
        // moves less than a third, but an axis's low byte goes around).
        func moved(_ path: [[UInt8]], offset: Int, width: Int) -> Double? {
            let range = 1 << width
            let all = path.map { GamepadField.bits($0, offset: offset, width: width)! }
            let values = Array(all.prefix(furthest(path, offset: offset, width: width) + 1))
            guard zip(all, all.dropFirst()).allSatisfy({ abs($1 - $0) <= range / 2 }),
                  let from = values.first, let to = values.last, (range * 3 / 8 ... range * 5 / 8).contains(from),
                  values.allSatisfy({ to > from ? $0 >= from - range / 16 : $0 <= from + range / 16 }),
                  let start = values.indices.min(by: { (values[$0] - to).magnitude > (values[$1] - to).magnitude }),
                  zip(values[start...], values[(start + 1)...]).allSatisfy({ to > from ? $1 >= $0 - range / 64 : $1 <= $0 + range / 64 })
            else { return nil }
            return Double(to - from) / Double(range)
        }
        var found: [(field: GamepadField, moved: Double)] = []
        for width in [8, 12, 16] {
            let range = 1 << width
            for offset in stride(from: 8, through: length * 8 - width, by: 4) {
                // Its lowest nibble changed on the way, as an axis's does (not a value's below one that stayed), and
                // no byte of it counts.
                guard own.prefix(furthest(own, offset: offset, width: width) + 1).contains(where: {
                          GamepadField.bits($0, offset: offset, width: 4) != GamepadField.bits(before, offset: offset, width: 4)
                      }),
                      !(offset / 8 ... (offset + width - 1) / 8).contains(where: { noise[$0] == 0xFF }),
                      let move = moved(own, offset: offset, width: width), abs(move) >= (opposite == nil ? 0.15 : 0.1) else { continue }
                var distance = abs(move)
                if let opposite {
                    guard let back = moved(opposite, offset: offset, width: width), back * move < 0 else { continue }
                    distance += abs(back)
                }
                guard across.allSatisfy({ path in
                    let values = path.map { GamepadField.bits($0, offset: offset, width: width)! }
                    return values.allSatisfy { abs($0 - values[0]) < range / 4 }
                }) else { continue }
                let from = GamepadField.bits(before, offset: offset, width: width)!
                let to = GamepadField.bits(own[furthest(own, offset: offset, width: width)], offset: offset, width: width)!
                found.append((.threshold(offset: offset, width: width, limit: (from + to) / 2, below: to < from), distance))
            }
        }
        // The one that moved furthest: an axis's top bits move as far as all of it, and so does a field that adds
        // another axis's top bits below them, so any of those is the axis.
        return found.max { $0.moved < $1.moved }?.field
    }
}
