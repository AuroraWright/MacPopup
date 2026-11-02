import Foundation

// CTC beam search with a character n-gram LM and a class prior: google_ocr::CTCDecoder (+ CTCBeamOps) as
// GocrCTCDecoderRecognizer configures it for the scripts that ship an LM (arab, cyrl, deva, hani, jpan, knda, kore,
// mlym, taml, telu, thai). See ctc_decoder.h of the C++ port for the cost bookkeeping.

/// libc++ std::__nth_element (non-branchless sort3 and selection sort), for the order it leaves equal keys in.
func libcxxNthElement<T>(_ a: inout [T], _ first0: Int, _ nth: Int, _ last0: Int, _ comp: (T, T) -> Bool) {
    var first = first0, last = last0
    func sort3(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        if !comp(a[y], a[x]) {
            if !comp(a[z], a[y]) { return false }
            a.swapAt(y, z)
            if comp(a[y], a[x]) { a.swapAt(x, y) }
            return true
        }
        if comp(a[z], a[y]) {
            a.swapAt(x, z)
            return true
        }
        a.swapAt(x, y)
        if comp(a[z], a[y]) { a.swapAt(y, z) }
        return true
    }
    func selectionSort(_ f: Int, _ l: Int) {
        var first = f
        let lm1 = l - 1
        while first != lm1 {
            var m = first
            for i in (first + 1)..<l where comp(a[i], a[m]) { m = i }
            if m != first { a.swapAt(first, m) }
            first += 1
        }
    }
    let limit = 7
    while true {
        if nth == last { return }
        let len = last - first
        switch len {
        case 0, 1: return
        case 2:
            if comp(a[last - 1], a[first]) { a.swapAt(first, last - 1) }
            return
        case 3:
            _ = sort3(first, first + 1, last - 1)
            return
        default: break
        }
        if len <= limit {
            selectionSort(first, last)
            return
        }
        var m = first + len / 2
        let lm1 = last - 1
        var nSwaps = sort3(first, m, lm1) ? 1 : 0
        var i = first
        var j = lm1
        var restart = false
        if !comp(a[i], a[m]) {
            var foundGuard = false
            while true {
                j -= 1
                if i == j { break }
                if comp(a[j], a[m]) {
                    foundGuard = true
                    break
                }
            }
            if foundGuard {
                a.swapAt(i, j)
                nSwaps += 1
            } else {
                i += 1
                j = last
                j -= 1
                if !comp(a[first], a[j]) {
                    while true {
                        if i == j { return }
                        if comp(a[first], a[i]) {
                            a.swapAt(i, j)
                            nSwaps += 1
                            i += 1
                            break
                        }
                        i += 1
                    }
                }
                if i == j { return }
                while true {
                    while !comp(a[first], a[i]) { i += 1 }
                    repeat { j -= 1 } while comp(a[first], a[j])
                    if i >= j { break }
                    a.swapAt(i, j)
                    nSwaps += 1
                    i += 1
                }
                if nth < i { return }
                first = i
                restart = true
            }
        }
        if restart { continue }
        i += 1
        if i < j {
            while true {
                while comp(a[i], a[m]) { i += 1 }
                repeat { j -= 1 } while !comp(a[j], a[m])
                if i >= j { break }
                a.swapAt(i, j)
                nSwaps += 1
                if m == i { m = j }
                i += 1
            }
        }
        if i != m && comp(a[m], a[i]) {
            a.swapAt(i, m)
            nSwaps += 1
        }
        if nth == i { return }
        if nSwaps == 0 {
            var sorted = true
            if nth < i {
                j = first
                m = first
                while true {
                    j += 1
                    if j == i { break }
                    if comp(a[j], a[m]) {
                        sorted = false
                        break
                    }
                    m = j
                }
            } else {
                j = i
                m = i
                while true {
                    j += 1
                    if j == last { break }
                    if comp(a[j], a[m]) {
                        sorted = false
                        break
                    }
                    m = j
                }
            }
            if sorted { return }
        }
        if nth < i {
            last = i
        } else {
            i += 1
            first = i
        }
    }
}

/// tensorflow.TensorProto (DT_FLOAT) values.
private func parseFloatTensor(_ b: [UInt8]) -> [Float]? {
    var out: [Float] = []
    var r = ProtoReader(b)
    var dtype = 1
    func floats(_ c: ArraySlice<UInt8>) -> [Float] {
        let a = Array(c)
        return stride(from: 0, to: a.count - 3, by: 4).map {
            Float(bitPattern: UInt32(a[$0]) | UInt32(a[$0 + 1]) << 8 | UInt32(a[$0 + 2]) << 16 | UInt32(a[$0 + 3]) << 24)
        }
    }
    while r.next() {
        switch r.field {
        case 1: dtype = r.int
        case 4: out = floats(r.bytes)
        case 5:
            if r.wireType == .fixed32 { out.append(r.float32) } else if r.wireType == .len { out += floats(r.bytes) }
        default: break
        }
    }
    return r.ok && dtype == 1 ? out : nil
}

/// ocr::photo::SparseDequantizeBatch for one frame of uint8 logits: entries with q >= clamp(int(0.01 / scale +
/// zero_point), 0, 255), packed as (q << 16 | class); the k largest (libc++ nth_element, greater) as (class,
/// (q - zero_point) * scale); missing entries stay (0, 0).
func sparseDequantizeFrame(_ logits: UnsafePointer<UInt8>, _ numClasses: Int, _ zeroPoint: Int, _ scale: Float,
                           _ k: Int) -> [(id: Float, value: Float)] {
    var threshold = Int(0.01 / scale + Float(zeroPoint))
    threshold = min(max(threshold, 0), 255)
    var out = [(id: Float, value: Float)](repeating: (0, 0), count: k)
    var packed: [Int32] = []
    for c in 0..<numClasses where Int(logits[c]) >= threshold { packed.append(Int32(c) + (Int32(logits[c]) << 16)) }
    if k < packed.count { libcxxNthElement(&packed, 0, k - 1, packed.count, >) }
    for i in 0..<min(k, packed.count) {
        out[i] = (Float(packed[i] & 0xFFFF), Float(((Int(packed[i]) >> 16) & 0xFF) - zeroPoint) * scale)
    }
    return out
}

final class CTCBeamDecoder {
    struct Label {
        var label: Int
        var frame: Int
    }

    /// gocr_internal::BeamItemInfo: a class (label selection) or candidate index (pruning) with its cost.
    private struct Item {
        var id: Int
        var cost: Float
    }

    private struct BeamItem {
        var label: Int
        var state: Int
        var optical: Float, lm: Float, misc: Float, prior: Float
        var parent: Int
    }

    private var beamSize = 0, labelSelectionSize = 0
    private var beamWidth = 0.0, labelSelectionWidth = 0.0
    private var lmWeight: Float = 0
    private var insertionPenalty = 0.0, priorWeight = 0.0, blankCost = 0.0, selfLoopCost = 0.0
    private let blank: Int
    private let prior: [Float]
    private let lm: CharLanguageModel

    /// `configFile`: the recognizer's config in `dir` (e.g. "jpan_fst_config.pb").
    init(resources: Resources, dir: String, configFile: String) throws {
        guard let config = resources.read(dir + configFile) else { throw ScreenAIError("Missing \(configFile)") }
        var gocr: ArraySlice<UInt8> = []
        var r = ProtoReader(config)
        while r.next() {
            guard r.field == 2 else { continue }
            var any = ProtoReader(r.bytes)
            while any.next() {
                if any.field == 2 { gocr = any.bytes }
            }
        }
        var labelMapPath = "", lmFilename = "", lmSymbols = "", priorPath = ""
        var encodedPrior: [UInt8] = []
        var hasLm = false
        var rec: ArraySlice<UInt8> = []
        var g = ProtoReader(gocr)
        while g.next() {
            if g.field == 14 { labelMapPath = g.string }
            if g.field == 102 { rec = g.bytes }
        }
        var rr = ProtoReader(rec)
        while rr.next() {
            if rr.field == 9 { priorPath = rr.string }
            if rr.field == 8 { encodedPrior = Array(rr.bytes) }
            guard rr.field == 1 else { continue }
            var dc = ProtoReader(rr.bytes)  // CTCDecoderConfig
            while dc.next() {
                var m = ProtoReader(dc.bytes)
                switch dc.field {
                case 1:  // OcrLanguageModelSpec
                    while m.next() {
                        guard m.field == 7 else { continue }  // FstCharLanguageModelSpec
                        hasLm = true
                        var f = ProtoReader(m.bytes)
                        while f.next() {
                            if f.field == 1 { lmFilename = f.string }
                            if f.field == 2 { lmSymbols = f.string }
                        }
                    }
                case 2:  // BeamOptions
                    while m.next() {
                        switch m.field {
                        case 1: beamSize = m.int
                        case 2: beamWidth = m.float64
                        case 3: labelSelectionSize = m.int
                        case 4: labelSelectionWidth = m.float64
                        default: break
                        }
                    }
                case 3:  // CostOptions
                    while m.next() {
                        switch m.field {
                        case 1: lmWeight = Float(m.float64)
                        case 2: insertionPenalty = m.float64
                        case 3: priorWeight = m.float64
                        case 4: blankCost = m.float64
                        case 5: selfLoopCost = m.float64
                        default: break
                        }
                    }
                default: break
                }
            }
        }
        guard hasLm else { throw ScreenAIError("\(configFile) has no language model") }

        // The label map; blank = its size.
        guard let labelMap = resources.read(dir + labelMapPath) else { throw ScreenAIError("Missing \(labelMapPath)") }
        var labels: [Int: [UInt8]] = [:]
        var lr = ProtoReader(labelMap)
        while lr.next() {
            guard lr.field == 1 else { continue }
            var id = 0
            var name: [UInt8] = []
            var l = ProtoReader(lr.bytes)
            while l.next() {
                if l.field == 1 { name = Array(l.bytes) }
                if l.field == 2 { id = l.int }
            }
            if labels[id] == nil { labels[id] = name }
        }
        blank = labels.count
        // Log priors: encoded_prior or prior_path (tensorflow.TensorProto, num_classes + 1 values).
        guard let priorBytes = encodedPrior.isEmpty ? resources.read(dir + priorPath) : encodedPrior,
              let prior = parseFloatTensor(priorBytes), prior.count > blank
        else { throw ScreenAIError("Bad prior for \(configFile)") }
        self.prior = prior
        guard let fst = resources.read(dir + lmFilename), let syms = resources.read(dir + lmSymbols)
        else { throw ScreenAIError("Missing language model for \(configFile)") }
        lm = try CharLanguageModel(fst: fst, symbols: syms, labels: labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    /// CTCBeamOps::PruneIdCostPair / PartitionItems.
    private func prune(_ items: inout [Item], _ n: Int, _ width: Double) {
        guard !items.isEmpty else { return }
        var best = 0
        for i in 1..<items.count where items[i].cost < items[best].cost { best = i }
        var threshold = Float(width + Double(items[best].cost))
        let k = min(n - 1, items.count - 1)
        libcxxNthElement(&items, 0, k, items.count) { $0.cost < $1.cost }
        if items[k].cost <= threshold { threshold = items[k].cost }
        // std::stable_partition, then at most n
        let kept = items.filter { $0.cost <= threshold }
        items = Array(kept.prefix(n))
        items.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.id < $1.id }
    }

    /// CTCBeamOps::ExpandAndPruneBeam + PruneBeam.
    private func expand(_ beam: [BeamItem], _ labels: [Item]) -> [BeamItem] {
        var cand: [BeamItem] = []
        cand.reserveCapacity(beam.count * labels.count)
        for (b, item) in beam.enumerated() {
            let classes = labels.filter { $0.id != blank && $0.id != item.label }.map(\.id)
            let lmCosts = lm.costs(classes, item.state)
            var li = 0
            for l in labels {
                var e = item
                e.optical = l.cost + item.optical
                e.parent = b
                if l.id == blank {
                    e.misc = Float(blankCost + Double(e.misc))
                } else if l.id == item.label {
                    e.misc = Float(selfLoopCost + Double(e.misc))
                } else {
                    let (cost, state) = lmCosts[li]
                    li += 1
                    e.lm = Float(cost * Double(lmWeight) + Double(e.lm))
                    e.state = state
                    if l.id != lm.eosClass {
                        e.misc = Float(insertionPenalty + Double(e.misc))
                        e.prior = Float(priorWeight * Double(prior[l.id]) + Double(e.prior))
                    }
                }
                e.label = l.id
                cand.append(e)
            }
        }
        var infos = cand.indices.map { Item(id: $0, cost: ((cand[$0].optical + cand[$0].lm) + cand[$0].misc) + cand[$0].prior) }
        prune(&infos, beamSize, beamWidth)
        var next: [BeamItem] = []
        for it in infos {
            let e = cand[it.id]
            // std::unique on (label, LM history)
            if let last = next.last, last.label == e.label && last.state == e.state { continue }
            next.append(e)
        }
        return next
    }

    /// CTCDecoder::DecodeNth for one line: per frame, the top-k (class id, logit).
    func decode(frames: Int, k: Int, ids: [Float], values: [Float]) -> [Label] {
        var beams = [[BeamItem]](repeating: [], count: max(frames, -2) + 2)
        beams[0].append(BeamItem(label: blank, state: lm.bosState, optical: 0, lm: 0, misc: 0, prior: 0, parent: -1))
        for t in 0..<frames {
            var items = (0..<k).map { j in
                Item(id: Int(Int64(rintf(ids[t * k + j]))), cost: -values[t * k + j])
            }
            prune(&items, labelSelectionSize, labelSelectionWidth)
            beams[t + 1] = expand(beams[t], items)
        }
        beams[frames + 1] = expand(beams[frames], [Item(id: lm.eosClass, cost: 0)])

        // GenerateOutput
        var last = frames
        for i in 0..<min(frames + 3, beams.count) where beams[i].isEmpty {
            last = i - 2
            break
        }
        if last <= 0 { return [] }
        var path: [BeamItem] = []
        var cur = beams[last + 1][0]
        for v in stride(from: last, through: 1, by: -1) {
            cur = beams[v][cur.parent]
            path.append(cur)
        }
        path.reverse()
        var out: [Label] = []
        var prev: Float = 0
        if path[0].label != blank && path[0].label != -1 {
            out.append(Label(label: path[0].label, frame: 0))
            prev = path[0].optical
        }
        for k in 1..<path.count {
            let p = path[k - 1], c = path[k]
            if c.label == blank { continue }
            let d = Double(c.optical) - Double(p.optical)
            if p.label == c.label {
                if d >= Double(prev) || out.isEmpty { continue }
                out[out.count - 1].frame = k
            } else {
                out.append(Label(label: c.label, frame: k))
            }
            prev = Float(d)
        }
        return out
    }
}
