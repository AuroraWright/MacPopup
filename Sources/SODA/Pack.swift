import Foundation

/// One language of Chrome's Live Caption: a pack's SODAModels folder, as scripts/convert-soda.py lays it out (Chrome's
/// files, with each symbol table also as JSON, <name>.syms.json), recognizing a stretch of speech at a time.
public final class SODAPack: @unchecked Sendable {
    private let recognizer: SODARecognizer
    private let lock = NSLock()

    /// Loads the pack's models; throws if a file is missing or unreadable.
    public init(directory: URL) throws {
        let config = try Self.config(directory)
        let symbolsFile = directory.appendingPathComponent(config.symbolsFile)
        let symbolsJSON = symbolsFile.deletingPathExtension().appendingPathExtension("json")
        let symbols = try JSONDecoder().decode([String].self, from: Data(contentsOf: symbolsJSON))
        func encoder(_ e: PipelineConfig.Encoder) throws -> TFLiteEncoder {
            let encoder = try TFLiteEncoder(contentsOf: directory.appendingPathComponent(e.file))
            if e.defaultDomainID >= 0 { encoder.domainID = e.domainIDs["CAPTION"] ?? e.defaultDomainID }
            return encoder
        }
        let cascade = config.cascade.encoder.file.isEmpty ? nil : try encoder(config.cascade.encoder)
        recognizer = try SODARecognizer(models: directory, config: config, symbols: symbols,
                                        encoder: try encoder(config.encoder), cascadeEncoder: cascade)
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
        let pcm = samples.map { Float(Int16(clamping: Int(($0 * 32768).rounded()))) }
        lock.lock()
        defer { lock.unlock() }
        return try recognizer.recognize(pcm)
    }
}
