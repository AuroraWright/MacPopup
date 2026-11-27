// Imported settings brought within the limits Settings keeps when editing (SettingsSchema.clamped).
import Foundation
import Testing
@testable import MacPopup

@MainActor @Test func numbersStayInTheirRange() {
    let clamped = SettingsSchema.clamped(["popupWidth": 123456789012, "popupFontSize": 0, "audioVolume": -5.5, "maxLines": 50])
    #expect(clamped["popupWidth"] as? Int == 2000)
    #expect(clamped["popupFontSize"] as? Int == 8)
    #expect(clamped["audioVolume"] as? Int == 0)
    #expect(clamped["maxLines"] as? Int == 50)
}

@MainActor @Test func listsKeepTheirMaximum() {
    let keys = (0..<8).map { ["key": "Key\($0)", "modifiers": []] as [String: Any] }
    let urls = (0..<8).map { "ws://localhost:\(6000 + $0)" }
    let clamped = SettingsSchema.clamped(["sentenceAudioOpenKeys": keys, "websocketUrls": urls])
    #expect((clamped["sentenceAudioOpenKeys"] as? [Any])?.count == 5)
    #expect(clamped["websocketUrls"] as? [String] == Array(urls.prefix(5)))
}

@MainActor @Test func linesKeepTheFirstWithSomethingOnThem() {
    let urls = ["ws://localhost:1", "", " ws://localhost:2 ", "  ", "ws://localhost:3", "ws://localhost:4", "ws://localhost:5", "ws://localhost:6"]
    let clamped = SettingsSchema.clamped(["websocketUrls": urls])
    #expect(clamped["websocketUrls"] as? [String] == (1...5).map { "ws://localhost:\($0)" })
}

@MainActor @Test func terminationCharactersAreOneCharacter() {
    let items: [[String: Any]] = [
        ["enabled": true, "character1": "「long", "character2": "」long"],
        ["enabled": true, "character1": "。", "character2": NSNull()],
    ]
    let clamped = SettingsSchema.clamped(["sentenceTerminationCharacters": items]) as [String: Any]
    let result = clamped["sentenceTerminationCharacters"] as? [[String: Any]]
    #expect(result?[0]["character1"] as? String == "「")
    #expect(result?[0]["character2"] as? String == "」")
    #expect(result?[1]["character1"] as? String == "。")
    #expect(result?[1]["character2"] is NSNull)
}

@MainActor @Test func otherSettingsAreLeftAsTheyAre() {
    let clamped = SettingsSchema.clamped(["popupTheme": "dark", "notASetting": 123456789012])
    #expect(clamped["popupTheme"] as? String == "dark")
    #expect(clamped["notASetting"] as? Int == 123456789012)
}
