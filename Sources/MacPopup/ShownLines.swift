import Foundation

/// The lines shown lately in the text box or read by OCR, oldest first, for Anki Audio and Anki Screenshot, so that both
/// take the same line for a card. Each line keeps every version of its text seen, without whitespace, and what its user
/// needs to know about it (`Info`).
struct ShownLines<Info>: RandomAccessCollection, MutableCollection {
    struct Line {
        let id: Int
        var texts: [String]
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

    /// Notes a line's text (normalized, not empty). Another version of the last line (it grows as the game draws it,
    /// arrives again from OCR after the WebSocket, or a long one is read a little differently) is added to that line's
    /// texts; anything else is a new line, with `info`. Short text isn't matched that loosely: it's often a line of its
    /// own (誰？) that happens to be in the last one.
    mutating func note(_ text: String, info: () -> Info) -> Noted {
        let isAgain = { (seen: String) in
            text.hasPrefix(seen) || seen.hasPrefix(text) || (Swift.min(text.count, seen.count) >= Self.shortLength && Self.isSameLine(text, seen))
        }
        if let last = lines.indices.last, lines[last].texts.contains(where: isAgain) {
            let grew = text.count > lines[last].texts.map(\.count).max() ?? 0
            if !lines[last].texts.contains(text) { lines[last].texts.append(text) }
            return .again(index: last, grew: grew)
        }
        lines.append(Line(id: nextID, texts: [text], info: info()))
        nextID += 1
        return .new(index: lines.count - 1)
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
