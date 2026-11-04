import Foundation
import VisionKit

/// OCR mode's language: Settings → General → Language, an ISO code of Yomitan's (see web/src/lib/languages.js).
enum OCRLanguage {
    /// The languages Live Text reads on this version of macOS, e.g. "ja-JP" or "zh-Hans".
    @MainActor private static let liveTextLanguages = ImageAnalyzer.supportedTextRecognitionLanguages

    /// Yomitan's languages that Live Text reads as another one.
    private static let liveTextEquivalents = ["arz": ["ar"], "no": ["no", "nb", "nn"]]

    /// The Live Text languages for `language` (e.g. both Chinese scripts for "zh"), empty when it doesn't read it.
    @MainActor static func liveTextLocales(for language: String) -> [String] {
        let codes = liveTextEquivalents[language] ?? [language]
        return liveTextLanguages.filter { identifier in
            Locale.Language(identifier: identifier).languageCode.map { codes.contains($0.identifier) } ?? false
        }
    }

    /// Whether the engine (Settings → OCR Mode → Text recognition engine) reads `language`. Screen AI and OneOCR read most
    /// scripts; PP-OCRv6_manga is trained on Japanese and Chinese.
    @MainActor static func isRead(_ language: String, by engine: String) -> Bool {
        switch engine {
        case "liveText": !liveTextLocales(for: language).isEmpty
        case "meikiocr": language == "ja"
        case "ppocrmanga": ["ja", "zh", "yue"].contains(language)
        default: true
        }
    }

    /// Whether `text` may be in `language`, as Yomitan's isTextLookupWorthy decides it: some of it is in the language's
    /// characters (Japanese's and Chinese's as in Yomitan, otherwise the language's script), or it has no letters
    /// (e.g. "……"). Unknown languages and "Any" take everything.
    static func contains(_ text: String, language: String) -> Bool {
        guard text.contains(where: \.isLetter) else { return true }
        switch language {
        case "ja": return text.unicodeScalars.contains { japaneseRanges.contains($0.value) }
        case "zh", "yue": return text.unicodeScalars.contains { chineseRanges.contains($0.value) }
        default:
            guard let scripts = scripts[language] else { return true }
            return scripts.contains { text.range(of: "\\p{Script=\($0)}", options: .regularExpression) != nil }
        }
    }

    /// The Unicode scripts each of Yomitan's other languages is written in.
    private static let scripts: [String: [String]] = {
        var scripts: [String: [String]] = [
            "aii": ["Syriac"], "ar": ["Arabic"], "arz": ["Arabic"], "fa": ["Arabic"],
            "be": ["Cyrillic"], "bg": ["Cyrillic"], "mn": ["Cyrillic"], "ru": ["Cyrillic"], "uk": ["Cyrillic"],
            "sh": ["Latin", "Cyrillic"], "el": ["Greek"], "grc": ["Greek"], "he": ["Hebrew"], "yi": ["Hebrew"],
            "hi": ["Devanagari"], "hy": ["Armenian"], "ka": ["Georgian"], "kn": ["Kannada"], "km": ["Khmer"],
            "ko": ["Hangul"], "lo": ["Lao"], "th": ["Thai"],
        ]
        for language in [
            "br", "cs", "cy", "da", "de", "en", "eo", "es", "et", "eu", "fi", "fr", "ga", "gd", "gv", "haw", "hu", "id",
            "it", "kw", "la", "lv", "mt", "nl", "no", "pl", "pt", "ro", "sga", "sq", "sv", "tl", "tok", "tr", "vi",
        ] {
            scripts[language] = ["Latin"]
        }
        return scripts
    }()

    /// Yomitan's CJK_IDEOGRAPH_RANGES, CJK_PUNCTUATION_RANGE and FULLWIDTH_CHARACTER_RANGES (js/language/CJK-util.js).
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF,
        0x2CEB0...0x2EBEF, 0x30000...0x3134F, 0x31350...0x323AF, 0x2EBF0...0x2EE5F, 0x323B0...0x3347F, 0xF900...0xFAFF,
        0x2F800...0x2FA1F,
        0x3000...0x303F,
        0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF01...0xFF0F, 0xFF1A...0xFF1F, 0xFF3B...0xFF3F,
        0xFF5B...0xFF60, 0xFFE0...0xFFEE,
    ]

    /// Yomitan's JAPANESE_RANGES (js/language/ja/japanese.js): kana, halfwidth kana and kana punctuation, and CJK.
    private static let japaneseRanges = cjkRanges + [0x3040...0x309F, 0x30A0...0x30FF, 0xFF66...0xFF9F, 0xFF61...0xFF65]

    /// Yomitan's CHINESE_RANGES (js/language/zh/chinese.js): CJK, bopomofo, and ideographic, small and vertical forms.
    private static let chineseRanges = cjkRanges + [0x3100...0x312F, 0x31A0...0x31BF, 0x16FE0...0x16FFF, 0xFE50...0xFE6F, 0xFE10...0xFE1F]
}

private extension Array where Element == ClosedRange<UInt32> {
    func contains(_ value: UInt32) -> Bool {
        contains { $0.contains(value) }
    }
}
