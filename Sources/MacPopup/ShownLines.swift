import Foundation

/// Commas and colons: a sentence that ends a row with one goes on in the next row. This is Unicode's SContinue
/// (UAX #29) without its dashes, since a dash often ends a paragraph of dialogue.
private let sentenceContinuing: Set<Unicode.Scalar> = [
    "\u{2C}", "\u{3A}", "\u{55D}", "\u{60C}", "\u{60D}", "\u{7F8}", "\u{1802}", "\u{1808}", "\u{3001}", "\u{FE10}",
    "\u{FE11}", "\u{FE13}", "\u{FE50}", "\u{FE51}", "\u{FE55}", "\u{FF0C}", "\u{FF1A}", "\u{FF64}",
]

/// The lines recently shown in the text box or read by OCR, oldest first. Anki Audio, Anki Screenshot and the
/// Floating Window's text box all use it, so they agree on what each line is. Each line keeps every version of its
/// text without whitespace, the text as shown, and the user's own data (`Info`).
///
/// When OCR reads a page that keeps growing (as in visual novels), each new sentence or paragraph becomes a new line
/// (see note).
struct ShownLines<Info>: RandomAccessCollection, MutableCollection {
    struct Line {
        let id: Int
        var texts: [String]
        /// The latest version of the text as shown, whitespace included.
        var text: String
        var info: Info
    }

    /// What `note` did with a text.
    enum Noted {
        /// Another version of the last line. `grew`: longer than any seen so far (it's still being drawn).
        case again(index: Int, grew: Bool)
        /// A new line, now the last.
        case new(index: Int)
    }

    private var lines: [Line] = []
    private var nextID = 0
    /// The last reading of a page (see note), normalized and as shown, and where the last line starts in it (counted
    /// in characters of `text`).
    private var page: (text: String, shown: String, lastStart: Int)?
    /// Text shorter than this could be part of almost any line (see isSameLine).
    private static var shortLength: Int { 6 }

    var startIndex: Int { lines.startIndex }
    var endIndex: Int { lines.endIndex }

    subscript(index: Int) -> Line {
        get { lines[index] }
        set { lines[index] = newValue }
    }

    /// Text as the lines keep it: without whitespace.
    static func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// Notes a line's text (`shown` is the text as shown). Returns nil when it's empty or only whitespace.
    ///
    /// If the text is another version of the last line, it's added to that line's texts. That happens when the line
    /// grows as the game draws it, when OCR reads it again after the WebSocket sent it, or when a long line is read a
    /// little differently. Anything else becomes a new line with `info`. Short text has to match exactly, since it's
    /// often a separate line (誰？) that happens to appear inside the last one.
    ///
    /// With `page`, the text is a whole settled reading of OCR's dialogue area. It may be the previous reading with
    /// more text added, as on a visual novel's page or when a line continues after a pause. The added text becomes a
    /// new line when a sentence ends before it (by Unicode's sentence boundaries, so it works in any language) or a
    /// paragraph does. `breaks` lists where the reading's rows start a paragraph, in characters of the normalized
    /// text; a row ending in a comma doesn't count, since games also wrap rows after commas. Otherwise the last line
    /// grew. Text that appears all at once stays one line, because the voice of each line would start at the same time.
    mutating func note(_ shown: String, page isPage: Bool = false, breaks: Set<Int> = [], info: () -> Info) -> Noted? {
        let text = Self.normalized(shown)
        guard !text.isEmpty else { return nil }
        let previousPage = page
        if isPage { page = (text, shown, 0) }
        if isPage, let previousPage, let last = lines.indices.last {
            let page = previousPage
            // The same page, or part of it, read again. Dots are ignored because OCR reads a different number of them
            // each time.
            let key = Self.undotted(text), pageKey = Self.undotted(page.text)
            if pageKey.hasPrefix(key) || (text.count <= page.text.count && Self.isLongAndSame(text, page.text)) {
                self.page = page
                return .again(index: last, grew: false)
            }
            // The page with more text added. The old part may be read a little differently or gain a mark or two
            // (e.g. a dash before a line), so it's aligned with the new reading, and the last line is taken from that.
            let before = String(text.prefix(page.text.count))
            let exact = before == page.text
            let (end, edits) = exact ? (page.text.count, 0) : Self.end(of: page.text, in: text)
            let inserted = edits == 0 || (edits <= 2 && edits == end - page.text.count)
            if key.count > pageKey.count, exact || inserted || Self.isLongAndSame(before, page.text) {
                let paragraphEnds = breaks.contains(end) && !Self.continuesSentence(text, before: end)
                if end < text.count, paragraphEnds || Self.sentenceEnds(in: shown, after: end) {
                    self.page?.lastStart = end
                    return append(Self.shown(shown, after: end), info: info)
                }
                let start = exact ? page.lastStart : Self.end(of: String(page.text.prefix(page.lastStart)), in: text).end
                self.page?.lastStart = start
                lines[last].text = Self.shown(shown, after: start)
                let normalized = Self.normalized(lines[last].text)
                if !lines[last].texts.contains(normalized) { lines[last].texts.append(normalized) }
                return .again(index: last, grew: true)
            }
        }
        let isAgain = { (seen: String) in text.hasPrefix(seen) || seen.hasPrefix(text) || Self.isLongAndSame(text, seen) }
        if let last = lines.indices.last, lines[last].texts.contains(where: isAgain) {
            let grew = text.count > lines[last].texts.map(\.count).max() ?? 0
            if !lines[last].texts.contains(text) { lines[last].texts.append(text) }
            if grew { lines[last].text = shown }
            return .again(index: last, grew: grew)
        }
        // A different line (e.g. from a WebSocket) ends the page. The last line coming in again (e.g. from a WebSocket
        // after OCR read it) doesn't.
        if !isPage { page = nil }
        return append(shown, info: info)
    }

    private mutating func append(_ shown: String, info: () -> Info) -> Noted {
        lines.append(Line(id: nextID, texts: [Self.normalized(shown)], text: shown, info: info()))
        nextID += 1
        return .new(index: lines.count - 1)
    }

    /// Whether both texts are long enough to be matched loosely, and match (see isSameLine).
    private static func isLongAndSame(_ a: String, _ b: String) -> Bool {
        Swift.min(a.count, b.count) >= shortLength && isSameLine(a, b)
    }

    /// The index after the first `count` non-whitespace characters of `shown`, skipping any whitespace that follows.
    private static func index(after count: Int, in shown: String) -> String.Index? {
        var seen = 0
        var index = shown.startIndex
        while index < shown.endIndex {
            let isSpace = shown[index].unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            if !isSpace {
                if seen == count { return index }
                seen += 1
            }
            index = shown.index(after: index)
        }
        return nil
    }

    /// The rest of `shown` after its first `count` non-whitespace characters.
    private static func shown(_ shown: String, after count: Int) -> String {
        guard let start = index(after: count, in: shown) else { return "" }
        return String(shown[start...])
    }

    /// Dots, which OCR often reads with one more or fewer, or misses.
    private static func isDot(_ character: Character) -> Bool {
        "・･.．…‥·".contains(character)
    }

    private static func undotted(_ text: String) -> String {
        text.filter { !isDot($0) }
    }

    /// Where the earlier reading `old` ends within `new`, in characters, allowing for differences in how it was read.
    /// That's the end of the shortest start of `new` with the fewest edits from `old`, returned with the edit count.
    /// Dots that were added, dropped or read as other dots cost nothing.
    private static func end(of old: String, in new: String) -> (end: Int, edits: Int) {
        let a = Array(old), b = Array(new)
        guard !a.isEmpty, !b.isEmpty else { return (0, a.count) }
        let cost = { (character: Character) in isDot(character) ? 0 : 1 }
        // Levenshtein distance between `old` and every start of `new`, one character of `old` at a time.
        var row = [0]
        for character in b { row.append(row[row.count - 1] + cost(character)) }
        for x in a {
            var diagonal = row[0]
            row[0] += cost(x)
            for j in 1...b.count {
                let above = row[j]
                let substitution = x == b[j - 1] || (isDot(x) && isDot(b[j - 1])) ? 0 : 1
                row[j] = Swift.min(diagonal + substitution, above + cost(x), row[j - 1] + cost(b[j - 1]))
                diagonal = above
            }
        }
        let end = row.indices.min { row[$0] < row[$1] } ?? 0
        return (end, row[end])
    }

    /// Whether the normalized `text` has a comma or colon just before character `count` (see sentenceContinuing).
    private static func continuesSentence(_ text: String, before count: Int) -> Bool {
        guard count > 0, let character = text.dropFirst(count - 1).first else { return false }
        return character.unicodeScalars.first.map(sentenceContinuing.contains) ?? false
    }

    /// Whether a sentence ends after the first `count` non-whitespace characters of `shown`, using Unicode's sentence
    /// boundaries (UAX #29), which work in any language. They attach opening punctuation after a sentence end to that
    /// sentence (。」「), so the boundary may come a little later.
    static func sentenceEnds(in shown: String, after count: Int) -> Bool {
        guard let split = index(after: count, in: shown) else { return false }
        var ends = false
        shown.enumerateSubstrings(in: shown.startIndex..<shown.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
            if range.lowerBound >= split {
                ends = shown[split..<range.lowerBound].allSatisfy { character in
                    [.openPunctuation, .initialPunctuation].contains(character.unicodeScalars.first?.properties.generalCategory)
                }
                stop = true
            }
        }
        return ends
    }

    /// The newest line a card's sentence comes from.
    func lastIndex(of sentence: String) -> Int? {
        let sentence = Self.normalized(sentence)
        return lines.lastIndex { $0.texts.contains { Self.isSameLine(sentence, $0) } }
    }

    mutating func removeAll(where shouldBeRemoved: (Line) -> Bool = { _ in true }) {
        lines.removeAll(where: shouldBeRemoved)
    }

    mutating func removeFirst(_ count: Int) {
        lines.removeFirst(count)
    }

    /// Whether a card's sentence comes from a line shown with `text`: one must contain the other (a sentence is often
    /// part of a line; a short one, only that way round), allowing a few characters to differ, since OCR may misread
    /// some.
    private static func isSameLine(_ sentence: String, _ text: String) -> Bool {
        let a = Array(sentence.precomposedStringWithCompatibilityMapping), b = Array(text.precomposedStringWithCompatibilityMapping)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Short text could match almost any line, so it has to match exactly: a short sentence may be part of its line,
        // but a short line (e.g. a stray character OCR read on its own) isn't the line of every sentence it's part of.
        if Swift.min(a.count, b.count) < shortLength { return String(b).contains(String(a)) }
        // Longest common subsequence.
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let above = row[j]
                row[j] = x == b[j - 1] ? diagonal + 1 : Swift.max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return Double(row[b.count]) >= 0.85 * Double(Swift.min(a.count, b.count))
    }
}
