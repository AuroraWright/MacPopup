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
        Failure("\(name)’s .zip file doesn’t work with this version of MacPopup. Make it again with \(script).")
    }
}

/// What a model does: 16 kHz mono audio (-1 to 1) to text.
protocol Recognizer: AnyObject, Sendable {
    func transcribe(_ samples: [Float], language: String) async throws -> Transcript
    /// Loads what transcribing `language` needs, for models with a part per language.
    func prepare(language: String) async throws
}

extension Recognizer {
    func prepare(language: String) async throws {}
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
        Self.tidied(try await recognizer().transcribe(samples, language: language))
    }

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
        return ConvertedModelsKind.Failure("\(kind.name) isn’t loaded. Load it in Settings → \(kind.settingsSection).")
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
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
