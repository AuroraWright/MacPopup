// The Japanese SODA pack's 。 after numbers (LiveCaptionRecognizer.withoutStopsAfterNumbers).
import Testing
@testable import Transcription

private func cleaned(_ text: String) -> String {
    LiveCaptionRecognizer.withoutStopsAfterNumbers(Transcript(text: text)).text
}

@Test(arguments: [
    ("答えは5。次の問題です。", "答えは5次の問題です。"),
    ("1。つ目", "1つ目"),
    ("9。月上旬に", "9月上旬に"),
    ("約1。1。× 3.5。× 6。CM", "約11× 3.5× 6CM"),
    ("２。人で", "２人で"),
])
func stopsAfterNumbersMidSentenceAreDropped(text: String, expected: String) {
    #expect(cleaned(text) == expected)
}

@Test(arguments: [
    "全部で3。」と言った。",
    "答えは5。「次はこれ」",
    "10。",
    "10。  ",
    "これで終わり。次へ。",
])
func stopsThatEndSentencesAreKept(text: String) {
    #expect(cleaned(text) == text)
}

@Test func timesFollowTheCharactersKept() {
    let result = LiveCaptionRecognizer.withoutStopsAfterNumbers(Transcript(text: "1。つ目", times: [0, 1, 2, 3]))
    #expect(result.text == "1つ目")
    #expect(result.times == [0, 2, 3])
}
