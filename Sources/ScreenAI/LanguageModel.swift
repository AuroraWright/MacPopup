import Foundation

// The recognizers' character n-gram language models (<script>_lm.fst + <script>_lm.syms): OpenFst files of type
// "compact_lm" (speech::CompactLmFst), an fst::NGramFst (LOUDS-encoded backoff n-gram model) over 16-bit labels
// with 8-bit quantized weights, a label bitmap and a quantized unigram table. See lm_compact_fst.h of the C++ port
// for the layout.

/// fst::BitmapIndex: rank and select over a bit array.
private struct BitmapIndex {
    var bits: [UInt64] = []
    var numBits = 0
    /// Ones before each 64-bit word, plus the total.
    private var rank: [Int] = [0]

    init() {}

    init(_ bits: [UInt64], _ numBits: Int) {
        self.bits = bits
        self.numBits = numBits
        let n = (numBits + 63) >> 6
        rank = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            var w = bits[i]
            if i + 1 == n && numBits & 63 != 0 { w &= (UInt64(1) << UInt64(numBits & 63)) - 1 }
            rank[i + 1] = rank[i] + w.nonzeroBitCount
        }
    }

    func get(_ i: Int) -> Bool { (bits[i >> 6] >> UInt64(i & 63)) & 1 != 0 }

    /// Ones in [0, end).
    func rank1(_ end: Int) -> Int {
        let w = end >> 6, b = end & 63
        var r = rank[w]
        if b != 0 { r += (bits[w] & ((UInt64(1) << UInt64(b)) - 1)).nonzeroBitCount }
        return r
    }

    func rank0(_ end: Int) -> Int { end - rank1(end) }

    private static func selectInWord(_ w0: UInt64, _ r0: Int) -> Int {
        var w = w0
        for _ in 0..<r0 { w &= w - 1 }
        return w.trailingZeroBitCount
    }

    /// Position of the r-th one (0-based), numBits if none.
    func select1(_ r: Int) -> Int {
        if r >= rank.last! { return numBits }
        // the last word w with rank[w] <= r
        var lo = 0, hi = rank.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rank[mid] <= r { lo = mid + 1 } else { hi = mid }
        }
        let w = lo - 1
        return (w << 6) + Self.selectInWord(bits[w], r - rank[w])
    }

    /// Position of the r-th zero (0-based), numBits if none.
    func select0(_ r: Int) -> Int {
        if r >= numBits - rank.last! { return numBits }
        var lo = 0, hi = rank.count - 1  // the last w with (zeros before w) <= r
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if (mid << 6) - rank[mid] <= r { lo = mid } else { hi = mid }
        }
        let w = lo
        return (w << 6) + Self.selectInWord(~bits[w], r - ((w << 6) - rank[w]))
    }

    func select0s(_ r: Int) -> (Int, Int) { (select0(r), select0(r + 1)) }
}

private final class CompactLmFst {
    struct Arc {
        var weight: Float = 0
        var nextstate = -1
    }

    private(set) var start = 0
    private var numLabels = 0
    private var scale: Float = 0
    private var contextWords: [UInt16] = [], futureWords: [UInt16] = []
    private var backoff: [UInt8] = [], futureProbs: [UInt8] = [], unigramWeights: [UInt8] = []
    private var contextIndex = BitmapIndex(), futureIndex = BitmapIndex(), labelIndex = BitmapIndex()
    private var selectRoot = (0, 0)
    private var rootChildren = 0  // offset into contextWords
    private var rootOffset = 0

    init(_ file: [UInt8]) throws {
        var pos = 0
        func get<T: FixedWidthInteger>(_: T.Type) throws -> T {
            guard file.count - pos >= MemoryLayout<T>.size else { throw ScreenAIError("Truncated language model") }
            let v = file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: T.self) }
            pos += MemoryLayout<T>.size
            return T(littleEndian: v)
        }
        func string() throws -> String {
            let n = Int(try get(Int32.self))
            guard n >= 0, file.count - pos >= n else { throw ScreenAIError("Truncated language model") }
            defer { pos += n }
            return String(decoding: file[pos..<pos + n], as: UTF8.self)
        }
        guard try get(Int32.self) == 0x7EB2_FDD6 else { throw ScreenAIError("Not an OpenFst file") }
        guard try string() == "compact_lm" else { throw ScreenAIError("The language model isn't compact_lm") }
        _ = try string()
        _ = try get(Int32.self)  // version
        let flags = try get(Int32.self)
        _ = try get(UInt64.self)  // properties
        start = Int(try get(Int64.self))
        _ = try get(Int64.self)  // states
        _ = try get(Int64.self)  // arcs
        // Embedded symbol tables (flags 1, 2) aren't used by the shipped models; 4: data aligned to 16 bytes.
        guard flags & ~4 == 0 else { throw ScreenAIError("Unsupported OpenFst header flags") }
        numLabels = Int(try get(Int32.self))
        let numUnigrams = Int(try get(Int32.self))
        _ = try get(UInt8.self)
        scale = Float(bitPattern: try get(UInt32.self))
        let ngramSize = Int(try get(UInt64.self))
        if flags & 4 != 0 { pos = (pos + 15) & ~15 }
        let labelWords = (numLabels + 63) >> 6
        let lw = (ngramSize + 7) & ~7
        guard pos <= file.count, file.count - pos >= lw + 8 * labelWords + numUnigrams
        else { throw ScreenAIError("Truncated language model data") }
        let base = pos
        func u64s(_ off: Int, _ n: Int) -> [UInt64] {
            file.withUnsafeBytes { raw in
                (0..<n).map { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base + off + 8 * $0, as: UInt64.self)) }
            }
        }
        func u16s(_ off: Int, _ n: Int) -> [UInt16] {
            file.withUnsafeBytes { raw in
                (0..<n).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: base + off + 2 * $0, as: UInt16.self)) }
            }
        }
        func u8s(_ off: Int, _ n: Int) -> [UInt8] { Array(file[base + off..<base + off + n]) }
        let head = u64s(0, 3)
        let ns = Int(head[0]), nf = Int(head[1]), nfinal = Int(head[2])
        func words(_ bits: Int) -> Int { (bits + 63) >> 6 }
        var off = 24
        let context = u64s(off, words(2 * ns + 1))
        off += 8 * words(2 * ns + 1)
        let future = u64s(off, words(ns + nf + 1))
        off += 8 * words(ns + nf + 1)
        off += 8 * words(ns)  // final states
        contextWords = u16s(off, ns + 1)
        off += 2 * (ns + 1)
        futureWords = u16s(off, nf)
        off += 2 * nf
        backoff = u8s(off, ns + 1)
        off += ns + 1
        off += nfinal  // final probabilities (unused: the end of the text is scored as a label)
        futureProbs = u8s(off, nf + 1)
        off += nf + 1
        guard off <= ngramSize else { throw ScreenAIError("Inconsistent language model") }
        contextIndex = BitmapIndex(context, 2 * ns + 1)
        futureIndex = BitmapIndex(future, ns + nf + 1)
        selectRoot = contextIndex.select0s(0)
        guard contextIndex.rank1(0) == 0, selectRoot.0 == 1, contextIndex.get(2)
        else { throw ScreenAIError("Malformed language model") }
        rootChildren = contextIndex.rank1(2)
        labelIndex = BitmapIndex(u64s(lw, labelWords), numLabels)
        unigramWeights = u8s(lw + 8 * labelWords, numUnigrams)
        rootOffset = instFuture(0).offset
    }

    private func weight(_ q: UInt8) -> Float { q == 254 ? .infinity : scale * Float(q) }

    private func instFuture(_ state: Int) -> (offset: Int, count: Int) {
        let zeros = futureIndex.select0s(state)
        return (futureIndex.rank1(zeros.0 + 1), zeros.1 - zeros.0 - 1)
    }

    private func node(_ state: Int) -> Int { contextIndex.select1(state) }

    private func context(_ node0: Int) -> [UInt16] {
        var out: [UInt16] = []
        var node = node0
        while node != 0 {
            out.append(contextWords[contextIndex.rank1(node)])
            node = contextIndex.select1(contextIndex.rank0(node) - 1)
        }
        return out
    }

    private static func lowerBound(_ a: [UInt16], _ start: Int, _ n: Int, _ v: UInt16) -> Int {
        var lo = start, hi = start + n
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func transition(_ context: [UInt16], _ future: UInt16) -> Int {
        var children = rootChildren
        let numChildren = selectRoot.1 - 2
        var loc = Self.lowerBound(contextWords, children, numChildren, future)
        if loc == children + numChildren || contextWords[loc] != future { return contextIndex.rank1(0) }
        var node = 2 + (loc - children)
        var nodeRank = contextIndex.rank1(node)
        var zeros = nodeRank == 0 ? selectRoot : contextIndex.select0s(nodeRank)
        var firstChild = zeros.0 + 1
        if !contextIndex.get(firstChild) { return contextIndex.rank1(node) }
        var lastChild = zeros.1 - 1
        for word in stride(from: context.count - 1, through: 0, by: -1) {
            children = contextIndex.rank1(firstChild)
            let n = lastChild - firstChild + 1
            loc = Self.lowerBound(contextWords, children, n, context[word])
            if loc == children + n || contextWords[loc] != context[word] { break }
            node = firstChild + (loc - children)
            nodeRank = contextIndex.rank1(node)
            zeros = nodeRank == 0 ? selectRoot : contextIndex.select0s(nodeRank)
            firstChild = zeros.0 + 1
            if !contextIndex.get(firstChild) { break }
            lastChild = zeros.1 - 1
        }
        return contextIndex.rank1(node)
    }

    /// The arc with full label `label` leaving `state` (CompactLmFstMatcher::Find). At the unigram state an arc of
    /// infinite weight counts as missing.
    func findLabel(_ state: Int, _ label: Int) -> Arc? {
        if label <= 0 || label >= numLabels { return nil }
        if state == 0 {
            // The unigram state: dense arcs.
            var arc = Arc()
            if !labelIndex.get(label) {
                arc.weight = weight(unigramWeights[label - labelIndex.rank1(label)])
                arc.nextstate = 0
            } else {
                let pos = Int(UInt16(truncatingIfNeeded: labelIndex.rank1(label))) - 1
                let shortLabel = futureWords[rootOffset + pos]
                arc.weight = weight(futureProbs[rootOffset + pos])
                arc.nextstate = transition([], shortLabel)
            }
            return arc.weight != .infinity ? arc : nil
        }
        if !labelIndex.get(label) { return nil }
        let shortLabel = UInt16(truncatingIfNeeded: labelIndex.rank1(label))
        let (offset, count) = instFuture(state)
        let it = Self.lowerBound(futureWords, offset, count, shortLabel)
        if it == offset + count || futureWords[it] != shortLabel { return nil }
        return Arc(weight: weight(futureProbs[it]), nextstate: transition(context(node(state)), shortLabel))
    }

    /// The backoff (epsilon) arc of `state`; none for the unigram state.
    func findBackoff(_ state: Int) -> Arc? {
        if state == 0 { return nil }
        let n = node(state)
        return Arc(weight: weight(backoff[state]),
                   nextstate: contextIndex.rank1(contextIndex.select1(contextIndex.rank0(n) - 1)))
    }
}

/// google_ocr::FstCharLanguageModel<speech::CompactLmFst>. Each recognizer class maps to a sequence of LM symbols:
/// " " to "<space>"; other labels are normalized (NormalizeOcrSymbol) and split into code points, each looked up in
/// the symbol table ("<unk>" when missing). NormalizeOcrSymbol tests `name[0] <= 31` on a signed char, so a label
/// that is a single non-ASCII code point gets no symbols: such classes cost nothing and keep the state. The
/// end-of-sentence class maps to "</S>" (or "<eos>").
final class CharLanguageModel {
    private let fst: CompactLmFst
    /// By bytes: Swift strings compare canonically equivalent ones as equal (e.g. CJK compatibility ideographs).
    private var symbols: [[UInt8]: Int] = [:]
    private var classSymbols: [[Int]] = []
    private var unk = -1
    let eosClass: Int
    let maxCost = -log(1e-6)

    var bosState: Int { fst.start }

    /// labels: class id -> label (the recognizer's label map, without the CTC blank).
    init(fst file: [UInt8], symbols symsFile: [UInt8], labels: [(Int, [UInt8])]) throws {
        fst = try CompactLmFst(file)
        for line0 in symsFile.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = line0
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty, let tab = line.lastIndex(where: { $0 == 0x09 || $0 == 0x20 }) else { continue }
            let key = Array(line[..<tab])
            if symbols[key] == nil { symbols[key] = Int(atoi(String(decoding: line[(tab + 1)...], as: UTF8.self))) }
        }
        var maxId = 0
        var eos: Int?
        for (id, name) in labels {
            if name.starts(with: Array("eos".utf8)) { eos = id }
            maxId = max(maxId, id)
        }
        if eos == nil {
            maxId += 1
            eos = maxId
        }
        eosClass = eos!
        unk = lmId("<unk>")
        classSymbols = [[Int]](repeating: [], count: maxId + 1)
        for (id, name) in labels where id != eosClass {
            if name == [0x20] {
                classSymbols[id].append(lmId("<space>"))
                continue
            }
            for piece in Self.preparePoints(name) { classSymbols[id].append(lmId(piece)) }
        }
        var eosSymbol = lmId("</S>")
        if eosSymbol == unk { eosSymbol = lmId("<eos>") }
        classSymbols[eosClass].append(eosSymbol)
    }

    private func lmId(_ token: String) -> Int { lmId(Array(token.utf8)) }

    private func lmId(_ token: [UInt8]) -> Int {
        if token == [0x20] { return lmId("<space>") }
        return symbols[token] ?? unk
    }

    /// One symbol from `state`: its cost; updates the state.
    private func lookup(_ state: inout Int, _ symbol: Int) -> Double {
        if symbol == unk {
            state = fst.start
            return maxCost
        }
        var cost: Float = 0
        var s = state
        var arc = fst.findLabel(s, symbol)
        while arc == nil {
            guard let b = fst.findBackoff(s) else {
                state = fst.start
                return maxCost
            }
            s = b.nextstate
            cost += b.weight
            arc = fst.findLabel(s, symbol)
        }
        var c = Double(cost + arc!.weight)
        if maxCost < c { c = maxCost }
        state = arc!.nextstate
        return c
    }

    /// GetNLogProbabilities: per class, -log p summed over its symbols, and the resulting state.
    func costs(_ classes: [Int], _ state: Int) -> [(cost: Double, state: Int)] {
        classes.map { c in
            var cost = 0.0
            var s = state
            let syms = c >= 0 && c < classSymbols.count ? classSymbols[c] : [unk]
            for symbol in syms { cost += lookup(&s, symbol) }
            return (cost, s)
        }
    }

    // MARK: - Label normalization

    /// Code points of UTF-8 bytes (leniently: an invalid byte is a point of its own).
    private static func codePoints(_ s: [UInt8]) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            var n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
            if c >= 0x80 && c < 0xC0 { n = 1 }
            n = min(n, s.count - i)
            out.append(s[i..<i + n])
            i += n
        }
        return out
    }

    private static func decode(_ cp: ArraySlice<UInt8>) -> UInt32 {
        let c = cp[cp.startIndex]
        if cp.count == 1 { return UInt32(c) }
        var v = UInt32(c) & (0x7F >> UInt32(cp.count))
        for b in cp.dropFirst() { v = (v << 6) | (UInt32(b) & 0x3F) }
        return v
    }

    /// UnicodeProps::IsFirstCharHorizWhitespace (tab + Unicode Zs).
    private static func isHorizWhitespace(_ c: UInt32) -> Bool {
        c == 0x09 || c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x205F
            || c == 0x3000
    }

    private static func isWhitespace(_ c: UInt32) -> Bool {
        (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0x85 || isHorizWhitespace(c) || c == 0x2028 || c == 0x2029
    }

    private static func replaceAll(_ s: [UInt8], _ from: [UInt8], _ to: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < s.count {
            if i + from.count <= s.count && Array(s[i..<i + from.count]) == from {
                out += to
                i += from.count
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    /// google_ocr::NormalizeOcrSymbol(s, use_space_token: true).
    private static func normalize(_ s: [UInt8]) -> [UInt8] {
        var p = s
        for from: [UInt8] in [[0xE2, 0x80, 0x8E], [0xE2, 0x80, 0x8D], [0xE2, 0x80, 0x8C], [0xE2, 0x80, 0xA9]] {
            p = replaceAll(p, from, [0x20])
        }
        if !s.isEmpty {
            let cps = codePoints(s)
            if cps.count == 1 {
                if isHorizWhitespace(decode(cps[0])) { return Array("<space>".utf8) }
                // The original compares a signed char: every non-ASCII single code point counts as a control char.
                if Int8(bitPattern: s[0]) <= 31 { return [] }
            }
        }
        return replaceAll(p, [0x20], [])
    }

    /// google_ocr::PreparePoints(s, normalize_points: false).
    private static func preparePoints(_ s: [UInt8]) -> [[UInt8]] {
        let cps = codePoints(normalize(s))
        var out: [[UInt8]] = []
        var i = 0
        if !cps.isEmpty && Array(cps[0]) == [0xC2, 0xA0] {
            out.append(Array("<space>".utf8))
            i = 1
        }
        while i < cps.count {
            defer { i += 1 }
            if isWhitespace(decode(cps[i])) { continue }
            out.append(Array(cps[i]) == [0x20] ? Array("<space>".utf8) : Array(cps[i]))
        }
        return out
    }
}
