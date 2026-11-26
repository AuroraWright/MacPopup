import CoreML
import Foundation
import OCREngines

/// SaT (Segment any Text, sat-3l-sm, made by scripts/convert-sat.py): where sentences end in text without punctuation,
/// such as speech transcribed a stretch at a time. XLM-RoBERTa with 3 layers gives each token the probability that a
/// sentence ends after it, which goes to the token's last character (as wtpsplit does). The word embeddings are looked
/// up here, from embeddings.bin (8-bit rows with a scale each, memory-mapped), and the Core ML model does the rest on
/// the CPU.
public actor SentenceEnds: ConvertedModelsStore {
    @MainActor public static let shared = SentenceEnds()

    private let directory = ConvertedModelsKind.sat.directory
    private var loading: Task<Model, Error>?

    /// The probability that a sentence ends after each of the text's characters (0 inside a token), loading the
    /// models first if needed. Only the last 510 tokens are read (the longest input).
    public func probabilities(_ text: String) async throws -> [Float] {
        try await model().probabilities(text)
    }

    public func load() async throws {
        _ = try await model()
    }

    public func unload() {
        loading?.cancel()
        loading = nil
    }

    private func model() async throws -> Model {
        if let loading { return try await loading.value }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ConvertedModelsKind.Failure("SaT model isn’t loaded. Load it in Settings → Transcription.")
        }
        let directory = directory
        let task = Task.detached(priority: .userInitiated) { try await ModelsLoading.counting { try Model(directory: directory) } }
        loading = task
        do {
            return try await task.value
        } catch {
            if loading == task { loading = nil }
            throw error
        }
    }

    public func installModels(from archive: URL) async throws {
        let kind = ConvertedModelsKind.sat
        let staging = try await kind.unpack(archive)
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in ["coreml/SaT.mlmodelc", "embeddings.bin", "tokenizer.json"]
        where !FileManager.default.fileExists(atPath: staging.appendingPathComponent(file).path) {
            throw kind.unexpectedModels
        }
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

    /// The loaded model; nothing changes after init, so probabilities may be asked for at the same time.
    final class Model: @unchecked Sendable {
        /// A model per input length (sat.json's buckets), the functions of SaT.mlmodelc.
        private let models: [Int: MLModel]
        private let tokenizer: UnigramTokenizer
        /// The rows' scales ([vocabulary] float32), then the rows ([vocabulary][hidden] int8).
        private let embeddings: Data
        private let vocabulary, hidden, start, end: Int
        /// The model's input lengths in tokens (sat.json): the embeddings are padded to the shortest that fits.
        private let buckets: [Int]

        init(directory: URL) throws {
            guard let info = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("sat.json"))) as? [String: Any],
                  let vocabulary = info["vocabulary"] as? Int, let hidden = info["hidden"] as? Int,
                  let buckets = info["buckets"] as? [Int], !buckets.isEmpty, let start = info["start"] as? Int, let end = info["end"] as? Int
            else { throw ConvertedModelsKind.sat.unexpectedModels }
            (self.vocabulary, self.hidden, self.start, self.end) = (vocabulary, hidden, start, end)
            self.buckets = buckets.sorted()
            embeddings = try Data(contentsOf: directory.appendingPathComponent("embeddings.bin"), options: .alwaysMapped)
            guard embeddings.count == vocabulary * (4 + hidden) else { throw ConvertedModelsKind.sat.unexpectedModels }
            tokenizer = try UnigramTokenizer(directory.appendingPathComponent("tokenizer.json"))
            models = try Dictionary(uniqueKeysWithValues: self.buckets.map { bucket in
                let configuration = MLModelConfiguration()
                // Small enough for the CPU, which leaves the GPU and Neural Engine to the speech models.
                configuration.computeUnits = .cpuOnly
                configuration.functionName = "b\(bucket)"
                return (bucket, try MLModel(contentsOf: directory.appendingPathComponent("coreml/SaT.mlmodelc"), configuration: configuration))
            })
            // Each length once, as the first prediction takes longer.
            for bucket in self.buckets {
                _ = try probabilities(String(repeating: "あ", count: bucket / 2))
            }
        }

        func probabilities(_ text: String) throws -> [Float] {
            var tokens = tokenizer.tokens(text)
            var result = [Float](repeating: 0, count: text.count)
            guard !tokens.isEmpty else { return result }
            tokens = Array(tokens.suffix(buckets.last! - 2))
            let ids = [start] + tokens.map(\.id) + [end]
            let bucket = buckets.first { $0 >= ids.count }!
            let input = try MLMultiArray(shape: [1, NSNumber(value: bucket), NSNumber(value: hidden)], dataType: .float32)
            embeddings.withUnsafeBytes { raw in
                let scales = raw.bindMemory(to: Float.self)
                let rows = raw.baseAddress!.advanced(by: 4 * vocabulary).assumingMemoryBound(to: Int8.self)
                input.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
                    pointer.update(repeating: 0)
                    for (position, id) in ids.enumerated() where id < vocabulary {
                        let scale = scales[id], row = rows + id * hidden, out = pointer.baseAddress! + position * hidden
                        for index in 0..<hidden { out[index] = Float(row[index]) * scale }
                    }
                }
            }
            let output = try models[bucket]!.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "embeddings": MLFeatureValue(multiArray: input),
                "length": MLFeatureValue(multiArray: int32Array(ids.count)),
            ]))
            try withOutput(output, "logits") { logits, _, strides in
                for (index, token) in tokens.enumerated() {
                    guard let last = token.last else { continue }
                    result[last] = 1 / (1 + exp(-logits[(index + 1) * strides[1]]))
                }
            }
            return result
        }
    }
}

/// XLM-RoBERTa's tokenizer (tokenizer.json): NFKC, words split at spaces with "▁" before each, then the unigram pieces
/// that score highest (Viterbi).
struct UnigramTokenizer {
    struct Token {
        let id: Int
        /// The index of the text's last character the token covers; nil for a "▁" alone.
        let last: Int?
    }

    private let pieces: [String: (id: Int, score: Float)]
    private let longest: Int
    private let unknown: Int
    private let unknownScore: Float

    init(_ url: URL) throws {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = json["model"] as? [String: Any], (model["type"] as? String ?? "Unigram") == "Unigram",
              let vocab = model["vocab"] as? [[Any]], let unknown = model["unk_id"] as? Int
        else { throw ConvertedModelsKind.sat.unexpectedModels }
        var pieces: [String: (id: Int, score: Float)] = [:]
        pieces.reserveCapacity(vocab.count)
        var longest = 1, lowest = Float.infinity
        for (id, entry) in vocab.enumerated() {
            guard entry.count == 2, let piece = entry[0] as? String, let score = (entry[1] as? NSNumber)?.floatValue else { continue }
            pieces[piece] = (id, score)
            longest = max(longest, piece.unicodeScalars.count)
            lowest = min(lowest, score)
        }
        (self.pieces, self.longest, self.unknown) = (pieces, longest, unknown)
        // As SentencePiece: unknown characters score 10 below the lowest piece.
        unknownScore = lowest - 10
    }

    func tokens(_ text: String) -> [Token] {
        // The normalized text's characters (Unicode scalars, as SentencePiece reads), with the index of the text's
        // character each comes from; spaces become "▁" starting a word.
        var words: [[(scalar: Unicode.Scalar, owner: Int?)]] = []
        var word: [(scalar: Unicode.Scalar, owner: Int?)] = []
        for (index, character) in text.enumerated() {
            if character.isWhitespace {
                if !word.isEmpty { words.append(word) }
                word = []
                continue
            }
            if word.isEmpty { word.append(("▁", nil)) }
            for scalar in String(character).precomposedStringWithCompatibilityMapping.unicodeScalars {
                word.append((scalar, index))
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.flatMap(viterbi)
    }

    /// The word's best pieces.
    private func viterbi(_ word: [(scalar: Unicode.Scalar, owner: Int?)]) -> [Token] {
        let count = word.count
        var best = [Float](repeating: -.infinity, count: count + 1)
        var from = [(start: Int, id: Int)](repeating: (0, 0), count: count + 1)
        best[0] = 0
        for end in 1...count {
            for start in max(0, end - longest)..<end where best[start] > -.infinity {
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: word[start..<end].map(\.scalar))
                if let (id, score) = pieces[String(piece)], best[start] + score > best[end] {
                    best[end] = best[start] + score
                    from[end] = (start, id)
                }
            }
            if best[end] == -.infinity, best[end - 1] > -.infinity {
                best[end] = best[end - 1] + unknownScore
                from[end] = (end - 1, unknown)
            }
        }
        var tokens: [Token] = []
        var end = count
        while end > 0 {
            let (start, id) = from[end]
            tokens.append(Token(id: id, last: word[start..<end].last(where: { $0.owner != nil })?.owner))
            end = start
        }
        return tokens.reversed()
    }
}
