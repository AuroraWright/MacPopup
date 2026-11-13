import Foundation

// The layout analysis' ClusterSortGcn step with the shipped config (skip_line_clustering: the detector's paragraphs
// stay as they are): the graph network marks the lines of paragraphs that read in columns; boxes are re-estimated
// from the symbols; the lines of each paragraph are sorted; and the paragraphs are put in reading order, nesting
// those that lie inside others, each in a block of its own. Same arithmetic and tie order as the original.

private let radToDeg = layoutRadToDeg

// MARK: - Line graph (google_ocr::LineClusteringFeatures, GetBoxEdgeTensors)

/// UnicodeProps::IsFirstCharCJKLetter.
private let cjkLetterRanges: [ClosedRange<UInt32>] = [
    0x1100...0x11FF, 0x3005...0x3007, 0x3021...0x302F, 0x3031...0x3035, 0x3038...0x303C, 0x3041...0x3096,
    0x3099...0x30FA, 0x30FC...0x30FF, 0x3105...0x312F, 0x3131...0x318E, 0x31A0...0x31BF, 0x31F0...0x31FF,
    0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97C, 0xAC00...0xD7A3, 0xD7B0...0xD7C6, 0xD7CB...0xD7FB,
    0xF900...0xFA6D, 0xFA70...0xFAD9, 0xFF66...0xFFBE, 0xFFC2...0xFFC7, 0xFFCA...0xFFCF, 0xFFD2...0xFFD7,
    0xFFDA...0xFFDC, 0x16FE3...0x16FE3, 0x16FF0...0x16FF6, 0x1AFF0...0x1AFF3, 0x1AFF5...0x1AFFB, 0x1AFFD...0x1AFFE,
    0x1B000...0x1B122, 0x1B132...0x1B132, 0x1B150...0x1B152, 0x1B155...0x1B155, 0x1B164...0x1B167,
    0x20000...0x2A6DF, 0x2A700...0x2B81D, 0x2B820...0x2CEAD, 0x2CEB0...0x2EBE0, 0x2EBF0...0x2EE5D,
    0x2F800...0x2FA1D, 0x30000...0x3134A, 0x31350...0x323AF,
]

private func isFirstCharCjkLetter(_ s: String) -> Bool {
    let u = Array(s.utf8.prefix(4)).map { UInt32($0) }
    guard let b0 = u.first, b0 >= 0xE1 else { return false }
    let cp: UInt32
    if b0 < 0xF0 {
        guard u.count >= 3 else { return false }
        cp = (b0 & 0x0F) << 12 | (u[1] & 0x3F) << 6 | (u[2] & 0x3F)
    } else {
        guard u.count >= 4 else { return false }
        cp = (b0 & 0x07) << 18 | (u[1] & 0x3F) << 12 | (u[2] & 0x3F) << 6 | (u[3] & 0x3F)
    }
    return cjkLetterRanges.contains { $0.contains(cp) }
}

struct LineGraph {
    /// The LINE entities, in level order.
    var lines: [Int] = []
    /// Their boxes (vertical lines turned to read left to right).
    var boxes: [RBox] = []
    /// -1 when the line starts with a CJK letter, else its first word's width over the page width.
    var extra: [Float] = []
    var edges: [GraphEdge] = []
}

extension PageLayout {
    func lineGraph() -> LineGraph {
        var g = LineGraph()
        let children = childLists()
        g.lines = descendants(children).filter { entities[$0].type == .line }
        for li in g.lines {
            let e = entities[li]
            var b = e.box ?? RotatedBox()
            if e.writingDirection == 2 {
                let r = sinCos(b.angle * degToRad)
                let w = Float(b.width)
                b.left = layoutRoundToInt((r.cos * w) + Float(b.left))
                b.top = layoutRoundToInt((r.sin * w) + Float(b.top))
                swap(&b.width, &b.height)
                b.angle = normalizeAngle(b.angle + 90)
            }
            g.boxes.append(RBox(x: Float(b.left), y: Float(b.top), w: Float(b.width), h: Float(b.height), angle: b.angle))
            var extra: Float = 0
            if let w = descendants(of: li, children).first(where: { entities[$0].type == .word }) {
                extra = isFirstCharCjkLetter(entities[w].text ?? "") ? -1
                    : Float(entities[w].box?.width ?? 0) / Float(width)
            }
            g.extra.append(extra)
        }
        g.edges = boxNeighborEdges(g.boxes, pointsHorizontal: 10, pointsVertical: 2)
        return g
    }
}

/// GetBoxEdgeTensors: per line its box's width and height (over `scale`), angle (radians), cosine and sine, then per
/// corner x, cos·x, sin·x, y, cos·y, sin·y, then the extra feature.
func lineNodeFeatures(_ g: LineGraph, scale: Float) -> [Float] {
    var f: [Float] = []
    for (i, b) in g.boxes.enumerated() {
        let rad = Float(Double(b.angle) * 3.141592653589793 / 180.0)
        let r = sinCos(rad)
        f += [b.w / scale, b.h / scale, rad, r.cos, r.sin]
        for p in boxCorners(RBox(x: b.x / scale, y: b.y / scale, w: b.w / scale, h: b.h / scale, angle: b.angle)) {
            f += [p.x, r.cos * p.x, r.sin * p.x, p.y, r.cos * p.y, r.sin * p.y]
        }
        f.append(g.extra[i])
    }
    return f
}

// MARK: - box_util on float boxes

/// CopyBoundingBox<RotatedBoundingBox, Box<float>>.
func floatBox(_ b: RotatedBox) -> RBox {
    RBox(x: Float(b.left), y: Float(b.top), w: Float(b.width), h: Float(b.height), angle: normalizeAngle(b.angle))
}

/// RotateBoundingBox<Box<float>>: the origin corner rotated about (cx, cy) by `a` degrees.
private func rotate(_ b: inout RBox, _ cx: Float, _ cy: Float, _ a: Float) {
    let r = sinCos(a * degToRad)
    let x = b.x, y = b.y
    b.x = (cx + (r.cos * (x - cx))) - (r.sin * (y - cy))
    b.y = (cy + (r.sin * (x - cx))) + (r.cos * (y - cy))
    b.angle = normalizeAngle(a + b.angle)
}

/// ConvertToAxisAlignedBoundingBox<Box<float>>.
private func axisAligned(_ b: inout RBox) {
    if b.angle == 0 { return }
    let r = sinCos(b.angle * degToRad)
    let p1x = b.x + (r.cos * b.w), p1y = b.y + (r.sin * b.w)
    let ns = -r.sin
    let px = [b.x, p1x, p1x + (ns * b.h), b.x + (ns * b.h)]
    let py = [b.y, p1y, p1y + (r.cos * b.h), b.y + (r.cos * b.h)]
    var mnx = px[0], mny = py[0], mxx = px[0], mxy = py[0]
    for k in 1..<4 {
        mnx = mnx > px[k] ? px[k] : mnx
        mny = mny > py[k] ? py[k] : mny
        mxx = px[k] > mxx ? px[k] : mxx
        mxy = py[k] > mxy ? py[k] : mxy
    }
    b = RBox(x: mnx, y: mny, w: mxx - mnx, h: mxy - mny)
}

/// GetCenter<Box<float>>.
private func center(_ b: RBox) -> (x: Float, y: Float) {
    let r = sinCos(normalizeAngle(b.angle) * degToRad)
    let hw = b.w * 0.5, hh = b.h * 0.5
    return ((b.x - (r.sin * hh)) + (r.cos * hw), (b.y + (r.cos * hh)) + (r.sin * hw))
}

/// ExpandBoxToContainBox<Box<float>, Box<float>>.
private func expand(_ src: RBox, _ dst: inout RBox) {
    if dst.w <= 0 || dst.h <= 0 {
        dst = src
        dst.angle = normalizeAngle(src.angle)
        return
    }
    let sa = normalizeAngle(src.angle), da = normalizeAngle(dst.angle)
    if sa == 0 && da == 0 {
        var x = dst.x, y = dst.y
        let dx = x - src.x
        if dx > 0 {
            dst.x = src.x
            dst.w = dx + dst.w
            x = src.x
        }
        let dy = y - src.y
        if dy > 0 {
            dst.y = src.y
            dst.h = dy + dst.h
            y = src.y
        }
        let r = src.x + src.w
        if r > x + dst.w { dst.w = r - x }
        let b = src.y + src.h
        if b > y + dst.h { dst.h = b - y }
        return
    }
    var s = src
    rotate(&s, dst.x, dst.y, -da)
    var px = [s.x, 0, 0, 0], py = [s.y, 0, 0, 0]
    if s.angle == 0 {
        (px[1], py[1]) = (s.x + s.w, s.y)
        (px[2], py[2]) = (s.x + s.w, s.y + s.h)
        (px[3], py[3]) = (s.x, s.y + s.h)
    } else {
        let r = sinCos(s.angle * degToRad)
        (px[1], py[1]) = (s.x + (r.cos * s.w), s.y + (r.sin * s.w))
        (px[2], py[2]) = (px[1] - (r.sin * s.h), py[1] + (r.cos * s.h))
        (px[3], py[3]) = (s.x - (r.sin * s.h), s.y + (r.cos * s.h))
    }
    let qx = dst.x + dst.w, qy = dst.y + dst.h
    var mnx = dst.x > px[0] ? px[0] : dst.x, mny = dst.y > py[0] ? py[0] : dst.y
    var mxx = px[0] > qx ? px[0] : qx, mxy = py[0] > qy ? py[0] : qy
    for k in 1..<4 {
        mnx = mnx > px[k] ? px[k] : mnx
        mny = mny > py[k] ? py[k] : mny
        mxx = px[k] > mxx ? px[k] : mxx
        mxy = py[k] > mxy ? py[k] : mxy
    }
    let r = sinCos(da * degToRad)
    let ex = mnx - dst.x, ey = mny - dst.y
    let nx = (dst.x + (r.cos * ex)) - (r.sin * ey)
    let ny = (dst.y + (r.sin * ex)) + (r.cos * ey)
    dst = RBox(x: nx, y: ny, w: mxx - mnx, h: mxy - mny, angle: dst.angle)
}

/// The average angle of FindContainingBoxWithAverageAngle<Box<float>>.
private func averageAngle(_ a: [Float]) -> Float {
    if a.isEmpty { return 0 }
    if a.count == 1 { return normalizeAngle(a[0]) }
    var s: Float = 0, c: Float = 0
    for v in a {
        let r = sinCos(v * degToRad)
        s = s + r.sin
        c = c + r.cos
    }
    let absS = abs(s)
    if abs(c) <= 1e-5 && absS <= 1e-5 {
        var best: Float = 180, out: Float = 180
        for v in a {
            let j = normalizeAngle(v)
            if j == -out { out = abs(out) }
            if abs(j) < best {
                out = j
                best = abs(j)
            }
        }
        return out
    }
    if absS > 1e-5 || c > Float(a.count) * -0.99999 { return atan2f(s, c) * radToDeg }
    return 180
}

/// FindContainingBoxWithAverageAngle<Box<float>>.
private func containingBox(_ boxes: [RBox]) -> RBox {
    var out = RBox(angle: averageAngle(boxes.map(\.angle)))
    for b in boxes {
        if out.w <= 0 || out.h <= 0 {
            out.x = b.x
            out.y = b.y
            out.w = 1
            out.h = 1
        }
        expand(b, &out)
    }
    return out
}

/// AxisAlignedR2BoundingBox: (xmin, ymin, xmax, ymax).
private func r2Box(_ b: RBox) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
    var a = b
    axisAligned(&a)
    return (Double(a.x), Double(a.y), Double(a.x + a.w), Double(a.y + a.h))
}

// MARK: - RobustBoxEstimation

/// rotation_util::RobustAngleEstimation: votes for the dominant axis direction, then takes the median of the angles
/// relative to it.
private func robustAngle(_ angles: [Float]) -> Float {
    if angles.isEmpty { return 0 }
    let dirs: [(x: Float, y: Float)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    var votes = [0, 0, 0, 0]
    var unit: [(c: Float, s: Float)] = []
    for a in angles {
        let r = sinCos(a * degToRad)
        var best = 0
        for k in 1..<4 {
            let cur = ((r.cos * dirs[best].x) + 0) + (r.sin * dirs[best].y)
            let cand = ((r.cos * dirs[k].x) + 0) + (r.sin * dirs[k].y)
            if cur < cand { best = k }
        }
        votes[best] += 1
        unit.append((r.cos, r.sin))
    }
    var dominant = 0
    for k in 1..<4 where votes[dominant] < votes[k] { dominant = k }
    let dx = dirs[dominant].x, dy = dirs[dominant].y
    var keyed = unit.map { u in (c: u.c, s: u.s, key: atan2f((dx * u.s) - (dy * u.c), ((dx * u.c) + 0) + (dy * u.s))) }
    keyed.libcxxSort { $0.key < $1.key }
    let n = keyed.count
    var mc = keyed[n / 2].c, ms = keyed[n / 2].s
    if n % 2 == 0 {
        mc = (mc + keyed[n / 2 - 1].c) * 0.5
        ms = (ms + keyed[n / 2 - 1].s) * 0.5
    }
    if ms == 0 && mc == 0 { return 0 }
    return atan2f(ms, mc) * radToDeg
}

/// CreateCurveRepresentation (use_max_height, a moving-average window of 1) and the mid line RobustBoxEstimation
/// keeps: the midpoints of the parts' left and right edges along the line, thinned to a quarter of the thickness
/// apart, offset to the top and bottom polylines and averaged back. Turned clockwise first for top-to-bottom text.
private func curve(_ boxes: [RotatedBox], _ robust: RotatedBox, topToBottom: Bool) -> Curve {
    var frame = robust
    if topToBottom { layoutTurnClockwise(&frame) }
    var pts: [(x: Float, y: Float)] = []
    var t: Float = 0
    for var b in boxes {
        if topToBottom { layoutTurnClockwise(&b) }
        let x = Float(b.left), y = Float(b.top), w = Float(b.width), h = Float(b.height)
        var p = [x, y, 0, 0, 0, 0, 0, 0]
        if b.angle == 0 {
            (p[2], p[3], p[4], p[5], p[6], p[7]) = (x + w, y, x + w, h + y, x, h + y)
        } else {
            let r = sinCos(b.angle * degToRad)
            p[2] = (r.cos * w) + x
            p[3] = (r.sin * w) + y
            p[4] = p[2] - (r.sin * h)
            p[5] = (r.cos * h) + p[3]
            p[6] = x - (r.sin * h)
            p[7] = (r.cos * h) + y
        }
        pts.append(((p[0] + p[6]) * 0.5, (p[1] + p[7]) * 0.5))
        pts.append(((p[2] + p[4]) * 0.5, (p[3] + p[5]) * 0.5))
        if t < h { t = h }
    }
    let dir = sinCos(frame.angle * degToRad)
    let ox = Float(frame.left), oy = Float(frame.top)
    func key(_ q: (x: Float, y: Float)) -> Float { (dir.cos * (q.x - ox) + 0) + dir.sin * (q.y - oy) }
    pts.libcxxSort { key($0) < key($1) }
    var mid: [(x: Float, y: Float)] = []
    let n = pts.count
    if n > 1 {
        mid.append(pts[0])
        for i in 1..<(n - 1) {
            let dx = pts[i].x - mid[mid.count - 1].x, dy = pts[i].y - mid[mid.count - 1].y
            if dx * dx + dy * dy > t * (t * 0.25) { mid.append(pts[i]) }
        }
    }
    if n > 0 { mid.append(pts[n - 1]) }
    var top: [(x: Float, y: Float)] = [], bottom: [(x: Float, y: Float)] = []
    let half = t * 0.5
    for i in mid.indices.dropFirst() {
        let a = mid[i - 1], b = mid[i]
        let r = sinCos(atan2f(b.x - a.x, a.y - b.y))
        let cx = r.cos * half, cy = r.sin * half
        top.append((a.x - cx, a.y - cy))
        bottom.append((cx + a.x, cy + a.y))
        if i + 1 == mid.count {
            top.append((b.x - cx, b.y - cy))
            bottom.append((cx + b.x, cy + b.y))
        }
    }
    var c = Curve(thickness: Double(t), topToBottom: topToBottom)
    for k in 0..<min(top.count, bottom.count) {
        let x = (top[k].x + bottom[k].x) * 0.5, y = (top[k].y + bottom[k].y) * 0.5
        if k > 0, let last = c.points.last, Float(last.x) == x && Float(last.y) == y { continue }
        c.points.append((Double(x), Double(y)))
    }
    return c
}

extension PageLayout {
    /// google_ocr::box_util::RobustBoxEstimation: the box of the symbols and word breaks below `e`, at their robust
    /// angle; lines and words whose parts' angles spread become curved.
    mutating func robustBoxEstimation(_ e: Int, _ children: [[Int]]) {
        var boxes: [RotatedBox] = []
        for d in descendants(of: e, children) {
            let ent = entities[d]
            if ent.type == .symbol { boxes.append(ent.box ?? RotatedBox()) }
            if ent.type == .word, let b = ent.wordBreak?.box { boxes.append(b) }
        }
        if boxes.isEmpty { return }
        let angles = boxes.map(\.angle)
        let angle = robustAngle(angles)
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
        if entities[e].type == .word || entities[e].type == .line {
            let r = sinCos(angle * degToRad)
            var minCos: Float = 1
            for a in angles {
                let ra = sinCos(a * degToRad)
                let d = (r.sin * ra.sin) + ((r.cos * ra.cos) + 0)
                if d < minCos { minCos = d }
            }
            if Double(minCos) < 0.99 { out.curve = curve(boxes, out, topToBottom: entities[e].writingDirection == 2) }
        }
        entities[e].box = out
    }

    // MARK: SortChildrenOfEntity

    /// SortChildrenOfEntity with CompareByBox: in the parent's frame, each child is ranked by how many siblings come
    /// before it, and the children take their slots in that (stable) order, so `children` stays valid. `track`
    /// follows the reorder.
    mutating func sortChildren(of e: Int, _ children: [[Int]], track: inout [Int]) {
        let ch = children[e]
        guard let pbox = entities[e].box else { return }
        let negAngle = -floatBox(pbox).angle
        let order = entities[e].textlineOrder ?? 0, direction = entities[e].writingDirection ?? 0
        let keys: [RotatedBox?] = ch.map { c in
            guard var b = entities[c].box else { return nil }
            let r = sinCos(negAngle * degToRad)
            let x = Float(b.left), y = Float(b.top)
            let ny = ((r.sin * x) + 0) + (r.cos * y)
            b.left = layoutRoundToInt(((r.cos * x) + 0) - (r.sin * y))
            b.top = layoutRoundToInt(ny)
            b.angle = normalizeAngle(negAngle + b.angle)
            Self.canonicalizeMinAbsAngle(&b)
            return b
        }
        func less(_ ia: Int, _ ib: Int) -> Bool {
            guard let a = keys[ia] else { return false }
            guard let b = keys[ib] else { return true }
            if order & ~1 == 2 {
                let cb = Int(Double(b.height) * 0.5 + Double(b.top)), ca = Int(Double(a.height) * 0.5 + Double(a.top))
                if a.top + a.height <= cb || a.top > cb || b.top + b.height <= ca || b.top > ca {
                    return order == 2 ? ca < cb : ca > cb
                }
                return direction != 0 ? a.left + a.width > b.left + b.width : a.left < b.left
            }
            let ca = Int(Double(a.width) * 0.5 + Double(a.left)), cb = Int(Double(b.width) * 0.5 + Double(b.left))
            if a.left + a.width < cb || a.left > cb || b.left + b.width < ca || b.left > ca {
                return order != 0 ? ca > cb : ca < cb
            }
            return direction == 2 ? a.top < b.top : a.top > b.top
        }
        let n = ch.count
        var priority = [Int](repeating: 0, count: n)
        for i in 0..<n {
            for j in 0..<n where i != j && less(i, j) { priority[j] += 1 }
        }
        var idx = Array(0..<n)
        idx.stableSort { priority[$0] < priority[$1] }
        var newOrder = Array(entities.indices)
        for k in 0..<n { newOrder[ch[k]] = ch[idx[k]] }
        let remap = reorder(newOrder)
        track = track.map { $0 >= 0 ? remap[$0] : $0 }
    }

    /// CanonicalizeWithMinimumAbsoluteAngle: turns the box by quarter turns until its angle is in [-45, 45].
    private static func canonicalizeMinAbsAngle(_ b: inout RotatedBox) {
        var i = b.angle
        let a = normalizeAngle(i)
        var v = a <= 45 ? a : a + -360
        while v < -45 {
            let r = sinCos(i * degToRad)
            let w = Float(b.width)
            let l = layoutRoundToInt((r.cos * w) + Float(b.left))
            let t = layoutRoundToInt((r.sin * w) + Float(b.top))
            b.left = l
            b.top = t
            swap(&b.width, &b.height)
            i = normalizeAngle(i + 90)
            v = v + 90
        }
        b.angle = v
    }
}

// MARK: - ClusterAndSortParagraphs

private struct OrderNode {
    /// The paragraph entity, for leaves.
    var paragraph = -1
    var parent = -1
    /// Children ordered in columns (the GCN's prediction).
    var column = false
    var children: [Int] = []
    var sorted = false
    var box = RBox()
    var area: Float = 0
    var sumLineHeight: Float = 0
    var lineCount = 0
    var rtl = false
}

private func computeNodeBox(_ nodes: inout [OrderNode], _ i: Int, referenceAngle: Float?) {
    nodes[i].sumLineHeight = 0
    nodes[i].lineCount = 0
    var angles: [Float] = []
    for c in nodes[i].children {
        var a = nodes[c].box.angle
        if let ref = referenceAngle {
            while true {
                var d = fmodf(abs(a - ref), 360)
                if d > 180 { d = 360 - d }
                if d <= 45 { break }
                a = a + 90
            }
        }
        angles.append(a)
        nodes[i].sumLineHeight = nodes[c].sumLineHeight + nodes[i].sumLineHeight
        nodes[i].lineCount += nodes[c].lineCount
    }
    var box = RBox(angle: averageAngle(angles))
    for c in nodes[i].children {
        let cb = nodes[c].box
        if box.w <= 0 || box.h <= 0 {
            box.x = cb.x
            box.y = cb.y
            box.w = 1
            box.h = 1
        }
        expand(cb, &box)
    }
    nodes[i].box = box
    nodes[i].area = box.w * box.h
}

/// (anonymous)::SortChildren: the children's boxes in the node's frame, by row (column) center; a skyline over their
/// shrunk extents gives "is before" edges, then a topological order, leftmost (topmost) first.
private func sortOrderChildren(_ nodes: inout [OrderNode], _ i: Int) {
    if nodes[i].sorted || nodes[i].children.count < 2 { return }
    let n = nodes[i]
    let (cx, cy) = center(n.box)
    struct SortBox {
        var node: Int
        var key1: Float, key2: Float, lo: Float, hi: Float
        var indegree = 0
        var next: [Int] = []
    }
    var sb: [SortBox] = n.children.map { c in
        var b = nodes[c].box
        rotate(&b, cx, cy, -n.box.angle)
        axisAligned(&b)
        let start: Float, end: Float, key1: Float, key2: Float
        if n.column {
            start = b.y
            end = b.y + b.h
            key2 = b.y + (b.h * 0.5)
            let xc = b.x + (b.w * 0.5)
            key1 = n.rtl ? -xc : xc
        } else {
            start = b.x
            end = b.x + (b.w * 1.0)
            key1 = b.y + (b.h * 0.5)
            let xc = b.x + (0.5 * b.w)
            key2 = n.rtl ? -xc : xc
        }
        var m = Double(n.sumLineHeight) * 0.25 / Double(n.lineCount)
        let len = Double(end - start) * 0.25
        if len < m { m = len }
        let mf = Float(m)
        return SortBox(node: c, key1: key1, key2: key2, lo: start + mf, hi: end - mf)
    }
    sb.stableSort { $0.key1 < $1.key1 }
    // The skyline: sorted keys, each owning [key, next key) (-1: none).
    var sky: [(key: Float, owner: Int)] = []
    func lowerBound(_ v: Float) -> Int {
        var lo = 0, hi = sky.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sky[mid].key < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    func assign(_ key: Float, _ owner: Int) {
        let k = lowerBound(key)
        if k < sky.count && sky[k].key == key { sky[k].owner = owner } else { sky.insert((key, owner), at: k) }
    }
    for k in sb.indices {
        let lo = sb[k].lo, hi = sb[k].hi
        var it = lowerBound(lo)
        if it != 0 && it != sky.count && sky[it].key > lo { it -= 1 }
        let first = it
        var last = -1
        while it != sky.count && !(sky[it].key > hi) {
            let owner = sky[it].owner
            if owner >= 0 {
                sb[owner].next.append(k)
                sb[k].indegree += 1
            }
            last = owner
            it += 1
        }
        var eraseFrom = first
        if eraseFrom != sky.count && sky[eraseFrom].key < lo { eraseFrom += 1 }
        if eraseFrom < it { sky.removeSubrange(eraseFrom..<it) }
        assign(lo, k)
        assign(hi, last)
    }
    let greater: ((Float, Int), (Float, Int)) -> Bool = { $0.0 > $1.0 }
    var heap: [(Float, Int)] = []
    for k in sb.indices where sb[k].indegree == 0 {
        heap.append((sb[k].key2, k))
        heap.libcxxPushHeap(by: greater)
    }
    var order: [Int] = []
    while !heap.isEmpty {
        let k = heap.libcxxPopHeap(by: greater).1
        order.append(sb[k].node)
        for s in sb[k].next {
            sb[s].indegree -= 1
            if sb[s].indegree == 0 {
                heap.append((sb[s].key2, s))
                heap.libcxxPushHeap(by: greater)
            }
        }
    }
    nodes[i].children = order
    nodes[i].sorted = true
}

private func traverse(_ nodes: [OrderNode], _ i: Int, _ paragraphs: inout [Int]) {
    if nodes[i].children.isEmpty {
        paragraphs.append(nodes[i].paragraph)
        return
    }
    for c in nodes[i].children { traverse(nodes, c, &paragraphs) }
}

/// RotateOrientationClockwise<Box<float>>: the same rectangle with its origin corner moved `q` quadrants clockwise.
private func rotateOrientationClockwise(_ b: inout RBox, _ q0: Int) {
    let q = q0 <= 0 ? -(-q0 & 3) : q0 & 3
    if q == 0 { return }
    let w = b.w, h = b.h
    if q & 1 != 0 {
        b.w = h
        b.h = w
    }
    let r = sinCos(b.angle * degToRad)
    let x: Float, y: Float
    if q == 3 {
        x = b.x - (h * r.sin)
        y = b.y + (h * r.cos)
    } else if q == 2 {
        x = (b.x + (w * r.cos)) - (h * r.sin)
        y = (h * r.cos) + (b.y + (w * r.sin))
    } else {
        x = b.x + (w * r.cos)
        y = b.y + (w * r.sin)
    }
    b.x = x
    b.y = y
    b.angle = normalizeAngle(b.angle + Float(UInt32(truncatingIfNeeded: 90 * q)))
}

/// BoxArea of a curved box: the mid line offset by half the thickness along its normals, cut into one quad per
/// segment, their areas summed.
private func curvedBoxArea(_ curve: Curve) -> Float {
    var p: [(x: Float, y: Float)] = []
    for q in curve.points {
        let f = (x: Float(q.x), y: Float(q.y))
        if p.isEmpty || f.x != p[p.count - 1].x || f.y != p[p.count - 1].y { p.append(f) }
    }
    let n = p.count
    if n < 2 { return 0 }
    var angles: [Float] = []
    for i in 1..<n { angles.append(atan2f(p[i].y - p[i - 1].y, p[i].x - p[i - 1].x)) }
    let h = Float(curve.thickness) * 0.5
    var top: [(x: Float, y: Float)] = [], bottom: [(x: Float, y: Float)] = []
    for i in 0..<n {
        let a: Float
        if i == 0 {
            a = angles[0]
        } else if i == n - 1 {
            a = angles[angles.count - 1]
        } else {
            let a0 = angles[i - 1], a1 = angles[i]
            let sum = a0 + a1
            a = Double(abs(a0 - a1)) <= Double.pi ? sum * 0.5 : Float((Double(sum) + 2.0 * Double.pi) * 0.5)
        }
        let r = sinCos(Double(a) + -1.5707963267948966)
        let dx = h * Float(r.cos), dy = h * Float(r.sin)
        top.append((p[i].x + dx, p[i].y + dy))
        bottom.append((p[i].x - dx, p[i].y - dy))
    }
    func quadArea(_ q: [(x: Float, y: Float)]) -> Float {
        var acc: Float = 0
        for k in 0..<4 {
            let a = q[k], b = q[(k + 1) % 4]
            let c = (a.x * b.y) - (a.y * b.x)
            acc = Float(Double(c) * 0.5 + Double(acc))
        }
        return abs(acc)
    }
    var area: Float = 0
    for k in 0..<(n - 1) { area = area + quadArea([top[k], top[k + 1], bottom[k + 1], bottom[k]]) }
    return area
}

extension PageLayout {
    /// GetTextlineOrderBox: the paragraph box turned so that its lines run top to bottom.
    private func textlineOrderBox(_ p: Entity) -> RBox {
        var b = floatBox(p.box ?? RotatedBox())
        let order = p.textlineOrder ?? 0
        if order == 1 { rotateOrientationClockwise(&b, 1) }
        if order == 0 { rotateOrientationClockwise(&b, 3) }
        return b
    }

    /// The paragraphs in reading order. `lines` are the graph's lines (level order), `columns` their predictions.
    fileprivate func orderParagraphs(_ lines: [Int], _ edges: [GraphEdge], _ columns: [Bool]) -> [Int] {
        let childAreaOverlap: Float = 0.25
        let n = lines.count
        // Per paragraph, the line area predicted to read in columns and not; each line takes its paragraph's majority.
        var paragraphArea = [(columns: Float, rows: Float)](repeating: (0, 0), count: entities.count)
        for i in 0..<n {
            let e = entities[lines[i]]
            guard e.parent >= 0, let box = e.box else { continue }
            let b = floatBox(box)
            let a = box.curve.map { $0.points.count >= 2 ? curvedBoxArea($0) : b.w * b.h } ?? b.w * b.h
            if columns[i] { paragraphArea[e.parent].columns = a + paragraphArea[e.parent].columns }
            else { paragraphArea[e.parent].rows = a + paragraphArea[e.parent].rows }
        }
        let bit = (0..<n).map { i in
            let p = entities[lines[i]].parent
            return p >= 0 && !(paragraphArea[p].columns <= paragraphArea[p].rows)
        }
        struct EdgeMeta {
            var to: Int, dir: Int
            /// The union's height is under twice the smaller height (close), or under three times it plus both
            /// heights (near).
            var close: Bool, near: Bool
        }
        var adjacent = [[EdgeMeta]](repeating: [], count: n)
        for ge in edges {
            let A = entities[lines[ge.a]], B = entities[lines[ge.b]]
            if (A.writingDirection ?? 0) != (B.writingDirection ?? 0) { continue }
            let ra = A.box ?? RotatedBox(), rb = B.box ?? RotatedBox()
            var d = fmodf(abs(ra.angle - rb.angle), 360)
            if d > 180 { d = 360 - d }
            if d > 30 { continue }
            let minHeight = rb.height >= ra.height ? ra.height : rb.height
            let fa = floatBox(ra), fb = floatBox(rb)
            let u = containingBox([fa, fb])
            var dir = 0
            if u.w <= fa.w + fb.w {
                let r = sinCos((u.angle + 90) * degToRad)
                let (ax, ay) = center(fa), (bx, by) = center(fb)
                dir = ((r.sin * (ay - by)) + ((r.cos * (ax - bx)) + 0)) <= 0 ? -1 : 1
            }
            var ra2 = fa, rb2 = fb
            rotate(&ra2, 0, 0, -u.angle)
            axisAligned(&ra2)
            rotate(&rb2, 0, 0, -u.angle)
            axisAligned(&rb2)
            let mh = Float(minHeight)
            let near = u.h < (mh * 3) + (ra2.h + rb2.h)
            let close = u.h < mh + mh
            adjacent[ge.a].append(EdgeMeta(to: ge.b, dir: dir, close: close, near: near))
            adjacent[ge.b].append(EdgeMeta(to: ge.a, dir: -dir, close: close, near: near))
        }

        var nodes: [OrderNode] = []
        var nodeOf = [Int](repeating: -1, count: entities.count)
        var roots: [Int] = []
        // Every inserted (box, node); stale entries stay.
        var rtree: [(box: (x0: Double, y0: Double, x1: Double, y1: Double), node: Int)] = []
        var unvisited = [Bool](repeating: true, count: n)
        for i in 0..<n where unvisited[i] {
            let b = bit[i]
            var queue = [i]
            var head = 0
            unvisited[i] = false
            var component: [Int] = []
            while head < queue.count {
                let j = queue[head]
                head += 1
                component.append(j)
                for e in adjacent[j] {
                    if unvisited[e.to] && b == bit[e.to] && e.near {
                        queue.append(e.to)
                        unvisited[e.to] = false
                    } else if b && e.dir != 0 {
                        for e2 in adjacent[e.to] where unvisited[e2.to] && e2.dir + e.dir == 0 && bit[e2.to] && e2.close {
                            queue.append(e2.to)
                            unvisited[e2.to] = false
                        }
                    }
                }
            }
            let before = nodes.count
            for j in component {
                let line = entities[lines[j]]
                let p = line.parent
                if p < 0 { continue }
                let h: Float = line.box.map { $0.curve.map { Float($0.thickness) } ?? Float($0.height) } ?? 0
                if nodeOf[p] >= 0 {
                    nodes[nodeOf[p]].sumLineHeight = nodes[nodeOf[p]].sumLineHeight + h
                    nodes[nodeOf[p]].lineCount += 1
                    continue
                }
                nodeOf[p] = nodes.count
                nodes.append(OrderNode(paragraph: p, column: b, box: textlineOrderBox(entities[p]), sumLineHeight: h,
                                       lineCount: 1))
            }
            if nodes.count == before { continue }
            nodes.append(OrderNode(column: b, rtl: entities[lines[i]].writingDirection == 1))
            let bi = nodes.count - 1
            for k in before..<bi {
                nodes[bi].children.append(k)
                nodes[k].parent = bi
                computeNodeBox(&nodes, bi, referenceAngle: nil)
            }
            roots.append(bi)
            rtree.append((r2Box(nodes[bi].box), bi))
        }

        // Nest roots that overlap a bigger root by more than the threshold of their own area (smallest first).
        typealias Item = (area: Float, childCount: Int, node: Int)
        let greater: (Item, Item) -> Bool = { $0.area > $1.area }
        var changed = true
        while changed {
            changed = false
            var heap: [Item] = []
            for r in roots {
                heap.append((nodes[r].area, nodes[r].children.count, r))
                heap.libcxxPushHeap(by: greater)
            }
            roots.removeAll()
            while !heap.isEmpty {
                let top = heap.libcxxPopHeap(by: greater)
                let k = top.node
                if nodes[k].area != top.area || nodes[k].children.count != top.childCount { continue }
                sortOrderChildren(&nodes, k)
                let q = r2Box(nodes[k].box)
                var candidates = Set<Int>()
                for (r, id) in rtree where r.x0 <= q.x1 && !(r.x1 < q.x0 || r.y0 > q.y1) && r.y1 >= q.y0 {
                    candidates.insert(id)
                }
                for m in candidates.sorted() where m != k && nodes[m].parent == -1 {
                    let overlap = boxOverlapArea(nodes[k].box, nodes[m].box)
                    if overlap > nodes[k].area * childAreaOverlap {
                        nodes[m].children.append(k)
                        nodes[k].parent = m
                        nodes[m].sorted = false
                        computeNodeBox(&nodes, m, referenceAngle: nodes[m].box.angle)
                        heap.append((nodes[m].area, nodes[m].children.count, m))
                        heap.libcxxPushHeap(by: greater)
                        rtree.append((r2Box(nodes[m].box), m))
                        changed = true
                        break
                    }
                }
                if nodes[k].parent == -1 { roots.append(k) }
            }
        }

        nodes.append(OrderNode(column: false))  // row_wise_at_top_level
        let ri = nodes.count - 1
        var rtl = 0
        for k in 0..<ri where nodes[k].parent == -1 {
            nodes[k].parent = ri
            nodes[ri].children.append(k)
            rtl += nodes[k].rtl ? 1 : 0
        }
        if nodes[ri].children.isEmpty { return [] }
        nodes[ri].rtl = 2 * rtl > nodes[ri].children.count
        computeNodeBox(&nodes, ri, referenceAngle: nil)
        sortOrderChildren(&nodes, ri)
        var order: [Int] = []
        traverse(nodes, ri, &order)
        return order
    }

    /// ClusterSortGcnStep (skip_line_clustering, recompute_entity_boxes_and_confidences, sort_lines_in_paragraphs;
    /// no heuristic blocks): one BLOCK per paragraph, in reading order.
    mutating func clusterSort(_ model: LayoutModel) throws {
        let g = lineGraph()
        var columns = [Bool](repeating: false, count: g.lines.count)
        if !g.edges.isEmpty {
            let logits = try model.nodeLogits(senders: g.edges.map(\.a), receivers: g.edges.map(\.b),
                                              features: lineNodeFeatures(g, scale: Float(width)), lines: g.lines.count)
            for k in logits.indices { columns[k] = logits[k] > 0 }
        }
        var lines = g.lines
        func track(_ remap: [Int]) { lines = lines.map { $0 >= 0 ? remap[$0] : -1 } }

        track(reorderUsingDfs())
        var children = childLists()
        for e in descendants(children).reversed() { robustBoxEstimation(e, children) }
        recomputeConfidencesFromSymbols()
        children = childLists()
        var delete = [Bool](repeating: false, count: entities.count)
        for i in entities.indices where entities[i].type == .paragraph {
            if children[i].isEmpty {
                delete[i] = true
                continue
            }
            let p = entities[i]
            if p.orientation == nil && p.writingDirection == nil && p.textlineOrder == nil {
                let c = entities[children[i][0]]
                entities[i].orientation = c.orientation
                entities[i].writingDirection = c.writingDirection
                entities[i].textlineOrder = c.textlineOrder
            }
        }
        track(deleteWithDescendants(delete))
        children = childLists()
        for i in entities.indices where entities[i].type == .paragraph { sortChildren(of: i, children, track: &lines) }

        let order = orderParagraphs(lines, g.edges, columns)
        var oldBlocks = entities.map { $0.type == .block }
        for p in order {
            var block = Entity()
            block.type = .block
            block.orientation = entities[p].orientation
            block.writingDirection = entities[p].writingDirection
            block.textlineOrder = entities[p].textlineOrder
            block.box = entities[p].box
            entities.append(block)
            entities[p].parent = entities.count - 1
        }
        oldBlocks += [Bool](repeating: false, count: entities.count - oldBlocks.count)
        deleteWithDescendants(oldBlocks)
        reorderUsingDfs()
        recomputeConfidencesFromSymbols()
    }
}
