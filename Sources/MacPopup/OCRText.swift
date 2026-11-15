/// What OCR reads inconsistently from one reading of the same text to the next, which comparisons of readings leave
/// out (the settle check in OCRController, and ShownLines). web/src/overlay.js's withoutNextIcon matches isNextIcon.
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
}
