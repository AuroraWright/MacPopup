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

    public var kind: ConvertedModelsKind {
        switch self {
        case .whisper: .whisper
        case .animeWhisper: .animeWhisper
        case .kitsune: .kitsune
        case .senseVoice: .senseVoice
        case .parakeet: .parakeet
        }
    }

    /// Whether the model transcribes `language` (Yomitan's ISO code).
    public func reads(_ language: String) -> Bool {
        switch self {
        case .whisper: WhisperRecognizer.languageCode(for: language) != nil
        case .animeWhisper, .kitsune: language == "ja"
        case .senseVoice: SenseVoiceRecognizer.languageIndex[language] != nil
        case .parakeet: ParakeetRecognizer.languages.contains(language)
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
        case .kitsune: ["coreml/Kitsune.mlmodelc", "mel.bin", "vocab.json"]
        case .senseVoice: ["coreml/SenseVoicePreprocessor.mlmodelc", "coreml/SenseVoiceSmall_int8.mlmodelc", "vocab.json"]
        case .parakeet:
            ["coreml/Preprocessor.mlmodelc", "coreml/Encoder.mlmodelc", "coreml/Decoder.mlmodelc", "coreml/Joint.mlmodelc",
             "parakeet.json", "vocab.json"]
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
    func transcribe(_ samples: [Float], language: String) async throws -> String
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
    public func transcribe(_ samples: [Float], language: String) async throws -> String {
        Self.tidied(try await recognizer().transcribe(samples, language: language))
    }

    /// The text without spaces next to Chinese or Japanese characters, which are written without them (SenseVoice
    /// often puts one between Japanese words), and with one space where there were several.
    public static func tidied(_ text: String) -> String {
        var result = ""
        var space = false
        for character in text {
            if character.isWhitespace {
                space = true
                continue
            }
            if space, let last = result.last, !isCJK(last), !isCJK(character) { result.append(" ") }
            space = false
            result.append(character)
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

    /// Loads the models, if they aren't yet. The first time, Core ML prepares them for the Neural Engine, which takes
    /// minutes for the Whisper models (macOS keeps the result, for models at the same place).
    public func load() async throws {
        _ = try await recognizer()
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
            switch model {
            case .whisper, .animeWhisper: return try await WhisperRecognizer(model, directory: directory)
            case .kitsune: return try KitsuneRecognizer(directory: directory)
            case .senseVoice: return try SenseVoiceRecognizer(directory: directory)
            case .parakeet: return try ParakeetRecognizer(directory: directory)
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
