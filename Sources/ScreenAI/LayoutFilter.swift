import Foundation

// The first steps of the original's layout analysis (PageLayoutAnalysisMutator), which drop what the recognizer read
// out of things that aren't text: the mutator's detection confidence pre-step, ConfidenceFilter (lines unlikely to be
// text), RemoveOverlapsWordPruning (lines and words read again out of a part of another line), FillSymbolGaps (see
// LayoutSymbolGaps.swift), then RemoveOverlappingWithCurvedBoxes (the same for curved lines). The reading order and
// line merging follow (LayoutClusterSort.swift, LayoutLines.swift).

extension PageLayout {
    /// Each entity's children, in index order.
    func childLists() -> [[Int]] {
        var children = [[Int]](repeating: [], count: entities.count)
        for i in entities.indices {
            let p = entities[i].parent
            if p >= 0 && p < entities.count { children[p].append(i) }
        }
        return children
    }

    /// PageLayout::Descendants(e): level order below `e` (excluded), or from the roots without one.
    func descendants(of e: Int? = nil, _ children: [[Int]]) -> [Int] {
        var out = e.map { children[$0] } ?? entities.indices.filter { entities[$0].parent < 0 || entities[$0].parent >= entities.count }
        var k = 0
        while k < out.count {
            out += children[out[k]]
            k += 1
        }
        return out
    }

    /// goodoc::PageLayout::Text: an entity's own text, or its children's joined (words by their breaks: nothing,
    /// "-" for a soft hyphen, else a space), without trailing whitespace. A line's text is always rebuilt from its
    /// words, as the analysis' last step does, so it leaves out the words the steps above removed.
    func text(of e: Int, _ children: [[Int]], ownText: Bool = true) -> String {
        if ownText, let t = entities[e].text, !t.isEmpty { return t }
        var out = ""
        for c in children[e] {
            let t = text(of: c, children)
            if t.isEmpty { continue }
            out += t
            switch entities[c].type {
            case .paragraph, .block: out += "\n"
            case .line: out += " "
            case .symbol: break
            case .word:
                switch entities[c].wordBreak?.type ?? 0 {
                case 1: break
                case 4: out += "-"
                default: out += " "
                }
            }
        }
        var bytes = Array(out.utf8)
        while let last = bytes.last, last == 0x20 || last == 0x09 || last == 0x0A { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Keeps the entities in `order` (each index once), with parents renumbered (-1 where the parent isn't kept).
    /// Returns each old index's new one (-1 for those dropped).
    @discardableResult
    mutating func reorder(_ order: [Int]) -> [Int] {
        var newIndex = [Int](repeating: -1, count: entities.count)
        for (k, i) in order.enumerated() { newIndex[i] = k }
        if order.count == entities.count {
            // The same result, copying only the entities that move.
            let moved = order.indices.filter { order[$0] != $0 }
            let movers = moved.map { entities[order[$0]] }
            for (k, i) in moved.enumerated() { entities[i] = movers[k] }
            for i in entities.indices {
                let p = entities[i].parent
                if p < 0 { continue }
                let q = p < newIndex.count ? newIndex[p] : -1
                if q != p { entities[i].parent = q }
            }
            return newIndex
        }
        entities = order.map { i in
            var e = entities[i]
            if e.parent >= 0 { e.parent = e.parent < newIndex.count ? newIndex[e.parent] : -1 }
            return e
        }
        return newIndex
    }

    /// Removes the marked entities and everything below them, keeping the order of the rest (see `reorder`).
    @discardableResult
    mutating func deleteWithDescendants(_ marked: [Bool]) -> [Int] {
        let children = childLists()
        var delete = marked
        for i in entities.indices where marked[i] {
            for d in descendants(of: i, children) { delete[d] = true }
        }
        return reorder(entities.indices.filter { !delete[$0] })
    }

    /// ReorderUsingDFS: the roots and everything below them in preorder (children in index order).
    @discardableResult
    mutating func reorderUsingDfs() -> [Int] {
        let children = childLists()
        var order: [Int] = []
        var stack = entities.indices.reversed().filter { entities[$0].parent < 0 || entities[$0].parent >= entities.count }
        while let e = stack.popLast() {
            order.append(e)
            stack += children[e].reversed()
        }
        return reorder(order)
    }

    /// The mutator's pre-step: a line's detection confidence is the mean score of the detector's raw boxes behind it
    /// (NaN without any, which ConfidenceFilter then drops).
    mutating func setDetectionConfidence() {
        for i in entities.indices where entities[i].type == .line {
            if let d = entities[i].detection {
                entities[i].detectionConfidence = d.sumRawBoxesScores / Float(d.numRawBoxes)
            } else {
                entities[i].detectionConfidence = nil
            }
        }
    }

    /// ConfidenceFilter: drops lines without words or recognizer confidence, and detected lines whose score (a
    /// logistic regression over the recognizer's confidence, the detector's, its garbage probability and the
    /// direction confidence) is under the threshold.
    mutating func confidenceFilter() {
        let wRec: Float = 3.1155417, wDet: Float = 7.5824437, wGarbage: Float = -8.527104, wDir: Float = 3.6975038
        let bias: Float = -8.170908
        let threshold = -logf(1 / Float(0.45) - 1)
        var hasWord = [Bool](repeating: false, count: entities.count)
        for e in entities where e.type == .word && e.parent >= 0 && e.parent < entities.count { hasWord[e.parent] = true }
        var delete = [Bool](repeating: false, count: entities.count)
        for (i, e) in entities.enumerated() where e.type == .line {
            let rec = e.confidence ?? 0
            if rec == 0 || !hasWord[i] {
                delete[i] = true
                continue
            }
            guard let d = e.detection else { continue }
            let garbage = d.garbageProb ?? 0
            let score = bias + (((rec * wRec + garbage * wGarbage) + (e.detectionConfidence ?? 0) * wDet)
                + (e.directionConfidence ?? 0) * wDir)
            if !(score >= threshold) { delete[i] = true }
        }
        deleteWithDescendants(delete)
    }

    // MARK: RemoveOverlapsWordPruning

    private struct LineWords {
        var line: Int
        var words: [Int]
        /// Symbols with a confidence, per word.
        var counts: [Int]
    }

    /// RemoveOverlapsWordPruning: sets word and line confidences from their symbols, then, from the most confident
    /// line down, settles each pair of overlapping lines: a line that covers another in a different direction and has
    /// less support (summed confidence) is removed, of two lines covering the same area the one with less support,
    /// and otherwise the words of the line with less support that the other line's words cover (lines left without
    /// confidence are removed).
    mutating func pruneOverlappingWords() {
        let children = childLists()
        var lines: [LineWords] = []
        var order: [(total: Float, index: Int)] = []
        for li in descendants(children) where entities[li].type == .line {
            let words = descendants(of: li, children).filter { entities[$0].type == .word }
            var counts: [Int] = []
            var total = 0.0, totalCount = 0
            for wi in words {
                var count = 0
                var sum = 0.0
                for si in descendants(of: wi, children) where entities[si].type == .symbol {
                    if let c = entities[si].confidence {
                        count += 1
                        sum = sum + Double(c)
                    }
                }
                entities[wi].confidence = count <= 0 ? 0 : Float(sum / Double(count))
                counts.append(count)
                total = total + sum
                totalCount += count
            }
            entities[li].confidence = total > 0 ? Float(total / Double(totalCount)) : 0
            order.append((Float(total), lines.count))
            lines.append(LineWords(line: li, words: words, counts: counts))
        }
        order.sort { $0.total != $1.total ? $0.total > $1.total : $0.index > $1.index }
        pruneOverlappingLines(lines, order)
    }

    /// CopyBoundingBox<goodoc::RotatedBoundingBox, Box<float>>.
    private static func floatBox(_ b: RotatedBox?) -> RBox {
        let b = b ?? RotatedBox()
        return RBox(x: Float(b.left), y: Float(b.top), w: Float(b.width), h: Float(b.height), angle: normalizeAngle(b.angle))
    }

    /// The overlaps of each box with the others, in index order of the others.
    private static func overlapsByBox(_ boxes: [RBox], split: Int) -> [[(other: Int, info: OverlapInfo)]] {
        var out = [[(other: Int, info: OverlapInfo)]](repeating: [], count: boxes.count)
        for (pair, info) in computeOverlaps(boxes, split: split) { out[pair.a].append((pair.b, info)) }
        for i in out.indices { out[i].sort { $0.other < $1.other } }
        return out
    }

    /// CommonCharsPortion(a, b): whether they're equal, and the share of b's bytes (with multiplicity) also in a.
    private static func commonCharsPortion(_ a: String, _ b: String) -> (exact: Bool, portion: Float) {
        let a = Array(a.utf8), b = Array(b.utf8)
        if a == b { return (true, 1) }
        var count = [Int](repeating: 0, count: 256)
        for c in b { count[Int(c)] += 1 }
        for c in a { count[Int(c)] -= 1 }
        let missing = count.reduce(0) { $0 + max($1, 0) }
        return (false, 1 - Float(missing) / Float(max(b.count, 1)))
    }

    private func support(_ lw: LineWords, _ li: Int, _ pruned: Set<IndexPair>) -> Float {
        var sup: Float = 0
        for k in lw.words.indices where !pruned.contains(IndexPair(a: li, b: k)) {
            sup = sup + (entities[lw.words[k]].confidence ?? 0) * Float(lw.counts[k])
        }
        return sup
    }

    private mutating func recomputeLineConfidence(_ lw: LineWords, _ li: Int, _ pruned: Set<IndexPair>) {
        var sum = 0.0, count = 0
        for k in lw.words.indices where !pruned.contains(IndexPair(a: li, b: k)) {
            sum = sum + Double((entities[lw.words[k]].confidence ?? 0) * Float(lw.counts[k]))
            count += lw.counts[k]
        }
        entities[lw.line].confidence = count > 0 ? Float(sum / Double(count)) : 0
    }

    /// DoPruneOverlap: marks the words of line `pi` that words of line `oi` cover.
    private func pruneOverlap(_ lines: [LineWords], other oi: Int, prune pi: Int, wordOverlap: Double, confDiff: Double,
                              _ pruned: inout Set<IndexPair>) {
        let exactMatch: Float = 0.5, commonChars: Float = 0.6
        let p = lines[pi], o = lines[oi]
        let boxes = (p.words + o.words).map { Self.floatBox(entities[$0].box) }
        let n = p.words.count
        let overlaps = Self.overlapsByBox(boxes, split: n)
        for a in 0..<n where !pruned.contains(IndexPair(a: pi, b: a)) {
            let w = entities[p.words[a]]
            for (other, info) in overlaps[a] {
                let b = other - n
                if pruned.contains(IndexPair(a: oi, b: b)) { continue }
                let ow = entities[o.words[b]]
                let ov = info.overFirst
                if Double(exactMatch) >= Double(ov) && wordOverlap >= Double(ov) { continue }
                let (exact, portion) = Self.commonCharsPortion(ow.text ?? "", w.text ?? "")
                let exactTest = exactMatch < ov && exact
                let prune: Bool
                if wordOverlap >= Double(ov) {
                    prune = exactTest
                } else {
                    let keep = confDiff <= Double((w.confidence ?? 0) - (ow.confidence ?? 0)) && commonChars > portion
                    prune = !keep || exactTest
                }
                if prune { pruned.insert(IndexPair(a: pi, b: a)) }
            }
        }
    }

    private mutating func pruneOverlappingLines(_ lines: [LineWords], _ order: [(total: Float, index: Int)]) {
        let iouThreshold = Double(Float(0.6)), overlapThreshold = Double(Float(0.6))
        let overlaps = Self.overlapsByBox(lines.map { Self.floatBox(entities[$0.line].box) }, split: -1)
        var removed = Set<Int>()
        var pruned = Set<IndexPair>()
        var processed = Set<IndexPair>()
        // Curved lines neither prune nor get pruned.
        let curved = lines.map { entities[$0.line].box?.curve != nil }
        for (_, i) in order {
            if removed.contains(i) || curved[i] { continue }
            let ei = entities[lines[i].line]
            var covered: [(j: Int, type: Int)] = []
            for (j, o) in overlaps[i] {
                if removed.contains(j) || curved[j] { continue }
                let ej = entities[lines[j].line]
                let sameOrientation = (ei.orientation ?? 0) == (ej.orientation ?? 0)
                let sameDirection = (ei.writingDirection ?? 0) == (ej.writingDirection ?? 0)
                let same = (ei.writingDirection ?? 0) == 2 || (ej.writingDirection ?? 0) == 2
                    ? sameOrientation && sameDirection : sameOrientation
                var type = 0
                if same {
                    if o.iou > 0.95 { type = 2 }
                    else if o.overFirst > 0.95 { type = 6 }
                    else if o.overSecond > 0.95 { type = 9 }
                    else if iouThreshold < Double(o.iou) { type = 1 }
                    else if overlapThreshold < Double(o.overFirst) { type = 5 }
                    else if overlapThreshold < Double(o.overSecond) { type = 8 }
                } else {
                    if o.iou > 0.95 { type = 3 }
                    else if o.overFirst > 0.95 { type = 7 }
                    else if o.overSecond > 0.95 { type = 10 }
                    else if iouThreshold < Double(o.iou) { type = 4 }
                    else if overlapThreshold < Double(o.overSecond) { type = 8 }
                }
                if type != 0 { covered.append((j, type)) }
            }
            if covered.isEmpty { continue }
            let supI = support(lines[i], i, pruned)
            var sup: [Int: Float] = [:]
            for (j, _) in covered {
                if removed.contains(j) || removed.contains(i) { continue }
                if !processed.insert(IndexPair(a: min(i, j), b: max(i, j))).inserted { continue }
                sup[j] = support(lines[j], j, pruned)
            }
            for (j, type) in covered {
                guard let supJ = sup[j] else { continue }
                if type == 7 && supJ > supI {
                    removed.insert(i)
                    continue
                }
                if type & ~1 == 2 {
                    let a = entities[lines[i].line], b = entities[lines[j].line]
                    if supI == supJ {
                        removed.insert((a.directionConfidence ?? 0) >= (b.directionConfidence ?? 0) ? j : i)
                    } else {
                        removed.insert(supJ <= supI ? j : i)
                    }
                    continue
                }
                let complete = (0x6D0 >> type) & 1 != 0
                let wordOverlap = complete ? Double(Float(0.1)) : 0.5
                let confDiff = complete ? Double(Float(0.2)) : Double(Float(0.05))
                let prune = supI <= supJ ? i : j, other = prune == i ? j : i
                pruneOverlap(lines, other: other, prune: prune, wordOverlap: wordOverlap, confDiff: confDiff, &pruned)
                recomputeLineConfidence(lines[prune], prune, pruned)
                if (entities[lines[prune].line].confidence ?? 0) == 0 { removed.insert(prune) }
            }
        }
        if removed.isEmpty && pruned.isEmpty { return }
        var delete = [Bool](repeating: false, count: entities.count)
        for i in removed { delete[lines[i].line] = true }
        for p in pruned { delete[lines[p.a].words[p.b]] = true }
        deleteWithDescendants(delete)
        deleteTextEntitiesWithNoSymbols()
    }

    /// DeleteTextEntitiesWithNoSymbols: bottom-up, text entities other than symbols left without children are deleted.
    @discardableResult
    mutating func deleteTextEntitiesWithNoSymbols() -> [Int] {
        let children = childLists()
        var delete = [Bool](repeating: false, count: entities.count)
        for i in descendants(children).reversed() {
            let e = entities[i]
            if (e.contentType ?? 0) > 1 || e.type.rawValue > 4 || e.type.rawValue == 1 { continue }
            if children[i].allSatisfy({ delete[$0] }) { delete[i] = true }
        }
        return deleteWithDescendants(delete)
    }

    // MARK: RemoveOverlappingWithCurvedBoxes

    /// Sum of the symbol box areas of a line.
    private func lineSymbolsArea(_ line: Int, _ children: [[Int]]) -> Double {
        var area = 0.0
        for s in descendants(of: line, children) where entities[s].type == .symbol {
            let b = Self.floatBox(entities[s].box)
            area = area + Double(b.w * b.h)
        }
        return area
    }

    /// How much the symbols of word `wa` overlap those of word `wb` (summed over the pairs, in wa's symbol areas).
    private func symbolsOverlapArea(_ wa: Int, _ wb: Int, _ children: [[Int]]) -> Double {
        let sa = descendants(of: wa, children).filter { entities[$0].type == .symbol }
        let sb = descendants(of: wb, children).filter { entities[$0].type == .symbol }
        let overlaps = Self.overlapsByBox((sa + sb).map { Self.floatBox(entities[$0].box) }, split: sa.count)
        var area = 0.0
        for k in sa.indices {
            let b = entities[sa[k]].box ?? RotatedBox()
            let ak = Float(b.height * b.width)
            for (_, info) in overlaps[k] { area = area + Double(info.overFirst * ak) }
        }
        return area
    }

    /// RemoveOverlappingWithCurvedBoxes: curved lines, best (confidence + direction confidence / 100) × symbols
    /// first, against every line after them in that order: the words whose symbols overlap are marked, and a line
    /// whose symbols overlap by more than 0.3 of the smaller line's symbol area is removed (a straight one only by its
    /// marked words, unless they're all marked).
    mutating func removeOverlapsWithCurvedLines() {
        let threshold = 0.3
        let children = childLists()
        let lines = descendants(children).filter { entities[$0].type == .line }
        let n = lines.count
        var order: [(score: Float, index: Int)] = []
        var curvedCount = 0
        for (i, li) in lines.enumerated() {
            let e = entities[li]
            var score: Float = 0
            if e.box?.curve != nil {
                let symbols = descendants(of: li, children).filter { entities[$0].type == .symbol }.count
                score = Float((Double(e.directionConfidence ?? 0) * 0.01 + Double(e.confidence ?? 0)) * Double(symbols))
                curvedCount += 1
            }
            order.append((score, i))
        }
        if curvedCount == 0 { return }
        order.sort { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }
        let overlaps = computeOverlaps(lines.map { Self.floatBox(entities[$0].box) }, split: -1)
        var removed = [Bool](repeating: false, count: n)
        var marks = [[Bool]](repeating: [], count: n)
        var removedCount = 0
        for a in 0..<curvedCount {
            let ia = order[a].index
            if removed[ia] || a + 1 >= n { continue }
            for b in (a + 1)..<n {
                let ib = order[b].index
                guard let o = overlaps[IndexPair(a: ia, b: ib)], o.overFirst != 0 else { continue }
                let wa = descendants(of: lines[ia], children).filter { entities[$0].type == .word }
                let wb = descendants(of: lines[ib], children).filter { entities[$0].type == .word }
                if marks[ib].isEmpty { marks[ib] = [Bool](repeating: false, count: wb.count) }
                let wordOverlaps = Self.overlapsByBox((wa + wb).map { Self.floatBox(entities[$0].box) }, split: wa.count)
                var total = 0.0
                for k in wa.indices {
                    for (other, _) in wordOverlaps[k] {
                        let j = other - wa.count
                        let area = symbolsOverlapArea(wa[k], wb[j], children)
                        total = total + area
                        if area > 0 { marks[ib][j] = true }
                    }
                }
                let areaA = lineSymbolsArea(lines[ia], children), areaB = lineSymbolsArea(lines[ib], children)
                var smaller = areaB >= areaA ? areaA : areaB
                if smaller < 0.0001 { smaller = 0.0001 }
                if threshold < total / smaller {
                    removed[ib] = true
                    removedCount += 1
                }
            }
        }
        if removedCount == 0 { return }
        var delete = [Bool](repeating: false, count: entities.count)
        var recompute = false
        for i in 0..<n where removed[i] {
            if entities[lines[i]].box?.curve != nil || marks[i].allSatisfy({ $0 }) {
                delete[lines[i]] = true
                continue
            }
            let words = descendants(of: lines[i], children).filter { entities[$0].type == .word }
            for k in words.indices where marks[i][k] { delete[words[k]] = true }
            recompute = true
        }
        deleteWithDescendants(delete)
        deleteTextEntitiesWithNoSymbols()
        if recompute {
            recomputeBoxesFromSymbols()
            recomputeWordTexts()
            recomputeConfidencesFromSymbols()
        }
    }

    /// goodoc::RecomputeWordTextContentFromSymbols: a word's text is its symbols' texts joined.
    private mutating func recomputeWordTexts() {
        let children = childLists()
        for i in entities.indices where entities[i].type == .word {
            entities[i].text = descendants(of: i, children).filter { entities[$0].type == .symbol }
                .map { entities[$0].text ?? "" }.joined()
        }
    }

    /// goodoc::RecomputeConfidenceFromDescendants from the roots: each entity's confidence is the mean of the
    /// confidences of the leaves below it.
    mutating func recomputeConfidencesFromSymbols() {
        let children = childLists()
        for i in entities.indices where entities[i].parent < 0 || entities[i].parent >= entities.count {
            recomputeConfidence(i, children)
        }
    }

    /// goodoc::RecomputeConfidenceFromDescendants(e): the mean of the leaves' confidences, set on `e` and the
    /// entities below it. Returns the number of leaves with a confidence and their sum.
    @discardableResult
    mutating func recomputeConfidence(_ e: Int, _ children: [[Int]]) -> (count: Int, sum: Double) {
        var n = 0, sum = 0.0
        for c in children[e] {
            let r = recomputeConfidence(c, children)
            n += r.count
            sum = sum + r.sum
        }
        if n < 1 { return entities[e].confidence.map { (1, Double($0)) } ?? (0, 0) }
        entities[e].confidence = Float(sum / Double(n))
        return (n, sum)
    }
}
