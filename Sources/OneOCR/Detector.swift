import CoreML
import Foundation

// The text detector (RelationRCNNRpn2): the int8 network on Core ML, then segment proposals, chain grouping,
// polynomial line fitting, textline NMS and line merging, all computed operation by operation as oneocr does
// (float32 without FMA contraction except where it computes in double), so the polygons come out identical.

/// A detected text line, in original image pixel coordinates. The first half of `polygon` is the upper chain
/// (left to right; for vertical lines the right edge, top to bottom), the second half the under chain.
struct DetectedLine {
    var polygon: [Pt]
    var score: Float
    var isHorizontal: Bool
    var isAmbiguous: Bool
    var isPolygon: Bool
}

struct DetectorConfig {
    var imageResizeFactor = 32
    var useFloorResize = false
    var lineMergeThreshold = 4.0
    var lineMergeRatio = 2.0
    var textlineNMSThreshold: Float = 0.2
    var textlineOverlapThreshold: Float = 0.4
    var textlineConfThreshold: [Int: Float] = [2: 0.7, 3: 0.8, 4: 0.8, 5: 0.8]
    var keepAmbiguousLine = true
    var ambiguousNMSThreshold: Float = 0.3
    var ambiguousOverlapConst: Float = 0.4
    var ambiguousOverlapThreshold: Float = 0.5
    var ambiguousSaveThreshold: Float = 0.4

    /// The first det_model entry of config.json.
    init(_ cfg: [String: Any]?) {
        guard let c = cfg else { return }
        func num(_ k: String) -> Double? { (c[k] as? NSNumber)?.doubleValue }
        if let v = num("image_resize_factor") { imageResizeFactor = Int(v) }
        if let v = c["use_floor_resize"] as? Bool { useFloorResize = v }
        if let v = num("line_merge_threshold") { lineMergeThreshold = v }
        if let v = num("textline_nms_threshold") { textlineNMSThreshold = Float(v) }
        if let v = num("textline_onverlap_threshold") { textlineOverlapThreshold = Float(v) }
        if let v = c["keep_ambiguous_line"] as? Bool { keepAmbiguousLine = v }
        if let v = num("ambiguous_nms_threshold") { ambiguousNMSThreshold = Float(v) }
        if let v = num("ambiguous_overlap_threshold") { ambiguousOverlapThreshold = Float(v) }
        if let v = num("ambiguous_save_threshold") { ambiguousSaveThreshold = Float(v) }
        if let m = c["textline_conf_threshold"] as? [String: Any] {
            for (k, v) in m {
                if let level = Int(k.trimmingCharacters(in: CharacterSet(charactersIn: "Pp"))),
                   let t = (v as? NSNumber)?.doubleValue {
                    textlineConfThreshold[level] = Float(t)
                }
            }
        }
    }
}

// MARK: - TextLinePolygon

final class DetPoly {
    var pts: [Pt]
    var multi: Bool
    var amb = false
    var score: Float
    let hori: Bool
    let level: Int
    var index = 0
    var xmin = 0.0, xmax = 0.0, ymin = 0.0, ymax = 0.0
    var area: Float = 0
    var bboxArea = 0.0
    var cx: Float = 0, cy: Float = 0
    var meanH: Float = 0
    var mid: [Pt] = []
    private var tri: [Geom32.StripPair]?

    init(_ pts: [Pt], score: Float, hori: Bool, level: Int) throws {
        if pts.count % 2 != 0 { throw GeometryCheckError() }
        self.pts = pts
        multi = pts.count > 4
        self.score = score
        self.hori = hori
        self.level = level
        try recompute()
    }

    var upper: ArraySlice<Pt> { pts[0..<(pts.count / 2)] }
    var under: ArraySlice<Pt> { pts[(pts.count / 2)...] }

    func recompute() throws {
        guard !pts.isEmpty else { throw GeometryCheckError() }
        var x0 = pts[0].x, x1 = pts[0].x, y0 = pts[0].y, y1 = pts[0].y
        for p in pts.dropFirst() {
            x0 = pmin(x0, p.x)
            x1 = pmax(x1, p.x)
            y0 = pmin(y0, p.y)
            y1 = pmax(y1, p.y)
        }
        guard x0.isFinite, x1.isFinite, y0.isFinite, y1.isFinite else { throw GeometryCheckError() }
        xmin = Double(x0).rounded(.down)
        xmax = Double(x1).rounded(.up)
        ymin = Double(y0).rounded(.down)
        ymax = Double(y1).rounded(.up)
        area = abs(Geom32.shoelace(pts))
        bboxArea = (xmax - xmin + 1) * (ymax - ymin + 1)
        var sx: Float = 0, sy: Float = 0
        for p in pts {
            sx = p.x + sx
            sy = p.y + sy
        }
        cx = sx / Float(pts.count)
        cy = sy / Float(pts.count)
        let up = Array(upper), rv = Array(under.reversed())
        var acc: Float = 0
        for (u, l) in zip(up, rv) {
            acc = (CRT.powf(u.y - l.y, 2) + CRT.powf(u.x - l.x, 2)).squareRoot() + acc
        }
        meanH = acc / Float(rv.count)
        mid = zip(up, rv).map { u, l in Pt((l.x + u.x) * 0.5, (u.y + l.y) * 0.5) }
        tri = nil
    }

    func strip() throws -> [Geom32.StripPair] {
        if let t = tri { return t }
        let t = try Geom32.stripPairs(Array(upper), Array(under))
        tri = t
        return t
    }
}

/// Intersection areas per pair of line indices, shared by NMS and merging and never invalidated (as in oneocr).
private struct InterCache {
    var d: [Int: Float] = [:]

    mutating func inter(_ a: DetPoly, _ b: DetPoly) throws -> Float {
        let key = min(a.index, b.index) << 32 | max(a.index, b.index)
        if let v = d[key] { return v }
        let v = a.index != b.index ? try Geom32.stripIntersection(a.strip(), b.strip()) : a.area
        d[key] = v
        return v
    }

    /// mode 0: IoU, mode 1: intersection / area(a).
    mutating func ratio(_ a: DetPoly, _ b: DetPoly, _ mode: Int) throws -> Float {
        let it = try inter(a, b)
        return mode == 0 ? it / ((a.area + b.area) - it) : it / a.area
    }
}

// MARK: - Polynomial fitting

enum PolyFit {
    /// Least squares polynomial of degree min(n-1, 2) in double (uBLAS LU of the normal equations), as
    /// float32-rounded coefficients (c0, c1, c2).
    static func fit(_ t: [Double], _ v: [Double], deg: Int = 2) -> [Double] {
        let n = t.count
        var out = [0.0, 0.0, 0.0]
        if n == 0 { return out }
        let m = min(n - 1, deg) + 1
        var cols = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
        for k in 0..<n {
            var p = 1.0
            for r in 0..<m {
                cols[r][k] = p
                p = t[k] * p
            }
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for i in 0..<a.count { s = a[i] * b[i] + s }
            return s
        }
        var N = (0..<m).map { r in (0..<m).map { c in dot(cols[r], cols[c]) } }
        var rhs = (0..<m).map { dot(cols[$0], v) }
        var perm = Array(0..<m)
        var singular = 0
        for i in 0..<m {
            var piv = i, best = 0.0
            for r in i..<m {
                let a = abs(N[r][i])
                if a > best {
                    best = a
                    piv = r
                }
            }
            if N[piv][i] != 0 {
                if piv != i {
                    perm[i] = piv
                    N.swapAt(i, piv)
                }
                let inv = 1.0 / N[i][i]
                for r in (i + 1)..<max(m, i + 1) { N[r][i] = inv * N[r][i] }
            } else if singular == 0 {
                singular = i + 1
            }
            for r in (i + 1)..<max(m, i + 1) {
                for c in (i + 1)..<m { N[r][c] = N[r][c] - N[i][c] * N[r][i] }
            }
        }
        var c: [Double]
        if singular != 0 {
            c = fitSVD(t, v, m - 1)
        } else {
            for i in 0..<m where perm[i] != i { rhs.swapAt(i, perm[i]) }
            for i in 0..<m {
                let x = rhs[i]
                if x != 0 {
                    for j in (i + 1)..<max(m, i + 1) { rhs[j] = rhs[j] - N[j][i] * x }
                }
            }
            for k in stride(from: m - 1, through: 0, by: -1) {
                let x = rhs[k] / N[k][k]
                rhs[k] = x
                if x != 0 {
                    for j in stride(from: k - 1, through: 0, by: -1) { rhs[j] = rhs[j] - N[j][k] * x }
                }
            }
            c = rhs
        }
        for i in 0..<min(m, c.count) { out[i] = Double(Float(c[i])) }
        return out
    }

    private static func cvIPow(_ x: Double, _ k: Int) -> Double {
        if k == 0 { return 1 }
        if k == 1 { return x }
        if k == 2 { return x * x }
        var a = 1.0, b = x, p = k
        while p > 1 {
            if p & 1 != 0 { a = a * b }
            b = b * b
            p >>= 1
        }
        return a * b
    }

    /// X^T v as cv::gemm computes it for a single result column.
    private static func gemmATAVec(_ cols: [[Double]], _ v: [Double], _ rowsD: Int) -> [Double] {
        let n = v.count
        return cols.map { c in
            if n <= 10000 {
                var s = [0.0, 0.0, 0.0, 0.0]
                var k = 0
                while k <= n - 4 {
                    for q in 0..<4 { s[q] = c[k + q] * v[k + q] + s[q] }
                    k += 4
                }
                while k < n {
                    s[0] = c[k] * v[k] + s[0]
                    k += 1
                }
                return ((s[0] + s[1]) + s[2]) + s[3]
            }
            let dk0 = min(16384 / min(128, rowsD), 16384, n)
            var acc = 0.0, k = 0, first = true
            while k < n {
                var dk = dk0
                if k + dk >= n || 8 * (k + dk) + dk > 8 * n { dk = n - k }
                var s0 = first ? 0.0 : acc, s1 = 0.0
                var j = 0
                while j <= dk - 2 {
                    s0 = c[k + j] * v[k + j] + s0
                    s1 = c[k + j + 1] * v[k + j + 1] + s1
                    j += 2
                }
                while j < dk {
                    s0 = c[k + j] * v[k + j] + s0
                    j += 1
                }
                acc = s0 + s1
                first = false
                k += dk
            }
            return acc
        }
    }

    /// OpenCV's one-sided Jacobi SVD (JacobiSVDImpl_<double>) on the n rows (length m) of At, in place.
    private static func jacobiSVD(_ At: inout [[Double]], _ m: Int, _ n: Int) -> ([Double], [[Double]]) {
        let eps = 2.220446049250313e-15, minval = 2.2250738585072014e-308
        var W = [Double](repeating: 0, count: n)
        var Vt = (0..<n).map { r in (0..<n).map { c in r == c ? 1.0 : 0.0 } }
        for i in 0..<n {
            var sd = 0.0
            for k in 0..<m { sd = At[i][k] * At[i][k] + sd }
            W[i] = sd
        }
        for _ in 0..<max(m, 30) {
            var changed = false
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    var a = W[i], b = W[j]
                    var p = 0.0
                    for k in 0..<m { p = At[j][k] * At[i][k] + p }
                    if !(abs(p) > (b * a).squareRoot() * eps) { continue }
                    p = p + p
                    let beta = a - b
                    let fb = abs(beta), fp = abs(p)
                    let gamma: Double
                    if fp <= fb {
                        gamma = fb <= 0 ? 0 : (fp / fb * (fp / fb) + 1).squareRoot() * fb
                    } else {
                        gamma = (fb / fp * (fb / fp) + 1).squareRoot() * fp
                    }
                    let c: Double, s: Double
                    if beta >= 0 {
                        c = ((gamma + beta) / (gamma + gamma)).squareRoot()
                        s = p / (gamma * c + gamma * c)
                    } else {
                        s = ((gamma - beta) * 0.5 / gamma).squareRoot()
                        c = p / (gamma * s + gamma * s)
                    }
                    a = 0
                    b = 0
                    for k in 0..<m {
                        let xi = At[i][k], xj = At[j][k]
                        let t0 = xj * s + c * xi
                        let t1 = xj * c - s * xi
                        At[i][k] = t0
                        At[j][k] = t1
                        a = t0 * t0 + a
                        b = t1 * t1 + b
                    }
                    W[i] = a
                    W[j] = b
                    changed = true
                    for k in 0..<n {
                        let xi = Vt[i][k], xj = Vt[j][k]
                        Vt[i][k] = xi * c + xj * s
                        Vt[j][k] = xj * c - xi * s
                    }
                }
            }
            if !changed { break }
        }
        for i in 0..<n {
            var sd = 0.0
            for k in 0..<m { sd = At[i][k] * At[i][k] + sd }
            W[i] = sd.squareRoot()
        }
        for i in 0..<max(n - 1, 0) {
            var j = i
            for k in (i + 1)..<n where W[j] < W[k] { j = k }
            if i != j {
                W.swapAt(i, j)
                At.swapAt(i, j)
                Vt.swapAt(i, j)
            }
        }
        var state: UInt64 = 0x1234_5678
        for i in 0..<n {
            var sd = W[i]
            var ii = 0
            while sd <= minval && ii < 100 {
                let val0 = 1.0 / Double(m)
                for k in 0..<m {
                    state = (state & 0xFFFF_FFFF) &* 4_164_903_690 &+ (state >> 32)
                    At[i][k] = state & 256 != 0 ? val0 : -val0
                }
                for _ in 0..<2 {
                    for j in 0..<i {
                        sd = 0
                        for k in 0..<m { sd = At[i][k] * At[j][k] + sd }
                        var asum = 0.0
                        for k in 0..<m {
                            let t = At[i][k] - At[j][k] * sd
                            At[i][k] = t
                            asum = abs(t) + asum
                        }
                        asum = asum <= eps * 100 ? 0 : 1 / asum
                        for k in 0..<m { At[i][k] = At[i][k] * asum }
                    }
                }
                sd = 0
                for k in 0..<m { sd = At[i][k] * At[i][k] + sd }
                sd = sd.squareRoot()
                ii += 1
            }
            let s = sd > minval ? 1 / sd : 0
            for k in 0..<m { At[i][k] = At[i][k] * s }
        }
        return (W, Vt)
    }

    /// The OpenCV fallback (cv::solve with DECOMP_SVD) used when the LU is exactly singular.
    private static func fitSVD(_ t: [Double], _ v: [Double], _ d0: Int) -> [Double] {
        let n = t.count
        let d = min(d0, n - 1)
        if d < 1 { return [Double](repeating: 0, count: max(d + 1, 0)) }
        let m = d + 1
        let cols = (0..<m).map { k in t.map { cvIPow($0, k) } }
        var N = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for r in 0..<m {
            for c in 0..<m {
                var s = 0.0
                for k in 0..<n { s = cols[r][k] * cols[c][k] + s }
                N[r][c] = s
            }
        }
        let rhs = gemmATAVec(cols, v, m)
        var At = (0..<m).map { r in (0..<m).map { c in N[c][r] } }
        let (W, Vt) = jacobiSVD(&At, m, m)
        var thr = 0.0
        for w in W { thr = w + thr }
        thr = thr * 4.440892098500626e-16
        var x = [Double](repeating: 0, count: m)
        for i in 0..<m {
            var wi = W[i]
            if !(abs(wi) > thr) { continue }
            wi = 1 / wi
            var s = 0.0
            for j in 0..<m { s = rhs[j] * At[i][j] + s }
            s = s * wi
            for j in 0..<m { x[j] = Vt[i][j] * s + x[j] }
        }
        return x
    }

    /// Corner evaluation: float32 Horner over (c0, c1, c2).
    static func horner32(_ c: [Double], _ t: Float) -> Float {
        var v: Float = 0
        for k in [2, 1, 0] { v = t * v + Float(c[k]) }
        return v
    }

    /// Point evaluation with the cubic coefficients (0, c2, c1, c0).
    static func poly3(_ c: [Double], _ t: Float) -> Float {
        var v = CRT.powf(t, 2) * Float(c[2])
        v = v + CRT.powf(t, 3) * 0
        return (v + Float(c[1]) * t) + Float(c[0])
    }

    /// Fit both chains and evaluate the corners (TL, TR, BR, BL); curved: a quadratic coefficient > 0.05.
    static func fitAndCorners(_ hori: Bool, _ ux: [Float], _ uy: [Float], _ lx: [Float], _ ly: [Float])
        -> (corners: [Pt], cu: [Double], cl: [Double], curved: Bool) {
        let d = { (a: [Float]) in a.map(Double.init) }
        let mn = { (a: [Float]) in a.dropFirst().reduce(a[0], pmin) }
        let mx = { (a: [Float]) in a.dropFirst().reduce(a[0], pmax) }
        let cu: [Double], cl: [Double], corners: [Pt]
        if hori {
            cu = fit(d(ux), d(uy))
            cl = fit(d(lx), d(ly))
            let xs = [mn(ux), mx(ux), mx(lx), mn(lx)]
            corners = [Pt(xs[0], horner32(cu, xs[0])), Pt(xs[1], horner32(cu, xs[1])),
                       Pt(xs[2], horner32(cl, xs[2])), Pt(xs[3], horner32(cl, xs[3]))]
        } else {
            cu = fit(d(uy), d(ux))
            cl = fit(d(ly), d(lx))
            let ys = [mn(ly), mn(uy), mx(uy), mx(ly)]
            corners = [Pt(horner32(cl, ys[0]), ys[0]), Pt(horner32(cu, ys[1]), ys[1]),
                       Pt(horner32(cu, ys[2]), ys[2]), Pt(horner32(cl, ys[3]), ys[3])]
        }
        let a = abs(Float(cl[2])), b = abs(Float(cu[2]))
        return (corners, cu, cl, (a <= b ? b : a) > Float(0.05))
    }

    /// The polygon points from the corners: up to 8 points per chain, depending on the aspect ratio.
    static func polygonPoints(_ corners: [Pt], _ hori: Bool, _ cu: [Double], _ cl: [Double]) -> [Pt] {
        let P = hori ? corners : [corners[1], corners[2], corners[3], corners[0]]
        let p0 = P[0], p1 = P[1], p2 = P[2], p3 = P[3]
        let thick = ((p0.x - p3.x) * (p0.x - p3.x) + (p0.y - p3.y) * (p0.y - p3.y)).squareRoot()
        let along = ((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)).squareRoot()
        var n = 0
        if Double(thick) > 1e-6 {
            let r = along / thick
            let ri: Int
            if r.isFinite {
                ri = Int(r)
            } else {
                ri = r.isNaN || r < 0 ? Int(Int32.min) : Int(Int32.max)
            }
            n = min(max(ri, 0), 8)
        }
        var out = [p0]
        func inter(_ a: Pt, _ b: Pt, _ c: [Double]) {
            if n - 1 <= 1 { return }
            let den = Float(n - 1)
            if hori {
                let step = (b.x - a.x) / den
                for k in 1..<(n - 1) {
                    let t = Float(k) * step + a.x
                    out.append(Pt(t, poly3(c, t)))
                }
            } else {
                let step = (b.y - a.y) / den
                for k in 1..<(n - 1) {
                    let t = Float(k) * step + a.y
                    out.append(Pt(poly3(c, t), t))
                }
            }
        }
        inter(p0, p1, cu)
        out.append(p1)
        out.append(p2)
        inter(p2, p3, cl)
        out.append(p3)
        return out
    }
}

// MARK: - Segment proposals

private struct Seg {
    let q: [Pt]
    let score: Float
    let hori: Bool
    let cx: Float, cy: Float
    let aabb: (Float, Float, Float, Float)
    let slope: Float
    let area: Float

    init(_ q: [Pt], _ score: Float, _ hori: Bool) {
        self.q = q
        self.score = score
        self.hori = hori
        let (x0, y0, x1, y1, x2, y2, x3, y3) = (q[0].x, q[0].y, q[1].x, q[1].y, q[2].x, q[2].y, q[3].x, q[3].y)
        cx = (((x0 + x1) + x2) + x3) * 0.25
        cy = (((y0 + y1) + y2) + y3) * 0.25
        aabb = (pmin(x0, x3), pmin(y0, y1), pmax(x1, x2), pmax(y2, y3))
        let h: Float = 0.5
        if hori {
            slope = ((y2 + y1) * h - (y3 + y0) * h) / ((x2 + x1) * h - (x3 + x0) * h)
        } else {
            slope = ((x3 + x2) * h - (x0 + x1) * h) / ((y2 + y3) * h - (y1 + y0) * h)
        }
        area = abs(Geom32.shoelace(q))
    }
}

private enum Proposals {
    static let scoreThr: Float = 0.7
    static let linkThr: Float = 0.8
    static let nmsThr: Float = 0.5
    static let neighbors = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]

    static func affinity(_ a: Seg, _ b: Seg) throws -> Float {
        guard a.aabb.0 < b.aabb.2 && b.aabb.0 < a.aabb.2 && a.aabb.1 < b.aabb.3 && b.aabb.1 < a.aabb.3 else { return 0 }
        let it = try Geom32.quadIntersection(a.q, b.q)
        if abs(it) < Geom32.epsOrient { return 0 }
        return it / ((b.area + a.area) - it)
    }

    static func components(_ score: [Float], _ links: [Float], _ fh: Int, _ fw: Int, _ vh: Int, _ vw: Int) -> [[Int]] {
        let plane = fh * fw
        var visited = [Bool](repeating: false, count: plane)
        var comps: [[Int]] = []
        for r0 in 0..<vh {
            for c0 in 0..<vw where score[r0 * fw + c0] >= scoreThr && !visited[r0 * fw + c0] {
                visited[r0 * fw + c0] = true
                var comp = [r0 * fw + c0]
                var qi = 0
                while qi < comp.count {
                    let p = comp[qi]
                    let r = p / fw, c = p % fw
                    qi += 1
                    for (k, (dr, dc)) in neighbors.enumerated() {
                        if r == 0 && k < 3 { continue }
                        if r == vh - 1 && k > 4 { continue }
                        if c == 0 && (k == 0 || k == 3 || k == 5) { continue }
                        if c == vw - 1 && (k == 2 || k == 4 || k == 7) { continue }
                        let pp = (r + dr) * fw + c + dc
                        if !(score[pp] >= scoreThr) || visited[pp] { continue }
                        if links[k * plane + p] >= linkThr || links[(7 - k) * plane + pp] >= linkThr {
                            visited[pp] = true
                            comp.append(pp)
                        }
                    }
                }
                comps.append(comp)
            }
        }
        return comps
    }

    /// Greedy NMS on the AABBs (+1 convention), boxes already sorted.
    static func aabbNMS(_ b: [(Float, Float, Float, Float)], _ thr: Float) -> [Int] {
        let n = b.count
        var keep: [Int] = []
        var suppressed = [Bool](repeating: false, count: n)
        for i in 0..<n where !suppressed[i] {
            keep.append(i)
            let (x1, y1, x2, y2) = b[i]
            let ai = ((x2 - x1) + 1) * ((y2 - y1) + 1)
            for j in (i + 1)..<max(n, i + 1) {
                let (X1, Y1, X2, Y2) = b[j]
                if x1 > X2 || y1 > Y2 || x2 < X1 || y2 < Y1 { continue }
                let xx1 = x1 >= X1 ? x1 : X1, yy1 = y1 >= Y1 ? y1 : Y1
                let xx2 = X2 >= x2 ? x2 : X2, yy2 = Y2 >= y2 ? y2 : Y2
                var w = (xx2 - xx1) + 1
                if w <= 0 { w = 0 }
                var h = (yy2 - yy1) + 1
                if h <= 0 { h = 0 }
                let inter = w * h
                let aj = ((X2 - X1) + 1) * ((Y2 - Y1) + 1)
                if inter / ((ai + aj) - inter) >= thr { suppressed[j] = true }
            }
        }
        return keep
    }

    static func slopeBetween(_ a: Seg, _ b: Seg, _ hori: Bool) -> Float {
        if hori { return a.cx != b.cx ? (a.cy - b.cy) / (a.cx - b.cx) : .greatestFiniteMagnitude }
        return a.cy != b.cy ? (a.cx - b.cx) / (a.cy - b.cy) : .greatestFiniteMagnitude
    }

    /// Links segments into chains; returns lists of segment indices.
    static func chainGroup(_ segs: [Seg], _ hori: Bool) throws -> [[Int]] {
        let n = segs.count
        if n == 0 { return [] }
        let c15: Float = 0.15
        let keys = segs.map { hori ? (($0.q[3].x + $0.q[0].x) * 0.5) : (($0.q[1].y + $0.q[0].y) * 0.5) }
        let order = (0..<n).sorted { keys[$0] < keys[$1] || (!(keys[$1] < keys[$0]) && $0 < $1) }
        var nxt = [Int](repeating: -1, count: n), prv = [Int](repeating: -1, count: n)
        for (pos, i) in order.enumerated() {
            let si = segs[i]
            var best = -Float.greatestFiniteMagnitude, second = -Float.greatestFiniteMagnitude
            var bID = -1, sID = -1
            for j in order[(pos + 1)...] {
                let v = try affinity(si, segs[j])
                if v <= best {
                    if v > second {
                        second = v
                        sID = j
                    }
                } else {
                    second = best
                    sID = bID
                    best = v
                    bID = j
                }
            }
            if bID == -1 { continue }
            if sID != -1 {
                let sb = slopeBetween(si, segs[bID], hori), ss = slopeBetween(si, segs[sID], hori)
                let sl = si.slope
                if best < c15 || second < c15 || (best - second) >= c15 {
                    if best < Float(0.01) {
                        let swap: Bool
                        if abs(sb - ss) > c15 {
                            swap = !(abs(sl - sb) <= abs(sl - ss))
                        } else {
                            let b = segs[bID], s = segs[sID]
                            let dB = CRT.powf(si.cy - b.cy, 2) + CRT.powf(si.cx - b.cx, 2)
                            let dS = CRT.powf(si.cy - s.cy, 2) + CRT.powf(si.cx - s.cx, 2)
                            swap = !(dB <= dS)
                        }
                        if swap { bID = sID }
                    } else if best <= 0 {
                        continue
                    }
                } else if !(abs(sl - sb) <= abs(sl - ss)) {
                    bID = sID
                }
            }
            let b = bID
            if prv[b] == -1 {
                nxt[i] = b
                prv[b] = i
                continue
            }
            let k = prv[b]
            let sbk = slopeBetween(segs[k], segs[b], hori), sbi = slopeBetween(si, segs[b], hori)
            let bs = segs[b].slope
            if abs(bs - sbi) <= abs(bs - sbk) {
                nxt[i] = b
                prv[b] = i
                if abs(bs - sbk) < c15 && prv[i] == -1 {
                    nxt[k] = i
                    prv[i] = k
                } else {
                    nxt[k] = -1
                }
            }
        }
        if n == 1 { return [[0]] }
        var groups: [[Int]] = []
        for idx in 0..<n where prv[idx] == -1 && nxt[idx] != -1 {
            var chain = [idx]
            var seen: Set<Int> = [idx]
            var cur = idx
            while nxt[cur] != -1 {
                cur = nxt[cur]
                if !seen.insert(cur).inserted { break }
                chain.append(cur)
            }
            groups.append(chain)
        }
        return groups
    }

    /// The segment chains of one FPN level and orientation.
    static func decode(score: [Float], deltas: [Float], links: [Float], fh: Int, fw: Int, level: Int,
                       H: Int, W: Int, newH: Int, newW: Int, hori: Bool) throws -> [[Seg]] {
        let stride = 1 << level
        let vh = min(newH >> level, fh), vw = min(newW >> level, fw)
        let S = Float((1 << (level + 3)) - 1)
        let half = Double(Float(Double(stride - 1) * 0.5))
        let plane = fh * fw
        var out: [[Seg]] = []
        for comp0 in components(score, links, fh, fw, vh, vw) {
            let comp = comp0.sorted { score[$0] > score[$1] || (score[$0] == score[$1] && $0 < $1) }
            var quads: [[Pt]] = []
            var boxes: [(Float, Float, Float, Float)] = []
            quads.reserveCapacity(comp.count)
            boxes.reserveCapacity(comp.count)
            let wl = Double(W) - 1, hl = Double(H) - 1
            for p in comp {
                let cx = Double((p % fw) * stride) + half, cy = Double((p / fw) * stride) + half
                func v(_ k: Int, _ c: Double) -> Double { Double(deltas[k * plane + p] * S) + c }
                let x0 = Float(max(0, v(0, cx))), y0 = Float(max(0, v(1, cy)))
                let x1 = Float(min(wl, v(2, cx))), y1 = Float(max(0, v(3, cy)))
                let x2 = Float(min(wl, v(4, cx))), y2 = Float(min(hl, v(5, cy)))
                let x3 = Float(max(0, v(6, cx))), y3 = Float(min(hl, v(7, cy)))
                quads.append([Pt(x0, y0), Pt(x1, y1), Pt(x2, y2), Pt(x3, y3)])
                boxes.append((min(x0, x3), min(y0, y1), max(x1, x2), max(y2, y3)))
            }
            let segs = aabbNMS(boxes, nmsThr).map { Seg(quads[$0], score[comp[$0]], hori) }
            for g in try chainGroup(segs, hori) { out.append(g.map { segs[$0] }) }
        }
        return out
    }
}

// MARK: - Detector

final class TextDetector: @unchecked Sendable {
    static let defaultResizeResolution = (1152, 768)
    static let upscale = 1.5
    static let maxDetectedLines = 3000

    let cfg: DetectorConfig
    private let model: CoreMLModel
    private let mean: [Float], std: [Float], scale: Float, zeroPoint: Float

    init(model: CoreMLModel, quantization: [String: Any], config: [String: Any]?) throws {
        self.model = model
        cfg = DetectorConfig(config)
        guard let m = quantization["mean"] as? [NSNumber], let s = quantization["std"] as? [NSNumber], m.count == 3,
              s.count == 3, let sc = quantization["scale"] as? NSNumber, let zp = quantization["zero_point"] as? NSNumber
        else { throw OneOCRError("detector.json is invalid") }
        mean = m.map(\.floatValue)
        std = s.map(\.floatValue)
        scale = sc.floatValue
        zeroPoint = zp.floatValue
    }

    /// Target size (h, w) of the detector input: the sides scaled into the resize resolution, rounded up to 32.
    static func computeResize(_ oh: Int, _ ow: Int, resolution: (Int, Int), align: Int, useFloor: Bool,
                              scale: Double) -> (Int, Int) {
        let hOpt = resolution.0 > 0 ? resolution.0 : 1536, wOpt = resolution.1 > 0 ? resolution.1 : 768
        let minLen = min(hOpt, wOpt), maxLen = max(hOpt, wOpt)
        let eps: Float = 1e-6
        let minT = min(Int(Float(min(oh, ow)) * Float(scale) + eps), minLen)
        let maxT = min(Int(Float(max(oh, ow)) * Float(scale) + eps), maxLen)
        var h = oh, w = ow
        let hShort = h < w
        func get(_ short: Bool) -> Int { short == hShort ? h : w }
        func set(_ short: Bool, _ v: Int) { if short == hShort { h = v } else { w = v } }
        if get(true) < minT {
            set(false, minT * get(false) / get(true))
            set(true, minT)
        }
        if maxT > 0 && get(false) > maxT {
            set(true, get(true) * maxT / get(false))
            set(false, maxT)
        }
        if minT > 0 && get(true) > minT {
            set(false, minT * get(false) / get(true))
            set(true, minT)
        }
        if useFloor {
            return (max(h / align, 1) * align, max(w / align, 1) * align)
        }
        return (max((h + align - 1) / align, 1) * align, max((w + align - 1) / align, 1) * align)
    }

    /// The quantized network input [1, 3, h, w] of a BGR image.
    func preprocess(_ bgr: ImageU8, resolution: (Int, Int)) throws -> (MLMultiArray, Int, Int) {
        let (nh, nw) = Self.computeResize(bgr.height, bgr.width, resolution: resolution, align: cfg.imageResizeFactor,
                                          useFloor: cfg.useFloorResize, scale: Self.upscale)
        var img = ImageF32(bgr)
        if nh != bgr.height || nw != bgr.width {
            if Double(nh * nw) / Double(bgr.height * bgr.width) <= 0.04 {
                img = CV.resizeArea(img, nw, nh)
            } else {
                img = CV.resizeLinear(img, nw, nh)
            }
        }
        let input = try makeInput(nh, nw) { dst in
            let plane = nh * nw
            img.data.withUnsafeBufferPointer { src in
                let src = src.baseAddress!
                forEachRange(nh, size: nw * 3) { rows in
                    for c in 0..<3 {
                        let m = mean[c], s = std[c], sc = scale, zp = zeroPoint
                        for i in rows.lowerBound * nw..<rows.upperBound * nw {
                            let x = (src[i * 3 + c] - m) / s
                            let q = (x / sc).rounded(.toNearestOrEven) + zp
                            dst[c * plane + i] = min(max(q, 0), 255)
                        }
                    }
                }
            }
        }
        return (input, nh, nw)
    }

    func detect(_ bgr: ImageU8, resolution: (Int, Int) = TextDetector.defaultResizeResolution) throws -> [DetectedLine] {
        let oh = bgr.height, ow = bgr.width
        let (input, nh, nw) = try preprocess(bgr, resolution: resolution)
        let outs = try model.predict(["data_q": input])
        let sx = Float(nw) / Float(ow), sy = Float(nh) / Float(oh)
        var polys: [DetPoly] = []
        for level in 2...4 {
            var groups: [[Seg]] = []
            for (orient, hori) in [("hori", true), ("vert", false)] {
                guard let sc = outs["scores_\(orient)_fpn\(level)"], let de = outs["bbox_deltas_\(orient)_fpn\(level)"],
                      let lk = outs["link_scores_\(orient)_fpn\(level)"] else { throw OneOCRError("Detector output missing") }
                let s = floats(sc), d = floats(de), l = floats(lk)
                let fh = s.shape[2], fw = s.shape[3]
                groups += try Proposals.decode(score: s.data, deltas: d.data, links: l.data, fh: fh, fw: fw,
                                               level: level, H: nh, W: nw, newH: nh, newW: nw, hori: hori)
            }
            for g in groups {
                if let p = try buildPolygon(g, sx, sy, ow, oh, level) { polys.append(p) }
            }
        }
        if polys.count > Self.maxDetectedLines {
            MSVC.nthElement(&polys, Self.maxDetectedLines) { a, b in a.level == b.level ? a.score > b.score : a.level > b.level }
            polys.removeLast(polys.count - Self.maxDetectedLines)
        }
        for (k, p) in polys.enumerated() { p.index = k }
        var sorted = polys
        MSVC.sort(&sorted) { $0.score > $1.score }
        var cache = InterCache()
        let nms: Float, ovl: Float, aOvl: Float, aSave: Float
        if cfg.keepAmbiguousLine {
            (nms, ovl, aOvl, aSave) = (cfg.ambiguousNMSThreshold, cfg.ambiguousOverlapConst,
                                       cfg.ambiguousOverlapThreshold, cfg.ambiguousSaveThreshold)
        } else {
            (nms, ovl, aOvl, aSave) = (cfg.textlineNMSThreshold, cfg.textlineOverlapThreshold, 0.5, 0.4)
        }
        let keep = try textlineNMS(sorted, &cache, nms: nms, overlap: ovl, ambOverlap: aOvl, ambSave: aSave,
                                   sameThr: 0.95, keepAmb: cfg.keepAmbiguousLine, levelThr: cfg.textlineConfThreshold)
        let merged = try mergeLines(keep.map { sorted[$0] }, &cache, cfg.lineMergeThreshold, cfg.lineMergeRatio)
        return merged.map {
            DetectedLine(polygon: $0.pts, score: $0.score, isHorizontal: $0.hori, isAmbiguous: $0.amb, isPolygon: $0.multi)
        }
    }

    // MARK: line polygons

    private func buildPolygon(_ segs: [Seg], _ sx: Float, _ sy: Float, _ W: Int, _ H: Int, _ level: Int) throws -> DetPoly? {
        let quads = segs.map { s in s.q.map { Pt($0.x / sx, $0.y / sy) } }
        var hsum: Float = 0
        for s in segs { hsum = (s.hori ? 1 : 0) + hsum }
        let frac = hsum / Float(segs.count)
        var acc: Float = 0
        for s in segs { acc = acc + s.score }
        let score = acc / Float(segs.count)
        let hori = frac > Float(0.6)
        var ux: [Float] = [], uy: [Float] = [], lx: [Float] = [], ly: [Float] = []
        for q in quads {
            let up = hori ? [q[0], q[1]] : [q[1], q[2]]
            let lo = hori ? [q[2], q[3]] : [q[3], q[0]]
            for p in up {
                ux.append(p.x)
                uy.append(p.y)
            }
            for p in lo {
                lx.append(p.x)
                ly.append(p.y)
            }
        }
        let fc = PolyFit.fitAndCorners(hori, ux, uy, lx, ly)
        if fc.curved { return nil }
        let wl = Float(W) - 1, hl = Float(H) - 1
        let pts = PolyFit.polygonPoints(fc.corners, hori, fc.cu, fc.cl).map { p -> Pt in
            let x = p.x <= 0 ? 0 : p.x, y = p.y <= 0 ? 0 : p.y
            return Pt(x >= wl ? wl : x, y >= hl ? hl : y)
        }
        let poly = try DetPoly(pts, score: score, hori: hori, level: level)
        return poly.meanH > 0 ? poly : nil
    }

    // MARK: textline NMS

    private static func polyAngle(_ p: DetPoly) -> Double {
        let up = p.upper, un = p.under
        return Layout.quadAngle([up.first!, up.last!, un.first!, un.last!])
    }

    private static func midlineCrosses(_ a: DetPoly, _ coef: [Double], _ tol: Float, _ hori: Bool) -> Bool {
        var pos = false, neg = false
        for p in a.pts {
            let (t, v) = hori ? (p.x, p.y) : (p.y, p.x)
            var val: Float = 0
            for i in 0..<3 { val = CRT.powf(t, Float(i)) * Float(coef[i]) + val }
            if abs(v - val) > tol {
                if v <= val { neg = true } else { pos = true }
            }
        }
        return pos && neg
    }

    /// Is line a (mostly) a duplicate inside line b?
    private static func contained(_ a: DetPoly, _ b: DetPoly, _ cache: inout InterCache, _ thr: Float) throws -> Bool {
        if a.hori != b.hori { return false }
        if a.hori {
            if !(Double(a.cx) >= b.xmin && Double(a.cx) <= b.xmax) { return false }
        } else {
            if !(Double(a.cy) >= b.ymin && Double(a.cy) <= b.ymax) { return false }
        }
        let r = try cache.ratio(a, b, 1)
        if r <= thr { return false }
        if r >= Float(0.99) { return true }
        let (a0, a1, b0, b1) = a.hori ? (a.ymin, a.ymax, b.ymin, b.ymax) : (a.xmin, a.xmax, b.xmin, b.xmax)
        let inter = pmax(0.0, pmin(b1, a1) - pmax(a0, b0))
        let union = pmax(a1, b1) - pmin(a0, b0)
        if union > 0 && Float(inter) / Float(union) > Float(0.7) {
            let (c0, c1, d0, d1) = a.hori ? (a.xmin, a.xmax, b.xmin, b.xmax) : (a.ymin, a.ymax, b.ymin, b.ymax)
            let inter2 = pmax(0.0, pmin(d1, c1) - pmax(c0, d0))
            if (c1 - c0) <= 0 || Float(inter2) / Float(c1 - c0) < Float(0.6) { return false }
        }
        let la = a.hori ? a.xmax - a.xmin : a.ymax - a.ymin
        let lb = b.hori ? b.xmax - b.xmin : b.ymax - b.ymin
        if Float(la) < Float(lb) * Float(0.2) { return true }
        let mx = b.mid.map { Double($0.x) }, my = b.mid.map { Double($0.y) }
        let coef = b.hori ? PolyFit.fit(mx, my) : PolyFit.fit(my, mx)
        let tol = pmin(a.meanH, b.meanH) * Float(0.2)
        return midlineCrosses(a, coef, tol, b.hori)
    }

    /// polys sorted by score (descending). Returns the kept positions in order.
    private func textlineNMS(_ polys: [DetPoly], _ cache: inout InterCache, nms: Float, overlap: Float,
                             ambOverlap: Float, ambSave: Float, sameThr: Float, keepAmb: Bool,
                             levelThr: [Int: Float]) throws -> [Int] {
        let n = polys.count
        var sup = [Bool](repeating: false, count: n), amb = [Bool](repeating: false, count: n)
        let tree = RTree()
        func rect(_ p: DetPoly) -> RTree.Rect { RTree.Rect(Float(p.xmin), Float(p.ymin), Float(p.xmax), Float(p.ymax)) }
        for (i, p) in polys.enumerated() { tree.insert(rect(p), i) }
        let cand = polys.map { tree.search(rect($0)) }
        let nmsD = Double(nms)
        for i in 0..<n where !sup[i] {
            let pi = polys[i]
            guard let lt = levelThr[pi.level] else { throw OneOCRError("invalid map<K, T> key") }
            var ok = pi.score >= lt
            if ok {
                var a = Self.polyAngle(pi)
                while a > 90 { a -= 180 }
                a = abs(a)
                ok = pi.hori ? a < 50 : a > 40
            }
            if !ok {
                sup[i] = true
                continue
            }
            for j in cand[i] where j > i && !sup[j] {
                let pj = polys[j]
                let iw = pmin(pi.xmax, pj.xmax) - pmax(pi.xmin, pj.xmin) + 1
                let ih = pmin(pi.ymax, pj.ymax) - pmax(pi.ymin, pj.ymin) + 1
                let inter = pmax(iw, 0) * pmax(ih, 0)
                if !(inter > (pj.bboxArea + pi.bboxArea) / (nmsD + 1) * nmsD) { continue }
                let iou = try cache.ratio(pi, pj, 0)
                if iou > nms {
                    if !keepAmb || pi.hori == pj.hori {
                        sup[j] = true
                    } else if iou >= sameThr && min(pi.pts.count, pj.pts.count) / 2 > 4 {
                        sup[j] = true
                    }
                }
            }
        }
        for i in 0..<n where !sup[i] {
            let pi = polys[i]
            for j in cand[i] where j != i && !sup[j] {
                let pj = polys[j]
                if keepAmb && pi.hori != pj.hori { continue }
                if try Self.contained(pi, pj, &cache, overlap) {
                    if pi.score > pj.score, try Self.contained(pj, pi, &cache, overlap) {
                        sup[j] = true
                        continue
                    }
                    sup[i] = true
                    break
                }
            }
        }
        if keepAmb {
            for i in 0..<n where !sup[i] {
                let pi = polys[i]
                var total = 0.0
                var hits: [Int] = []
                for j in cand[i] where j != i && !sup[j] {
                    let pj = polys[j]
                    if pj.hori == pi.hori { continue }
                    if try cache.ratio(pj, pi, 1) > ambOverlap {
                        total += Double(try cache.inter(pi, pj))
                        hits.append(j)
                    }
                }
                if total >= Double(pi.area) * Double(ambSave) {
                    amb[i] = true
                    for j in hits { amb[j] = true }
                }
            }
        }
        var keep: [Int] = []
        for i in 0..<n where !sup[i] || amb[i] {
            keep.append(i)
            if sup[i] && amb[i] { polys[i].amb = true }
        }
        return keep
    }

    // MARK: line merging

    private static func pointLineDistOK(_ p: DetPoly, _ pa: Pt, _ pb: Pt, _ tol: Double) -> Bool {
        let up = p.upper, un = p.under
        let h: Float = 0.5
        let sx = (un.last!.x + up.first!.x) * h, sy = (up.first!.y + un.last!.y) * h
        let ex = (up.last!.x + un.first!.x) * h, ey = (un.first!.y + up.last!.y) * h
        let mx = (pa.x + pb.x) * h, my = (pa.y + pb.y) * h
        let dx = sx - ex, dy = ey - sy
        let num = abs((dy * mx + dx * my) + (ex * sy - ey * sx))
        let d = num / (CRT.powf(dy, 2) + CRT.powf(dx, 2)).squareRoot()
        return Double(d) < tol
    }

    private static func inside(_ p: DetPoly, _ pt: Pt) -> Bool { CV.pointPolygonTest(p.pts, pt.x, pt.y) >= 0 }

    /// Refits a on the union of the chains of a and b.
    private static func mergeUnion(_ a: DetPoly, _ b: DetPoly) throws {
        let ux = a.upper.map(\.x) + b.upper.map(\.x), uy = a.upper.map(\.y) + b.upper.map(\.y)
        let lx = a.under.map(\.x) + b.under.map(\.x), ly = a.under.map(\.y) + b.under.map(\.y)
        let score = (b.score + a.score) * 0.5
        let fc = PolyFit.fitAndCorners(a.hori, ux, uy, lx, ly)
        let pts = PolyFit.polygonPoints(fc.corners, a.hori, fc.cu, fc.cl)
        let xmin = b.xmin < a.xmin ? b.xmin : a.xmin, xmax = a.xmax < b.xmax ? b.xmax : a.xmax
        let ymin = b.ymin < a.ymin ? b.ymin : a.ymin, ymax = a.ymax < b.ymax ? b.ymax : a.ymax
        func clamp(_ v0: Float, _ lo: Double, _ hi: Double) -> Float {
            let v = lo < Double(v0) ? Double(v0) : lo
            return Float(v >= hi ? hi : v)
        }
        a.pts = pts.map { Pt(clamp($0.x, xmin, xmax), clamp($0.y, ymin, ymax)) }
        a.multi = a.pts.count > 4
        a.score = score
        try a.recompute()
        a.xmin = xmin
        a.xmax = xmax
        a.ymin = ymin
        a.ymax = ymax
        a.bboxArea = (ymax - ymin + 1) * (xmax - xmin + 1)
    }

    private static func tryMerge(_ a: DetPoly, _ b: DetPoly, _ cache: inout InterCache, _ thr: Double,
                                 _ ratio: Double) throws -> Bool {
        if a.hori != b.hori { return false }
        if a.xmin > b.xmax || a.ymin > b.ymax || a.xmax < b.xmin || a.ymax < b.ymin { return false }
        let iw = pmax(0.0, pmin(a.xmax, b.xmax) - pmax(a.xmin, b.xmin) + 1)
        let ih = pmax(0.0, pmin(a.ymax, b.ymax) - pmax(a.ymin, b.ymin) + 1)
        if iw * ih <= 0 { return false }
        if Double(try cache.inter(a, b)) < Double(Float(0.01)) { return false }
        let (first, second): (DetPoly, DetPoly)
        if a.hori {
            (first, second) = a.xmin >= b.xmin ? (b, a) : (a, b)
        } else {
            (first, second) = a.ymax >= b.ymax ? (b, a) : (a, b)
        }
        let fTop = first.upper.last!, fBot = first.under.first!
        let sTop = second.upper.first!, sBot = second.under.last!
        let h: Float = 0.5
        let fMid = Pt((fBot.x + fTop.x) * h, (fTop.y + fBot.y) * h)
        let sMid = Pt((sBot.x + sTop.x) * h, (sBot.y + sTop.y) * h)
        if !(inside(first, sMid) || inside(second, fMid)) { return false }
        let h1 = (CRT.powf(fTop.y - fBot.y, 2) + CRT.powf(fTop.x - fBot.x, 2)).squareRoot()
        let h2 = (CRT.powf(sTop.y - sBot.y, 2) + CRT.powf(sTop.x - sBot.x, 2)).squareRoot()
        let hmax = h1 >= h2 ? h1 : h2
        let hmin = h2 >= h1 ? h1 : h2
        if Double(hmax) >= Double(hmin) * ratio { return false }
        if thr == 0 { return false }
        let tol = Double(hmin) / thr
        if !pointLineDistOK(first, sTop, sBot, tol) { return false }
        if !pointLineDistOK(second, fTop, fBot, tol) { return false }
        try mergeUnion(a, b)
        return true
    }

    private func mergeLines(_ polys: [DetPoly], _ cache: inout InterCache, _ thr: Double, _ ratio: Double) throws -> [DetPoly] {
        let n = polys.count
        var merged = [Bool](repeating: false, count: n)
        var out: [DetPoly] = []
        for i in 0..<n where !merged[i] {
            var j = i + 1
            while j < n {
                if !merged[j] {
                    let m = try Self.tryMerge(polys[i], polys[j], &cache, thr, ratio)
                    merged[j] = m
                    if m { j = i + 1 }  // the increment then restarts at i + 2, as in oneocr
                }
                j += 1
            }
            out.append(polys[i])
        }
        return out
    }
}
