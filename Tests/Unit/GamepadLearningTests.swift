// Learning a controller's raw HID reports (GamepadLearning.field) and the learned layout (GamepadLayout), on made-up
// reports of a single Joy-Con. The learning on real controllers' recordings is checked locally (the recordings aren't
// in the repo).
import Foundation
import Testing
@testable import MacPopup

/// A single Joy-Con's simple report (0x3F): buttons in bytes 1-2, the stick as a hat in byte 3 (8 = centre).
private let rest: [UInt8] = [0x3f, 0x00, 0x00, 0x08, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80]

private func learned(_ control: String, byte: Int, value: UInt8) -> GamepadField? {
    var during = rest
    during[byte] = value
    return GamepadLearning.field(for: control, before: rest, during: during, noise: [UInt8](repeating: 0, count: rest.count))
}

@Test func buttonsAreTheBitThatChanged() {
    #expect(learned("Button A", byte: 1, value: 0x01) == .bit(byte: 1, bit: 0, inverted: false))
    #expect(learned("Button Home", byte: 2, value: 0x10) == .bit(byte: 2, bit: 4, inverted: false))
}

@Test func hatDirectionsTakeTheirDiagonals() {
    #expect(learned("Direction Pad Down", byte: 3, value: 4) == .values(byte: 3, high: false, values: [3, 4, 5]))
    #expect(learned("Right Thumbstick Up", byte: 3, value: 0) == .values(byte: 3, high: false, values: [7, 0, 1]))
    #expect(learned("Right Thumbstick Right", byte: 3, value: 2) == .values(byte: 3, high: false, values: [1, 2, 3]))
    #expect(learned("Right Thumbstick Left", byte: 3, value: 6) == .values(byte: 3, high: false, values: [5, 6, 7]))
}

@Test func anOlderLayoutGetsASecondReportKind() throws {
    // A layout saved by MacPopup 1.1 (report 0x30 only), then a single Joy-Con's controls (report 0x3F) added to it.
    var layout = try #require(GamepadLayout(json: ["name": "Joy-Con (R)", "reportID": 48,
                                                   "controls": ["Button A": ["type": "bit", "byte": 3, "bit": 3, "inverted": false]]]))
    #expect(layout.reads(reportID: 48))
    #expect(!layout.reads(reportID: 63))
    layout.add(["Button A": .bit(byte: 1, bit: 0, inverted: false),
                "Direction Pad Up": .values(byte: 3, high: false, values: [7, 0, 1])], reportID: 63)

    // Saved and loaded again.
    let data = try JSONSerialization.data(withJSONObject: layout.json, options: [.sortedKeys])
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let back = try #require(GamepadLayout(json: json))
    #expect(back.reads(reportID: 48) && back.reads(reportID: 63))

    var pair = [UInt8](repeating: 0, count: 49)
    (pair[0], pair[3]) = (48, 8)
    #expect(back.pressed(pair) == ["Button A"])
    var single: [UInt8] = [0x3f, 0x01, 0x00, 0x00, 0, 0x80, 0, 0x80, 0, 0x80, 0, 0x80]
    #expect(back.pressed(single) == ["Button A", "Direction Pad Up"])
    (single[1], single[3]) = (0, 8)
    #expect(back.pressed(single) == [])
    // A report it wasn't set up with (a subcommand reply) isn't read.
    #expect(back.pressed([0x21, 1, 2]) == nil)
}
