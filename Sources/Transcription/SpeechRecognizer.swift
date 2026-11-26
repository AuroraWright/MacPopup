import Foundation
import OCREngines

/// The speech recognition models of Settings → Transcription. None comes with MacPopup: a script per model makes a zip
/// (see ConvertedModelsKind), loaded into Application Support.
public enum SpeechModel: String, CaseIterable, Sendable {
    /// OpenAI's Whisper large-v3 turbo, in Argmax's Core ML build, run with WhisperKit: 99 languages.
    case whisper
    /// litagin's anime-whisper (kotoba-whisper fine-tuned on game and anime voices), run with WhisperKit: Japanese.
    case animeWhisper
    /// Kitsune-Transcribe P-0.3B (from NVIDIA's Parakeet): Japanese, CTC (no repeated or made-up phrases), fast.
    case kitsune
    /// FunAudioLLM's SenseVoice Small: Chinese, Cantonese, Japanese, Korean and English, CTC, the fastest.
    case senseVoice
    /// NVIDIA's Parakeet TDT 0.6B v3: 25 European languages, fast.
    case parakeet
    /// Google's speech recognition for Chrome's Live Caption (SODA), from Chrome's language packs: 16 languages.
    case soda

    public var kind: ConvertedModelsKind {
        switch self {
        case .whisper: .whisper
        case .animeWhisper: .animeWhisper
        case .kitsune: .kitsune
        case .senseVoice: .senseVoice
        case .parakeet: .parakeet
        case .soda: .soda
        }
    }

    /// Whether it gives words as they're heard ("Show words as they're heard"): Whisper's models take too long.
    public var hearsLive: Bool { self != .whisper && self != .animeWhisper }

    /// Whether the model transcribes `language` (Yomitan's ISO code).
    public func reads(_ language: String) -> Bool {
        switch self {
        case .whisper: WhisperRecognizer.languageCode(for: language) != nil
        case .animeWhisper, .kitsune: language == "ja"
        case .senseVoice: SenseVoiceRecognizer.languageIndex[language] != nil
        case .parakeet: ParakeetRecognizer.languages.contains(language)
        case .soda: LiveCaptionRecognizer.locales[language] != nil
        }
    }

    /// Makes Settings' Load and Remove buttons reach the models.
    @MainActor public static func registerModels() {
        for model in allCases {
            ConvertedModelsKind.register(SpeechRecognizer.shared(model), for: model.kind)
        }
        ConvertedModelsKind.register(SentenceEnds.shared, for: .sat)
    }

    /// The files besides its Core ML models that the model needs.
    var requiredFiles: [String] {
        switch self {
        case .whisper, .animeWhisper:
            ["coreml/MelSpectrogram.mlmodelc", "coreml/AudioEncoder.mlmodelc", "coreml/TextDecoder.mlmodelc",
             "coreml/tokenizer.json", "coreml/tokenizer_config.json", "coreml/config.json"]
        case .kitsune: ["coreml/Kitsune.mlmodelc", "kitsune.json", "mel.bin", "vocab.json"]
        case .senseVoice:
            ["coreml/SenseVoicePreprocessor.mlmodelc", "coreml/SenseVoiceSmall_int8.mlmodelc", "sensevoice.json", "vocab.json"]
        case .parakeet:
            ["coreml/Preprocessor.mlmodelc", "coreml/Encoder.mlmodelc", "coreml/Decoder.mlmodelc", "coreml/Joint.mlmodelc",
             "parakeet.json", "vocab.json"]
        case .soda: ["soda.json"]
        }
    }
}

extension ConvertedModelsKind {
    /// The loaded zip isn't what this version of MacPopup reads (files or model outputs missing).
    var unexpectedModels: Failure {
        Failure("\(name)’s .zip archive isn’t compatible with this version of MacPopup. Regenerate it with \(script).")
    }
}

/// What a model does: 16 kHz mono audio (-1 to 1) to text.
protocol Recognizer: AnyObject, Sendable {
    func transcribe(_ samples: [Float], language: String) async throws -> Transcript
    /// Loads what transcribing `language` needs, for models with a part per language.
    func prepare(language: String) async throws
    /// Words as they're heard in `language`, for models that can give them.
    func live(language: String) async throws -> (any LiveTranscription)?
}

extension Recognizer {
    func prepare(language: String) async throws {}
    func live(language: String) async throws -> (any LiveTranscription)? { nil }
}

/// A stretch of speech's words as it's heard, for its line while it's said (Settings → Transcription → "Show words as
/// they're heard"); the line's text comes from `transcribe` once the stretch has ended. One stretch at a time, and one
/// call at a time.
public protocol LiveTranscription: AnyObject, Sendable {
    /// Starts a new stretch.
    func start()
    /// Takes the stretch's next 16 kHz mono samples (-1 to 1), and returns its text so far.
    func accept(_ samples: [Float]) async throws -> String
}

/// Words as they're heard from a model that transcribes whole stretches: the stretch so far, transcribed again each
/// time `interval` seconds more of it were heard. Without the characters heard in its last 0.25 s (when the model
/// tells when they were heard): the last word is often cut there, and the model's guess at it changes as more is heard.
/// Text two passes in a row agree on stays as it is, and later passes only add what follows it: earlier words don't
/// change while the speaker goes on (the stretch's line replaces them all). On a talk, with SenseVoice, 0.18 characters
/// of the text shown changed per update rather than 0.56, and its last text was 13.2% off the line's rather than 10.3%.
final class RepeatedTranscription: LiveTranscription, @unchecked Sendable {
    private static let heldBack = 0.25

    private let recognizer: any Recognizer
    private let language: String
    private let interval: Int
    private var samples: [Float] = []
    private var transcribed = 0
    /// The text that stays, and what followed it in the last pass.
    private var fixed: [Character] = [], rest: [Character] = []

    init(_ recognizer: any Recognizer, language: String, interval: Double) {
        (self.recognizer, self.language, self.interval) = (recognizer, language, Int(interval * 16000))
    }

    func start() {
        (samples, transcribed, fixed, rest) = ([], 0, [], [])
    }

    func accept(_ samples: [Float]) async throws -> String {
        self.samples += samples
        guard self.samples.count - transcribed >= interval else { return String(fixed + rest) }
        let first = transcribed == 0
        transcribed = self.samples.count
        let transcript = SpeechRecognizer.tidied(try await recognizer.transcribe(self.samples, language: language))
        let heard = Double(self.samples.count) / 16000 - Self.heldBack
        var text = transcript.times.map { Array(zip(transcript.text, $0).prefix { $0.1 < heard }.map(\.0)) }
            ?? Array(transcript.text)
        // The models end the stretch's sentence (SenseVoice and Parakeet), which goes on.
        while let last = text.last, "。．.？?！!".contains(last) { text.removeLast() }
        var next = Array(text[Self.end(of: fixed, in: text)...])
        if !first {
            let agreed = zip(rest, next).prefix { $0 == $1 }.count
            fixed += next[..<agreed]
            next.removeFirst(agreed)
        }
        rest = next
        return String(fixed + rest)
    }

    /// Where `fixed` ends in a pass's text: the end of the start of `text` closest to it (by edit distance), the
    /// longest of equally close ones.
    private static func end(of fixed: [Character], in text: [Character]) -> Int {
        guard !fixed.isEmpty else { return 0 }
        var row = Array(0...text.count)
        for character in fixed {
            var diagonal = row[0]
            row[0] += 1
            for (j, other) in zip(1..., text) {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (other == character ? 0 : 1))
                diagonal = above
            }
        }
        let best = row.min()!
        return row.lastIndex(of: best)!
    }
}

/// A transcription, and when each of its characters was heard, for models that tell (all but Whisper's).
public struct Transcript: Sendable, Equatable {
    public private(set) var text = ""
    /// Seconds into the audio, a time per Character of `text`; nil when the model doesn't tell.
    public private(set) var times: [Double]?

    public init(text: String = "", times: [Double]? = nil) {
        (self.text, self.times) = (text, times)
    }

    mutating func append(_ character: Character, at time: Double) {
        text.append(character)
        times?.append(time)
    }

    mutating func append(_ other: Transcript) {
        text += other.text
        times = times.flatMap { mine in other.times.map { mine + $0 } }
    }
}

/// How many speech and sentence-end models are loading, for the Floating Window's audio button: the first time, Core
/// ML can take up to 3 minutes to prepare one.
@MainActor public enum ModelsLoading {
    public private(set) static var count = 0
    /// Posted on the main thread when `count` changes.
    public static let changed = Notification.Name("MacPopupModelsLoadingChanged")

    /// Runs `load`, counted while it runs (also when the load was let go meanwhile, as Core ML goes on preparing).
    nonisolated static func counting<T>(_ load: () async throws -> T) async rethrows -> T {
        await change(by: 1)
        defer { Task { await change(by: -1) } }
        return try await load()
    }

    private static func change(by difference: Int) {
        count += difference
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// One model's loaded recognizer, loading its models and replacing or removing them (Settings' Load and Remove).
public actor SpeechRecognizer: ConvertedModelsStore {
    @MainActor private static var instances: [SpeechModel: SpeechRecognizer] = [:]

    @MainActor public static func shared(_ model: SpeechModel) -> SpeechRecognizer {
        if let recognizer = instances[model] { return recognizer }
        let recognizer = SpeechRecognizer(model)
        instances[model] = recognizer
        return recognizer
    }

    public let model: SpeechModel
    private let directory: URL
    private var loading: Task<any Recognizer, Error>?

    /// - Parameter directory: Where the unpacked zip is; Application Support's by default.
    public init(_ model: SpeechModel, directory: URL? = nil) {
        self.model = model
        self.directory = directory ?? model.kind.directory
    }

    /// Transcribes 16 kHz mono audio (-1 to 1, at most 30 s) in `language` (Yomitan's ISO code; models that don't
    /// read it guess), loading the models first if needed.
    public func transcribe(_ samples: [Float], language: String) async throws -> Transcript {
        let silence = max(0, min(Self.trailingSilence, 30 * 16000 - samples.count))
        return Self.tidied(try await recognizer().transcribe(samples + repeatElement(0, count: silence), language: language))
    }

    /// Silence put after the speech (0.6 s): the models write a word only once they've heard a little past it, and a
    /// stretch cut at a short pause ends right after its last word. Live Caption, Whisper and anime-whisper otherwise
    /// lost the last syllables (on a talk, CER 11.5 → 8.3%, 9.7 → 7.3%, 13.3 → 11.1%); Kitsune and SenseVoice gain less.
    static let trailingSilence = 9600

    /// The text without spaces next to Chinese or Japanese characters, which are written without them (SenseVoice
    /// often puts one between Japanese words), with one space where there were several, and none at either end.
    public static func tidied(_ text: String) -> String {
        tidied(Transcript(text: text)).text
    }

    public static func tidied(_ transcript: Transcript) -> Transcript {
        var result = Transcript(times: transcript.times.map { _ in [] })
        var space: Double?
        for (index, character) in transcript.text.enumerated() {
            let time = transcript.times?[index] ?? 0
            if character.isWhitespace {
                space = space ?? time
                continue
            }
            if let space, let last = result.text.last, !isCJK(last), !isCJK(character) { result.append(" ", at: space) }
            space = nil
            result.append(character, at: time)
        }
        return result
    }

    /// Han, kana, and their punctuation and full-width forms.
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(scalar) || (0x31F0...0x31FF).contains(scalar) || (0x3400...0x4DBF).contains(scalar)
            || (0x4E00...0x9FFF).contains(scalar) || (0xF900...0xFAFF).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
            || (0x20000...0x3FFFF).contains(scalar)
    }

    /// Loads the models, if they aren't yet, with their part for `language` (Live Caption's pack). The first time, Core
    /// ML prepares them for the Neural Engine or the GPU, which takes up to 3 minutes (macOS keeps the result, for
    /// models at the same place).
    public func load(language: String? = nil) async throws {
        let recognizer = try await recognizer()
        if let language { try await recognizer.prepare(language: language) }
    }

    /// Words as they're heard in `language`, loading the models first if needed; nil for models that only transcribe
    /// whole stretches.
    public func live(language: String) async throws -> (any LiveTranscription)? {
        try await recognizer().live(language: language)
    }

    /// Lets the models go, to free their memory; the next transcription loads them again.
    public func unload() {
        loading?.cancel()
        loading = nil
    }

    private func recognizer() async throws -> any Recognizer {
        if let loading { return try await loading.value }
        guard FileManager.default.fileExists(atPath: directory.path) else { throw notLoaded }
        let model = model, directory = directory
        let task = Task.detached(priority: .userInitiated) { () throws -> any Recognizer in
            try Self.check(model, directory)
            return try await ModelsLoading.counting { () throws -> any Recognizer in
                switch model {
                case .whisper, .animeWhisper: return try await WhisperRecognizer(model, directory: directory)
                case .kitsune: return try KitsuneRecognizer(directory: directory)
                case .senseVoice: return try SenseVoiceRecognizer(directory: directory)
                case .parakeet: return try ParakeetRecognizer(directory: directory)
                case .soda: return try LiveCaptionRecognizer(directory: directory)
                }
            }
        }
        loading = task
        do {
            return try await task.value
        } catch {
            if loading == task { loading = nil }
            throw error
        }
    }

    private var notLoaded: Error {
        let kind = model.kind
        return ConvertedModelsKind.Failure("\(kind.name) model isn’t loaded. Load it in Settings → \(kind.settingsSection).")
    }

    private static func check(_ model: SpeechModel, _ directory: URL) throws {
        let kind = model.kind
        for file in model.requiredFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            throw kind.unexpectedModels
        }
    }

    /// Replaces the models with those in a zip made by the model's script, then loads them where they'll stay, so that
    /// Core ML's slow first preparation happens now rather than when transcription starts. If they don't load, they're
    /// removed again.
    public func installModels(from archive: URL) async throws {
        let kind = model.kind
        let staging = try await kind.unpack(archive)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Self.check(model, staging)
        unload()
        defer { postModelsChanged() }
        try kind.moveIn(staging)
        do {
            try await load()
        } catch {
            unload()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func removeModels() async throws {
        unload()
        defer { postModelsChanged() }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Posted on the main thread when a model's files were replaced or removed (the SpeechModel is the object): what
    /// was loaded from the old ones (as a LiveTranscription) is outdated.
    public static let modelsChanged = Notification.Name("MacPopupSpeechModelsChanged")

    private nonisolated func postModelsChanged() {
        let model = model
        Task { @MainActor in NotificationCenter.default.post(name: Self.modelsChanged, object: model) }
    }
}
