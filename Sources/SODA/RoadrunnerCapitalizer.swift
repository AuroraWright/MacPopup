import Foundation

/// Restores letter case with a pack's Roadrunner capitalization model (RuntimeRoadrunnerCapitalizationNormalizer:
/// id-ID, pl-PL, tr-TR, vi-VN), as libsoda does before formatting.
///
/// denorm/SODA_capitalization_model.tflite is a text normalization model that reads and writes a serialized
/// speech.textnorm.Sentence. A tagger labels each word "keep as is" or "rewrite"; a character seq2seq model rewrites
/// the latter (in practice, capitalizes them). Its custom ops, which move words between the Sentence proto and tensors,
/// are below. Like libsoda, long inputs are cased in overlapping windows of words.
final class RoadrunnerCapitalizer: WordStage {
    private let interpreter: Interpreter
    /// Words per model call; `left` and `right` of them are context only, except at the ends of the input.
    private let window: Int, left: Int, right: Int

    init(model: URL, window: Int, left: Int, right: Int) throws {
        guard window > left + right else { throw SODAError("bad capitalization window") }
        interpreter = try Interpreter(contentsOf: model)
        (self.window, self.left, self.right) = (window, left, right)
        guard interpreter.inputs.count == 1, !interpreter.outputs.isEmpty else {
            throw SODAError("unsupported capitalization model")
        }
    }

    /// The model's input for some words: a serialized Sentence.
    static func sentence(_ words: ArraySlice<[UInt8]>) -> [UInt8] {
        var s = TextnormSentence()
        s.hasText = true
        var request = ProtoWriter()
        for w in words {
            if !s.context.isEmpty { s.originalText.append(32) }
            let l = s.originalText.count
            s.originalText += w
            s.context.append(w)
            s.spans.append((l, s.originalText.count))
            request.bytes(1, w)
        }
        request.bytes(2, s.originalText)
        var inputRequest = ProtoWriter()
        inputRequest.message(3, request)
        s.inputRequest = inputRequest.data
        return s.serialized
    }

    /// Runs the model on one serialized Sentence and returns its output.
    func run(_ sentence: [UInt8]) throws -> [UInt8] {
        let out = try interpreter.run([Tensor(shape: [1], data: .string([sentence]))])[0]
        guard case .string(let v) = out.data, let first = v.first else { return [] }
        return first
    }

    func apply(_ strings: inout [String]) {
        let words = strings.map { Array($0.utf8) }
        var cased = strings
        let n = words.count
        let step = window - left - right
        var start = 0
        while start < n {
            let end = min(n, start + window)
            let last = end == n
            // The words this window decides: all but its buffers, except at the ends.
            let keepFrom = start == 0 ? 0 : start + left
            let keepTo = last ? n : end - right
            // A failed run leaves the words as they are, as libsoda's empty output does.
            let out = TextnormSentence((try? run(Self.sentence(words[start..<end]))) ?? [])
            for e in out.examples {
                let i = start + e.spanLeft
                if e.spanRight != e.spanLeft + 1 || i < keepFrom || i >= keepTo { continue }
                if e.hypothesis.isEmpty || (e.hypothesis.count == 1 && e.hypothesis[0] == Array("<self>".utf8)) { continue }
                cased[i] = String(decoding: e.hypothesis.joined(), as: UTF8.self)
            }
            if last { break }
            start += step
        }
        strings = cased
    }
}

/// speech.textnorm.Sentence, the fields the capitalization model uses.
struct TextnormSentence {
    struct Example {
        /// 1 input_token_pieces
        var input: [[UInt8]] = []
        /// 5 hypothesis_token_pieces
        var hypothesis: [[UInt8]] = []
        /// 10
        var skipInTraining = false
        /// 12 context_span
        var hasSpan = false
        var spanLeft = 0, spanRight = 0
        /// 13
        var skipInInference = false
    }

    /// 1
    var examples: [Example] = []
    /// 2
    var hasText = false
    var originalText: [UInt8] = []
    /// 3 context_token_pieces
    var context: [[UInt8]] = []
    /// 4, byte offsets
    var spans: [(Int, Int)] = []
    /// 6
    var hasScore = false
    var score: Float = 0
    /// 8, passed through as is
    var inputRequest: [UInt8] = []

    init() {}

    private static func span(_ r: ProtoReader) -> (Int, Int) {
        var s = (0, 0)
        r.forEach { f in
            if f.field == 1 { s.0 = Int(Int32(truncatingIfNeeded: f.int)) }
            if f.field == 2 { s.1 = Int(Int32(truncatingIfNeeded: f.int)) }
        }
        return s
    }

    init(_ data: [UInt8]) {
        ProtoReader(data).forEach { r in
            switch r.field {
            case 1:
                var e = Example()
                r.message.forEach { x in
                    switch x.field {
                    case 1: e.input.append(x.bytes)
                    case 5: e.hypothesis.append(x.bytes)
                    case 10: e.skipInTraining = x.bool
                    case 12:
                        e.hasSpan = true
                        (e.spanLeft, e.spanRight) = Self.span(x.message)
                    case 13: e.skipInInference = x.bool
                    default: break
                    }
                }
                examples.append(e)
            case 2:
                hasText = true
                originalText = r.bytes
            case 3: context.append(r.bytes)
            case 4: spans.append(Self.span(r.message))
            case 6:
                hasScore = true
                score = r.float
            case 8: inputRequest = r.bytes
            default: break
            }
        }
    }

    private static func write(_ w: inout ProtoWriter, _ field: Int, _ left: Int, _ right: Int) {
        var span = ProtoWriter()
        span.varint(1, UInt64(bitPattern: Int64(left)))
        span.varint(2, UInt64(bitPattern: Int64(right)))
        w.message(field, span)
    }

    var serialized: [UInt8] {
        var w = ProtoWriter()
        for e in examples {
            var x = ProtoWriter()
            e.input.forEach { x.bytes(1, $0) }
            e.hypothesis.forEach { x.bytes(5, $0) }
            if e.skipInTraining { x.bool(10, true) }
            if e.hasSpan { Self.write(&x, 12, e.spanLeft, e.spanRight) }
            if e.skipInInference { x.bool(13, true) }
            w.message(1, x)
        }
        if hasText { w.bytes(2, originalText) }
        context.forEach { w.bytes(3, $0) }
        for (l, r) in spans { Self.write(&w, 4, l, r) }
        if hasScore { w.float(6, score) }
        if !inputRequest.isEmpty { w.bytes(8, inputRequest) }
        return w.data
    }
}

/// The capitalization model's custom ops.
extension Context {
    /// Padding and space replacement of the ops that turn words into tensors.
    private struct TokenOptions {
        var padding: [UInt8]
        var replaceSpace: [UInt8]

        init(_ options: FlexValue?) {
            padding = options?["padding"].asBytes ?? []
            replaceSpace = options?["replace_space"].asBytes ?? []
        }

        func token(_ s: [UInt8]) -> [UInt8] {
            s.flatMap { $0 == 32 ? replaceSpace : [$0] }
        }
    }

    /// UTF-8 characters of `s`.
    private static func characters(_ s: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i < s.count {
            let n = UnicodeCase.characterLength(s, i)
            out.append(Array(s[i..<i + n]))
            i += n
        }
        return out
    }

    /// The model's tag set has one hypothesis class, <self>: label 1 keeps a word as it is, label 2 has the seq2seq
    /// model rewrite it.
    private static let keepLabel = 1, rewriteLabel = 2

    mutating func textnorm(_ op: TFLiteModel.Operator, _ options: FlexValue?) throws -> Bool {
        switch op.custom {
        case "SentenceToInputContext":
            // The words of each sentence, padded.
            let o = TokenOptions(options)
            let sentences = input(op, 0).strings.map(TextnormSentence.init)
            let most = sentences.map(\.context.count).max() ?? 0
            var words: [[UInt8]] = []
            for s in sentences {
                for i in 0..<most { words.append(i < s.context.count ? o.token(s.context[i]) : o.padding) }
            }
            set(op, 0, Tensor(shape: [sentences.count, most], data: .string(words)))
            set(op, 1, Tensor(sentences.map { Int32($0.context.count) }))
        case "RetokenizeSentence":
            // One example per word, from the tagger's labels.
            let labels = input(op, 1), counts = input(op, 2).ints, scores = input(op, 3).floats
            guard labels.shape.count == 3 else { throw SODAError("RetokenizeSentence labels") }
            let tokenizations = labels.shape[1], width = labels.shape[2]
            let l = labels.ints
            var out: [[UInt8]] = []
            for (b, data) in input(op, 0).strings.enumerated() {
                var s = TextnormSentence(data)
                s.inputRequest = []
                for i in 0..<min(counts[b], s.context.count) {
                    let at = b * tokenizations * width + i
                    let label = l[at]
                    if label != Self.keepLabel && label != Self.rewriteLabel { continue }
                    var e = TextnormSentence.Example()
                    e.input = Self.characters(s.context[i])
                    if label == Self.keepLabel {
                        e.hypothesis = [Array("<self>".utf8)]
                        e.skipInTraining = true
                        e.skipInInference = true
                    }
                    e.hasSpan = true
                    e.spanLeft = i
                    e.spanRight = i + 1
                    s.examples.append(e)
                    s.hasScore = true
                    s.score += scores[at]
                }
                out.append(s.serialized)
            }
            set(op, 0, Tensor(shape: [out.count], data: .string(out)))
        case "SentenceToTokenTensors":
            // The words to rewrite, as character tensors.
            let o = TokenOptions(options)
            var batch: [Int32] = [], example: [Int32] = [], spans: [Int32] = [], lengths: [Int32] = []
            var chars: [[[UInt8]]] = [], joined: [[UInt8]] = []
            var longest = 1
            for (b, data) in input(op, 0).strings.enumerated() {
                for (i, e) in TextnormSentence(data).examples.enumerated() where !e.skipInInference {
                    batch.append(Int32(b))
                    example.append(Int32(i))
                    spans += [Int32(e.spanLeft), Int32(e.spanRight)]
                    chars.append(e.input.map(o.token))
                    lengths.append(Int32(e.input.count))
                    joined.append(Array(e.input.joined()))
                    longest = max(longest, e.input.count)
                }
            }
            let n = batch.count
            let padded = chars.flatMap { $0 + Array(repeating: o.padding, count: longest - $0.count) }
            set(op, 0, Tensor(batch))
            set(op, 1, Tensor([Int32](repeating: 0, count: n)))
            set(op, 2, Tensor(example))
            set(op, 3, Tensor(spans, shape: [n, 2]))
            set(op, 4, Tensor(shape: [n, longest], data: .string(padded)))
            set(op, 5, Tensor(lengths))
            // No targets at inference.
            set(op, 6, Tensor(shape: [n, 1], data: .string(Array(repeating: o.padding, count: n))))
            set(op, 7, Tensor([Int32](repeating: 0, count: n)))
            set(op, 8, Tensor(shape: [n], data: .string(joined)))
        case "AttachHypothesisToSentence":
            // The rewritten words back into examples.
            var sentences = input(op, 0).strings.map(TextnormSentence.init)
            let batch = input(op, 1).ints, example = input(op, 3).ints
            let hypotheses = input(op, 4), lengths = input(op, 5).ints, scores = input(op, 6).floats
            let pieces = hypotheses.strings
            let width = hypotheses.shape.count == 2 ? hypotheses.shape[1] : 0
            for i in 0..<(input(op, 1).shape.first ?? 0) {
                let b = batch[i], x = example[i]
                guard b >= 0 && b < sentences.count, x >= 0 && x < sentences[b].examples.count else {
                    throw SODAError("AttachHypothesisToSentence index")
                }
                let n = min(lengths[i], width)
                sentences[b].examples[x].hypothesis = Array(pieces[(i * width)..<(i * width + n)])
                sentences[b].hasScore = true
                sentences[b].score += scores[i]
            }
            set(op, 0, Tensor(shape: [sentences.count], data: .string(sentences.map(\.serialized))))
        case "TokenPostProcess":
            // Resolves <unk> to the input character it stands for.
            let out = input(op, 0).strings.map { data -> [UInt8] in
                var s = TextnormSentence(data)
                for x in s.examples.indices {
                    for i in s.examples[x].hypothesis.indices
                    where s.examples[x].hypothesis[i] == Array("<unk>".utf8) && i < s.examples[x].input.count {
                        s.examples[x].hypothesis[i] = s.examples[x].input[i]
                    }
                }
                return s.serialized
            }
            set(op, 0, Tensor(shape: [out.count], data: .string(out)))
        default:
            return false
        }
        return true
    }
}
