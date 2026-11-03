import Foundation

// The layout analysis' EstimateLines step with the shipped config (a MergeLinesSpec: adjacent lines only, depth gap
// up to 2.5 symbols): in each paragraph, a line that continues the one before it (same thickness and angle, mostly
// level with it, close behind it) is merged into it, its words moving over in reading order. Then the analysis'
// last step sets each line's text from its words.

private let minBreadthRatio = 0.6
private let maxAngleDifference = 3.0
private let minBreadthOverlap = 0.6
private let maxDepthGap = 2.5
private let degToRadDouble = 0.017453292519943295

/// goodoc orientation of an entity: page orientation, writing direction, textline order.
private struct OrientationLabel: Hashable, Comparable {
    var orientation = 0, writingDirection = 0, textlineOrder = 0

    static func < (a: Self, b: Self) -> Bool {
        (a.orientation, a.writingDirection, a.textlineOrder) < (b.orientation, b.writingDirection, b.textlineOrder)
    }
}

/// page_layout_utils::Thickness / LineLength: the extent across / along the writing direction.
private func thickness(_ b: RotatedBox, _ wd: Int) -> Int { wd == 2 ? b.width : b.height }
private func lineLength(_ b: RotatedBox, _ wd: Int) -> Int { wd == 2 ? b.height : b.width }

/// page_layout_utils::StartCoordinate / StartTextlineCoordinate: where the box starts along direction `d` (writing
/// direction or textline order) for page orientation `o`.
private func startCoordinate(_ b: RotatedBox, _ o: Int, _ d: Int) -> Int {
    let h2 = Double(b.height) / 2, w2 = Double(b.width) / 2, left = Double(b.left), top = Double(b.top)
    let a = b.angle
    func sc() -> (sin: Double, cos: Double) { sinCos(Double(a) * degToRadDouble) }
    func fromLeft() -> Int {
        if a == 0 { return Int(left) }
        let t = h2 == 0 ? 0 : sc().sin * h2
        return Int((left - t).rounded(.toNearestOrAwayFromZero))
    }
    func fromRight() -> Int {
        if a == 0 { return Int(Double(b.width) + left) }
        let r = sc()
        let v = (b.width == 0 ? -0.0 : r.cos * Double(b.width)) + left
        return Int((h2 == 0 ? v : v - r.sin * h2).rounded(.toNearestOrAwayFromZero))
    }
    func fromTop() -> Int {
        if a == 0 { return Int(top) }
        let t = w2 == 0 ? -0.0 : sc().sin * w2
        return Int((t + top).rounded(.toNearestOrAwayFromZero))
    }
    if o == 0 { return d == 0 ? fromLeft() : d == 1 ? fromRight() : fromTop() }
    if d == 1 {
        if o == 2 { return fromRight() }
        if a == 0 { return Int(h2 + top) }
        let r = sc()
        var v = (b.width == 0 ? -0.0 : r.sin * Double(b.width)) + top
        if h2 != 0 { v = h2 * r.cos + v }
        return Int(v.rounded(.toNearestOrAwayFromZero))
    }
    if o == 2 { return d == 0 ? fromLeft() : fromTop() }
    let v4 = d != 0 ? w2 : h2, v6 = d != 0 ? left : top
    if a == 0 { return Int(v4 + v6) }
    let t = v4 == 0 ? -0.0 : v4 * sc().cos
    return Int((t + v6).rounded(.toNearestOrAwayFromZero))
}

/// page_layout_utils::EndCoordinate / EndTextlineCoordinate.
private func endCoordinate(_ b: RotatedBox, _ o: Int, _ d: Int) -> Int {
    let h2 = Double(b.height) / 2, w2 = Double(b.width) / 2, left = Double(b.left), top = Double(b.top)
    let a = b.angle
    func sc() -> (sin: Double, cos: Double) { sinCos(Double(a) * degToRadDouble) }
    func atLeft() -> Int {
        if a == 0 { return Int(left) }
        let t = h2 == 0 ? 0 : sc().sin * h2
        return Int((left - t).rounded(.toNearestOrAwayFromZero))
    }
    func atRight() -> Int {
        if a == 0 { return Int(Double(b.width) + left) }
        let r = sc()
        let v = (b.width == 0 ? -0.0 : r.cos * Double(b.width)) + left
        return Int((h2 == 0 ? v : v - r.sin * h2).rounded(.toNearestOrAwayFromZero))
    }
    func atBottom() -> Int {
        if a == 0 { return Int(Double(b.height) + top) }
        let r = sc()
        var v = (w2 == 0 ? -0.0 : r.sin * w2) + top
        if b.height != 0 { v = r.cos * Double(b.height) + v }
        return Int(v.rounded(.toNearestOrAwayFromZero))
    }
    if o == 0 { return d == 0 ? atRight() : d == 1 ? atLeft() : atBottom() }
    if d == 1 {
        if o == 2 { return atLeft() }
        if a == 0 { return Int(h2 + top) }
        let t = h2 == 0 ? -0.0 : h2 * sc().cos
        return Int((t + top).rounded(.toNearestOrAwayFromZero))
    }
    if d != 0 {
        if o == 2 { return atBottom() }
        if a == 0 { return Int(w2 + left) }
        let r = sc()
        let v = (w2 == 0 ? -0.0 : w2 * r.cos) + left
        return Int((b.height == 0 ? v : v - r.sin * Double(b.height)).rounded(.toNearestOrAwayFromZero))
    }
    if o == 2 { return atRight() }
    if a == 0 { return Int(h2 + top) }
    let r = sc()
    var v = (b.width == 0 ? -0.0 : r.sin * Double(b.width)) + top
    if h2 != 0 { v = h2 * r.cos + v }
    return Int(v.rounded(.toNearestOrAwayFromZero))
}

private struct ReadingOrderKey {
    var start = 0, end = 0, textlineStart = 0, textlineEnd = 0
}

/// CompareByReadingOrder: `a` before `b` along the writing direction, then the textline order.
private func readingOrderLess(_ rtl: Bool, _ a: ReadingOrderKey, _ b: ReadingOrderKey) -> Bool {
    // Both boxes run against the expected direction.
    var flip = rtl ? a.start < a.end && b.start < b.end : a.start > a.end && b.start > b.end
    var x = a.start, y = b.start
    if x == y {
        flip = rtl ? a.textlineStart < a.textlineEnd && b.textlineStart < b.textlineEnd
            : a.textlineStart > a.textlineEnd && b.textlineStart > b.textlineEnd
        x = a.textlineStart
        y = b.textlineStart
    }
    let lt = flip ? x < y : y < x, gt = flip ? y < x : x < y
    return rtl ? lt : gt
}

/// Entity indices that follow the layout through reorders and deletions (-1 once deleted).
private struct EntityRefs {
    var at: [Int] = []

    mutating func add(_ e: Int) -> Int {
        at.append(e)
        return at.count - 1
    }

    mutating func apply(_ remap: [Int]) {
        at = at.map { $0 >= 0 ? remap[$0] : -1 }
    }
}

extension PageLayout {
    /// PageLayout::Orientation(e): from the nearest entity (e or an ancestor) with an orientation.
    private func orientationLabel(_ e: Int) -> OrientationLabel {
        var i = e, guardCount = 0
        while i >= 0 && i < entities.count && guardCount < 64 {
            let x = entities[i]
            if x.orientation != nil || x.writingDirection != nil || x.textlineOrder != nil {
                return OrientationLabel(orientation: x.orientation ?? 0, writingDirection: x.writingDirection ?? 0,
                                        textlineOrder: x.textlineOrder ?? 0)
            }
            i = x.parent
            guardCount += 1
        }
        return OrientationLabel()
    }

    private func entityThickness(_ e: Int) -> Int {
        thickness(entities[e].box ?? RotatedBox(), orientationLabel(e).writingDirection)
    }

    private func entityLineLength(_ e: Int) -> Int {
        lineLength(entities[e].box ?? RotatedBox(), orientationLabel(e).writingDirection)
    }

    private func readingOrderKey(_ e: Int) -> ReadingOrderKey {
        let b = entities[e].box ?? RotatedBox()
        let o = orientationLabel(e)
        return ReadingOrderKey(start: startCoordinate(b, o.orientation, o.writingDirection),
                               end: endCoordinate(b, o.orientation, o.writingDirection),
                               textlineStart: startCoordinate(b, o.orientation, o.textlineOrder),
                               textlineEnd: endCoordinate(b, o.orientation, o.textlineOrder))
    }

    /// ComputeSymbolMetrics: the mean symbol length along the writing direction over the words below `e`.
    private func meanSymbolLength(_ e: Int, _ children: [[Int]]) -> Double {
        var sum = 0.0
        var n = 0
        for w in descendants(of: e, children) where entities[w].type == .word {
            let symbols = descendants(of: w, children).filter { entities[$0].type == .symbol }
            n += symbols.count
            if !symbols.contains(where: { entities[$0].box != nil }) {
                // Estimated from the word (then the symbols are still measured, as in the original).
                let t = entityThickness(w)
                let math = (entities[w].contentType ?? 0) & ~1 == 6
                sum = sum + (math ? Double((UInt64(symbols.count) &* UInt64(bitPattern: Int64(t))) >> 1)
                                  : Double(entityLineLength(w)))
                if symbols.isEmpty { continue }
            }
            for s in symbols { sum = sum + Double(entityLineLength(s)) }
        }
        return n > 0 ? sum / Double(n) : 0
    }

    private static func rotatedBoxOnly(_ e: Entity) -> RotatedBox {
        if let b = e.box, b.curve == nil { return b }
        return RotatedBox()
    }

    /// MergeLinesStep::ShouldMerge(src, tgt).
    private func shouldMergeLines(_ src: Int, _ tgt: Int, _ children: [[Int]]) -> Bool {
        let bs = Self.rotatedBoxOnly(entities[src]), bt = Self.rotatedBoxOnly(entities[tgt])
        let wd = orientationLabel(src).writingDirection
        let ts = thickness(bs, wd), tt = thickness(bt, wd)
        if Double(min(ts, tt)) / Double(max(ts, tt)) < minBreadthRatio { return false }
        let angleS = Double(bs.angle), angleT = Double(bt.angle)
        var d = fmod(abs(angleS - angleT), 360)
        if d > 180 { d = 360 - d }
        if !(d <= maxAngleDifference) { return false }
        var m = RotatedBox(left: bs.left, top: bs.top, width: 1, height: 1, angle: Float((angleS + angleT) * 0.5))
        layoutExpandBox(bs, &m)
        layoutExpandBox(bt, &m)
        let tm = thickness(m, wd)
        if !(Double(tt + ts - tm) / Double(tm) >= minBreadthOverlap) { return false }
        let ds = entityLineLength(src), dt = entityLineLength(tgt), dm = lineLength(m, wd)
        var average = (meanSymbolLength(src, children) + meanSymbolLength(tgt, children)) * 0.5
        if average == 0 { average = Double(entityThickness(src) + entityThickness(tgt)) / 4 }
        return Double(dm - (dt + ds)) / average <= maxDepthGap
    }

    private mutating func setWordTextFromSymbols(_ w: Int) {
        entities[w].text = nil
        entities[w].text = text(of: w, childLists())
    }

    /// ConvertSoftHyphenToSymbol: a SOFT_HYPHEN break becomes a trailing "-" symbol (break NONE).
    private mutating func convertSoftHyphenToSymbol(_ w: Int) {
        guard entities[w].wordBreak?.type == 4 else { return }
        var s = Entity()
        s.type = .symbol
        s.parent = w
        s.text = "-"
        s.box = entities[w].wordBreak?.box ?? RotatedBox()
        entities.append(s)
        entities[w].wordBreak = WordBreak(type: 1, box: nil)
        setWordTextFromSymbols(w)
        recomputeBoxFromChildren(w, childLists())
    }

    /// ConvertEndingHyphenToSoftHyphen: the word's break becomes NONE, or SOFT_HYPHEN (boxed by the removed symbol)
    /// when the last of its several symbols is "-".
    private mutating func convertEndingHyphenToSoftHyphen(_ w: Int, _ refs: inout EntityRefs) {
        if entities[w].wordBreak?.type == 4 { return }
        let children = childLists()
        entities[w].wordBreak = WordBreak(type: 1, box: nil)
        guard children[w].count >= 2, let last = children[w].last, entities[last].text ?? "" == "-" else { return }
        entities[w].wordBreak = WordBreak(type: 4, box: entities[last].box ?? RotatedBox())
        var delete = [Bool](repeating: false, count: entities.count)
        delete[last] = true
        let wr = refs.add(w)
        refs.apply(deleteWithDescendants(delete))
        setWordTextFromSymbols(refs.at[wr])
    }

    /// MergeLinesStep::Merge(src, tgt): the source's words move into the target, in reading order.
    private mutating func mergeLine(_ src0: Int, _ tgt0: Int, _ refs: inout EntityRefs) {
        let rtl = orientationLabel(tgt0).writingDirection == 1
        let sr = refs.add(src0), tr = refs.add(tgt0)
        for r in [sr, tr] {
            let children = childLists()
            let e = refs.at[r]
            guard let w = children[e].last else { continue }
            convertSoftHyphenToSymbol(w)
            if entities[w].wordBreak == nil { entities[w].wordBreak = WordBreak() }
            if entities[w].wordBreak?.type == 1 {
                entities[w].wordBreak?.box = nil
                entities[w].wordBreak?.type = 2  // NONE -> SPACE
            }
        }
        let src = refs.at[sr], tgt = refs.at[tr]
        let children = childLists()
        let moved = children[tgt] + children[src]
        for c in children[src] { entities[c].parent = tgt }
        var keys: [Int: ReadingOrderKey] = [:]
        for c in moved { keys[c] = readingOrderKey(c) }
        var sorted = moved
        sorted.stableSort { readingOrderLess(rtl, keys[$0]!, keys[$1]!) }
        let slots = moved.sorted()
        var order = Array(entities.indices)
        for k in slots.indices { order[slots[k]] = sorted[k] }
        refs.apply(reorder(order))
    }

    /// MergeLinesStep::AnalyzeForDirection: passes merging each line with the next one (the window widening after
    /// each merge) until nothing merges. `children` is kept up to date.
    private mutating func mergeLines(_ lines: [Int], _ refs: inout EntityRefs, _ children: inout [[Int]]) {
        var deleted: [Int] = []  // refs
        func isDeleted(_ e: Int, _ refs: EntityRefs) -> Bool { deleted.contains { refs.at[$0] == e } }
        let n = lines.count
        var changed = true
        while changed {
            changed = false
            for i in 0..<n {
                let a = refs.at[lines[i]]
                if entities[a].box?.curve != nil || isDeleted(a, refs) { continue }
                var window = 1
                var j = i + 1
                while j < n {
                    defer { j += 1 }
                    let tgt = refs.at[lines[i]], src = refs.at[lines[j]]
                    if entities[src].box?.curve == nil && !isDeleted(src, refs) && shouldMergeLines(src, tgt, children) {
                        mergeLine(src, tgt, &refs)
                        deleted.append(lines[j])
                        var t = refs.at[lines[i]]
                        children = childLists()
                        if let w = children[t].last, !children[w].isEmpty { convertEndingHyphenToSoftHyphen(w, &refs) }
                        t = refs.at[lines[i]]
                        children = childLists()
                        recomputeBoxFromChildren(t, children)
                        recomputeConfidence(t, children)
                        // Ancestors of the source left with it as their only child go too.
                        var p = entities[refs.at[lines[j]]].parent
                        while p >= 0 && children[p].count == 1 {
                            deleted.append(refs.add(p))
                            p = entities[p].parent
                        }
                        changed = true
                        window += 1
                    }
                    if window + i <= j { break }
                }
            }
        }
        if deleted.isEmpty { return }
        var delete = [Bool](repeating: false, count: entities.count)
        for r in deleted where refs.at[r] >= 0 { delete[refs.at[r]] = true }
        refs.apply(deleteWithDescendants(delete))
        refs.apply(deleteTextEntitiesWithNoSymbols())
        children = childLists()
    }

    /// EstimateLinesStep with a MergeLinesSpec: each paragraph's lines merged, per orientation.
    mutating func estimateLines() {
        var refs = EntityRefs()
        let paragraphs = entities.indices.filter { entities[$0].type == .paragraph }.map { refs.add($0) }
        var children = childLists()  // only merges change it
        for r in paragraphs where refs.at[r] >= 0 {
            let p = refs.at[r]
            guard let first = children[p].first else { continue }
            let lines = (entities[first].type == .line ? children[p] : descendants(of: p, children))
                .filter { entities[$0].type == .line }
            var groups: [OrientationLabel: [Int]] = [:]
            for e in lines { groups[orientationLabel(e), default: []].append(refs.add(e)) }
            for key in groups.keys.sorted() { mergeLines(groups[key]!, &refs, &children) }
        }
    }

    /// The analysis' last step: each line's text from its words.
    mutating func recomputeLineTexts() {
        let children = childLists()
        for i in entities.indices where entities[i].type == .line {
            entities[i].text = nil
            entities[i].text = text(of: i, children)
        }
    }
}
