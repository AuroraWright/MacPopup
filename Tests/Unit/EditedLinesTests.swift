// The WebSocket URL box's lines (Settings → WebSockets, LinesEditor): what's saved, how tall it is, what an edit puts in.
import Foundation
import Testing
@testable import MacPopup

private let edited = EditedLines(limit: 5)

/// The text after `replacement` is typed or pasted at the end of `text`.
private func typed(_ replacement: String, after text: String) -> String {
    let end = NSRange(location: (text as NSString).length, length: 0)
    return text + edited.revise(text, end, replacement)
}

@Test func itemsAreTrimmedNonEmptyLines() {
    #expect(edited.items("  ws://a  \n\n\tws://b\n   \n") == ["ws://a", "ws://b"])
}

@Test func itemsSplitOnAnyLineBreak() {
    #expect(edited.items("ws://a\r\nws://b\rws://c\nws://d") == ["ws://a", "ws://b", "ws://c", "ws://d"])
}

@Test func itemsKeepTheFirstFive() {
    #expect(edited.items((1...7).map { "ws://\($0)" }.joined(separator: "\n")) == (1...5).map { "ws://\($0)" })
}

@Test func rowsAreTheLinesAndAnEmptyOneUpToFive() {
    #expect(edited.rows("") == 1)
    #expect(edited.rows("ws://a") == 2)
    #expect(edited.rows("ws://a\nws://b") == 3)
    #expect(edited.rows("1\n2\n3\n4") == 5)
    #expect(edited.rows("1\n2\n3\n4\n5") == 5)
    #expect(edited.rows("1\n2\n3\n4\n5\n6\n7") == 5)
}

@Test func returnOnTheFifthLineIsRefused() {
    #expect(edited.revise("1\n2\n3\n4\n5", NSRange(location: 9, length: 0), "\n") == "")
}

@Test func returnBeforeTheFifthLineIsKept() {
    #expect(typed("\n", after: "1\n2\n3") == "1\n2\n3\n")
}

@Test func typingWithoutLineBreaksIsUnchanged() {
    #expect(edited.revise("1\n2\n3\n4\n5", NSRange(location: 9, length: 0), "x") == "x")
}

@Test func windowsLineBreaksBecomeNewlines() {
    #expect(typed("ws://b\r\nws://c", after: "ws://a\n") == "ws://a\nws://b\nws://c")
}

@Test func aPasteKeepsTheLinesThatFit() {
    #expect(typed("\nb\nc\nd", after: "1\n2\n3\n4") == "1\n2\n3\n4\nb")
}

@Test func replacingASelectionFreesItsLines() {
    // The last two lines selected and replaced by three.
    #expect(edited.revise("1\n2\n3\n4\n5", NSRange(location: 5, length: 4), "a\nb\nc") == "a\nb\nc")
}
