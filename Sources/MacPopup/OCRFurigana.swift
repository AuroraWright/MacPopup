import CoreGraphics

extension OCRLayout {
    /// Leaves out furigana (Settings → OCR Mode → Strip furigana). The engines read them as lines of their own,
    /// often several words' furigana as one line: small text without kanji, right next to the kanji it's for, above
    /// them in horizontal text and to their right in vertical text. As in owocr's furigana filter, a line is
    /// furigana when it's like that next to a line with kanji, but the line can be anywhere among the others
    /// (no reading order is needed), it must be on the furigana's side of that line (furigana between two lines
    /// belong to the next one), close to it (a speaker's name above the text is further away), and over kanji in it.
    static func removingFurigana(_ lines: [Line]) -> [Line] {
        let bases = furigana(in: lines)
        return lines.indices.filter { bases[$0] == nil }.map { lines[$0] }
    }

    /// The furigana among `lines` (see removingFurigana), by index, with the index of the line each is the reading of.
    static func furigana(in lines: [Line]) -> [Int: Int] {
        var bases: [Int: Int] = [:]
        for (index, line) in lines.enumerated() {
            bases[index] = lines.firstIndex { isFurigana(line, of: $0) }
        }
        return bases
    }

    private static func hasKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    private static func isFurigana(_ ruby: Line, of base: Line) -> Bool {
        guard hasKanji(base.text), !hasKanji(ruby.text), ruby.text.unicodeScalars.contains(where: \.properties.isAlphabetic) else { return false }
        // A reading of one or two kana may be taken for either direction; longer ones go the base's way.
        if ruby.text.count >= 3, ruby.vertical != base.vertical { return false }
        let vertical = base.vertical
        // Along the base line, and across it toward the side furigana go on (up, or right).
        let along = { (box: CGRect) in vertical ? (box.minY, box.maxY) : (box.minX, box.maxX) }
        let across = { (box: CGRect) in vertical ? (box.minX, box.maxX) : (-box.maxY, -box.minY) }
        let (rubyStart, rubyEnd) = along(ruby.box), (baseStart, baseEnd) = along(base.box)
        let (rubyNear, rubyFar) = across(ruby.box), (baseNear, baseFar) = across(base.box)
        let baseSize = baseFar - baseNear
        guard rubyEnd > rubyStart, baseSize > 0,
              // Smaller: furigana are usually about half the size (measured: at most 0.65 of the base line).
              rubyFar - rubyNear <= 0.75 * baseSize,
              // Close to the base line: at most a quarter of its size away (measured: furigana 0.12, a speaker's
              // name above the text from 0.35), and mostly beyond its middle (OCR boxes often overlap).
              rubyNear - baseFar <= 0.25 * baseSize,
              (rubyNear + rubyFar) / 2 > (baseNear + baseFar) / 2 + 0.25 * baseSize,
              // Mostly along the base line (furigana longer than their kanji reach past them).
              min(rubyEnd, baseEnd) - max(rubyStart, baseStart) >= 0.6 * (rubyEnd - rubyStart)
        else { return false }
        // Over kanji: furigana that reach past their kanji only reach part of a character further.
        let start = rubyStart - 0.25 * baseSize, end = rubyEnd + 0.25 * baseSize
        return base.chars.contains { char in
            let (charStart, charEnd) = along(char.box)
            return charEnd > start && charStart < end && hasKanji(char.text)
        }
    }
}
