// Lines of speech that grow while their sentence goes on (GrowingLines, "Detect sentence ends"): where a stretch's text
// joins the open line or starts a line of its own, from SaT's made-up probabilities, punctuation, pauses and the
// line's length; and for models that tell when each character was heard, the open line's speech heard again and where
// a line starts in it.
import Testing
@testable import Transcription

private let rate = Int(GrowingLines.sampleRate)

/// Speech, loud throughout (the times don't matter without the models' character times).
private func speech(_ seconds: Double) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { $0 % 2 == 0 ? 0.5 : -0.5 }
}

/// Lines as (text, start, grows), to compare.
private func shown(_ lines: [GrowingLines.Line]) -> [String] {
    lines.map { "\($0.text) @\($0.start)\($0.grows ? " grows" : "")" }
}

/// A stretch heard at `start` and its transcript (without times) added: SaT's `probabilities` by index (the rest 0), or
/// nil without SaT (punctuation only).
private func add(_ lines: inout GrowingLines, _ text: String, start: Double, seconds: Double = 1, pause: Double = 0.2,
                 probabilities: [Int: Float]? = [:]) -> [String] {
    let joined = lines.join(Transcript(text: text), earlier: nil, stretchDuration: seconds)
    let sat = probabilities.map { probabilities in
        var sat = [Float](repeating: 0, count: joined.text.count)
        for (index, probability) in probabilities { sat[index] = probability }
        return sat
    }
    return shown(lines.add(joined, probabilities: sat, stretch: speech(seconds), start: start, pause: pause, language: "ja"))
}

@Test func aSentenceThatGoesOnGrowsTheLine() {
    var lines = GrowingLines()
    #expect(add(&lines, "今日はいい天気ですね", start: 0) == ["今日はいい天気ですね @0.0"])
    #expect(add(&lines, "散歩に行こうか", start: 1.2) == ["今日はいい天気ですね散歩に行こうか @0.0 grows"])
}

/// At a short pause, SaT's endAtPause (0.1) ends the line; the stretch starts the next one.
@Test(arguments: [(Float(0.09), false), (0.1, true), (0.5, true)])
func anEndAtAPause(probability: Float, ends: Bool) {
    var lines = GrowingLines()
    _ = add(&lines, "今日はいい天気ですね", start: 0)
    // Index 9: after ね, where the stretch joins.
    let second = add(&lines, "散歩に行こうか", start: 1.2, probabilities: [9: probability])
    #expect(second == (ends ? ["散歩に行こうか @1.2"] : ["今日はいい天気ですね散歩に行こうか @0.0 grows"]))
}

/// Inside a stretch, an end takes endWithoutPause (0.6).
@Test(arguments: [(Float(0.59), false), (0.6, true)])
func anEndInsideAStretch(probability: Float, ends: Bool) {
    var lines = GrowingLines()
    let result = add(&lines, "今日はいい天気ですね散歩に行こうか", start: 3, probabilities: [9: probability])
    #expect(result == (ends ? ["今日はいい天気ですね @3.0", "散歩に行こうか @3.0"] : ["今日はいい天気ですね散歩に行こうか @3.0"]))
}

@Test func anEndNeedsSixCharactersAfterIt() {
    var lines = GrowingLines()
    // After ね (4 characters follow) and at the end: SaT takes the end of any text for a sentence end.
    let result = add(&lines, "今日はいい天気ですね行こうか", start: 0, probabilities: [9: 0.99, 13: 0.99])
    #expect(result == ["今日はいい天気ですね行こうか @0.0"])
}

@Test func afterALongPauseAShortStretchIsALineOfItsOwn() {
    var lines = GrowingLines()
    _ = add(&lines, "そうなんだ", start: 0, pause: GrowingLines.longPause)
    // Even with SaT's 0, and one character after the join is enough.
    #expect(add(&lines, "はい", start: 1.6) == ["はい @1.6"])
}

@Test func afterAShortPauseAShortStretchGrowsTheLine() {
    var lines = GrowingLines()
    _ = add(&lines, "そうなんだ", start: 0, pause: 0.3)
    #expect(add(&lines, "はい", start: 1.3, probabilities: [4: 0.99]) == ["そうなんだはい @0.0 grows"])
}

@Test func punctuationEndsLines() {
    var lines = GrowingLines()
    #expect(add(&lines, "おはよう。今日は早いね", start: 0) == ["おはよう。 @0.0", "今日は早いね @0.0"])
    // The open line, 今日は早いね, grows; a sentence end closes it.
    #expect(add(&lines, "どうしたの？", start: 1.2) == ["今日は早いねどうしたの？ @0.0 grows"])
    #expect(add(&lines, "別に", start: 2.4) == ["別に @2.4"])
}

@Test func theVoiceStoppingEndsTheLine() {
    var lines = GrowingLines()
    _ = add(&lines, "それなのにいったい誰が", start: 0, pause: .infinity, probabilities: nil)
    // Even without SaT's ends.
    #expect(add(&lines, "そんなことを", start: 5, probabilities: nil) == ["そんなことを @5.0"])
}

@Test func aLineGrowsToThirtySecondsOfSpeech() {
    var grown = GrowingLines(), ended = GrowingLines()
    _ = add(&grown, "長い話", start: 0, seconds: 25)
    _ = add(&ended, "長い話", start: 0, seconds: 25)
    #expect(add(&grown, "の続き", start: 25.2, seconds: 5) == ["長い話の続き @0.0 grows"])
    #expect(add(&ended, "の続き", start: 25.2, seconds: 5.5) == ["の続き @25.2"])
}

/// With the models' character times: the open line's speech is heard again with the next stretch, and a line starts
/// at the quietest moment between its first character and the one before.
@Test func heardAgainALineStartsInTheQuietBetweenWords() throws {
    var lines = GrowingLines()
    let first = speech(2), text = "今日はいい天気ですね"
    let times = (0..<10).map { 0.1 + 0.18 * Double($0) }
    var joined = lines.join(Transcript(text: text, times: times), earlier: nil, stretchDuration: 2)
    #expect(shown(lines.add(joined, probabilities: Array(repeating: 0, count: 10), stretch: first, start: 0, pause: 0.2,
                            language: "ja")) == ["今日はいい天気ですね @0.0"])
    // Heard 0.2 s later: 1.5 s, quiet from 0.1 to 0.2 s into it.
    var second = speech(1.5)
    for index in rate / 10..<rate / 5 { second[index] = 0 }
    let earlier = try #require(lines.earlier(before: second))
    #expect(earlier == first)
    #expect(lines.earlier(before: speech(28.5)) == nil)

    // Heard again with the stretch, ね at 1.8 s and 散 at 2.3 s into both; SaT ends the sentence at the pause.
    let again = Transcript(text: text + "散歩に行こうか", times: times + (0..<7).map { 2.3 + 0.15 * Double($0) })
    #expect(!lines.heardWorse(again))
    #expect(lines.heardWorse(Transcript(text: "今日はね散歩に行こうか", times: [0.1, 0.4, 0.8, 1.8] + (0..<7).map { 2.3 + 0.15 * Double($0) })))
    joined = lines.join(again, earlier: earlier, stretchDuration: 1.5)
    var sat = [Float](repeating: 0, count: 17)
    sat[9] = 0.5
    let added = lines.add(joined, probabilities: sat, stretch: second, start: 2.2, pause: 0.2, language: "ja")
    #expect(added.map(\.text) == ["散歩に行こうか"])
    #expect(added.map(\.grows) == [false])
    // The quiet starts 2.1 s into the speech heard again: 0.1 s into the stretch heard at 2.2.
    let start = try #require(added.first?.start)
    #expect(start > 2.3 && start < 2.4, "starts at \(start)")
    // The new open line's speech, to hear again: from that moment on.
    let next = try #require(lines.earlier(before: speech(1)))
    #expect(abs(Double(next.count) / Double(rate) - (3.5 - (start - 0.2))) < 0.001, "\(next.count) samples")
}
