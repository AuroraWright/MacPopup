import Foundation

/// Case mapping for the scripts of the packs' languages (ASCII, Latin-1, Latin Extended-A, Greek, Cyrillic), over
/// UTF-8 text.
enum UnicodeCase {
    /// The byte length of the UTF-8 character at `i`.
    static func characterLength(_ s: [UInt8], _ i: Int) -> Int {
        let c = s[i]
        return min(c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4, s.count - i)
    }

    private static func decode(_ s: [UInt8], _ i: Int, _ n: Int) -> UInt32 {
        if n == 1 { return UInt32(s[i]) }
        var cp = UInt32(s[i]) & (0x7F >> UInt32(n))
        for k in 1..<n { cp = (cp << 6) | UInt32(s[i + k] & 0x3F) }
        return cp
    }

    private static func encode(_ cp: UInt32, _ out: inout [UInt8]) {
        if cp < 0x80 {
            out.append(UInt8(cp))
        } else if cp < 0x800 {
            out += [UInt8(0xC0 | (cp >> 6)), UInt8(0x80 | (cp & 0x3F))]
        } else if cp < 0x10000 {
            out += [UInt8(0xE0 | (cp >> 12)), UInt8(0x80 | ((cp >> 6) & 0x3F)), UInt8(0x80 | (cp & 0x3F))]
        } else {
            out += [UInt8(0xF0 | (cp >> 18)), UInt8(0x80 | ((cp >> 12) & 0x3F)), UInt8(0x80 | ((cp >> 6) & 0x3F)),
                    UInt8(0x80 | (cp & 0x3F))]
        }
    }

    private static func caseMap(_ c: UInt32, upper: Bool) -> UInt32 {
        func pair(_ u: UInt32, _ l: UInt32) -> UInt32 { upper ? (c == l ? u : c) : (c == u ? l : c) }
        if c < 0x80 {
            if upper && c >= 97 && c <= 122 { return c - 32 }
            if !upper && c >= 65 && c <= 90 { return c + 32 }
            return c
        }
        if (c >= 0xC0 && c <= 0xDE && c != 0xD7) || (c >= 0xE0 && c <= 0xFE && c != 0xF7) {
            return c >= 0xE0 ? pair(c - 0x20, c) : pair(c, c + 0x20)
        }
        if c == 0xFF || c == 0x178 { return pair(0x178, 0xFF) }
        if c >= 0x100 && c <= 0x17E && c != 0x130 && c != 0x131 && c != 0x138 && c != 0x149 {
            // Upper case is even, except in 139–148 and 179–17E, where it is odd.
            let oddUpper = (c >= 0x139 && c <= 0x148) || c >= 0x179
            let isUpper = (c % 2 == 1) == oddUpper
            return isUpper ? pair(c, c + 1) : pair(c - 1, c)
        }
        if (c >= 0x391 && c <= 0x3A9 && c != 0x3A2) || (c >= 0x3B1 && c <= 0x3C9 && c != 0x3C2) {
            return c >= 0x3B1 ? pair(c - 0x20, c) : pair(c, c + 0x20)
        }
        if c >= 0x410 && c <= 0x44F { return c >= 0x430 ? pair(c - 0x20, c) : pair(c, c + 0x20) }
        if c >= 0x400 && c <= 0x45F { return c >= 0x450 ? pair(c - 0x50, c) : pair(c, c + 0x50) }
        return c
    }

    static func lower(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            let n = characterLength(s, i)
            encode(caseMap(decode(s, i, n), upper: false), &out)
            i += n
        }
        return out
    }

    /// The first character upper case, the rest lower case.
    static func capitalize(_ s: [UInt8]) -> [UInt8] {
        guard !s.isEmpty else { return s }
        let n = characterLength(s, 0)
        var out: [UInt8] = []
        encode(caseMap(decode(s, 0, n), upper: true), &out)
        return out + lower(Array(s[n...]))
    }
}

/// Restores letter case with a pack's capitalization normalizer (greco's GeneralCapitalizationNormalizer), as libsoda
/// does before formatting: denorm/transducer.pruned.fst lists each word's case variants ("sns" → "SNS" or "sns") and
/// denorm/lm.pruned.sorted.fst, an OpenGrm n-gram model, picks the likeliest sequence. Both are OpenFst VectorFsts.
final class Truecaser: WordStage {
    private struct Arc {
        var input: Int32
        var output: Int32
        var weight: Float
        var next: Int32
    }

    private struct Fst {
        var start = -1
        var final: [Float] = []
        /// Per state, its first arc; states + 1 entries.
        var first: [Int] = []
        var arcs: [Arc] = []
        /// The input symbol table, by label.
        var symbols: [[UInt8]] = []
    }

    /// Cost charged for a word the language model cannot score at all.
    private static let unscoredCost: Float = 20
    /// Marks spoken punctuation attaches to words.
    private static let attachedMarks: [[UInt8]] = [
        ".", ",", "!", "?", ":", ";", "(", ")", "[", "]", "{", "}", "\"", "'", "#", "@", "&", "*", "/", "\\", "_", "^",
        "|", "~", "-", "\u{2013}", "\u{2026}", "\u{201E}", "\u{201C}", "\u{201D}", "\u{201A}", "\u{2018}", "\u{2019}",
        "\u{AB}", "\u{BB}", "\u{BF}", "\u{A1}"].map { Array($0.utf8) }

    /// The language model, without its symbols (in lmIDs).
    private let lm: Fst
    private let lmIDs: ByteStringIndex
    /// Words with a case variant other than themselves: (LM label, text) each.
    private var variants: [[UInt8]: [(label: Int, text: [UInt8])]] = [:]
    /// The transducer's symbols: its words in lower case and their variants.
    private let known: ByteStringIndex
    private var unknown = -1
    /// </S>, when the transducer writes it to end a sentence.
    private var endOfSentence = -1

    init(transducer: URL, lm lmURL: URL) throws {
        let transducer = try Self.loadFst(transducer)
        var lm = try Self.loadFst(lmURL)
        lmIDs = ByteStringIndex(lm.symbols)
        lm.symbols = []
        self.lm = lm
        known = ByteStringIndex(transducer.symbols)
        unknown = lmIDs[Array("<UNK>".utf8)] ?? -1
        // The language model's arcs must be sorted by label for step's search.
        for s in 0..<(lm.first.count - 1) {
            let arcs = lm.arcs[lm.first[s]..<lm.first[s + 1]]
            guard zip(arcs, arcs.dropFirst()).allSatisfy({ $0.input <= $1.input }) else {
                throw SODAError("\(lmURL.lastPathComponent): arcs are not sorted by label")
            }
        }
        // The transducer maps each word to its variants, from its start state (ja-JP) or from the states its start
        // reaches without input (de-DE first writes a sentence start, <S>).
        let sym = transducer.symbols
        var all: [[UInt8]: [(label: Int, text: [UInt8])]] = [:]
        var queue = [transducer.start]
        var seen = [Bool](repeating: false, count: transducer.first.count)
        seen[transducer.start] = true
        while let s = queue.popLast() {
            for a in transducer.arcs[transducer.first[s]..<transducer.first[s + 1]] {
                if a.input == 0 {
                    // A sentence end the transducer writes (de-DE, fr-FR, es-ES; not ru-RU or it-IT, which map words
                    // only) is scored by the LM.
                    if a.output > 0 && Int(a.output) < sym.count && sym[Int(a.output)] == Array("</S>".utf8) {
                        if let id = lmIDs[Array("</S>".utf8)] { endOfSentence = id }
                    }
                    if a.next >= 0 && !seen[Int(a.next)] {
                        seen[Int(a.next)] = true
                        queue.append(Int(a.next))
                    }
                    continue
                }
                guard a.output > 0, Int(max(a.input, a.output)) < sym.count else { continue }
                let out = sym[Int(a.output)]
                all[sym[Int(a.input)], default: []].append((lmIDs[out] ?? unknown, out))
            }
        }
        for (word, v) in all where v.count > 1 || v[0].text != word { variants[word] = v }
    }

    /// An OpenFst VectorFst file (standard arcs) with its input symbols.
    private static func loadFst(_ url: URL) throws -> Fst {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var pos = 0
        func read<T>(_: T.Type) throws -> T {
            guard data.count - pos >= MemoryLayout<T>.size else { throw SODAError("\(url.lastPathComponent): truncated") }
            defer { pos += MemoryLayout<T>.size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: T.self) }
        }
        func string() throws -> [UInt8] {
            let n = Int(try read(Int32.self))
            guard n >= 0, data.count - pos >= n else { throw SODAError("\(url.lastPathComponent): truncated") }
            defer { pos += n }
            return Array(data[pos..<pos + n])
        }
        // OpenFst SymbolTable::Read: magic, name, available key, size, entries.
        func symbols(_ into: inout [[UInt8]]?) throws {
            _ = try read(Int32.self)
            _ = try string()
            _ = try read(Int64.self)
            let size = try read(Int64.self)
            for _ in 0..<max(0, size) {
                let symbol = try string()
                let key = try read(Int64.self)
                guard key >= 0 else { throw SODAError("\(url.lastPathComponent): bad symbol table") }
                if into != nil && key < 1 << 24 {
                    if into!.count <= Int(key) { into!.append(contentsOf: repeatElement([], count: Int(key) + 1 - into!.count)) }
                    into![Int(key)] = symbol
                }
            }
        }
        guard (try? read(UInt32.self)) == 0x7EB2_FDD6 else { throw SODAError("\(url.lastPathComponent) is not an OpenFst file") }
        let fstType = try string(), arcType = try string()
        _ = try read(Int32.self)
        let flags = try read(Int32.self)
        _ = try read(UInt64.self)
        let start = try read(Int64.self), states = try read(Int64.self)
        _ = try read(Int64.self)
        guard fstType == Array("vector".utf8), arcType == Array("standard".utf8), flags & 4 == 0 else {
            throw SODAError("\(url.lastPathComponent): unsupported FST")
        }
        var fst = Fst()
        var input: [[UInt8]]? = []
        var none: [[UInt8]]? = nil
        if flags & 1 != 0 { try symbols(&input) }
        if flags & 2 != 0 { try symbols(&none) }
        fst.symbols = input ?? []
        fst.start = Int(start)
        fst.final.reserveCapacity(Int(states))
        fst.first.reserveCapacity(Int(states) + 1)
        // At most this many arcs (16 bytes each in the file).
        fst.arcs.reserveCapacity(data.count / 16)
        for _ in 0..<states {
            fst.final.append(try read(Float.self))
            let n = try read(Int64.self)
            guard n >= 0 else { throw SODAError("\(url.lastPathComponent): truncated") }
            fst.first.append(fst.arcs.count)
            for _ in 0..<n {
                fst.arcs.append(Arc(input: try read(Int32.self), output: try read(Int32.self), weight: try read(Float.self),
                                    next: try read(Int32.self)))
            }
        }
        fst.first.append(fst.arcs.count)
        return fst
    }

    /// The ways to read word `w` after LM state `state`, directly or after backoff arcs: (cost, next state) each.
    private func step(_ state: Int, _ w: Int, _ out: inout [(cost: Float, next: Int)]) {
        out.removeAll(keepingCapacity: true)
        // libsoda composes with the LM's backoff arcs as plain epsilons, so a word may also be read after backing off
        // from a history that has it.
        for label in [w, unknown] {
            if label <= 0 { continue }
            var cost: Float = 0
            var s = state
            while true {
                let begin = lm.first[s], end = lm.first[s + 1]
                var lo = begin, hi = end
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if Int(lm.arcs[mid].input) < label { lo = mid + 1 } else { hi = mid }
                }
                if lo != end && Int(lm.arcs[lo].input) == label { out.append((cost + lm.arcs[lo].weight, Int(lm.arcs[lo].next))) }
                if begin == end || lm.arcs[begin].input != 0 {
                    if out.isEmpty && label == unknown { out.append((cost + Self.unscoredCost, s)) }
                    break
                }
                cost += lm.arcs[begin].weight  // Back off to a shorter history.
                s = Int(lm.arcs[begin].next)
            }
            if !out.isEmpty { return }  // Unknown words fall back to <UNK>.
        }
        if out.isEmpty { out.append((Self.unscoredCost, state)) }
    }

    /// The cost of ending the sentence in `state`.
    private func finalCost(_ state: Int) -> Float {
        func cost(_ start: Int) -> Float {
            var best = Self.unscoredCost, cost: Float = 0
            var s = start
            while true {
                if lm.final[s].isFinite { best = min(best, cost + lm.final[s]) }
                if lm.first[s] == lm.first[s + 1] || lm.arcs[lm.first[s]].input != 0 { return best }
                cost += lm.arcs[lm.first[s]].weight
                s = Int(lm.arcs[lm.first[s]].next)
            }
        }
        // de-DE's and fr-FR's transducers end every sentence with </S>, which the LM scores like a word; otherwise the
        // LM's final weights end it.
        if endOfSentence <= 0 { return cost(state) }
        var ends: [(cost: Float, next: Int)] = []
        step(state, endOfSentence, &ends)
        return ends.reduce(Float.infinity) { min($0, $1.cost + cost($1.next)) }
    }

    /// Replaces each word by its likeliest case variant. Words without variants are kept as they are (and still give
    /// the language model context); words the transducer does not know are kept and left out of the context.
    func apply(_ strings: inout [String]) {
        var words = strings.map { Array($0.utf8) }
        apply(&words)
        strings = words.map { String(decoding: $0, as: UTF8.self) }
    }

    func apply(_ words: inout [[UInt8]]) {
        guard !words.isEmpty, lm.start >= 0 else { return }
        // libsoda cases each word's text without the punctuation an earlier stage attached to it, looked up in lower
        // case. It takes out the words the transducer's symbol table lacks, cases the rest as one sentence and puts
        // them back, so a word that is only punctuation ("«") or unknown ("guillemets") is not part of the LM context.
        var parts: [(before: [UInt8], core: [UInt8], after: [UInt8])] = []
        var kept: [Int] = []
        var any = false
        for (i, w) in words.enumerated() {
            var b = 0, e = w.count
            var more = true
            while more {
                more = false
                for m in Self.attachedMarks {
                    let n = m.count
                    if e - b >= n && w[b..<b + n].elementsEqual(m) {
                        b += n
                        more = true
                    }
                    if e - b > n && w[(e - n)..<e].elementsEqual(m) {
                        e -= n
                        more = true
                    }
                }
            }
            var core = Array(w[b..<e])
            let lower = UnicodeCase.lower(core)
            if variants[lower] != nil { core = lower }
            any = any || variants[core] != nil
            if core.isEmpty || !known.contains(UnicodeCase.lower(core)) { continue }
            parts.append((Array(w[..<b]), core, Array(w[e...])))
            kept.append(i)
        }
        if !any { return }

        // Viterbi over case variants; the DP state is the LM state.
        struct Node {
            var lmState: Int
            var cost: Float
            /// Index into the previous position's nodes.
            var previous: Int
            /// Index into that position's candidates.
            var variant: Int
        }
        let candidates = parts.map { p in variants[p.core] ?? [(lmIDs[p.core] ?? unknown, p.core)] }
        var lattice = [[Node]](repeating: [], count: parts.count + 1)
        // libsoda scores the first word without sentence-start context: from the state the LM's start backs off to in
        // the end (de-DE: <S> herr 8.3 beats <S> Herr 11.7, yet libsoda writes "Herr"; unigram costs 10.9 / 10.2).
        var start = lm.start
        while lm.first[start] != lm.first[start + 1] && lm.arcs[lm.first[start]].input == 0 {
            start = Int(lm.arcs[lm.first[start]].next)
        }
        lattice[0].append(Node(lmState: start, cost: 0, previous: -1, variant: -1))
        var steps: [(cost: Float, next: Int)] = []
        for i in parts.indices {
            var best: [Int: Int] = [:]  // LM state → node index.
            for (p, from) in lattice[i].enumerated() {
                for (c, candidate) in candidates[i].enumerated() {
                    step(from.lmState, candidate.label, &steps)
                    for (s, next) in steps {
                        let cost = from.cost + s
                        let node = Node(lmState: next, cost: cost, previous: p, variant: c)
                        if let k = best[next] {
                            if cost < lattice[i + 1][k].cost { lattice[i + 1][k] = node }
                        } else {
                            best[next] = lattice[i + 1].count
                            lattice[i + 1].append(node)
                        }
                    }
                }
            }
        }
        var bestEnd = 0
        var bestCost = Float.infinity
        for (k, node) in lattice[parts.count].enumerated() {
            let cost = node.cost + finalCost(node.lmState)
            if cost < bestCost {
                bestCost = cost
                bestEnd = k
            }
        }
        var k = bestEnd
        for i in parts.indices.reversed() {
            let n = lattice[i + 1][k]
            words[kept[i]] = parts[i].before + candidates[i][n.variant].text + parts[i].after
            k = n.previous
        }
    }
}

/// Byte strings (a symbol table's), each with its first id, in one buffer with an open-addressing hash table: in place
/// of a [[UInt8]: Int] dictionary, which takes an allocation per string (a pack's LM has 100,000 words). Empty strings
/// are left out.
struct ByteStringIndex {
    private var bytes: [UInt8] = []
    /// String k is bytes[starts[k] ..< starts[k + 1]].
    private var starts: [Int32] = [0]
    private var ids: [Int32] = []
    /// String k + 1, or 0 for none.
    private var slots: [Int32]

    init(_ strings: [[UInt8]]) {
        slots = [Int32](repeating: 0, count: max(16, 1 << (Int.bitWidth - (2 * strings.count).leadingZeroBitCount)))
        bytes.reserveCapacity(strings.reduce(0) { $0 + $1.count })
        for (id, s) in strings.enumerated() where !s.isEmpty {
            let (slot, found) = find(s)
            if found { continue }
            bytes += s
            starts.append(Int32(bytes.count))
            ids.append(Int32(id))
            slots[slot] = Int32(ids.count)
        }
    }

    /// The slot holding `s`, or the empty slot where it would go.
    private func find(_ s: some Collection<UInt8>) -> (slot: Int, found: Bool) {
        // FNV-1a.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s { hash = (hash ^ UInt64(b)) &* 0x100_0000_01B3 }
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        while slots[slot] != 0 {
            let k = Int(slots[slot]) - 1
            if bytes[Int(starts[k])..<Int(starts[k + 1])].elementsEqual(s) { return (slot, true) }
            slot = (slot + 1) & mask
        }
        return (slot, false)
    }

    subscript(_ s: some Collection<UInt8>) -> Int? {
        let (slot, found) = find(s)
        return found ? Int(ids[Int(slots[slot]) - 1]) : nil
    }

    func contains(_ s: some Collection<UInt8>) -> Bool { find(s).found }
}
