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
        // Without losing the stretch's last words (see endMargin).
        recognizer.endMargin = 1
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
    /// put on 16-bit samples first, as libsoda takes it. A stretch longer than `longest` is recognized in pieces cut
    /// at its quietest moments, each followed by 0.6 s of silence (as SpeechRecognizer ends a stretch).
    public func recognize(_ samples: [Float]) throws -> SODAResult {
        let pcm = Self.pcm(samples)
        lock.lock()
        defer { lock.unlock() }
        var results: [SODAResult] = []
        let pieces = Self.pieces(pcm, 0..<pcm.count)
        for piece in pieces {
            var audio = Array(pcm[piece])
            if piece.upperBound < pcm.count { audio += repeatElement(0, count: 9600) }
            var result = try recognizer.recognize(audio)
            guard !result.words.isEmpty else { continue }
            let offset = piece.lowerBound / 16
            result.startMs += offset
            result.endMs += offset
            for i in result.words.indices { result.words[i].startMs += offset }
            results.append(result)
        }
        guard results.count > 1, let first = results.first, let last = results.last else {
            if let only = results.first { return only }
            return try recognizer.recognize(pcm)
        }
        let separator = recognizer.spacedWords ? " " : ""
        return SODAResult(text: results.map(\.text).joined(separator: separator),
                          rawText: results.map(\.rawText).joined(separator: separator),
                          startMs: first.startMs, endMs: last.endMs, words: results.flatMap(\.words))
    }

    /// The longest piece of speech the model hears at once, in samples. Over a longer one its encoder starts to miss
    /// words, Google's libsoda too: a talk's 21 s stretch lost its last 1.3 s ("…パソコンを持って出かける時に"), which
    /// it kept heard from 4.8 s in; fed the talk continuously, as Chrome does, libsoda lost a phrase a few seconds
    /// later instead. In pieces of at most 15 s, 1,000 Japanese clips (64 longer): 12.72 → 12.71% CER.
    static let longest = 15 * 16000

    /// `range` of the samples in pieces of at most `longest` where it can be, cut in the middle of the quietest 0.2 s
    /// that leaves both sides at least 1 s long (or else in its middle third).
    static func pieces(_ samples: [Float], _ range: Range<Int>) -> [Range<Int>] {
        guard range.count > longest else { return [range] }
        let window = 3200, step = 320
        var low = max(range.lowerBound + 16000, range.upperBound - longest)
        var high = min(range.upperBound - 16000, range.lowerBound + longest) - window
        if low > high { (low, high) = (range.lowerBound + range.count / 3, range.lowerBound + range.count * 2 / 3 - window) }
        var cut = low, quietest = Float.infinity
        for start in stride(from: low, through: max(low, high), by: step) {
            var sum: Float = 0
            for i in start..<min(start + window, range.upperBound) { sum += samples[i] * samples[i] }
            if sum < quietest { (cut, quietest) = (start + window / 2, sum) }
        }
        return pieces(samples, range.lowerBound..<cut) + pieces(samples, cut..<range.upperBound)
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
///
/// As SODAPack.recognize, it hears a long stretch in pieces: past `quietAfter` of a piece, it starts the next one
/// at the first quiet 0.1 s (a tenth of the piece's loudness so far), or at SODAPack.longest without one.
public final class SODAStream: @unchecked Sendable {
    private static let quietAfter = 10 * 16000

    private let recognizer: SODARecognizer
    /// The words of the stretch's earlier pieces.
    private var earlier = ""
    /// The piece's samples so far, and their sum of squares.
    private var heard = 0
    private var energy: Float = 0

    public init(directory: URL) throws {
        recognizer = try SODAPack.recognizer(directory, live: true)
        // A piece's last words, as SODAPack's (see SODARecognizer.endMargin).
        recognizer.endMargin = 1
    }

    /// Starts a new stretch.
    public func start() {
        recognizer.reset()
        (earlier, heard, energy) = ("", 0, 0)
    }

    /// Takes the stretch's next 16 kHz mono samples (-1 to 1), and returns its words so far.
    public func accept(_ samples: [Float]) throws -> String {
        let pcm = SODAPack.pcm(samples)
        try recognizer.accept(pcm)
        let last = pcm.suffix(1600)
        let lastEnergy = last.reduce(0) { $0 + $1 * $1 }
        energy += pcm.reduce(0) { $0 + $1 * $1 }
        heard += pcm.count
        let quiet = lastEnergy / Float(max(1, last.count)) < energy / Float(heard) / 10
        if heard >= SODAPack.longest || (heard >= Self.quietAfter && quiet) {
            // Its last words, with the silence a stretch ends with (see SpeechRecognizer.trailingSilence).
            try recognizer.accept([Float](repeating: 0, count: 9600))
            _ = try recognizer.finish()
            earlier = joined(earlier, recognizer.partialText)
            recognizer.reset()
            (heard, energy) = (0, 0)
        }
        return joined(earlier, recognizer.partialText)
    }

    private func joined(_ a: String, _ b: String) -> String {
        a.isEmpty || b.isEmpty ? a + b : a + (recognizer.spacedWords ? " " : "") + b
    }
}
