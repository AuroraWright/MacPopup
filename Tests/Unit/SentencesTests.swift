// Sentence splitting for the Floating Window's lines (Sentences.ranges): Unicode's boundaries with the language's
// abbreviations, and opening brackets going with the sentence they open.
import Testing
import Transcription

private func sentences(_ text: String, _ language: String) -> [String] {
    Sentences.ranges(in: text, language: language).map { String(text[$0]) }
}

@Test func japaneseSentencesEndAtTheirStops() {
    #expect(sentences("おはよう。今日は早いね！どうしたの？", "ja") == ["おはよう。", "今日は早いね！", "どうしたの？"])
}

@Test func anOpeningBracketGoesWithTheNextSentence() {
    #expect(sentences("えお。「かき」と言った。", "ja") == ["えお。", "「かき」と言った。"])
    #expect(sentences("そうか。『本当に？』", "ja") == ["そうか。", "『本当に？』"])
}

@Test func abbreviationsDontEndASentence() {
    #expect(sentences("Mr. Smith went home. He slept.", "en") == ["Mr. Smith went home. ", "He slept."])
    #expect(sentences("Das ist z. B. gut. Ja.", "de") == ["Das ist z. B. gut. ", "Ja."])
}

@Test func textWithoutAnEndIsOneSentence() {
    #expect(sentences("それなのにいったい誰が", "ja") == ["それなのにいったい誰が"])
    #expect(sentences("", "ja").isEmpty)
}
