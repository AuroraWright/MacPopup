import NaturalLanguage

/// Where sentences end, in any language: Unicode's sentence boundaries (UAX #29), where the language's abbreviations
/// (CLDR's, such as "Dr." or "z. B.") don't end one. The Floating Window's lines are split with them, from OCR
/// (ShownLines) and from audio (AudioTranscriber).
enum Sentences {
    /// The ranges of the text's sentences, with any whitespace after each. `language` is Yomitan's code (Settings →
    /// General).
    static func ranges(in text: String, language: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: language))
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }
}
