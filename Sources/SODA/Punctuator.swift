import Foundation

/// Automatic punctuation with the pack's SODA_punctuation_model, as opensoda's Punctuator:
/// - a pQRNN classifier (ja-JP, de-DE...): takes the space-separated tokens of a hypothesis (characters, or words in
///   packs that segment by whitespace) and predicts, for each, the mark to append;
/// - a Roadrunner tagger (en-US, ko-KR...): takes one lowercased string per word and returns one label per word, the
///   mark before it (from the config's codebook). Long inputs are tagged in overlapping windows.
/// Both then capitalize the first token and each one after a sentence end.
final class Punctuator: Punctuating {
    private let interpreter: Interpreter
    private var labels: [[UInt8]] = []
    private var supportedMarks: [[UInt8]] = []
    private var sentenceEndMarks: [[UInt8]] = []
    /// BasicTextSegmenterConfig.SegmentBy: what a pQRNN model token is.
    private static let simpleWhitespace = 1
    private var segmentBy = 2
    private var scoresOutput = -1, labelsOutput = -1
    private let roadrunner: Bool
    private var codebook: [[UInt8]] = []
    private var appendDummyToken = false
    private var windowSize = 30, windowLeft = 2, windowRight = 5, windowMinRemainder = 0

    init(models: URL) throws {
        interpreter = try Interpreter(contentsOf: models.appendingPathComponent("SODA_punctuation_model.tflite"))
        let graph = interpreter.model.subgraphs[0]
        for index in graph.outputs {
            // ja-JP names them "Softmax"; de-DE "pqrnn_model/pqrnn_encoder/Softmax".
            let name = graph.tensors[index].name.split(separator: "/").last.map(String.init) ?? ""
            if name == "Softmax" { scoresOutput = index }
            if name == "LabelMap" { labelsOutput = index }
        }
        // A Roadrunner tagger returns int32 labels instead of class scores.
        roadrunner = scoresOutput < 0 && graph.outputs.count == 1 && graph.tensors[graph.outputs[0]].type == .int32
            && graph.tensors[graph.inputs[0]].type == .string
        guard scoresOutput >= 0 || roadrunner else { throw SODAError("unsupported punctuation model") }
        // speech_formatting.UnspokenPunctuationInferenceSettings: field 7 is the BasicTextSegmenterConfig (1 supported
        // marks, 2 end of sentence marks, 3 segment by), 11 the RoadrunnerPunctuationNormalizerParams.
        if let settings = try? Data(contentsOf: models.appendingPathComponent("SODA_punctuation_config.pb")) {
            ProtoReader([UInt8](settings)).forEach { f in
                if f.field == 7 {
                    f.message.forEach { s in
                        if s.field == 1 { supportedMarks.append(s.bytes) }
                        if s.field == 2 { sentenceEndMarks.append(s.bytes) }
                        if s.field == 3 { segmentBy = s.int }
                    }
                }
                if f.field == 11 {
                    f.message.forEach { r in
                        switch r.field {
                        case 2: codebook.append(r.bytes)
                        case 3: appendDummyToken = r.int != 0
                        case 7: windowSize = r.int
                        case 8: windowLeft = r.int
                        case 9: windowRight = r.int
                        case 10: windowMinRemainder = r.int
                        default: break
                        }
                    }
                }
            }
        }
        if roadrunner && codebook.isEmpty { throw SODAError("punctuation config lacks a codebook") }
    }

    private func isMark(_ t: ArraySlice<UInt8>) -> Bool { supportedMarks.contains { $0[...] == t } }
    private func isSentenceEnd(_ mark: [UInt8]) -> Bool { !mark.isEmpty && sentenceEndMarks.contains(mark) }

    private static func characterLength(_ c: UInt8) -> Int { c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4 }

    func punctuate(_ strings: inout [String], final: Bool, modelWords: [String]?) throws {
        var words = strings.map { Array($0.utf8) }
        defer { strings = words.map { String(decoding: $0, as: UTF8.self) } }
        if roadrunner {
            try punctuateRoadrunner(&words, final: final, modelWords: modelWords?.map { Array($0.utf8) })
            capitalize(&words)
            return
        }
        // Model tokens, and for each the (word, byte offset) it ends at: words (SIMPLE_WHITESPACE, de-DE) or
        // characters (UNICODE_CHARACTER, ja-JP).
        var tokens: [[UInt8]] = [], ends: [(word: Int, at: Int)] = []
        for (w, word) in words.enumerated() {
            if segmentBy == Self.simpleWhitespace {
                // The model sees each part of the word between spaces without the marks it already carries, and a
                // part of marks only not at all.
                var i = 0
                while i < word.count {
                    let j = word[i...].firstIndex(of: 32) ?? word.count
                    var b = i, e = j
                    var more = true
                    while more {
                        more = false
                        for m in supportedMarks {
                            if e - b >= m.count && word[b..<b + m.count].elementsEqual(m) { b += m.count; more = true }
                            if e - b >= m.count && word[e - m.count..<e].elementsEqual(m) { e -= m.count; more = true }
                        }
                    }
                    if b != e {
                        tokens.append(Array(word[b..<e]))
                        ends.append((w, j))
                    }
                    i = j + 1
                }
                continue
            }
            var i = 0
            while i < word.count {
                let n = min(word.count - i, Self.characterLength(word[i]))
                let ch = word[i..<i + n]
                i += n
                // Existing punctuation is not a model token.
                if isMark(ch) { continue }
                tokens.append(Array(ch))
                ends.append((w, i))
            }
        }
        var marks = try predict(tokens)
        if !final && !marks.isEmpty { marks[marks.count - 1] = [] }
        // Insert from the back so earlier offsets stay valid.
        for k in marks.indices.reversed() where !marks[k].isEmpty {
            let (w, end) = ends[k]
            let word = words[w]
            // Already followed by a mark (de-DE: spoken; fr-FR: after a space)?
            let following: Int = word[end...].firstIndex(where: { $0 != 32 }) ?? word.count
            func has(_ m: [UInt8], at i: Int) -> Bool {
                i >= 0 && i + m.count <= word.count && word[i..<i + m.count].elementsEqual(m)
            }
            let spaced = segmentBy == Self.simpleWhitespace
            let marked = supportedMarks.contains { m in has(m, at: following) || (spaced && has(m, at: end - m.count)) }
            if !marked { words[w].insert(contentsOf: marks[k], at: end) }
        }
        capitalize(&words)
    }

    /// For each model token, the mark to append (empty for none).
    private func predict(_ tokens: [[UInt8]]) throws -> [[UInt8]] {
        var marks = [[UInt8]](repeating: [], count: tokens.count)
        guard !tokens.isEmpty else { return marks }
        let text = Array(tokens.joined(separator: [32]))
        let values = try interpreter.runAll([Tensor(shape: [1], data: .string([text]))])
        if labels.isEmpty && labelsOutput >= 0, let t = values[labelsOutput] {
            // Labels are "KEEP" (no mark) or "KEEP|<mark>".
            labels = t.strings.map { label in label.firstIndex(of: UInt8(ascii: "|")).map { Array(label[($0 + 1)...]) } ?? [] }
        }
        guard let scores = values[scoresOutput] else { throw SODAError("punctuation model gave no scores") }
        let classes = scores.shape.last ?? 1
        let rows = scores.count / classes
        let score: (Int) -> Float
        switch scores.data {
        case .uint8(let v):
            let q = scores.quantization
            score = { Float(Int32(v[$0]) - q.zeroPoint) * q.scale }
        default:
            let v = scores.floats
            score = { v[$0] }
        }
        for r in 0..<min(rows, tokens.count) {
            var best = 0
            for c in 1..<classes where score(r * classes + c) > score(r * classes + best) { best = c }
            if best < labels.count { marks[r] = labels[best] }
        }
        return marks
    }

    // MARK: Roadrunner

    /// libsoda tags words in windows of windowSize words that overlap by the left and right buffers, keeping each
    /// window's labels between its buffers; a last window shorter than windowMinRemainder is merged into the one before.
    private func roadrunnerLabels(_ tokens: [[UInt8]]) throws -> [Int] {
        let n = tokens.count
        let size = max(1, windowSize)
        let left = min(windowLeft, size - 1)
        let right = min(windowRight, size - 1 - left)
        let stride = size - left - right
        var windows: [(start: Int, end: Int, keepStart: Int, keepEnd: Int)] = []
        var s = 0
        while s < n {
            let end = min(n, s + size)
            windows.append((s, end, s > 0 ? left : 0, end - s - (n > s + size ? right : 0)))
            if n <= s + size { break }
            s += stride
        }
        if windows.count >= 2 && windows[windows.count - 1].end - windows[windows.count - 1].start < windowMinRemainder {
            windows.removeLast()
            windows[windows.count - 1].end = n
            windows[windows.count - 1].keepEnd = n - windows[windows.count - 1].start
        }
        var labels = [Int](repeating: 0, count: n)
        for w in windows {
            let input = Tensor(shape: [1, w.end - w.start], data: .string(Array(tokens[w.start..<w.end])))
            let out = try interpreter.run([input])[0].ints
            for i in w.keepStart..<min(w.keepEnd, out.count) { labels[w.start + i] = out[i] }
        }
        return labels
    }

    private func punctuateRoadrunner(_ words: inout [[UInt8]], final: Bool, modelWords: [[UInt8]]?) throws {
        var tokens = (modelWords ?? words).map(SequenceProjection.lowercased)
        if appendDummyToken { tokens.append([]) }
        let labels = try roadrunnerLabels(tokens)
        // A label is the mark before its word: (label - 1) / 2 indexes the codebook, whose entries ("|.", "|,", ...)
        // are the mark after a "|".
        func mark(_ entry: [UInt8]) -> [UInt8] {
            entry.lastIndex(of: UInt8(ascii: "|")).map { Array(entry[($0 + 1)...]) } ?? entry
        }
        var i = 0
        while i + 1 < labels.count && i < words.count {
            defer { i += 1 }
            // Partials end unmarked.
            if !final && i + 1 == words.count { break }
            let k = (labels[i + 1] - 1) >> 1
            guard k >= 0 && k < codebook.count else { continue }
            let m = mark(codebook[k])
            // libsoda leaves a word that already ends with a mark of the codebook (checked in codebook order, up to
            // its first empty entry) as it is.
            var marked = false
            for e in codebook {
                let em = mark(e)
                if em.isEmpty { break }
                if words[i].count >= em.count && words[i][(words[i].count - em.count)...].elementsEqual(em) {
                    marked = true
                    break
                }
            }
            if !marked { words[i] += m }
        }
    }

    // MARK: Capitalization

    /// Upper-cases a word's first letter: ASCII, Latin-1, Latin Extended-A and Cyrillic, enough for the packs' languages.
    private static func upcaseFirst(_ w: inout [UInt8]) {
        guard let c0 = w.first else { return }
        if c0 >= 97 && c0 <= 122 {
            w[0] = c0 - 32
            return
        }
        guard c0 >= 0xC0 && c0 < 0xE0 && w.count >= 2 else { return }
        var c = (UInt32(c0 & 0x1F) << 6) | UInt32(w[1] & 0x3F)
        if (c >= 0xE0 && c <= 0xFE && c != 0xF7) || (c >= 0x430 && c <= 0x44F) {
            c -= 0x20
        } else if c >= 0x450 && c <= 0x45F {
            c -= 0x50
        } else if c >= 0x100 && c <= 0x17F && c != 0x131 && c != 0x138 && c != 0x149 && c != 0x17F
                    && ((c < 0x139 || c > 0x148) && c < 0x179 ? c % 2 == 1 : c % 2 == 0) {
            c -= 1
        } else {
            return
        }
        w[0] = UInt8(0xC0 | (c >> 6))
        w[1] = UInt8(0x80 | (c & 0x3F))
    }

    /// libsoda's alphanumeric test for where capitalization applies: digits, ASCII letters and the letter blocks of 2-
    /// and 3-byte UTF-8 (4-byte characters never match).
    private static func isAlphanumeric(_ w: [UInt8], _ i: Int) -> Bool {
        let c0 = w[i]
        var c = UInt32(c0)
        if c0 >= 0x80 {
            if c0 & 0xE0 == 0xC0 && i + 1 < w.count {
                c = (UInt32(c0 & 0x1F) << 6) | UInt32(w[i + 1] & 0x3F)
            } else if c0 & 0xF0 == 0xE0 && i + 2 < w.count {
                c = (UInt32(c0 & 0x0F) << 12) | (UInt32(w[i + 1] & 0x3F) << 6) | UInt32(w[i + 2] & 0x3F)
            } else {
                return false
            }
        }
        let ranges: [(UInt32, UInt32)] = [
            (48, 10), (65, 26), (97, 26), (0xC0, 23), (0xD8, 31), (0xF8, 449), (0x389, 249), (0x48A, 255), (0x5C8, 39),
            (0x620, 43), (0x66E, 104), (0x710, 32), (0x74B, 212), (0x1CFB, 182), (0x1DFB, 246), (0xFB00, 7), (0x370, 4),
            (0xB5, 1), (0x376, 1)]
        return ranges.contains { c &- $0.0 < $0.1 }
    }

    /// libsoda sets every pack's PositionalCapitalizationBehavior to CAPITALIZE_ALL: the first model token is
    /// capitalized, and each one after a token that ends a sentence.
    private func capitalize(_ words: inout [[UInt8]]) {
        var next = true
        if segmentBy != Self.simpleWhitespace {
            // A token is a character, with the marks that follow it, so a mark inside a word capitalizes the next
            // character (ja-JP: `シャンT。Faceb` from `シャンTfaceb`).
            for w in words.indices {
                var i = 0
                while i < words[w].count {
                    let n = min(Self.characterLength(words[w][i]), words[w].count - i)
                    let ch = Array(words[w][i..<i + n])
                    if ch == [32] {
                    } else if supportedMarks.contains(ch) {
                        next = sentenceEndMarks.contains(ch)
                    } else {
                        if next {
                            var upper = ch
                            Self.upcaseFirst(&upper)
                            words[w].replaceSubrange(i..<i + n, with: upper)
                        }
                        next = false
                    }
                    i += n
                }
            }
            return
        }
        for w in words.indices {
            if next {
                // At the first letter or digit ("#urlaub" → "#Urlaub", "(1)" unchanged).
                var b = 0
                while b < words[w].count && !Self.isAlphanumeric(words[w], b) {
                    b += min(Self.characterLength(words[w][b]), words[w].count - b)
                }
                var rest = Array(words[w][b...])
                Self.upcaseFirst(&rest)
                words[w] = Array(words[w][..<b]) + rest
            }
            next = sentenceEndMarks.contains { m in words[w].count >= m.count && words[w].suffix(m.count).elementsEqual(m) }
        }
    }
}
