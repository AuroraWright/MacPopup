import CoreGraphics

extension OCRLayout {
    /// Leaves out furigana (Settings → OCR Mode → Ignore furigana). The engines read them as lines of their own,
    /// often several words' furigana as one line: small text without kanji, right next to the kanji it's for, above
    /// them in horizontal text and to their right in vertical text. As in owocr's furigana filter, a line is
    /// furigana when it's like that next to a line with kanji, but the line can be anywhere among the others
    /// (no reading order is needed), it must be on the furigana's side of that line (furigana between two lines
    /// belong to the next one), close to it (a speaker's name above the text is further away), and over kanji in it.
    public static func removingFurigana(_ lines: [Line]) -> [Line] {
        let bases = furigana(in: lines)
        return lines.indices.filter { bases[$0] == nil }.map { lines[$0] }
    }

    /// The furigana among `lines` (see removingFurigana), by index, with the index of the line each is the reading of.
    public static func furigana(in lines: [Line]) -> [Int: Int] {
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
        // Mostly along the base line (furigana longer than their kanji reach past them).
        guard rubyEnd > rubyStart, min(rubyEnd, baseEnd) - max(rubyStart, baseStart) >= 0.6 * (rubyEnd - rubyStart) else { return false }
        // Across, on the strokes where both lines' can be told from the background: the engines' boxes are padded
        // (Screen AI's for small kana about twice as wide as their strokes), and how much varies by engine.
        let rubyBox = across(ruby.box), baseBox = across(base.box)
        let inked = inkAcross(ruby, base)
        let ((rubyNear, rubyFar), (baseNear, baseFar)) = inked ?? (rubyBox, baseBox)
        let baseSize = baseFar - baseNear
        guard baseSize > 0,
              // Its box no bigger than the base's either: in tilted text both lines' ink spreads over more rows than
              // their strokes take, and a slice of it can look small.
              rubyBox.1 - rubyBox.0 <= baseBox.1 - baseBox.0,
              // Smaller: furigana are usually about half the size (measured on the ink in Manga109-s: mostly
              // 0.3–0.5 of their base line, text beside one mostly from 0.6; on boxes: at most 0.65).
              rubyFar - rubyNear <= (inked == nil ? 0.75 : 0.55) * baseSize,
              // Close to the base line (measured on boxes: furigana 0.12, a speaker's name above the text from 0.35;
              // on the ink, without the boxes' padding, up to 0.3 in games that space them widely), and mostly
              // beyond its middle (OCR boxes often overlap).
              rubyNear - baseFar <= (inked == nil ? 0.25 : 0.3) * baseSize,
              (rubyNear + rubyFar) / 2 > (baseNear + baseFar) / 2 + 0.25 * baseSize
        else { return false }
        // Over kanji: furigana that reach past their kanji only reach part of a character further.
        let start = rubyStart - 0.25 * baseSize, end = rubyEnd + 0.25 * baseSize
        return base.chars.contains { char in
            let (charStart, charEnd) = along(char.box)
            return charEnd > start && charStart < end && hasKanji(char.text)
        }
    }

    /// The ruby's and the base's extent across (as in isFurigana) on their ink: the base's run with the most (its
    /// text, not a neighbor's strokes reaching into its box) and the ruby's nearest run with much ink from about the
    /// base's far edge on; nil when they run different ways or either has no runs.
    private static func inkAcross(_ ruby: Line, _ base: Line) -> ((CGFloat, CGFloat), (CGFloat, CGFloat))? {
        guard ruby.vertical == base.vertical, let baseInk = base.ink?.runs, let main = baseInk.max(by: { $0.amount < $1.amount }),
              let rubyInk = ruby.ink?.runs
        else { return nil }
        let across = { (run: Ink.Run) in base.vertical ? (run.start, run.end) : (-run.end, -run.start) }
        let (baseNear, baseFar) = across(main)
        let beyond = rubyInk.filter { across($0).0 >= baseFar - 0.1 * (baseFar - baseNear) }
        let most = beyond.map(\.amount).max() ?? 0
        guard most > 0, let run = beyond.filter({ 4 * $0.amount >= most }).min(by: { across($0).0 < across($1).0 }) else { return nil }
        return (across(run), (baseNear, baseFar))
    }
}
