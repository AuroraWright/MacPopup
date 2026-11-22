import NaturalLanguage

/// Where sentences end, in any language: Unicode's sentence boundaries (UAX #29), where the language's abbreviations
/// (CLDR's, such as "Dr." or "z. B.") don't end one. The Floating Window's lines are split with them, from OCR
/// (ShownLines) and from audio (AudioTranscriber).
public enum Sentences {
    /// The ranges of the text's sentences, with any whitespace after each. `language` is Yomitan's code (Settings →
    /// General).
    public static func ranges(in text: String, language: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: language))
        var ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        // Unicode's boundaries leave opening punctuation right after a sentence end with that sentence ("えお。「" and
        // "かき」"): it goes with the next one.
        for index in ranges.indices.dropLast() {
            var end = ranges[index].upperBound
            while end > ranges[index].lowerBound, let scalar = text[text.index(before: end)].unicodeScalars.first,
                  [.openPunctuation, .initialPunctuation].contains(scalar.properties.generalCategory) {
                end = text.index(before: end)
            }
            guard end > ranges[index].lowerBound, end < ranges[index].upperBound else { continue }
            ranges[index] = ranges[index].lowerBound..<end
            ranges[index + 1] = end..<ranges[index + 1].upperBound
        }
        return ranges
    }
}
