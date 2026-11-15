import Foundation

/// Commas and colons: a sentence that ends a row with one goes on in the next row. This is Unicode's SContinue
/// (UAX #29) without its dashes, since a dash often ends a paragraph of dialogue.
private let sentenceContinuing: Set<Unicode.Scalar> = [
    "\u{2C}", "\u{3A}", "\u{55D}", "\u{60C}", "\u{60D}", "\u{7F8}", "\u{1802}", "\u{1808}", "\u{3001}", "\u{FE10}",
    "\u{FE11}", "\u{FE13}", "\u{FE50}", "\u{FE51}", "\u{FE55}", "\u{FF0C}", "\u{FF1A}", "\u{FF64}",
]

/// The lines recently shown in the text box or read by OCR, oldest first, each with an id. The Floating Window's text
/// box, Anki Audio and Anki Screenshot all go by these lines (see AppDelegate.noteLine), and a card added from a popup
/// keeps the id of the line it was scanned in. Each line keeps every version of its text without whitespace, the text
/// as shown, and the user's own data (`Info`).
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
        /// The latest version of its text that came as a line (from a WebSocket or the clipboard) rather than from OCR,
        /// normalized.
        var sent: String?
    }

    /// When a line sent after another sent one (see Line.sent) is still that line, as the text box decides it
    /// (Settings → Text Box): the same text again (`repeats`), or the line with more text (`grows`). Otherwise it's a
    /// new line, however much it looks like the one before.
    struct SentLines {
        var repeats = false
        var grows = false
    }

    /// Where a line starts in a page's reading, in characters of its normalized text.
    typealias Start = (id: Int, start: Int)

    /// What `note` did with a text.
    struct Noted {
        /// The line it went to.
        let index: Int
        /// A new line, now the last. Otherwise it's another version of the last line.
        let isNew: Bool
        /// Longer than any version of the line seen so far (it's still being drawn).
        let grew: Bool
        /// For a page, the lines in this reading of it, in order.
        let starts: [Start]
    }

    private var lines: [Line] = []
    private var nextID = 0
    /// The last reading of a page (see note), normalized and as shown, and where its lines start in it.
    private var page: (text: String, shown: String, starts: [Start])?
    /// Text shorter than this could be part of almost any line (see isLongAndSame).
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
    /// often a separate line (誰？) that happens to appear inside the last one. A line that was sent (not `page`) after
    /// another sent line is only that line again as `sent` says.
    ///
    /// With `page`, the text is a whole settled reading of OCR's dialogue area. It may be the previous reading with
    /// more text added, as on a visual novel's page or when a line continues after a pause. The added text becomes a
    /// new line when a sentence ends before it (by Unicode's sentence boundaries, so it works in any language) or a
    /// paragraph does. `breaks` lists where the reading's rows start a paragraph, in characters of the normalized
    /// text; a row ending in a comma doesn't count, since games also wrap rows after commas. Otherwise the last line
    /// grew. Text that appears all at once stays one line, because the voice of each line would start at the same time.
    mutating func note(
        _ shown: String, page isPage: Bool = false, breaks: Set<Int> = [], sent sentLines: SentLines = .init(), info: () -> Info
    ) -> Noted? {
        let text = Self.normalized(shown)
        guard !text.isEmpty else { return nil }
        if isPage, let page, let last = lines.indices.last {
            // The same page, or part of it, read again. Dots are ignored because OCR reads a different number of them
            // each time.
            let key = Self.undotted(text), pageKey = Self.undotted(page.text)
            if pageKey.hasPrefix(key) || (text.count <= page.text.count && Self.isLongAndSame(text, page.text)) {
                return Noted(index: last, isNew: false, grew: false, starts: Self.moved(page.starts, from: page.text, to: text))
            }
            // The page with more text added. The old part may be read a little differently or gain a mark or two
            // (e.g. a dash before a line), so it's aligned with the new reading, and its lines' starts with it.
            let before = String(text.prefix(page.text.count))
            let exact = before == page.text
            let (end, edits) = exact ? (page.text.count, 0) : Self.ends(of: page.text, in: text, at: [page.text.count])[0]
            let inserted = edits == 0 || (edits <= 2 && edits == end - page.text.count)
            if key.count > pageKey.count, exact || inserted || Self.isLongAndSame(before, page.text) {
                var starts = Self.moved(page.starts, from: page.text, to: text)
                let paragraphEnds = breaks.contains(end) && !Self.continuesSentence(text, before: end)
                if end < text.count, paragraphEnds || Self.sentenceEnds(in: shown, after: end) {
                    let index = append(Self.shown(shown, after: end), info: info)
                    starts.append((lines[index].id, end))
                    self.page = (text, shown, starts)
                    return Noted(index: index, isNew: true, grew: false, starts: starts)
                }
                self.page = (text, shown, starts)
                lines[last].text = Self.shown(shown, after: starts.last?.start ?? 0)
                let normalized = Self.normalized(lines[last].text)
                if !lines[last].texts.contains(normalized) { lines[last].texts.append(normalized) }
                return Noted(index: last, isNew: false, grew: true, starts: starts)
            }
        }
        let noted: Noted
        let isAgain = { (seen: String) in text.hasPrefix(seen) || seen.hasPrefix(text) || Self.isLongAndSame(text, seen) }
        let last = lines.indices.last
        let isSame: Bool
        if !isPage, let last, let sent = lines[last].sent {
            isSame = (sentLines.repeats && text == sent) || (sentLines.grows && text.hasPrefix(sent))
        } else {
            isSame = last.map { lines[$0].texts.contains(where: isAgain) } ?? false
        }
        if let last, isSame {
            let grew = text.count > lines[last].texts.map(\.count).max() ?? 0
            if !lines[last].texts.contains(text) { lines[last].texts.append(text) }
            if grew { lines[last].text = shown }
            noted = Noted(index: last, isNew: false, grew: grew, starts: isPage ? [(lines[last].id, 0)] : [])
        } else {
            let index = append(shown, info: info)
            noted = Noted(index: index, isNew: true, grew: false, starts: isPage ? [(lines[index].id, 0)] : [])
        }
        if !isPage { lines[noted.index].sent = text }
        // A page read anew is a single line. A different line (e.g. from a WebSocket) ends the page; the last line
        // coming in again (e.g. from a WebSocket after OCR read it) doesn't.
        if isPage {
            page = (text, shown, noted.starts)
        } else if noted.isNew {
            page = nil
        }
        return noted
    }

    /// Where a line's text starts in a page's reading, as (row, offset in the row's UTF-16 code units). `rows` are the
    /// reading's rows of text, and `start` is counted in characters of its normalized text, as in Noted.starts.
    static func position(of start: Int, in rows: [String]) -> (row: Int, offset: Int)? {
        var left = start
        for (row, text) in rows.enumerated() {
            if let index = index(after: left, in: text) { return (row, text.utf16.distance(from: text.startIndex, to: index)) }
            left -= normalized(text).count
        }
        return nil
    }

    private mutating func append(_ shown: String, info: () -> Info) -> Int {
        lines.append(Line(id: nextID, texts: [Self.normalized(shown)], text: shown, info: info()))
        nextID += 1
        return lines.count - 1
    }

    /// The starts of lines in a page's reading `old`, moved to where they are in its reading `new`.
    private static func moved(_ starts: [Start], from old: String, to new: String) -> [Start] {
        guard !new.hasPrefix(old), !old.hasPrefix(new) else { return starts }
        let ends = ends(of: old, in: new, at: starts.map(\.start))
        return zip(starts, ends).map { ($0.id, $1.end) }
    }

    /// Whether two readings are of the same line: both are long enough to be matched loosely, and one contains the
    /// other, allowing a few characters to differ, since OCR may misread some.
    private static func isLongAndSame(_ a: String, _ b: String) -> Bool {
        let (whole, wholeB) = numbered(a.precomposedStringWithCompatibilityMapping, b.precomposedStringWithCompatibilityMapping)
        let shorter = Swift.min(whole.count, wholeB.count)
        guard shorter >= shortLength else { return false }
        // Longest common subsequence: the start and end they share, and that of what's between (in a table).
        let start = zip(whole, wholeB).prefix { $0 == $1 }.count
        let end = zip(whole[start...].reversed(), wholeB[start...].reversed()).prefix { $0 == $1 }.count
        let a = whole[start..<(whole.count - end)], b = Array(wholeB[start..<(wholeB.count - end)])
        var row = [Int](repeating: 0, count: b.count + 1)
        if !b.isEmpty {
            for x in a {
                var diagonal = 0
                for j in 1...b.count {
                    let above = row[j]
                    row[j] = x == b[j - 1] ? diagonal + 1 : Swift.max(row[j], row[j - 1])
                    diagonal = above
                }
            }
        }
        return Double(start + row[b.count] + end) >= 0.85 * Double(shorter)
    }

    /// The characters of `a` and `b` as numbers, the same for equal characters. The tables in isLongAndSame and ends
    /// compare every character of one text with every character of the other, and comparing Characters is slow (it
    /// takes Unicode's canonical equivalence into account): on a page of 1,500 characters, numbers made noting a
    /// reading 8 times faster.
    private static func numbered(_ a: String, _ b: String) -> ([Int], [Int]) {
        var numbers: [Character: Int] = [:]
        func number(_ text: String) -> [Int] {
            text.map { character in
                if let number = numbers[character] { return number }
                numbers[character] = numbers.count
                return numbers.count - 1
            }
        }
        return (number(a), number(b))
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

    private static func undotted(_ text: String) -> String {
        text.filter { !OCRText.isDot($0) }
    }

    /// Where the first `counts` characters of the earlier reading `old` end within `new`, allowing for differences in
    /// how it was read. For each, that's the end of the shortest start of `new` with the fewest edits from that part of
    /// `old`, returned with the edit count. Dots that were added, dropped or read as other dots cost nothing.
    private static func ends(of old: String, in new: String, at counts: [Int]) -> [(end: Int, edits: Int)] {
        let (a, b) = numbered(old, new)
        guard !b.isEmpty else { return counts.map { (0, $0) } }
        let aDots = old.map(OCRText.isDot), bDots = new.map(OCRText.isDot)
        // Levenshtein distance between `old` and every start of `new`, one character of `old` at a time.
        var row = [0]
        for isDot in bDots { row.append(row[row.count - 1] + (isDot ? 0 : 1)) }
        let wanted = Set(counts)
        var ends = [Int: (end: Int, edits: Int)]()
        let best = { (row: [Int]) in
            let end = row.indices.min { row[$0] < row[$1] } ?? 0
            return (end, row[end])
        }
        if wanted.contains(0) { ends[0] = (0, 0) }
        for (i, x) in a.enumerated() {
            let cost = aDots[i] ? 0 : 1
            var diagonal = row[0]
            row[0] += cost
            for j in 1...b.count {
                let above = row[j]
                let substitution = x == b[j - 1] || (aDots[i] && bDots[j - 1]) ? 0 : 1
                row[j] = Swift.min(diagonal + substitution, above + cost, row[j - 1] + (bDots[j - 1] ? 0 : 1))
                diagonal = above
            }
            if wanted.contains(i + 1) { ends[i + 1] = best(row) }
        }
        return counts.map { ends[$0] ?? best(row) }
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

    mutating func removeFirst(_ count: Int) {
        lines.removeFirst(count)
    }
}
