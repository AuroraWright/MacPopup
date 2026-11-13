import Foundation

/// A point in float32, as oneocr's geometry computes them.
struct Pt: Equatable {
    var x: Float
    var y: Float

    init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }
}

/// Thrown where a CHECK in oneocr's polygon code fails.
struct GeometryCheckError: Error {}

/// min and max with Python's (and std::min/max's) tie rule, where the first argument wins: min(a, b) is b only when
/// b < a.
@inline(__always) func pmin<T: Comparable>(_ a: T, _ b: T) -> T { b < a ? b : a }
@inline(__always) func pmax<T: Comparable>(_ a: T, _ b: T) -> T { b > a ? b : a }

// Float32 polygon geometry of oneocr (no FMA contraction in these routines).
enum Geom32 {
    static let epsOrient: Float = 1e-8
    static let epsSide = 1e-6

    /// Signed area 0.5 Σ x_i (y_{i+1} - y_{i-1}): the middle terms first, then term 0 and term n-1.
    static func shoelace(_ p: [Pt]) -> Float {
        let n = p.count
        if n < 3 { return 0 }
        var s: Float = 0
        for i in 1..<(n - 1) { s = (p[i + 1].y - p[i - 1].y) * p[i].x + s }
        s = (p[1].y - p[n - 1].y) * p[0].x + s
        s = s + (p[0].y - p[n - 2].y) * p[n - 1].x
        return s * 0.5
    }

    @inline(__always) private static func side(_ ax: Float, _ ay: Float, _ ex: Float, _ ey: Float, _ p: Pt) -> Int {
        let c = ex * (p.y - ay) - (p.x - ax) * ey
        if Double(c * c) >= Double(ex * ex + ey * ey) * epsSide { return c <= 0 ? -1 : 1 }
        return 0
    }

    /// Signed area of `subject` clipped by the positively oriented convex polygon `clip` (Sutherland-Hodgman).
    static func clipArea(_ clip: [Pt], _ subject: [Pt]) throws -> Float {
        var pts = subject
        let kn = clip.count
        var out: [Pt] = []
        out.reserveCapacity(subject.count + 6)
        for k in 0..<kn {
            let ax = clip[k].x, ay = clip[k].y
            let bx = clip[(k + 1) % kn].x, by = clip[(k + 1) % kn].y
            let ex = bx - ax, ey = by - ay
            let n = pts.count
            if n == 0 { continue }
            out.removeAll(keepingCapacity: true)
            var sPrev = side(ax, ay, ex, ey, pts[0])
            for j in 0..<n {
                let p = pts[j], q = pts[j + 1 == n ? 0 : j + 1]
                if sPrev >= 0 { out.append(p) }
                let sNext = side(ax, ay, ex, ey, q)
                if sNext * sPrev < 0 {
                    let dy = ay - by
                    let den = (q.x - p.x) * dy - (p.y - q.y) * ex
                    if abs(den) < epsOrient { throw GeometryCheckError() }
                    let c1 = by * ax - ay * bx
                    let c2 = p.x * q.y - p.y * q.x
                    out.append(Pt((c2 * ex - c1 * (q.x - p.x)) / den, (c1 * (p.y - q.y) - c2 * dy) / den))
                }
                sPrev = sNext
            }
            swap(&pts, &out)
        }
        return shoelace(pts)
    }

    /// (true, (a, b, c)) if positive or degenerate, else (false, (a, c, b)).
    static func orientTri(_ a: Pt, _ b: Pt, _ c: Pt) -> (Bool, [Pt]) {
        let cr = (c.y - b.y) * (b.x - a.x) - (b.y - a.y) * (c.x - b.x)
        if abs(cr) < epsOrient || cr > 0 { return (true, [a, b, c]) }
        return (false, [a, c, b])
    }

    typealias StripPair = ((Bool, [Pt]), (Bool, [Pt]))

    /// The triangle strip between the upper line and the reversed under line, as pairs per step.
    static func stripPairs(_ upper: [Pt], _ under: [Pt]) throws -> [StripPair] {
        let rv = Array(under.reversed())
        if upper.count < 2 || rv.count < 2 { throw GeometryCheckError() }
        return (0..<(min(upper.count, rv.count) - 1)).map { k in
            (orientTri(upper[k], upper[k + 1], rv[k + 1]), orientTri(rv[k + 1], rv[k], upper[k]))
        }
    }

    static func stripIntersection(_ pa: [StripPair], _ pb: [StripPair]) throws -> Float {
        var total: Float = 0
        for ((sa1, a1), (sa2, a2)) in pa {
            for ((sb1, b1), (sb2, b2)) in pb {
                for (sb, b) in [(sb1, b1), (sb2, b2)] {
                    var v = try clipArea(a1, b)
                    total = sa1 == sb ? v + total : total - v
                    v = try clipArea(a2, b)
                    total = sa2 == sb ? v + total : total - v
                }
            }
        }
        return total
    }

    static func quadIntersection(_ qa: [Pt], _ qb: [Pt]) throws -> Float {
        let ta = [orientTri(qa[0], qa[1], qa[2]), orientTri(qa[0], qa[2], qa[3])]
        let tb = [orientTri(qb[0], qb[1], qb[2]), orientTri(qb[0], qb[2], qb[3])]
        var total: Float = 0
        for (sa, a) in ta {
            for (sb, b) in tb {
                let v = try clipArea(a, b)
                total = sa == sb ? v + total : total - v
            }
        }
        return total
    }
}
