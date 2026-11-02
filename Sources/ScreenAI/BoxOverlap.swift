import Foundation

// Overlap areas of rotated boxes as google_ocr::box_util and google_ocr::Rectangle<float> compute them, with the
// same float operations in the same order (no fused multiply-adds).

let degToRad = Float(bitPattern: 0x3C8E_FA35)  // 0.017453292

/// box_util RotatedBox<float>: (x, y) is the top-left corner before the rotation about it; angle in degrees,
/// clockwise.
struct RBox {
    var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0, angle: Float = 0
}

/// google_ocr::Rectangle<float>: left, top, width, height, and the angle's unit direction (cos, sin).
private struct Rect {
    var l: Float, t: Float, w: Float, h: Float, c: Float, s: Float
    var isAxisAligned: Bool { c == 1 && s == 0 }

    init(l: Float, t: Float, w: Float, h: Float, c: Float, s: Float) {
        (self.l, self.t, self.w, self.h, self.c, self.s) = (l, t, w, h, c, s)
    }

    /// Rectangle<float>::CreateFromLTWHA.
    init(_ b: RBox) {
        let r = sinCos(b.angle * degToRad)
        self.init(l: b.x, t: b.y, w: b.w, h: b.h, c: r.cos, s: r.sin)
    }
}

/// (-180, 180].
func normalizeAngle(_ a0: Float) -> Float {
    var a = a0
    while a <= -180 { a += 360 }
    while a > 180 { a -= 360 }
    return a
}

/// Rectangle<float>::IntersectAxisAlignedNonAxisAligned (`a` axis aligned): Sutherland-Hodgman clip of b's corners
/// against a's top, right, bottom and left edges, then the shoelace area.
private func intersectAxisAlignedNonAxisAligned(_ a: Rect, _ b: Rect) -> Float {
    var pts: [(x: Float, y: Float)]
    if b.isAxisAligned {
        let r = b.w + b.l, bt = b.t + b.h
        pts = [(b.l, b.t), (r, b.t), (r, bt), (b.l, bt)]
    } else {
        let x1 = b.l + (b.w * b.c), y1 = b.t + (b.w * b.s)
        let ch = b.c * b.h, sh = b.s * b.h
        pts = [(b.l, b.t), (x1, y1), (x1 - sh, y1 + ch), (b.l - sh, b.t + ch)]
    }
    // Horizontal edge y = v (keep y >= v when `ge`): x = p.x + ((v - p.y) * (q.x - p.x)) / (q.y - p.y).
    func clipH(_ src: [(x: Float, y: Float)], _ v: Float, _ ge: Bool) -> [(x: Float, y: Float)] {
        var dst: [(x: Float, y: Float)] = []
        for i in src.indices {
            let p = src[i], q = src[i + 1 == src.count ? 0 : i + 1]
            let pin = ge ? p.y >= v : p.y <= v
            let cross = pin ? (ge ? q.y < v : q.y > v) : (ge ? q.y > v : q.y < v)
            if pin { dst.append(p) }
            if cross { dst.append((p.x + (((v - p.y) * (q.x - p.x)) / (q.y - p.y)), v)) }
        }
        return dst
    }
    // Vertical edge x = v: y = p.y + ((v - p.x) * (q.y - p.y)) / (q.x - p.x).
    func clipV(_ src: [(x: Float, y: Float)], _ v: Float, _ ge: Bool) -> [(x: Float, y: Float)] {
        var dst: [(x: Float, y: Float)] = []
        for i in src.indices {
            let p = src[i], q = src[i + 1 == src.count ? 0 : i + 1]
            let pin = ge ? p.x >= v : p.x <= v
            let cross = pin ? (ge ? q.x < v : q.x > v) : (ge ? q.x > v : q.x < v)
            if pin { dst.append(p) }
            if cross { dst.append((v, p.y + (((v - p.x) * (q.y - p.y)) / (q.x - p.x)))) }
        }
        return dst
    }
    pts = clipH(pts, a.t, true)
    if pts.count < 3 { return 0 }
    pts = clipV(pts, a.l + a.w, false)
    if pts.count < 3 { return 0 }
    pts = clipH(pts, a.t + a.h, false)
    if pts.count < 3 { return 0 }
    pts = clipV(pts, a.l, true)
    if pts.count < 3 { return 0 }
    var sum: Float = 0
    for i in 0..<pts.count - 1 { sum = sum + ((pts[i].x * pts[i + 1].y) - (pts[i].y * pts[i + 1].x)) }
    let n = pts.count
    return abs((sum + ((pts[n - 1].x * pts[0].y) - (pts[n - 1].y * pts[0].x))) * 0.5)
}

/// Rectangle<float>::OverlapArea.
private func rectOverlapArea(_ a: Rect, _ b: Rect) -> Float {
    if a.isAxisAligned && b.isAxisAligned {
        let l = b.l > a.l ? b.l : a.l, t = b.t > a.t ? b.t : a.t
        var r = a.l + a.w, bt = a.t + a.h
        let br = b.l + b.w, bb = b.t + b.h
        if r > br { r = br }
        if bt > bb { bt = bb }
        var w = r - l, h = bt - t
        if w < 0 { w = 0 }
        if h < 0 { h = 0 }
        return w * h
    }
    if a.isAxisAligned { return intersectAxisAlignedNonAxisAligned(a, b) }
    if b.isAxisAligned { return intersectAxisAlignedNonAxisAligned(b, a) }
    // Both rotated: into a's frame, where a is axis aligned.
    let c = a.c, s = a.s
    let ra = Rect(l: (c * a.l) + (s * a.t), t: (c * a.t) - (s * a.l), w: a.w, h: a.h, c: 1, s: 0)
    let rb = Rect(l: (c * b.l) + (s * b.t), t: (c * b.t) - (s * b.l), w: b.w, h: b.h, c: (c * b.c) + (s * b.s),
                  s: (c * b.s) - (s * b.c))
    return intersectAxisAlignedNonAxisAligned(ra, rb)
}

/// AxisAlignedBoxOverlapArea<Box<float>>.
func axisAlignedOverlapArea(_ a: RBox, _ b: RBox) -> Float {
    let l = a.x >= b.x ? a.x : b.x
    var r = a.x + a.w
    if b.x + b.w < r { r = b.x + b.w }
    let w = r - l
    if !(w >= 0) { return 0 }
    let t = a.y >= b.y ? a.y : b.y
    var bt = a.y + a.h
    if b.y + b.h < bt { bt = b.y + b.h }
    let h = bt - t
    return h < 0 ? 0 : w * h
}

/// SafeBoxOverlapArea for boxes without a curve: both angles 0 is axis aligned, else Rectangle<float> OverlapArea.
func boxOverlapArea(_ a: RBox, _ b: RBox) -> Float {
    if a.angle == 0 && b.angle == 0 { return axisAlignedOverlapArea(a, b) }
    return rectOverlapArea(Rect(a), Rect(b))
}

/// CopyBoundingBox<RotatedBox<float>, AlignedBox<float>>: the box itself when its normalized angle is 0, else the
/// bounds of its four corners.
func alignedBox(_ b: RBox) -> RBox {
    if normalizeAngle(b.angle) == 0 { return RBox(x: b.x, y: b.y, w: b.w, h: b.h) }
    let r = sinCos(b.angle * degToRad)
    let sh = r.sin * b.h, ch = r.cos * b.h
    let x1 = b.x + (r.cos * b.w), y1 = b.y + (r.sin * b.w)
    let p: [(x: Float, y: Float)] = [(b.x, b.y), (x1, y1), (x1 - sh, y1 + ch), (b.x + -sh, b.y + ch)]
    var mn = p[0], mx = p[0]
    for k in 1..<4 {
        if mn.x > p[k].x { mn.x = p[k].x }
        if mn.y > p[k].y { mn.y = p[k].y }
        if p[k].x > mx.x { mx.x = p[k].x }
        if p[k].y > mx.y { mx.y = p[k].y }
    }
    return RBox(x: mn.x, y: mn.y, w: mx.x - mn.x, h: mx.y - mn.y)
}

struct OverlapInfo {
    /// Intersection over union, over the first box's area, over the second's.
    var iou: Float = 0, overFirst: Float = 0, overSecond: Float = 0
}

struct IndexPair: Hashable {
    var a: Int, b: Int
}

/// box_util::OverlapComputer: pairs whose aligned boxes overlap with a nonzero area and whose overlap area is
/// nonzero, stored both ways. With split >= 0, only pairs between [0, split) and [split, n).
func computeOverlaps(_ boxes: [RBox], split: Int) -> [IndexPair: OverlapInfo] {
    var m: [IndexPair: OverlapInfo] = [:]
    let n = boxes.count
    let aligned = boxes.map(alignedBox)
    func candidate(_ i: Int, _ j: Int) -> Bool {
        let p = aligned[i], q = aligned[j]
        if !(p.w > 0 && p.h > 0 && q.w > 0 && q.h > 0) { return false }
        let l = p.x >= q.x ? p.x : q.x
        var r = p.x + p.w
        if q.x + q.w < r { r = q.x + q.w }
        let w = r - l
        if !(w >= 0) { return false }
        let t = p.y >= q.y ? p.y : q.y
        var bt = p.y + p.h
        if q.y + q.h < bt { bt = q.y + q.h }
        let h = bt - t
        return h >= 0 && w * h != 0
    }
    for a in 0..<n {
        if split >= 0 && a >= split { break }
        var b = split >= 0 ? (a + 1 > split ? a + 1 : split) : a + 1
        while b < n {
            defer { b += 1 }
            if !candidate(a, b) { continue }
            let A = boxes[a], B = boxes[b]
            let inter = boxOverlapArea(A, B)
            if inter == 0 { continue }
            let aa = A.w * A.h, ab = B.w * B.h
            let iou = inter / ((aa + ab) - inter)
            m[IndexPair(a: a, b: b)] = OverlapInfo(iou: iou, overFirst: inter / aa, overSecond: inter / ab)
            m[IndexPair(a: b, b: a)] = OverlapInfo(iou: iou, overFirst: inter / ab, overSecond: inter / aa)
        }
    }
    return m
}
