import Foundation
import WhisperKit

/// Whisper models in WhisperKit's Core ML format (Argmax's build of large-v3 turbo, or anime-whisper converted with
/// whisperkittools), run with WhisperKit: its retries at higher temperatures end the loops autoregressive models fall
/// into on moans and laughs.
final class WhisperRecognizer: Recognizer, @unchecked Sendable {
    private let pipe: WhisperKit
    private let model: SpeechModel

    init(_ model: SpeechModel, directory: URL) async throws {
        self.model = model
        let folder = directory.appendingPathComponent("coreml", isDirectory: true)
        // The tokenizer is the folder's; WhisperKit looks for it under tokenizerFolder's Hub-style subfolders first,
        // which don't exist there.
        pipe = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder.path, tokenizerFolder: folder, verbose: false, logLevel: .error,
            prewarm: false, load: true, download: false))
    }

    /// Whisper's code for a Yomitan language, nil when Whisper doesn't transcribe it.
    static func languageCode(for language: String) -> String? {
        let code = ["arz": "ar", "no": "no", "nb": "no", "nn": "nn"][language] ?? language
        return Set(Constants.languages.values).contains(code) ? code : nil
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        let options = DecodingOptions(
            // anime-whisper is Japanese only; Whisper detects languages it isn't given.
            language: model == .animeWhisper ? "ja" : Self.languageCode(for: language),
            skipSpecialTokens: true, withoutTimestamps: true,
            // WhisperKit's own check, not Whisper's: a first token below this ends the text there, and after the last
            // retry the line is empty. The audio given is speech (the voice detector's), so it's left out.
            firstTokenLogProbThreshold: nil)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
