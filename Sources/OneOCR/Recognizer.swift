import Foundation

// Text line recognition after the network: the sparse and reduced score matrices, greedy CTC decoding, words and
// their pixel positions, lattice candidates, the 21 confidence/rejection features, rejection and word confidence,
// and right-to-left reordering through ICU. Float32 where oneocr computes in float32, with the CRT's expf/logf.

private let NEG = -Float.greatestFiniteMagnitude
private let log1e9 = CRT.logf(1e-9)
private let laZero = -CRT.powf(10, 10)
private let laMinDiff = -CRT.logf(-laZero)
private let laThresh = CRT.powf(10, 10) * -0.5

/// Log-add with the CRT's expf/logf: a is the accumulated value, b the new one.
func logadd(_ a: Float, _ b: Float) -> Float {
    let hi = a < b ? b : a, lo = a >= b ? b : a
    let d = lo - hi
    if d >= laMinDiff { return CRT.logf(CRT.expf(d) + 1) + hi }
    if hi >= laThresh { return hi }
    return laZero
}

enum TokenType { static let other = 0, alpha = 1, cjk = 2, thai = 3, blank = 4, space = 5, apos = 6, punct = 7, trash = 8 }

private let punct7: Set<UInt32> = [0x2E, 0x2A, 0x2D, 0x3D, 0xB7, 0x30FB, 0x21, 0x2026, 0x3A, 0x3002, 0x3F, 0x5F, 0x3B,
                                   0x3001, 0x203B, 0xA1, 0x7E, 0xBF, 0x2022, 0x3C]
let cjkRanges: [ClosedRange<UInt32>] = [0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2EBEF,
                                        0x30000...0x3134F, 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x318F,
                                        0x31A0...0x33FF, 0xAC00...0xD7FF, 0xFF00...0xFFEF]

struct Token {
    let row: Int
    let char: String
    let insRow: Int
    let phone: Int
    let type: Int
    let insText: String
    let outText: String
}

/// The character tables of a recognizer (char2ind, char2inschar, composite chars).
struct CharacterMapper {
    let chars: [String]
    let tokens: [Token]
    let blank: Int, space: Int, trash: Int

    private static func readPairs(_ url: URL) -> [(String, String)]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [(String, String)] = []
        for line0 in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(line0)
            while let l = line.last, l == "\r" || l == "\n" { line = line.dropLast() }
            if line.isEmpty { continue }
            guard let sp = line.lastIndex(of: " ") else { continue }
            let k = String(line[..<sp]), v = String(line[line.index(after: sp)...])
            if k.isEmpty { continue }
            out.append((k, v))
        }
        return out
    }

    private static func type(_ c: String) -> Int {
        switch c {
        case "<blank>": return TokenType.blank
        case "<space>": return TokenType.space
        case "<trash_as_space>": return TokenType.trash
        case "'": return TokenType.apos
        default: break
        }
        if let b = c.utf8.first, b < 0x80, (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) { return TokenType.alpha }
        let s = c.unicodeScalars
        if c != "<eps>", s.count == 1, let cp = s.first?.value {
            if cjkRanges.contains(where: { $0.contains(cp) }) { return TokenType.cjk }
            if (0x0E00...0x0E7F).contains(cp) { return TokenType.thai }
            if punct7.contains(cp) { return TokenType.punct }
        }
        return TokenType.other
    }

    init(char2ind: URL, char2inschar: URL?, composite: URL?) throws {
        guard let pairs = Self.readPairs(char2ind), !pairs.isEmpty else { throw OneOCRError("Can't read \(char2ind.lastPathComponent)") }
        let ids = try pairs.map { p -> Int in
            guard let v = Int(p.1), v >= 0 else { throw OneOCRError("Invalid \(char2ind.lastPathComponent)") }
            return v
        }
        var chars = [String](repeating: "", count: ids.max()! + 1)
        for (p, v) in zip(pairs, ids) { chars[v] = p.0 }
        var index: [String: Int] = [:]
        for (i, c) in chars.enumerated() { index[c] = i }
        var ins: [String: String] = [:]
        if let u = char2inschar, let p = Self.readPairs(u) { for (c, r) in p { ins[c] = r } }
        var comp: [String: String] = [:]
        if let u = composite, let p = Self.readPairs(u) { for (m, o) in p { comp[m] = o } }
        guard let b = index["<blank>"] else { throw OneOCRError("Invalid CM char table, <blank> token not found.") }
        blank = b
        space = index["<space>"] ?? -1
        trash = index["<trash_as_space>"] ?? -1
        self.chars = chars
        tokens = chars.enumerated().map { i, c in
            let insRow = index[ins[c] ?? c] ?? i
            return Token(row: i, char: c, insRow: insRow, phone: i, type: Self.type(c), insText: chars[insRow],
                         outText: comp[c] ?? c)
        }
    }
}

/// A column of a sparse score matrix: (row, value) in insertion order, like the Python dict it models.
private struct Col {
    var keys: [Int] = []
    var vals: [Float] = []

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    func get(_ k: Int) -> Float? { keys.firstIndex(of: k).map { vals[$0] } }

    mutating func set(_ k: Int, _ v: Float) {
        if let i = keys.firstIndex(of: k) {
            vals[i] = v
        } else {
            keys.append(k)
            vals.append(v)
        }
    }

    mutating func remove(_ k: Int) {
        if let i = keys.firstIndex(of: k) {
            keys.remove(at: i)
            vals.remove(at: i)
        }
    }

    /// (row, value) by ascending row.
    var sorted: [(Int, Float)] { zip(keys, vals).sorted { $0.0 < $1.0 } }
}

struct CharModelConfig {
    let name: String
    let ppf: Int, pps: Int, ss: Int, es: Int
    let topK: Int
    let keepPeakBlanks: Bool
    let logMinProb: Float, logBlankThr: Float, logCharThr: Float

    init(_ e: [String: Any]) {
        func int(_ k: String, _ d: Int) -> Int {
            if let n = e[k] as? NSNumber { return Double(n.intValue) == n.doubleValue ? n.intValue : d }
            if let s = e[k] as? String, let v = Int(s) { return v }
            return d
        }
        func dbl(_ k: String, _ d: Double) -> Double {
            if let n = e[k] as? NSNumber { return n.doubleValue }
            if let s = e[k] as? String, let v = Double(s) { return v }
            return d
        }
        name = e["name"] as? String ?? ""
        ppf = int("pixels_per_frame", 4)
        pps = int("pixels_per_space", 12)
        ss = int("start_frame_shift", 0)
        es = int("end_frame_shift", 0)
        topK = int("sparse_xnn_top_k", 30)
        keepPeakBlanks = e["keep_continous_peak_blanks"] as? Bool ?? false
        logMinProb = CRT.logf(Float(dbl("sparse_xnn_min_prob", 0.0001)))
        logBlankThr = CRT.logf(Float(dbl("blank_threshold", 0.99)))
        logCharThr = CRT.logf(Float(dbl("char_threshold", 0.05)))
    }
}

private final class Seg {
    let tok: Token
    let start: Int, end: Int
    var f0: Float = 0, f1: Float = 0, f2: Float = 0, f3: Float = 0
    var best: Token?

    init(_ tok: Token, _ start: Int, _ end: Int) {
        self.tok = tok
        self.start = start
        self.end = end
    }
}

private final class Word {
    var segs: [Seg]
    var tileStart = 0, tileEnd = 0
    var candidates: [(String, Float)] = []
    var features: [Float] = []
    var conf: Float = 0

    init(_ segs: [Seg]) { self.segs = segs }

    var insText: String { segs.map { $0.tok.type == TokenType.space ? " " : $0.tok.insText }.joined() }
    var outText: String { segs.map(\.tok.outText).joined() }
}

struct RecognizedWord {
    var text: String
    var start = 0, end = 0  // line image pixels
    var startFrame: Int, endFrame: Int
    var confidence: Float
    var chars: [(text: String, startFrame: Int, endFrame: Int)]
}

struct RecognizedLine {
    var text = ""
    var words: [RecognizedWord] = []
    var confidence = 0.0
    var rejected = false
}

/// A recognizer: its network, character tables and settings.
final class CharModel: @unchecked Sendable {
    let cfg: CharModelConfig
    let mapper: CharacterMapper
    let net: CharNet

    init(files: ModelFiles, entry: [String: Any]) throws {
        cfg = CharModelConfig(entry)
        func url(_ k: String) -> URL? { (entry[k] as? String).map { files.url($0) } }
        guard let c2i = url("phone_to_idx_path") else { throw OneOCRError("\(cfg.name): no character table") }
        mapper = try CharacterMapper(char2ind: c2i, char2inschar: url("char_log_to_phy_path"),
                                     composite: url("composite_chars_map_path"))
        net = try CharNet(files: files, name: cfg.name)
    }
}

/// The recognizer stage: everything after the network for one line.
final class TextRecognizer: @unchecked Sendable {
    static let rtlBlocks: Set<Int32> = [11, 12, 81, 85, 128, 192, 210, 211]

    private let files: ModelFiles
    private let charEntries: [String: [String: Any]]
    private var charModels: [String: CharModel] = [:]
    private let lock = NSLock()
    private let confModels: [String: (ScoreModel, Double)]
    private let rejModels: [String: (ScoreModel, Double)]
    private let enableRej: Bool, enableConf: Bool
    private var enums: [String: [String: String]] = [:]
    /// The modes of ocr_mode_to_char_model_path in insertion order.
    private var charModelModes: [String] = []

    init(files: ModelFiles, config cfg: [String: Any]) throws {
        self.files = files
        var ce: [String: [String: Any]] = [:]
        for e in cfg["char_model"] as? [[String: Any]] ?? [] { if let n = e["name"] as? String { ce[n] = e } }
        charEntries = ce
        func scores(_ kind: String, _ thr: String, _ d: Double) throws -> [String: (ScoreModel, Double)] {
            var out: [String: (ScoreModel, Double)] = [:]
            for e in cfg["\(kind)_model"] as? [[String: Any]] ?? [] {
                guard let n = e["name"] as? String else { continue }
                let t = (e[thr] as? NSNumber)?.doubleValue ?? d
                out[n] = (try ScoreModel(files.json("scores/\(kind)/\(n).json")), t)
            }
            return out
        }
        confModels = try scores("conf", "word_class_threshold", 0.5)
        rejModels = try scores("rej", "rej_prob", 0)
        enableRej = ((cfg["rejection_option"] as? [String: Any])?["enable_rej"] as? Bool) ?? false
        enableConf = cfg["enable_conf"] as? Bool ?? false
        let kinds = ["ocr_mode_to_char_model_path", "ocr_mode_to_decoder_path", "ocr_mode_to_conf_rej_path",
                     "ocr_mode_to_text_script", "ocr_mode_to_text_category"]
        for k in kinds { enums[k] = [:] }
        let em = cfg["enums_map"] as? [String: [[String: Any]]] ?? [:]
        for k in kinds {
            for e in em[k] ?? [] {
                let mode = e["mode"] as? String ?? "Auto"
                let v = (e["path"] as? String) ?? (e["script"] as? String) ?? (e["category"] as? String)
                if k == kinds[0] && enums[k]![mode] == nil { charModelModes.append(mode) }
                enums[k]![mode] = v ?? (k == "ocr_mode_to_text_script" ? "Unknown" : "Mixed")
            }
        }
        if let f = cfg["enums_map_file"] as? String, let text = try? String(contentsOf: files.url(f), encoding: .utf8) {
            for (k, v) in Self.parseEnums(text, kinds) {
                if k == kinds[0] { charModelModes += v.order.filter { enums[k]![$0] == nil } }
                enums[k]!.merge(v.map) { $1 }
            }
        }
    }

    private static func parseEnums(_ text: String, _ kinds: [String]) -> [String: (map: [String: String], order: [String])] {
        var out: [String: (map: [String: String], order: [String])] = [:]
        for k in kinds { out[k] = ([:], []) }
        let block = try! NSRegularExpression(pattern: #"(\w+)\s*\{([^{}]*)\}"#)
        let field = try! NSRegularExpression(pattern: #"(\w+)\s*:\s*"?([\w]+)"?"#)
        let ns = text as NSString
        for m in block.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1)), body = ns.substring(with: m.range(at: 2))
            guard out[kind] != nil else { continue }
            let nb = body as NSString
            var fields: [String: String] = [:]
            for f in field.matches(in: body, range: NSRange(location: 0, length: nb.length)) {
                fields[nb.substring(with: f.range(at: 1))] = nb.substring(with: f.range(at: 2))
            }
            let mode = fields["mode"] ?? "Auto"
            let v = fields["path"] ?? fields["script"] ?? fields["category"]
            if out[kind]!.map[mode] == nil { out[kind]!.order.append(mode) }
            out[kind]!.map[mode] = v ?? (kind == "ocr_mode_to_text_script" ? "Unknown" : "Mixed")
        }
        return out
    }

    func charModel(_ name: String) throws -> CharModel {
        lock.lock()
        defer { lock.unlock() }
        if let m = charModels[name] { return m }
        guard let e = charEntries[name] else { throw OneOCRError("unknown char model \(name)") }
        let m = try CharModel(files: files, entry: e)
        charModels[name] = m
        return m
    }

    // MARK: XnnResult

    private static func sparse(_ cfg: CharModelConfig, _ blank: Int, _ logp: [Float], _ T: Int, _ C: Int) -> [Col] {
        logp.withUnsafeBufferPointer { logp in
            (0..<T).map { t in
                var col = Col()
                let row = logp.baseAddress! + t * C, threshold = cfg.logMinProb
                for i in 0..<C where row[i] > threshold {
                    col.keys.append(i)
                    col.vals.append(row[i])
                }
                if col.isEmpty { col.set(blank, cfg.logMinProb) }
                return col
            }
        }
    }

    /// XnnResult::BuildReduced: mutates cols (the decoder's input) and returns (offsets, R, L).
    private static func buildReduced(_ cfg: CharModelConfig, _ mp: CharacterMapper, _ cols: inout [Col])
        -> ([Int], [Col], [Col]) {
        let blank = mp.blank, space = mp.space, trash = mp.trash
        let T = cols.count
        if trash >= 0 {
            for i in 0..<T {
                guard let tv = cols[i].get(trash) else { continue }
                let greater = cols[i].vals.contains { $0 > tv }
                cols[i].remove(trash)
                if !greater { cols[i].set(space, tv) }
            }
        }
        var offsets = [Int](repeating: -1, count: T)
        var R = [Col](repeating: Col(), count: T)
        var runStart = -1
        var prevArg = blank
        for i in 0..<T {
            let b = cols[i].get(blank) ?? NEG
            var normal = true
            if b > cfg.logBlankThr {
                var strongPrev = false
                if runStart < 0 {
                    offsets[i] = -2
                    if prevArg == blank {
                        runStart = i
                    } else if (cols[i].get(prevArg) ?? NEG) <= cfg.logMinProb {
                        runStart = i
                    } else {
                        strongPrev = true
                    }
                }
                if !cfg.keepPeakBlanks && !strongPrev {
                    R[i] = Col(keys: [blank], vals: [b])
                    offsets[i] = i - runStart
                    normal = false
                }
            } else {
                runStart = -1
            }
            if normal {
                var best = NEG, arg = 0
                var ent: [(Int, Float)] = []
                for (r, v) in cols[i].sorted {
                    if v > best {
                        best = v
                        arg = r
                    }
                    ent.append((mp.tokens[r].insRow, v))
                }
                if ent.count > 1 {
                    MSVC.sort(&ent) { $0.0 < $1.0 }
                    for j in 1..<ent.count where ent[j].0 == ent[j - 1].0 {
                        ent[j].1 = logadd(ent[j - 1].1, ent[j].1)
                        ent[j - 1].1 = NEG
                    }
                }
                var r = Col()
                for (k, v) in ent where v != NEG { r.set(k, v) }
                R[i] = r
                prevArg = arg
                if cols[i].count > cfg.topK {
                    let kth = cols[i].vals.sorted(by: >)[cfg.topK - 1]
                    var c = Col()
                    for (k, v) in zip(cols[i].keys, cols[i].vals) where !(v < kth) {
                        c.keys.append(k)
                        c.vals.append(v)
                    }
                    cols[i] = c
                }
            }
        }
        var L: [Col] = []
        for i in 0..<T {
            let o = offsets[i]
            if o == 0 || o == -2 {
                L.append(Col(keys: [blank], vals: [0]))
            } else if o < 0 {
                var c = Col()
                for (k, v) in zip(R[i].keys, R[i].vals) where v > cfg.logCharThr {
                    c.keys.append(k)
                    c.vals.append(v)
                }
                L.append(c)
            } else {
                L.append(Col())
            }
        }
        if !cfg.keepPeakBlanks {
            for i in 0..<T {
                if offsets[i] > 0 {
                    cols[i] = Col()
                } else if offsets[i] == 0 {
                    cols[i] = Col(keys: [blank], vals: [0])
                }
            }
        }
        return (offsets, R, L)
    }

    /// ArgMaxDecoder::Decode: per-frame argmax -> CTC labels (2 id, or 2 id - 1 for a continuation).
    private static func argmaxDecode(_ mp: CharacterMapper, _ cols: [Col], _ offsets: [Int]) -> [Int] {
        let C = mp.chars.count
        var labels: [Int] = []
        var prev = -1
        for (i, col) in cols.enumerated() {
            let o = offsets[i]
            let empty = o < 0 ? col.isEmpty : o > 0
            var a = 0
            if empty {
                a = C - 1
            } else {
                var best = NEG
                for (r, v) in col.sorted where v > best {
                    best = v
                    a = r
                }
            }
            let lab = 2 * a
            if lab != 2 * mp.blank && lab == prev {
                labels.append(lab - 1)
            } else {
                labels.append(lab)
                prev = lab
            }
        }
        return labels
    }

    private static func segments(_ mp: CharacterMapper, _ labels: [Int]) -> [Seg] {
        let toks: [Token?] = labels.map { $0 & 1 != 0 ? nil : mp.tokens[$0 >> 1] }
        var segs: [Seg] = []
        var i = 0
        let n = toks.count
        while i < n {
            while i < n, let t = toks[i], t.type == TokenType.blank { i += 1 }
            if i >= n { break }
            let tok = toks[i]
            let start = i
            i += 1
            while i < n && toks[i] == nil { i += 1 }
            guard let tok else { continue }
            segs.append(Seg(tok, start, i - 1))
        }
        return segs
    }

    private static func segScores(_ mp: CharacterMapper, _ segs: [Seg], _ R: [Col]) {
        for s in segs {
            let n = Float(s.end - s.start + 1)
            var acc = MsvcUnorderedMap<Int32, Float>(hash: MSVC.hash)
            for f in s.start...s.end {
                for (k, v) in zip(R[f].keys, R[f].vals) {
                    let key = Int32(k)
                    acc[key] = CRT.expf(v) / n + (acc[key] ?? 0)
                }
            }
            let me = Int32(s.tok.insRow)
            s.f0 = acc[me] ?? 0
            s.f1 = acc[Int32(mp.blank)] ?? 0
            s.f2 = acc[Int32(mp.space)] ?? 0
            var bestID: Int32 = -1, bestV: Float = 0, other: Float = 0
            for (k, v) in acc.items {
                if v > bestV {
                    bestID = k
                    bestV = v
                }
                if k != me && v > other { other = v }
            }
            s.f3 = other
            s.best = bestID >= 0 ? mp.tokens[Int(bestID)] : nil
        }
    }

    // MARK: words

    /// Splits at <space>, then isolates runs of two or more punctuation chars.
    private static func splitWords(_ segs: [Seg]) -> ([Word], Bool, Bool) {
        var hasCJK = false, hasThai = false
        var groups: [[Seg]] = []
        var cur: [Seg] = []
        for s in segs {
            if s.tok.type == TokenType.space {
                if !cur.isEmpty { groups.append(cur) }
                cur = []
                continue
            }
            if !hasThai && s.tok.type == TokenType.thai {
                hasThai = true
            } else if !hasCJK && s.tok.type == TokenType.cjk {
                hasCJK = true
            }
            cur.append(s)
        }
        if !cur.isEmpty { groups.append(cur) }
        var words: [Word] = []
        for g in groups {
            if g.count == 1 {
                words.append(Word(g))
                continue
            }
            var acc: [Seg] = []
            var run = 0
            let n = g.count
            for (i, s) in g.enumerated() {
                if s.tok.type == TokenType.punct {
                    run += 1
                    if run == 1 && i != 0 && i < n - 1 && g[i - 1].tok.type != TokenType.punct
                        && g[i + 1].tok.type == TokenType.punct {
                        if !acc.isEmpty { words.append(Word(acc)) }
                        acc = []
                    }
                } else {
                    if run > 1 && !acc.isEmpty {
                        words.append(Word(acc))
                        acc = []
                    }
                    run = 0
                }
                acc.append(s)
            }
            if !acc.isEmpty { words.append(Word(acc)) }
        }
        return (words, hasCJK, hasThai)
    }

    private static func chunk(_ words: [Word], _ maxLen: Int?) -> [Word] {
        guard let maxLen else { return words.map { Word($0.segs) } }
        var out: [Word] = []
        for w in words {
            for k in stride(from: 0, to: w.segs.count, by: maxLen) { out.append(Word(Array(w.segs[k..<min(k + maxLen, w.segs.count)]))) }
        }
        return out
    }

    private static func tile(_ words: [Word], _ T: Int) {
        guard let first = words.first, let last = words.last else { return }
        first.tileStart = 0
        for i in 1..<max(words.count, 1) {
            let v = words[i - 1].segs.last!.end + words[i].segs[0].start
            words[i - 1].tileEnd = v / 2
            words[i].tileStart = v / 2 + 1
        }
        last.tileEnd = T - 1
    }

    /// ICU word boundaries ("th") kept for Thai (UTF-16 offsets into the words joined by spaces).
    private static func thaiBreaks(_ words: [Word]) -> [Int] {
        let text = words.filter { !$0.segs.isEmpty }.map { $0.segs.map(\.tok.outText).joined() }.joined(separator: " ")
        let u = Array(text.utf16)
        let n = u.count
        guard let bounds = ICU.wordBreaks(u, locale: "th") else { return [] }
        var out: [Int] = []
        for b in bounds where b != 0 && !(b < n && u[b] == 0x20) && !(b - 1 < n && u[b - 1] == 0x20) {
            if b == n || ICU.blockCode(ICU.char32At(u, b)) == ICU.blockThai
                || ICU.blockCode(ICU.char32At(u, b - 1)) == ICU.blockThai {
                out.append(b)
            }
        }
        return out
    }

    /// Every CJK char becomes its own word; with Thai, words are also cut at ICU's boundaries.
    private static func splitCJK(_ words: [Word], _ hasCJK: Bool, _ hasThai: Bool) -> [Word] {
        if !hasCJK && !hasThai { return words }
        let breaks = hasThai ? thaiBreaks(words) : []
        var out: [Word] = []
        var pos = 0, bi = 0
        for w in words {
            var acc: [Seg] = []
            for s in w.segs {
                if !acc.isEmpty && (s.tok.type == TokenType.cjk || (!breaks.isEmpty && bi < breaks.count && pos == breaks[bi])) {
                    out.append(Word(acc))
                    acc = []
                    bi += 1
                }
                acc.append(s)
                pos += 1
                if s.tok.type == TokenType.cjk {
                    out.append(Word(acc))
                    acc = []
                }
            }
            if !acc.isEmpty { out.append(Word(acc)) }
            pos += 1
        }
        return out
    }

    // MARK: lattice candidates

    private final class Node {
        let id: Int
        let score: Float
        let parent: Node?

        init(_ id: Int, _ score: Float, _ parent: Node?) {
            self.id = id
            self.score = score
            self.parent = parent
        }
    }

    /// The top-20 paths through L[s...e] as (text, score), merged by text and sorted.
    private static func lattice(_ mp: CharacterMapper, _ L: [Col], _ s0: Int, _ e0: Int, beam: Int = 20) -> [(String, Float)] {
        var s = s0, e = e0
        while L[s].isEmpty && s < e { s += 1 }
        while L[e].isEmpty && e > s { e -= 1 }
        if s > e || L[s].isEmpty { return [] }
        let greater = { (a: Node, b: Node) in a.score > b.score }
        var hyps = zip(L[s].keys, L[s].vals).filter { $0.1 != NEG }.map { Node($0.0, $0.1, nil) }
        if hyps.count <= beam {
            MSVC.sort(&hyps, greater)
        } else {
            MSVC.partialSort(&hyps, beam, greater)
            hyps.removeLast(hyps.count - beam)
        }
        if s + 1 <= e {
            for f in (s + 1)...e {
                let col = L[f]
                if col.isEmpty { continue }
                var heap: [Node] = []
                for (k, v) in zip(col.keys, col.vals) where v != NEG {
                    for h in hyps {
                        let sc = v + h.score
                        if heap.count >= beam {
                            if sc < heap[0].score { break }
                            MSVC.popHeap(&heap, greater)
                            heap[heap.count - 1] = Node(k, sc, h)
                            MSVC.pushHeap(&heap, greater)
                        } else {
                            heap.append(Node(k, sc, h))
                            if heap.count == beam { MSVC.makeHeap(&heap, greater) }
                        }
                    }
                }
                MSVC.sort(&heap, greater)
                hyps = heap
            }
        }
        var merged = MsvcUnorderedMap<String, Float>(hash: MSVC.hash)
        for node in hyps {
            var ids: [Int] = []
            var nd: Node? = node
            while let x = nd {
                if x.id != mp.blank && (x.parent == nil || x.id != x.parent!.id) { ids.append(x.id) }
                nd = x.parent
            }
            let toks = ids.reversed().map { mp.tokens[$0] }
            var a = 0, b = toks.count - 1
            while a <= b && toks[a].type == TokenType.space { a += 1 }
            while b >= a && toks[b].type == TokenType.space { b -= 1 }
            if a > b { continue }
            let text = toks[a...b].map { $0.type == TokenType.space ? " " : $0.insText }.joined()
            if text.isEmpty { continue }
            merged[text] = merged[text].map { logadd($0, node.score) } ?? node.score
        }
        var out = merged.items
        MSVC.sort(&out) { $0.1 > $1.1 }
        return out
    }

    // MARK: features

    private static func bestPath(_ w: Word) -> String {
        let segs = w.segs
        var prev = segs[0].best
        var out: [String] = []
        if let p = prev, p.type != TokenType.blank && p.type != TokenType.space { out.append(p.insText) }
        for i in 1..<max(segs.count, 1) {
            guard let t = segs[i].best else { continue }
            if t.type != TokenType.blank && (prev == nil || t.phone != prev!.phone || segs[i].start != segs[i - 1].end + 1) {
                out.append(t.type == TokenType.space ? " " : t.insText)
            }
            prev = t
        }
        return out.joined()
    }

    /// Levenshtein distance over the UTF-8 bytes.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...x.count)
        for j in 1...y.count {
            var cur = [Int](repeating: 0, count: x.count + 1)
            cur[0] = j
            let cj = y[j - 1]
            for i in 1...x.count { cur[i] = min(prev[i - 1] + (x[i - 1] != cj ? 1 : 0), prev[i] + 1, cur[i - 1] + 1) }
            prev = cur
        }
        return prev[x.count]
    }

    /// The 21 confidence / rejection features of a word.
    private static func features(_ w: Word) -> [Float] {
        let n = Float(w.segs.count)
        var hist = [Float](repeating: 0, count: 10)
        var minp: Float = 1, meanp: Float = 0
        let eps6: Float = 1e-6, eps9: Float = 1e-9
        for s in w.segs {
            var p = s.f0
            let b: Int
            if p >= eps6 {
                let q = Double(p) / 0.1
                b = min(max(q < 1e18 ? Int(q) : 9, 0), 9)
            } else {
                p = eps6
                b = 0
            }
            if minp >= p { minp = p }
            hist[b] = hist[b] + 1
            meanp = p / n + meanp
        }
        let text = w.insText
        var f1: Float = -10, f4: Float = -10, f2: Float = 1
        if let first = w.candidates.first {
            var v26 = w.candidates.last!.1
            for (t, sc) in w.candidates where t == text {
                v26 = sc
                break
            }
            f1 = v26 / n
            f4 = (v26 - first.1) / n
            f2 = -Float(Double(editDistance(first.0, text)) / Double(n))
        }
        let f3 = -(Float(editDistance(bestPath(w), text)) / n)
        var sL: Float = 0, sL2: Float = 0, sLb: Float = 0, sLs: Float = 0
        for s in w.segs {
            let Lp = s.f0 > eps9 ? CRT.logf(s.f0) : log1e9
            let Lb = s.f1 > eps9 ? CRT.logf(1 - s.f1) + Lp : Lp
            let Ls = s.f2 > eps9 ? CRT.logf(1 - s.f2) + Lp : Lp
            let L2 = s.f3 > eps9 ? CRT.logf(1 - s.f3) + Lp : Lp
            sLb = Lb + sLb
            sL2 = L2 + sL2
            sLs = Ls + sLs
            sL = Lp + sL
        }
        return [CRT.logf(n), f1, f2, f3, f4, sL / n, sL2 / n, sLb / n, sLs / n, CRT.logf(minp), CRT.logf(meanp)]
            + hist.map { -($0 / n) }
    }

    private static func candidatesAndFeatures(_ mp: CharacterMapper, _ words: [Word], _ L: [Col]) {
        for w in words {
            w.candidates = lattice(mp, L, w.tileStart, w.tileEnd)
            w.features = features(w)
        }
    }

    // MARK: pixel positions

    /// Runs (>= 12 columns) of columns whose binarized rows 5..H-6 are uniform. The line image's channels are seen
    /// in the opposite order, as oneocr passes them.
    static func inkGaps(_ img: ImageU8) -> [(Int, Int)] {
        let w = img.width, h = img.height
        let bw = CV.adaptiveThresholdMeanInv(CV.bgrToGray(img, swapRB: true), w, h, block: 61, delta: 10)
        var gaps: [(Int, Int)] = []
        var start = 0
        for c in 0..<w {
            var uniform = true
            if h - 5 > 6 {
                for r in 6..<(h - 5) where bw[r * w + c] != bw[5 * w + c] {
                    uniform = false
                    break
                }
            }
            if !uniform {
                if c - start >= 12 { gaps.append((start, c)) }
                start = c + 1
            }
        }
        return gaps
    }

    /// Word frame ranges -> [x start, x end] in line image pixels.
    private static func wordPixels(_ cfg: CharModelConfig, _ frames: [(Int, Int)], _ T: Int, _ gaps: [(Int, Int)]) -> [(Int, Int)] {
        let ppf = cfg.ppf, pps = cfg.pps, ss = cfg.ss, es = cfg.es
        let order = frames.indices.sorted { frames[$0].0 < frames[$1].0 || (frames[$0].0 == frames[$1].0 && $0 < $1) }
        var box = [[Int]](repeating: [0, 0], count: frames.count)
        var gi = 0
        let last = order.count - 1
        for (k, wi) in order.enumerated() {
            let (sf, ef) = frames[wi]
            var xs = k > 0 ? box[order[k - 1]][1] : 0
            xs = max(xs, ss + sf * ppf)
            let cand = es + ef * ppf
            let limit = k == last ? (T - 1) * ppf : frames[order[k + 1]].0 * ppf - pps + ss
            let xe = max(min(cand, limit), xs + ppf)
            box[wi] = [xs, xe]
            if k > 0 {
                let pi = order[k - 1]
                var g0: Int?, g1 = 0
                while gi < gaps.count {
                    let (gs, ge) = gaps[gi]
                    if gs >= xs { break }
                    let mid = floorDiv(gs + ge, 2)
                    if box[pi][1] <= mid && mid <= xs {
                        if g0 == nil { g0 = gs }
                        g1 = ge
                    }
                    gi += 1
                }
                if let g0, g1 > 0, g0 > box[pi][0] + ppf, g1 < xe - ppf {
                    if g1 != g0 && Int(Double(xs - box[pi][1]) / Double(g1 - g0)) < 3 {
                        box[wi][0] = g1
                        box[pi][1] = g0
                    }
                }
            } else if gaps.isEmpty || gaps[0].0 > box[wi][0] {
                box[wi][0] = 0
            }
            if k == last && (gaps.isEmpty || gaps[gaps.count - 1].1 < box[wi][1]) { box[wi][1] = ppf * T }
        }
        return box.map { ($0[0], $0[1]) }
    }

    // MARK: RTL

    /// ConvertTextV2L + the word remap: ICU inverse BiDi (reordering mode 5, DO_MIRRORING) of the visual text and the
    /// words it maps to. Nil without ICU.
    private static func convertV2L(_ text: String, _ words: [RecognizedWord]) -> (String, [RecognizedWord])? {
        guard ICU.available else { return nil }
        let src = Array(text.utf16)
        let n = src.count
        var level: UInt8 = 0xFE
        for i in 0..<n where rtlBlocks.contains(ICU.blockCode(ICU.char32At(src, i))) {
            level = 0xFF
            break
        }
        guard let (out, vmap) = ICU.reorder(src, mode: 5, level: level, options: 2) else {
            func reversed(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.reversed())) }
            return (reversed(text), words.reversed().map { w in
                var w = w
                w.text = reversed(w.text)
                return w
            })
        }
        var widx: [Int] = [], woff: [Int] = []
        var wi = 0, ws = 0
        for i in 0..<n {
            if src[i] == 0x20 {
                wi += 1
                ws = i + 1
                widx.append(-1)
                woff.append(-1)
            } else {
                widx.append(wi)
                woff.append(i - ws)
            }
        }
        var outWords: [([UInt16], Int, Int, Int)] = []
        var cur: [UInt16] = [], cw = -1, offs: [Int] = []
        func flush() { if !offs.isEmpty { outWords.append((cur, cw, offs.min()!, offs.count)) } }
        for k in 0..<vmap.count {
            let ch: UInt16? = k < out.count ? out[k] : nil
            if ch == 0x20 {
                flush()
                cur = []
                cw = -1
                offs = []
                continue
            }
            let j = vmap[k]
            guard j >= 0 && j < n else { continue }
            if cw == -1 {
                cw = widx[j]
            } else if cw != widx[j] {
                flush()
                cur = []
                cw = widx[j]
                offs = []
            }
            offs.append(woff[j])
            if let ch { cur.append(ch) }
        }
        flush()
        var res: [RecognizedWord] = []
        for (t, wi, first, ln) in outWords where wi >= 0 && wi < words.count {
            let w = words[wi]
            var nw = w
            nw.text = String(decoding: t, as: UTF16.self)
            let units = w.chars.map { $0.text.utf16.count }
            let total = units.reduce(0, +)
            if !w.chars.isEmpty && (first, ln) != (0, total) {
                var pos = 0
                var a: Int?, b: Int?
                for (ci, u) in units.enumerated() {
                    if a == nil && pos + u > first { a = ci }
                    if pos < first + ln { b = ci }
                    pos += u
                }
                if let a, let b {
                    nw.startFrame = w.chars[a].startFrame
                    nw.endFrame = w.chars[b].endFrame
                }
            }
            res.append(nw)
        }
        return (String(decoding: out, as: UTF16.self), res)
    }

    // MARK: main entry

    /// The OCR mode name for a char model, when the line's mode has none.
    func resolveMode(_ charModel: String) -> String {
        let cmp = enums["ocr_mode_to_char_model_path"]!
        if cmp[charModel] == charModel { return charModel }
        return charModelModes.first { cmp[$0] == charModel } ?? charModel
    }

    func confRejName(_ mode: String) -> String {
        var path = enums["ocr_mode_to_conf_rej_path"]?[mode] ?? mode
        if !path.hasSuffix("Dummy") { path += "Dummy" }
        return path
    }

    func textScript(_ mode: String) -> String { enums["ocr_mode_to_text_script"]?[mode] ?? "Unknown" }

    /// Recognizes a 60-pixel-high BGR line image with the char model, in the OCR mode (by name).
    func recognize(_ image: ImageU8, charModel name: String, mode: String) throws -> RecognizedLine {
        let cm = try charModel(name)
        let cfg = cm.cfg, mp = cm.mapper
        let crName = confRejName(mode)
        let script = textScript(mode)
        let w = image.width, ppf = cfg.ppf
        let w2 = max(w + ppf - w % ppf, 16)
        let input = w2 != w ? CV.resizeLinear(image, w2, Normalizer.lineHeight) : image
        let (logp, T) = try cm.net.run(input)
        var cols = Self.sparse(cfg, mp.blank, logp, T, cm.net.classes)
        let (offsets, R, L) = Self.buildReduced(cfg, mp, &cols)
        let labels = Self.argmaxDecode(mp, cols, offsets)
        let segs = Self.segments(mp, labels)
        Self.segScores(mp, segs, R)

        let (rejWords, hasCJK, hasThai) = Self.splitWords(segs)
        let wordList = Self.chunk(rejWords, script == "Latin" ? 30 : nil)
        Self.tile(rejWords, T)
        Self.tile(wordList, T)
        Self.candidatesAndFeatures(mp, wordList, L)

        var line = RecognizedLine()
        let rawText = rejWords.filter { !$0.segs.isEmpty }.map(\.outText).joined(separator: " ")
        if enableRej {
            if wordList.isEmpty {
                line.rejected = true
            } else if let (rej, thr) = rejModels[crName] {
                var totW = 0
                var tot: Float = 0
                for w in wordList {
                    let p = rej.prob1(w.features)
                    var n = w.segs.count
                    if n > 1 && w.segs[0].tok.type == TokenType.punct && w.segs[1].tok.type == TokenType.punct { n = 1 }
                    totW += n
                    tot = Float(n) * p + tot
                }
                let score = Double(tot / Float(totW))
                if !(totW > 0 && score >= thr) { line.rejected = true }
            }
        }
        if line.rejected { return line }

        line.text = rawText
        let outWords = Self.splitCJK(rejWords, hasCJK, hasThai)
        Self.tile(outWords, T)
        Self.candidatesAndFeatures(mp, outWords, L)
        if enableConf, let (conf, _) = confModels[crName] {
            for w in outWords { w.conf = conf.prob1(w.features) }
        }
        var words = outWords.filter { !$0.segs.isEmpty }.map { w in
            RecognizedWord(text: w.outText, startFrame: w.segs[0].start, endFrame: w.segs.last!.end, confidence: w.conf,
                           chars: w.segs.map { ($0.tok.outText, $0.start, $0.end) })
        }
        if script == "Arabic" || script == "Hebrew", let (t, ws) = Self.convertV2L(line.text, words) {
            line.text = t
            words = ws
        }
        let boxes = Self.wordPixels(cfg, words.map { ($0.startFrame, $0.endFrame) }, T, Self.inkGaps(image))
        for i in words.indices { (words[i].start, words[i].end) = boxes[i] }
        line.words = words
        var num = 0.0, den = 0.0
        for wd in words {
            let k = wd.text.utf8.count
            num = Double(wd.confidence * Float(k)) + num
            den = Double(k) + den
        }
        line.confidence = num / (den < 1 ? 1 : den)
        return line
    }
}
