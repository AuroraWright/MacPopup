import Foundation

/// One language of Chrome's Live Caption: a pack's SODAModels folder, as scripts/convert-soda.py lays it out (Chrome's
/// files, with each symbol table also as JSON, <name>.syms.json), recognizing a stretch of speech at a time.
public final class SODAPack: @unchecked Sendable {
    private let recognizer: SODARecognizer
    private let lock = NSLock()

    /// Loads the pack's models; throws if a file is missing or unreadable.
    public init(directory: URL) throws {
        recognizer = try Self.recognizer(directory, live: false)
        // The whole stretch is here at once: its frames are encoded 16 at a time (see wholeStretchBatch).
        recognizer.wholeStretchBatch = 16
    }

    /// The pack's recognizer; `live`: for words as they're heard, the first pass only (en-US's second pass gives
    /// finals), without punctuation.
    static func recognizer(_ directory: URL, live: Bool) throws -> SODARecognizer {
        let config = try Self.config(directory)
        let symbolsFile = directory.appendingPathComponent(config.symbolsFile)
        let symbolsJSON = symbolsFile.deletingPathExtension().appendingPathExtension("json")
        let symbols = try JSONDecoder().decode([String].self, from: Data(contentsOf: symbolsJSON))
        func encoder(_ e: PipelineConfig.Encoder) throws -> TFLiteEncoder {
            let encoder = try TFLiteEncoder(contentsOf: directory.appendingPathComponent(e.file))
            if e.defaultDomainID >= 0 { encoder.domainID = e.domainIDs["CAPTION"] ?? e.defaultDomainID }
            return encoder
        }
        let cascade = live || config.cascade.encoder.file.isEmpty ? nil : try encoder(config.cascade.encoder)
        return try SODARecognizer(models: directory, config: config, symbols: symbols, encoder: try encoder(config.encoder),
                                  cascadeEncoder: cascade, punctuation: !live)
    }

    /// Throws unless the folder has a pack's config, symbol table (as JSON) and encoder: quicker than loading it.
    public static func check(directory: URL) throws {
        let config = try config(directory)
        let symbols = directory.appendingPathComponent(config.symbolsFile).deletingPathExtension().appendingPathExtension("json")
        for file in [symbols, directory.appendingPathComponent(config.encoder.file)]
        where !FileManager.default.fileExists(atPath: file.path) {
            throw SODAError("\(directory.lastPathComponent) has no \(file.lastPathComponent)")
        }
    }

    /// The pack's Live Caption pipeline: its continuous config (the largest model there is), for the CAPTION domain.
    static func config(_ directory: URL) throws -> PipelineConfig {
        for name in ["ONDEVICE_LARGE_CONTINUOUS", "ONDEVICE_MEDIUM_CONTINUOUS", "ONDEVICE_SMALL_CONTINUOUS"] {
            let url = directory.appendingPathComponent("configs/\(name).config")
            if FileManager.default.fileExists(atPath: url.path) {
                var config = try PipelineConfig(contentsOf: url)
                config.select(domain: "CAPTION")
                return config
            }
        }
        throw SODAError("\(directory.lastPathComponent) has no continuous config")
    }

    /// Recognizes 16 kHz mono audio (-1 to 1) as one stretch: its final result, with each word's start. The audio is
    /// put on 16-bit samples first, as libsoda takes it.
    public func recognize(_ samples: [Float]) throws -> SODAResult {
        let pcm = Self.pcm(samples)
        lock.lock()
        defer { lock.unlock() }
        return try recognizer.recognize(pcm)
    }

    /// Samples from -1 to 1 on the 16-bit scale, clamped as floats: Int() of a NaN or infinite sample would crash.
    static func pcm(_ samples: [Float]) -> [Float] {
        samples.map { $0.isNaN ? 0 : min(max(($0 * 32768).rounded(), -32768), 32767) }
    }
}

/// A pack's words as a stretch of speech is heard, for showing its line while it's said (as Chrome's partial
/// results, without their formatting); the line's text comes from SODAPack.recognize once the stretch has ended. A
/// recognizer of its own, so that it goes on with the next stretch while SODAPack transcribes the last one. One
/// stretch at a time, from one thread at a time.
public final class SODAStream: @unchecked Sendable {
    private let recognizer: SODARecognizer

    public init(directory: URL) throws {
        recognizer = try SODAPack.recognizer(directory, live: true)
    }

    /// Starts a new stretch.
    public func start() {
        recognizer.reset()
    }

    /// Takes the stretch's next 16 kHz mono samples (-1 to 1), and returns its words so far.
    public func accept(_ samples: [Float]) throws -> String {
        try recognizer.accept(SODAPack.pcm(samples))
        return recognizer.partialText
    }
}
