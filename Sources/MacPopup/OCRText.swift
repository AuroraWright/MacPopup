/// What OCR reads inconsistently from one reading of the same text to the next, which comparisons of readings leave
/// out (the settle check in OCRController, and ShownLines), and whether two readings are of the same line.
/// web/src/overlay.js's withoutNextIcon matches isNextIcon.
enum OCRText {
    /// Dots, which OCR often reads with one more or fewer, or misses.
    static func isDot(_ character: Character) -> Bool {
        "・･.．…‥·".contains(character)
    }

    /// Dashes (a thin line), which OCR reads as any of these, or misses.
    static func isDash(_ character: Character) -> Bool {
        "-‐‑–—―─━ー一－".contains(character)
    }

    /// Whether a character at the end of a row is part of the page's "next" icon (▷, ■, ▼, often blinking): a symbol
    /// (Unicode's So and Sm: shapes, arrows, icons), which dialogue text rarely ends with, or whitespace around it.
    static func isNextIcon(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        guard let category = character.unicodeScalars.first?.properties.generalCategory else { return false }
        return category == .otherSymbol || category == .mathSymbol
    }

    /// Text shorter than this could be part of almost any line (see isLongAndSame).
    static var shortLength: Int { 6 }

    /// Whether two readings are of the same line: both are long enough to be matched loosely, and one contains the
    /// other, allowing a few characters to differ, since OCR may misread some.
    static func isLongAndSame(_ a: String, _ b: String) -> Bool {
        let a = a.precomposedStringWithCompatibilityMapping, b = b.precomposedStringWithCompatibilityMapping
        let shorter = Swift.min(a.count, b.count)
        return shorter >= shortLength && Double(commonLength(a, b)) >= 0.85 * Double(shorter)
    }

    /// How many characters `a` and `b` have in common, in the same order (their longest common subsequence).
    static func commonLength(_ a: String, _ b: String) -> Int {
        let (whole, wholeB) = numbered(a, b)
        // The start and end they share, and what's common to what's between (in a table).
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
        return start + row[b.count] + end
    }

    /// Whether most characters of the shorter of two readings are in the other, wherever they are: the same text read
    /// in another order (e.g. its lines), or with characters misread, missed or added.
    static func sharesMost(_ a: String, _ b: String) -> Bool {
        let a = a.precomposedStringWithCompatibilityMapping, b = b.precomposedStringWithCompatibilityMapping
        let shorter = Swift.min(a.count, b.count)
        guard shorter > 0 else { return false }
        var counts: [Character: Int] = [:]
        for character in a { counts[character, default: 0] += 1 }
        var common = 0
        for character in b where counts[character, default: 0] > 0 {
            counts[character, default: 0] -= 1
            common += 1
        }
        return Double(common) >= 2.0 / 3.0 * Double(shorter)
    }

    /// The characters of `a` and `b` as numbers, the same for equal characters. The tables in commonLength and
    /// ShownLines.ends compare every character of one text with every character of the other, and comparing Characters is
    /// slow (it takes Unicode's canonical equivalence into account): on a page of 1,500 characters, numbers made noting
    /// a reading 8 times faster.
    static func numbered(_ a: String, _ b: String) -> ([Int], [Int]) {
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
}
