import Foundation

/// A stage of the config's denormalizer list: rewrites a result's words, joined by spaces.
protocol TextNormalizer {
    func apply(_ text: [UInt8]) -> [UInt8]
}

/// greco's FstNormalizer: rewrites text with a byte-level transducer from a pack's denorm/*.mfar archive.
///
/// An .mfar file is greco's memory-mapped FST archive: a list of records, each a NUL-terminated key padded to 4 bytes,
/// a 64-bit length and the value aligned to 16 bytes. "v_" (2) is the version and "f_<i>" each FST. An FST ("mfv_" 1)
/// holds its start state ("0_"), the first arc of each state ("s_": count, then an offset per state) and its arcs
/// ("c_": count, then 12-byte arcs). An arc is an input byte, an output byte (0 for either: none, so an arc reading
/// none inserts its output), a tropical weight and the next state; next state -1 instead gives the state's final
/// weight.
final class FstNormalizer: TextNormalizer {
    private struct Arc {
        var input: UInt8
        var output: UInt8
        var weight: Float
        var next: Int32
    }

    private struct Fst {
        var start = 0
        /// Per state, its first arc; states + 1 entries.
        var first: [Int] = [0]
        /// Sorted by input within each state.
        var arcs: [Arc] = []
        /// Infinity where a state is not final.
        var final: [Float] = []
    }

    /// The archive's transducers, in order.
    private var fsts: [Fst] = []
    /// greco's ClassNormalizer (embedded_class_denorm.mfar): the transducer only accepts a whole span such as
    /// "<money> sieben euro </money>" ("7 €"), and `apply` rewrites the text's spans one at a time.
    let classSpans: Bool

    init(contentsOf url: URL, classSpans: Bool = false) throws {
        self.classSpans = classSpans
        let data = [UInt8](try Data(contentsOf: url))
        func bad(_ what: String) -> SODAError { SODAError("\(url.lastPathComponent): \(what)") }
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        guard let archive = Self.records(data, 0, data.count) else { throw bad("not an mfar archive") }
        guard let version = archive["v_"], version.count >= 4, u32(version.start) == 2, archive["f_0"] != nil else {
            throw bad("unsupported mfar archive")
        }
        var i = 0
        while let f = archive["f_\(i)"] {
            i += 1
            guard let fst = Self.records(data, f.start, f.start + f.count) else { throw bad("bad FST") }
            guard let v = fst["mfv_"], let s0 = fst["0_"], let s = fst["s_"], let c = fst["c_"],
                  [v, s0, s, c].allSatisfy({ $0.count >= 4 })
            else { throw bad("incomplete FST") }
            guard u32(v.start) == 1 else { throw bad("unsupported FST version") }
            var out = Fst()
            out.start = Int(Int32(bitPattern: u32(s0.start)))
            let states = Int(u32(s.start)), arcCount = Int(u32(c.start))
            guard s.count >= 16 + 4 * states, c.count >= 16 + 12 * arcCount, out.start >= 0, out.start < states else {
                throw bad("truncated FST")
            }
            var first = (0..<states).map { Int(u32(s.start + 16 + 4 * $0)) }
            first.append(arcCount)
            guard zip(first, first.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw bad("bad state table") }
            // Final weights move out of the arc list.
            out.final = [Float](repeating: .infinity, count: states)
            out.arcs.reserveCapacity(arcCount)
            for state in 0..<states {
                let begin = out.arcs.count
                for a in first[state]..<first[state + 1] {
                    let at = c.start + 16 + 12 * a
                    let labels = u32(at)
                    let weight = Float(bitPattern: u32(at + 4))
                    let next = Int32(bitPattern: u32(at + 8))
                    if next < 0 {
                        out.final[state] = weight
                        continue
                    }
                    guard Int(next) < states else { throw bad("arc to a missing state") }
                    out.arcs.append(Arc(input: UInt8(labels & 0xFF), output: UInt8((labels >> 8) & 0xFF), weight: weight,
                                        next: next))
                }
                // A stable sort by input.
                let sorted = out.arcs[begin...].enumerated().sorted {
                    $0.element.input != $1.element.input ? $0.element.input < $1.element.input : $0.offset < $1.offset
                }.map(\.element)
                out.arcs.replaceSubrange(begin..., with: sorted)
                out.first.append(out.arcs.count)
            }
            fsts.append(out)
        }
    }

    /// The records of an archive or FST between `begin` and `end`: key → value range.
    private static func records(_ data: [UInt8], _ begin: Int, _ end: Int) -> [String: (start: Int, count: Int)]? {
        var out: [String: (start: Int, count: Int)] = [:]
        var i = begin
        while i < end {
            guard let nul = data[i..<end].firstIndex(of: 0) else { return nil }
            let key = String(decoding: data[i..<nul], as: UTF8.self)
            i = (nul + 1 + 3) / 4 * 4
            guard i + 8 <= end else { return nil }
            let n = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt64.self) }
            i = (i + 8 + 15) / 16 * 16
            guard n <= UInt64(end - min(i, end)) else { return nil }
            out[key] = (i, Int(n))
            i = (i + Int(n) + 15) / 16 * 16
        }
        return out
    }

    /// The classes greco's ClassNormalizer knows, whose tags it recognizes as "<money>" and "</money>".
    private static let classes: Set<String> = [
        "addressnum", "alphanumseq", "app", "apt", "areacode", "contacts", "countrycode", "day", "fulldate",
        "fullphonenum", "grammars", "hotword", "money", "month", "operand", "ordinal", "percent", "personal", "phonenum",
        "postalcode", "recency", "reject", "restaurant", "root", "song", "street", "time", "unknown", "year",
        "dynamicclass"]

    /// The class of an opening or closing tag of one of greco's word classes.
    static func classTag(_ token: some Collection<UInt8>) -> (name: String, closing: Bool)? {
        let t = Array(token)
        guard t.count >= 3, t.first == UInt8(ascii: "<"), t.last == UInt8(ascii: ">") else { return nil }
        let closing = t[1] == UInt8(ascii: "/")
        let name = String(decoding: t[(closing ? 2 : 1)..<(t.count - 1)], as: UTF8.self)
        return classes.contains(name) ? (name, closing) : nil
    }

    /// The output of the cheapest path accepting `text`'s bytes, or `text` itself if the transducer rejects it; an
    /// archive of several transducers applies each in turn.
    func apply(_ text: [UInt8]) -> [UInt8] {
        classSpans ? rewriteSpans(text) : rewriteAll(text)
    }

    private func rewriteAll(_ text: [UInt8]) -> [UInt8] {
        fsts.reduce(text) { Self.rewrite($1, $0) }
    }

    /// libsoda hands the transducer each span from an opening tag to the next closing tag of its class, tags included,
    /// and puts the output in its place. A tag of another class inside the span, a missing closing tag or a span the
    /// transducer rejects lose only the opening tag; the words go on, and a stray closing tag is dropped too.
    private func rewriteSpans(_ text: [UInt8]) -> [UInt8] {
        let tokens = text.split(separator: 32).map(Array.init)
        var out: [UInt8] = []
        func append(_ t: [UInt8]) {
            guard !t.isEmpty else { return }
            if !out.isEmpty { out.append(32) }
            out += t
        }
        var i = 0
        while i < tokens.count {
            defer { i += 1 }
            guard let (name, closing) = Self.classTag(tokens[i]) else {
                append(tokens[i])
                continue
            }
            if closing { continue }
            var end = 0
            for k in (i + 1)..<max(i + 1, tokens.count) {
                guard let other = Self.classTag(tokens[k]) else { continue }
                if other.name != name { break }
                if other.closing {
                    end = k
                    break
                }
            }
            if end == 0 { continue }
            let span = Array(tokens[i...end].joined(separator: [32]))
            let rewritten = rewriteAll(span)
            if rewritten == span || rewritten.isEmpty { continue }
            append(rewritten)
            i = end
        }
        return out
    }

    /// Viterbi over (byte position, state); each node remembers its predecessor (at the same position after an arc
    /// reading no byte) and the byte it wrote.
    private static func rewrite(_ fst: Fst, _ text: [UInt8]) -> [UInt8] {
        if fst.arcs.isEmpty { return text }
        struct Node {
            var state: Int
            var cost: Float
            var previousPosition: Int
            /// Index into nodes[previousPosition].
            var previous: Int
            var output: UInt8
        }
        var nodes = [[Node]](repeating: [], count: text.count + 1)
        var slot = [Int](repeating: -1, count: fst.final.count)
        func relax(_ pos: Int, _ n: Node) -> Bool {
            let k = slot[n.state]
            if k < 0 {
                slot[n.state] = nodes[pos].count
                nodes[pos].append(n)
                return true
            }
            if n.cost < nodes[pos][k].cost {
                nodes[pos][k] = n
                return true
            }
            return false
        }
        // Arcs reading no byte (input 0, sorted first) insert their output.
        func close(_ pos: Int) {
            for (n, node) in nodes[pos].enumerated() { slot[node.state] = n }
            var queue = Array(nodes[pos].indices)
            var q = 0
            while q < queue.count && q < 64 * fst.final.count {
                let from = nodes[pos][queue[q]]
                var a = fst.first[from.state]
                while a < fst.first[from.state + 1] && fst.arcs[a].input == 0 {
                    let arc = fst.arcs[a]
                    if relax(pos, Node(state: Int(arc.next), cost: from.cost + arc.weight, previousPosition: pos,
                                       previous: queue[q], output: arc.output)) {
                        queue.append(slot[Int(arc.next)])
                    }
                    a += 1
                }
                q += 1
            }
            for node in nodes[pos] { slot[node.state] = -1 }
        }
        nodes[0].append(Node(state: fst.start, cost: 0, previousPosition: -1, previous: -1, output: 0))
        close(0)
        for (i, c) in text.enumerated() {
            for n in nodes[i].indices {
                let from = nodes[i][n]
                // The first arc reading `c` (lower bound), then all that do.
                var lo = fst.first[from.state], hi = fst.first[from.state + 1]
                let end = hi
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if fst.arcs[mid].input < c { lo = mid + 1 } else { hi = mid }
                }
                var a = lo
                while a < end && fst.arcs[a].input == c {
                    let arc = fst.arcs[a]
                    _ = relax(i + 1, Node(state: Int(arc.next), cost: from.cost + arc.weight, previousPosition: i,
                                          previous: n, output: arc.output))
                    a += 1
                }
            }
            for node in nodes[i + 1] { slot[node.state] = -1 }
            if nodes[i + 1].isEmpty { return text }
            close(i + 1)
        }
        var best = -1
        var bestCost = Float.infinity
        for (n, node) in nodes[text.count].enumerated() {
            let cost = node.cost + fst.final[node.state]
            if cost < bestCost {
                bestCost = cost
                best = n
            }
        }
        if best < 0 { return text }
        var out: [UInt8] = []
        var pos = text.count
        while best >= 0 {
            let n = nodes[pos][best]
            if n.output != 0 { out.append(n.output) }
            pos = n.previousPosition
            best = n.previous
        }
        return out.reversed()
    }
}
