import Foundation

// The layout analysis' FillSymbolGaps step with the shipped config (aksara_page_layout_analysis_rpn_gro_2024_q4):
// in lines of the scripts it doesn't skip, each symbol grows over part of the gaps to its neighbours; the space
// boxes between words are refit, and every box above the symbols is recomputed from its children. The next step,
// RemoveOverlappingWithCurvedBoxes, measures overlaps with these symbol boxes.

/// FillSymbolGapsSpec.ignored_scripts.
private let ignoredScripts: Set<String> = [
    "Arab", "Beng", "Cyrl", "Deva", "Geor", "Grek", "Gujr", "Hani", "Hebr", "Jpan", "Knda", "Kore", "Mlym", "Taml",
    "Telu", "Thai", "und",
]
/// FillSymbolGapsSpec.minimum_single_symbol_length_as_fraction_of_thickness.
private let minSingleSymbolLength = 0.3

let layoutRadToDeg = Float(bitPattern: 0x4265_2EE0)  // 57.295776

/// roundf, then clamped to the int range.
func layoutRoundToInt(_ v: Float) -> Int {
    let r = v.rounded(.toNearestOrAwayFromZero)
    if r >= 2_147_483_648 { return Int(Int32.max) }
    if r <= -2_147_483_648 { return Int(Int32.min) }
    return Int(r)
}

/// ExpandBoxToContainBox<goodoc::RotatedBoundingBox, ...>: a curved box keeps its curve.
func layoutExpandBox(_ src: RotatedBox, _ dst: inout RotatedBox) {
    let curve = dst.curve
    expandBoxToContainBox(src, &dst)
    dst.curve = curve
}

/// FindContainingBoxWithAverageAngle<goodoc::RotatedBoundingBox> as goodoc::RecomputeBoxFromChildren uses it.
func layoutContainingBox(_ boxes: [RotatedBox]) -> RotatedBox {
    var angle: Float = 0
    let n = boxes.count
    if n == 1 {
        angle = normalizeAngle(boxes[0].angle)
    } else if n > 1 {
        var s: Float = 0, c: Float = 0
        for b in boxes {
            let r = sinCos(b.angle * degToRad)
            s = s + r.sin
            c = c + r.cos
        }
        let absS = abs(s)
        if abs(c) > 1e-5 || absS > 1e-5 {
            angle = absS > 1e-5 || c > Float(n) * -0.99999 ? atan2f(s, c) * layoutRadToDeg : 180
        } else {
            var best: Float = 180
            angle = 180
            for b in boxes {
                let a = normalizeAngle(b.angle)
                let alt = a == -angle ? abs(angle) : angle
                if abs(a) < best {
                    angle = a
                    best = abs(a)
                } else {
                    angle = alt
                }
            }
        }
    }
    var out = RotatedBox()
    out.angle = angle
    for b in boxes {
        if out.width < 1 || out.height <= 0 {
            out.left = b.left
            out.top = b.top
            out.width = 1
            out.height = 1
        }
        layoutExpandBox(b, &out)
    }
    return out
}

/// box_util::ResizeBox: grows by (dw, dh) keeping the center.
private func resizeBox(_ dw: Int, _ dh: Int, _ b: inout RotatedBox) {
    b.width = max(b.width + dw, 0)
    b.height = max(b.height + dh, 0)
    let a = normalizeAngle(b.angle)
    if a == 0 {
        b.left = Int(Float(b.left) + Float(dw) * -0.5)
        b.top = Int(Float(b.top) + Float(dh) * -0.5)
        return
    }
    let l = Float(b.left), t = Float(b.top)
    let nl = Float(Double(b.left) - Double(dw) * 0.5)
    let nt = Float(Double(b.top) - Double(dh) * 0.5)
    let r = sinCos(a * degToRad)
    let y = ((r.sin * (nl - l)) + t) + (r.cos * (nt - t))
    b.left = layoutRoundToInt(((r.cos * (nl - l)) + l) - (r.sin * (nt - t)))
    b.top = layoutRoundToInt(y)
}

/// box_util::RotateBoundingBox: rotates the origin corner about (cx, cy) by `a` degrees.
private func rotateBox(_ cx: Int, _ cy: Int, _ a: Float, _ b: inout RotatedBox) {
    let r = sinCos(a * degToRad)
    let x = Float(b.left), y = Float(b.top)
    let fx = Float(cx), fy = Float(cy)
    let ny = ((r.sin * (x - fx)) + fy) + (r.cos * (y - fy))
    b.left = layoutRoundToInt(((r.cos * (x - fx)) + fx) - (r.sin * (y - fy)))
    b.top = layoutRoundToInt(ny)
    b.angle = normalizeAngle(a + b.angle)
}

/// A quarter turn clockwise (top-to-bottom text handled as left-to-right), and back.
func layoutTurnClockwise(_ b: inout RotatedBox) {
    let w = b.width
    swap(&b.width, &b.height)
    let r = sinCos(b.angle * degToRad)
    let ny = (r.sin * Float(w)) + Float(b.top)
    b.left = layoutRoundToInt((r.cos * Float(w)) + Float(b.left))
    b.top = layoutRoundToInt(ny)
    b.angle = normalizeAngle(b.angle + 90)
}

private func turnCounterClockwise(_ b: inout RotatedBox) {
    let h = b.height
    swap(&b.width, &b.height)
    let r = sinCos(b.angle * degToRad)
    let ny = (r.cos * Float(h)) + Float(b.top)
    b.left = layoutRoundToInt(Float(b.left) - (r.sin * Float(h)))
    b.top = layoutRoundToInt(ny)
    b.angle = normalizeAngle(b.angle + 270)
}

extension PageLayout {
    /// PageLayout::Orientation(e).writing_direction: from the nearest entity (e or an ancestor) with an orientation.
    func writingDirection(_ e: Int) -> Int {
        var i = e, guardCount = 0
        while i >= 0 && i < entities.count && guardCount < 64 {
            if entities[i].writingDirection != nil || entities[i].orientation != nil { return entities[i].writingDirection ?? 0 }
            i = entities[i].parent
            guardCount += 1
        }
        return 0
    }

    private static func lineLength(_ b: RotatedBox, _ writingDirection: Int) -> Int {
        writingDirection == 2 ? b.height : b.width
    }

    /// DepthGapBetweenEntities for two symbols: the free length between them along the writing direction.
    private func depthGap(_ a: Int, _ b: Int) -> Double {
        let ba = entities[a].box ?? RotatedBox(), bb = entities[b].box ?? RotatedBox()
        var u = ba
        layoutExpandBox(bb, &u)
        let wa = writingDirection(a)
        let d = Self.lineLength(u, wa) - (Self.lineLength(ba, wa) + Self.lineLength(bb, writingDirection(b)))
        return Double(d > 0 ? d : 0)
    }

    /// RecomputeSpaceWordBreakBoxes: each word's space box spans the gap to the next word's first symbol.
    private mutating func recomputeSpaceBreakBoxes(_ words: [Int], _ children: [[Int]]) {
        guard words.count > 1 else { return }
        for k in 0..<(words.count - 1) {
            guard let brk = entities[words[k]].wordBreak, brk.type & ~1 == 2 else { continue }
            let ka = children[words[k]], kb = children[words[k + 1]]
            guard let lastA = ka.last, let firstB = kb.first else { continue }
            let gap = depthGap(lastA, firstB)
            guard var box = brk.box else { continue }
            let wd = writingDirection(words[k])
            let delta = Int(gap - Double(Self.lineLength(box, wd)))
            if wd == 2 {
                resizeBox(0, delta, &box)
                box.height = max(box.height, 1)
            } else {
                resizeBox(delta, 0, &box)
                box.width = max(box.width, 1)
            }
            entities[words[k]].wordBreak?.box = box
        }
    }

    /// DeltaSymbolExpansionWithConstraints without nuggets: in the line's frame, each symbol grows by 0.4 of the gaps
    /// to its neighbours (0.8 towards the inside for the first and last), centered, but not past the line start (box
    /// left + the detection's padding); symbols already starting before it stay as they are. A word of one symbol is
    /// widened to the minimum length.
    private mutating func expandSymbols(_ symbols: [Int], _ wd: Int, frame: RotatedBox, padStart: Float) {
        let n = symbols.count
        if n < 1 { return }
        let minLeft = Int(padStart + Float(frame.left))
        var b = symbols.map { entities[$0].box ?? RotatedBox() }
        for k in 0..<n {
            if wd == 2 { layoutTurnClockwise(&b[k]) }
            rotateBox(frame.left, frame.top, -frame.angle, &b[k])
        }
        func gap(_ a: Int, _ c: Int) -> Float {
            let first = b[a].left > b[c].left ? b[c] : b[a]
            let g = max(b[a].left, b[c].left) - min(b[a].left, b[c].left) - first.width
            return Float(g > 0 ? g : 0)
        }
        for k in 0..<n {
            let leftNeighbour = wd == 1 ? k + 1 : k - 1, rightNeighbour = wd == 1 ? k - 1 : k + 1
            var delta: Float = 0
            if n == 1 {
                let minLength = Int(minSingleSymbolLength * Double(b[k].height))
                if b[k].width < minLength { delta = Float(minLength - b[k].width) }
            } else {
                if leftNeighbour >= 0 && leftNeighbour < n { delta = (k == n - 1 ? 0.8 : 0.4) * gap(k, leftNeighbour) }
                if rightNeighbour >= 0 && rightNeighbour < n { delta = delta + (k != 0 ? 0.4 : 0.8) * gap(k, rightNeighbour) }
            }
            var left = Int((Double(b[k].left) + Double(delta) * -0.5).rounded(.toNearestOrEven))
            if minLeft > left {
                delta = delta - Float(minLeft - left)
                left = minLeft
            }
            if b[k].left < minLeft { continue }
            b[k].left = left
            b[k].width = max(Int(delta + Float(b[k].width)), 1)
        }
        for k in 0..<n {
            rotateBox(frame.left, frame.top, frame.angle, &b[k])
            if wd == 2 { turnCounterClockwise(&b[k]) }
            let curve = entities[symbols[k]].box?.curve
            entities[symbols[k]].box = b[k]
            entities[symbols[k]].box?.curve = curve
        }
    }

    /// FillSymbolGaps (the config's nuggets refinement path; the layouts carry no detection nuggets).
    mutating func fillSymbolGaps() {
        let children = childLists()
        for i in entities.indices where entities[i].type == .line {
            let words = descendants(of: i, children).filter { entities[$0].type == .word }
            if words.isEmpty { continue }
            let line = entities[i]
            if !(line.recognizerScriptId.map { ignoredScripts.contains($0) } ?? false) {
                // The line box (turned for top-to-bottom writing) and the detection's padding before the line start.
                var frame = line.box ?? RotatedBox()
                frame.curve = nil
                var padStart: Float = 0
                if let d = line.detection {
                    var pads = [d.leftPadding, d.rightPadding]
                    if writingDirection(i) == 2 { layoutTurnClockwise(&frame) }
                    if abs(abs(frame.angle - d.detectionBox.angle) + -180) < 0.01 { pads.swapAt(0, 1) }
                    padStart = pads[0]
                }
                for w in words { expandSymbols(children[w], writingDirection(w), frame: frame, padStart: padStart) }
            }
            recomputeSpaceBreakBoxes(words, children)
        }
        recomputeBoxesFromSymbols()
    }

    /// goodoc::RecomputeBoxFromChildren bottom-up: each entity's box contains its children's boxes and break boxes.
    mutating func recomputeBoxesFromSymbols() {
        let children = childLists()
        for e in descendants(children).reversed() { recomputeBoxFromChildren(e, children) }
    }

    /// goodoc::RecomputeBoxFromChildren: the box containing the children's boxes and break boxes (a curved entity
    /// keeps its curve).
    mutating func recomputeBoxFromChildren(_ e: Int, _ children: [[Int]]) {
        var boxes: [RotatedBox] = []
        for c in children[e] {
            if let b = entities[c].box { boxes.append(b) }
            if let b = entities[c].wordBreak?.box { boxes.append(b) }
        }
        if boxes.isEmpty { return }
        let curve = entities[e].box?.curve
        entities[e].box = layoutContainingBox(boxes)
        entities[e].box?.curve = curve
    }
}
