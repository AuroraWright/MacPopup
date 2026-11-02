import Foundation

/// Line language identification: MobileLangID V2, the original's "pod" classifier (tflite_langid.tflite), computed
/// directly from its weights (exported to langid/ by scripts/convert-screenai.py):
///   NGramHash              lowercases, splits into "^", one token per code point (non-letters become " "), "$",
///                          and hashes every 1..4-gram with MurmurHash64(seed) % vocab + 1.
///   KmeansEmbeddingLookup  product-quantized embedding: per id, the codebook rows picked by a code table, averaged.
///   FULLY_CONNECTED        TFLite's hybrid kernel: the input quantized to int8 per call, int8 weights.
///   SOFTMAX                TFLite's optimized kernel (Eigen exp and sum).
final class LanguageIdentifier {
    private struct Embedding {
        var codes: [UInt8]  // [vocab][m]
        var codebook: [Float]  // [256][b]
        var m: Int, b: Int
    }

    private struct Dense {
        var weights: [Int8]  // [units][inputs]
        var rowSums: [Int32]
        var scale: Float
        var bias: [Float]
        var relu: Bool
        var units: Int, inputs: Int
    }

    private let seed: UInt64
    private let ngramLengths: [Int], vocabSizes: [Int]
    private let maxSplits: Int
    private let lowercase: Bool
    private let embeddings: [Embedding]
    private let layers: [Dense]
    let labels: [String]

    init(resources: Resources) throws {
        guard let manifestBytes = resources.read("langid/langid.json"), let blob = resources.read("langid/langid.bin"),
              let manifest = try? JSONSerialization.jsonObject(with: Data(manifestBytes)) as? [String: Any]
        else { throw ScreenAIError("The language identifier is missing") }
        func array(_ spec: Any?) throws -> (offset: Int, count: Int, shape: [Int]) {
            guard let d = spec as? [String: Any], let offset = d["offset"] as? Int, let shape = d["shape"] as? [Int]
            else { throw ScreenAIError("Bad language identifier manifest") }
            let count = shape.reduce(1, *)
            return (offset, count, shape)
        }
        func floats(_ spec: Any?) throws -> ([Float], [Int]) {
            let a = try array(spec)
            guard a.offset + 4 * a.count <= blob.count else { throw ScreenAIError("Bad language identifier weights") }
            let v = blob[a.offset..<a.offset + 4 * a.count].withUnsafeBytes { raw in
                (0..<a.count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self))) }
            }
            return (v, a.shape)
        }
        func bytes(_ spec: Any?) throws -> ([UInt8], [Int]) {
            let a = try array(spec)
            guard a.offset + a.count <= blob.count else { throw ScreenAIError("Bad language identifier weights") }
            return (Array(blob[a.offset..<a.offset + a.count]), a.shape)
        }
        guard let ngram = manifest["ngram"] as? [String: Any], let seed = ngram["seed"] as? NSNumber,
              let lengths = ngram["ngram_lengths"] as? [Int], let vocab = ngram["vocab_sizes"] as? [Int],
              let embeddingSpecs = manifest["embeddings"] as? [[String: Any]],
              let layerSpecs = manifest["layers"] as? [[String: Any]], let labels = manifest["labels"] as? [String]
        else { throw ScreenAIError("Bad language identifier manifest") }
        self.seed = seed.uint64Value
        ngramLengths = lengths
        vocabSizes = vocab
        maxSplits = ngram["max_splits"] as? Int ?? 128
        lowercase = ngram["lowercase"] as? Bool ?? true
        embeddings = try embeddingSpecs.map { spec in
            let (codes, cshape) = try bytes(spec["codes"])
            let (codebook, bshape) = try floats(spec["codebook"])
            return Embedding(codes: codes, codebook: codebook, m: cshape[1], b: bshape[1])
        }
        layers = try layerSpecs.map { spec in
            let (w, shape) = try bytes(spec["weights"])
            let (bias, _) = try floats(spec["bias"])
            guard let scale = spec["scale"] as? Double else { throw ScreenAIError("Bad language identifier manifest") }
            let weights = w.map { Int8(bitPattern: $0) }
            let units = shape[0], inputs = shape[1]
            let rowSums = (0..<units).map { r in (0..<inputs).reduce(Int32(0)) { $0 + Int32(weights[r * inputs + $1]) } }
            return Dense(weights: weights, rowSums: rowSums, scale: Float(scale), bias: bias,
                         relu: spec["relu"] as? Bool ?? false, units: units, inputs: inputs)
        }
        self.labels = labels
        guard embeddings.count == ngramLengths.count, ngramLengths.count == vocabSizes.count, maxSplits > 0
        else { throw ScreenAIError("Bad language identifier manifest") }
    }

    /// MobileLangIdV2::IdentifyLanguage: the best label ("unknown" becomes "und"), then SanitizeSaftLanguage ("und"
    /// below 0.2 confidence, under 5 characters or for "-Latn" labels; "ru-PETR1708" for pre-1918 Russian).
    func identify(_ text: String) -> String {
        let utf8 = Array(text.utf8)
        let scores = self.scores(utf8)
        var best = ""
        var confidence: Float = 0
        for (i, s) in scores.enumerated() where s > confidence {
            best = labels[i]
            confidence = s
        }
        if scores.isEmpty { return "und" }
        if best == "unknown" { best = "und" }
        return Self.sanitize(utf8, best, confidence)
    }

    /// Softmax over the labels.
    func scores(_ utf8: [UInt8]) -> [Float] {
        let (text, spans) = Self.tokenize(utf8, maxSplits: maxSplits, lowercase: lowercase)
        var features: [Float] = []
        for (k, emb) in embeddings.enumerated() {
            // NGramHash
            let n = ngramLengths[k]
            let vocab = UInt64(vocabSizes[k])
            var ids: [Int] = []
            for i in 0..<spans.count {
                var len = 0
                for j in i..<min(spans.count, i + n) { len += spans[j].length }
                let off = spans[i].offset
                len = min(len, text.count - off)
                ids.append(Int(Self.murmurHash64(text, off, len, seed) % vocab + 1))
            }
            // KmeansEmbeddingLookup
            var out = [Float](repeating: 0, count: emb.m * emb.b)
            var count = 0
            for id in ids {
                if id == 0 { break }
                for j in 0..<emb.m {
                    let row = Int(emb.codes[id * emb.m + j]) * emb.b
                    for e in 0..<emb.b { out[j * emb.b + e] += emb.codebook[row + e] }
                }
                count += 1
            }
            if count >= 2 {
                let denom = Float(count)
                for j in out.indices { out[j] /= denom }
            }
            features += out
        }
        for layer in layers { features = Self.hybridDense(features, layer) }
        return Self.softmax(features)
    }

    // MARK: - Layers

    /// TFLite's hybrid FULLY_CONNECTED (NEON kernels, asymmetric input quantization, batch 1).
    private static func hybridDense(_ input: [Float], _ l: Dense) -> [Float] {
        var out = l.bias
        let act: (Float) -> Float = l.relu ? { cmax(0, $0) } : { $0 }
        if input.allSatisfy({ $0 == 0 }) { return out.map(act) }
        // NeonAsymmetricQuantizeFloats
        var rmin: Float = 0, rmax: Float = 0
        for v in input {
            rmin = cmin(rmin, v)
            rmax = cmax(rmax, v)
        }
        var quantized = [Int32](repeating: 0, count: input.count)
        var scalingFactor: Float = 1
        var offset: Int32 = 0
        if rmin != rmax {
            let qmin = -128.0, qmax = 127.0
            let scale = Double(rmax - rmin) / (qmax - qmin)
            let fromMin = qmin - Double(rmin) / scale, fromMax = qmax - Double(rmax) / scale
            let errMin = abs(qmin) + abs(Double(rmin) / scale), errMax = abs(qmax) + abs(Double(rmax) / scale)
            let zp = errMin < errMax ? fromMin : fromMax
            offset = zp <= qmin ? -128 : zp >= qmax ? 127 : Int32(Int8(zp.rounded(.toNearestOrAwayFromZero)))
            scalingFactor = Float(scale)
            let inv = scalingFactor == 0 ? 0 : Float(1.0 / Double(scalingFactor))
            for (i, v) in input.enumerated() {
                let q = Int32((v * inv).rounded(.toNearestOrAwayFromZero)) + offset
                quantized[i] = min(127, max(-128, q))
            }
        }
        let factor = scalingFactor * l.scale
        for r in 0..<l.units {
            var dot: Int32 = 0
            let base = r * l.inputs
            for c in 0..<l.inputs { dot += Int32(l.weights[base + c]) * quantized[c] }
            dot -= l.rowSums[r] * offset
            out[r] = out[r] + Float(dot) * factor
        }
        return out.map(act)
    }

    /// TFLite's optimized float softmax (beta 1) over an aligned buffer.
    private static func softmax(_ logits: [Float]) -> [Float] {
        guard let mx = logits.max() else { return [] }
        var out = logits.map { $0 - mx }
        let vec = out.count / 4 * 4
        for i in 0..<vec { out[i] = eigenPexp(out[i]) }
        for i in vec..<out.count { out[i] = expf(out[i]) }
        let scale = 1 / eigenSum(out)
        return out.map { $0 * scale }
    }

    // MARK: - Text

    /// expander::predictondevice::Tokenize(text, max_splits, split_on_non_alpha: true): the token bytes and each
    /// token's (offset, length) in them. Empty on invalid UTF-8.
    static func tokenize(_ input: [UInt8], maxSplits: Int, lowercase: Bool) -> ([UInt8], [(offset: Int, length: Int)]) {
        let s = lowercase ? lowercaseUnicode(input) : input
        var text: [UInt8] = [UInt8(ascii: "^")]
        var spans: [(offset: Int, length: Int)] = [(0, 1)]
        var i = 0
        while i < s.count && spans.count + 1 < maxSplits {
            let (r, len) = charNToRune(s, i)
            if r == runeError { return ([], []) }
            if len == 0 { break }
            if isAlphaRune(r) {
                spans.append((text.count, len))
                text += s[i..<i + len]
            } else {
                spans.append((text.count, 1))
                text.append(UInt8(ascii: " "))
            }
            i += len
        }
        spans.append((text.count, 1))
        text.append(UInt8(ascii: "$"))
        return (text, spans)
    }

    /// expander::predictondevice::LowercaseUnicodeStr. (The original loops forever on a truncated trailing
    /// sequence; here it is copied as U+FFFD and decoding stops.)
    private static func lowercaseUnicode(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < s.count {
            var (r, len) = charNToRune(s, i)
            if isAlphaRune(r) { r = toLowerRune(r) }
            out += runeToChar(r)
            if len == 0 { break }
            i += len
        }
        return out
    }

    /// util_hash::MurmurHash64WithSeed (MurmurHash64A).
    static func murmurHash64(_ data: [UInt8], _ start: Int, _ len: Int, _ seed: UInt64) -> UInt64 {
        let m: UInt64 = 0xC6A4_A793_5BD1_E995
        var h = seed ^ (UInt64(len) &* m)
        let n8 = len & ~7
        var i = 0
        while i < n8 {
            var k: UInt64 = 0
            for b in 0..<8 { k |= UInt64(data[start + i + b]) << (8 * b) }
            k = k &* m
            k ^= k >> 47
            k = k &* m
            h ^= k
            h = h &* m
            i += 8
        }
        if len & 7 != 0 {
            var t: UInt64 = 0
            for b in stride(from: (len & 7) - 1, through: 0, by: -1) { t = (t << 8) | UInt64(data[start + n8 + b]) }
            h ^= t
            h = h &* m
        }
        h ^= h >> 47
        h = h &* m
        h ^= h >> 47
        return h
    }

    /// google_ocr::LangId::SanitizeSaftLanguage.
    private static func sanitize(_ text: [UInt8], _ lang: String, _ confidence: Float) -> String {
        let length = text.reduce(0) { $0 + (Int8(bitPattern: $1) >= -64 ? 1 : 0) }
        if confidence < 0.2 || length < 5 { return "und" }
        if lang.utf8.count >= 5 {
            if lang.hasSuffix("-Latn") { return "und" }
        } else if lang == "ru" {
            if Double(length) * 0.005 < Double(countObsoleteRussianChars(text)) { return "ru-PETR1708" }
        }
        return lang
    }

    /// aksara::util::CountObsoleteRussianChars: matches of [IiѢѣѲѳѴѵ] plus (non-overlapping) matches of \pL[ъЪ]\PL.
    private static func countObsoleteRussianChars(_ s: [UInt8]) -> Int {
        var runes: [Int32] = []
        var i = 0
        while i < s.count {
            let (r, len) = charNToRune(s, i)
            runes.append(r)
            i += len != 0 ? len : s.count
        }
        var count = 0
        for r in runes where [0x49, 0x69, 0x462, 0x463, 0x472, 0x473, 0x474, 0x475].contains(r) { count += 1 }
        var k = 0
        while k + 2 < runes.count {
            if isAlphaRune(runes[k]) && (runes[k + 1] == 0x44A || runes[k + 1] == 0x42A) && !isAlphaRune(runes[k + 2]) {
                count += 1
                k += 3
            } else {
                k += 1
            }
        }
        return count
    }
}

// MARK: - Plan 9 libutf, as linked into the original

private let runeError: Int32 = 0xFFFD
private let runeDelta: Int32 = 1_048_576  // the tables' deltas are biased by 2^20

/// charntorune: one rune from s[i...]; length 0 for a truncated sequence, runeError for malformed input.
private func charNToRune(_ s: [UInt8], _ i: Int) -> (Int32, Int) {
    let n = s.count - i
    if n < 1 { return (runeError, 0) }
    let c = UInt32(s[i])
    if c < 0x80 { return (Int32(c), 1) }
    if n == 1 { return (runeError, 0) }
    let c1 = UInt32(s[i + 1]) ^ 0x80
    if c1 > 0x3F { return (runeError, 1) }
    if c <= 0xDF {
        if c >= 0xC0 {
            let v = ((c & 0x1F) << 6) | c1
            if v >= 0x80 { return (Int32(v), 2) }
        }
        return (runeError, 1)
    }
    if n < 3 { return (runeError, 0) }
    let c2 = UInt32(s[i + 2]) ^ 0x80
    if c2 > 0x3F { return (runeError, 1) }
    if c <= 0xEF {
        let v = ((c & 0xF) << 12) | (c1 << 6)
        if v >= 0x800 { return (Int32(v | c2), 3) }
        return (runeError, 1)
    }
    if n == 3 { return (runeError, 0) }
    let c3 = UInt32(s[i + 3]) ^ 0x80
    if c3 > 0x3F || c > 0xF7 { return (runeError, 1) }
    let v = (((c & 7) << 12) | (c1 << 6) | c2) << 6
    if v &- 0x110000 < 0xFFF0_0000 { return (runeError, 1) }
    return (Int32(v | c3), 4)
}

private func runeToChar(_ r: Int32) -> [UInt8] {
    var c = UInt32(bitPattern: r)
    if c <= 0x7F { return [UInt8(c)] }
    if c <= 0x7FF { return [UInt8(0xC0 | (c >> 6)), UInt8(0x80 | (c & 0x3F))] }
    if c > 0x10FFFF { c = UInt32(runeError) }
    if c <= 0xFFFF { return [UInt8(0xE0 | (c >> 12)), UInt8(0x80 | ((c >> 6) & 0x3F)), UInt8(0x80 | (c & 0x3F))] }
    return [UInt8(0xF0 | (c >> 18)), UInt8(0x80 | ((c >> 12) & 0x3F)), UInt8(0x80 | ((c >> 6) & 0x3F)),
            UInt8(0x80 | (c & 0x3F))]
}

/// rbsearch: index of the last entry (`stride` ints each) whose first value is <= c, or nil.
private func rbSearch(_ c: Int32, _ t: [Int32], _ stride: Int) -> Int? {
    var base = 0
    var n = t.count / stride
    while n > 1 {
        let m = n >> 1
        if c >= t[base + m * stride] {
            base += m * stride
            n -= m
        } else {
            n = m
        }
    }
    return n != 0 && c >= t[base] ? base : nil
}

private func isAlphaRune(_ c: Int32) -> Bool {
    if let p = rbSearch(c, kIsalphar, 2), c >= kIsalphar[p] && c <= kIsalphar[p + 1] { return true }
    if let p = rbSearch(c, kIsalphas, 1), c == kIsalphas[p] { return true }
    return false
}

private func toLowerRune(_ c: Int32) -> Int32 {
    if let p = rbSearch(c, kTolowerr, 3), c >= kTolowerr[p] && c <= kTolowerr[p + 1] {
        return c + kTolowerr[p + 2] - runeDelta
    }
    if let p = rbSearch(c, kTolowerp, 3), c >= kTolowerp[p] && c <= kTolowerp[p + 1] && (c - kTolowerp[p]) & 1 == 0 {
        return c + kTolowerp[p + 2] - runeDelta
    }
    if let p = rbSearch(c, kTolowers, 2), c == kTolowers[p] { return c + kTolowers[p + 1] - runeDelta }
    return c
}
