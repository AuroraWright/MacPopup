import Foundation
import OCREngines
import SODA

/// Chrome's Live Caption (SODA), from the language packs scripts/convert-soda.py downloads from Chrome's update server:
/// a folder per pack (Chrome's locale) with Chrome's files, the packs listed in soda.json. A language's pack is loaded
/// when it's first needed, one at a time (each takes 150-400 MB).
final class LiveCaptionRecognizer: Recognizer, @unchecked Sendable {
    /// Yomitan's languages, and Chrome's packs that read them (the first one loaded is used).
    static let locales: [String: [String]] = [
        "ja": ["ja-JP"], "en": ["en-US"], "de": ["de-DE"], "fr": ["fr-FR"], "es": ["es-ES"], "it": ["it-IT"],
        "ru": ["ru-RU"], "ko": ["ko-KR"], "hi": ["hi-IN"], "pt": ["pt-BR"], "id": ["id-ID"], "pl": ["pl-PL"],
        "th": ["th-TH"], "tr": ["tr-TR"], "vi": ["vi-VN"], "zh": ["cmn-Hans-CN", "cmn-Hant-TW"],
    ]

    private let directory: URL
    /// The packs in the zip.
    private let installed: [String]
    private let lock = NSLock()
    private var loaded: (locale: String, pack: SODAPack)?

    init(directory: URL) throws {
        self.directory = directory
        let info = (try? Data(contentsOf: directory.appendingPathComponent("soda.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let installed = info?["languages"] as? [String], !installed.isEmpty else {
            throw ConvertedModelsKind.soda.unexpectedModels
        }
        do {
            for locale in installed { try SODAPack.check(directory: directory.appendingPathComponent(locale, isDirectory: true)) }
        } catch {
            throw ConvertedModelsKind.soda.unexpectedModels
        }
        self.installed = installed
    }

    func prepare(language: String) async throws {
        _ = try await pack(for: language)
    }

    func transcribe(_ samples: [Float], language: String) async throws -> Transcript {
        let result = try await pack(for: language).recognize(samples)
        return Self.transcript(result)
    }

    /// The pack for `language`, loading it in place of the last one if needed (counted in ModelsLoading, as a model's
    /// loading). A language Live Caption doesn't read gets the first pack.
    private func pack(for language: String) async throws -> SODAPack {
        let wanted = Self.locales[language]
        guard let locale = wanted.map({ $0.first(where: installed.contains) }) ?? installed.first else {
            let name = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
            throw ConvertedModelsKind.Failure(
                "The Live Caption .zip file has no \(name) pack. Make one with \(ConvertedModelsKind.soda.script) \(wanted?.first ?? language), then load it in Settings → Transcription.")
        }
        if let pack = lock.withLock({ loaded?.locale == locale ? loaded?.pack : nil }) { return pack }
        return try await ModelsLoading.counting { try load(locale) }
    }

    private func load(_ locale: String) throws -> SODAPack {
        try lock.withLock {
            if let loaded, loaded.locale == locale { return loaded.pack }
            // The last pack goes first, so that two aren't in memory at once.
            loaded = nil
            let pack = try SODAPack(directory: directory.appendingPathComponent(locale, isDirectory: true))
            loaded = (locale, pack)
            return pack
        }
    }

    /// The result's text, its characters timed from the words' starts: each word's characters spread evenly until the
    /// next word starts (the last until the end of the speech), the spaces and marks between words at the next one's.
    static func transcript(_ result: SODAResult) -> Transcript {
        let text = Array(result.text)
        var transcript = Transcript(times: [])
        var cursor = 0
        let words = result.words.filter { !$0.text.isEmpty }
        for (index, word) in words.enumerated() {
            let characters = Array(word.text)
            guard let at = (cursor...max(cursor, text.count - characters.count)).first(where: {
                $0 + characters.count <= text.count && Array(text[$0..<$0 + characters.count]) == characters
            }) else {
                // Not where expected: the text without times rather than wrong ones.
                return Transcript(text: result.text)
            }
            let start = Double(word.startMs) / 1000
            let end = max(start, Double(index + 1 < words.count ? words[index + 1].startMs : result.endMs) / 1000)
            for character in text[cursor..<at] { transcript.append(character, at: start) }
            for (offset, character) in characters.enumerated() {
                transcript.append(character, at: start + (end - start) * Double(offset) / Double(characters.count))
            }
            cursor = at + characters.count
        }
        for character in text[cursor...] { transcript.append(character, at: Double(result.endMs) / 1000) }
        return transcript
    }
}
