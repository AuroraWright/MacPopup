import Foundation

// Result-level geometry: quad angles, the page angle and the reading order of the lines.
enum Layout {
    static let scriptArabic = 5, scriptHebrew = 9

    /// Angle in degrees [0, 360) of a quad (TL, TR, BR, BL): atan2f, mean and difference in float32, the rest in double.
    static func quadAngle(_ q: [Pt]) -> Double {
        let a1 = CRT.atan2f(q[1].y - q[0].y, q[1].x - q[0].x)
        let a2 = CRT.atan2f(q[2].y - q[3].y, q[2].x - q[3].x)
        var m = Double((a2 + a1) * 0.5)
        if Double(abs(a1 - a2)) > .pi { m += .pi }
        var deg = m / .pi * 180
        if deg < 0 { deg += 360 }
        return deg
    }

    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 360 - d)
    }

    /// The dominant text angle of the page: the median of the largest 90-degree bucket.
    static func pageAngle(_ angles: [Double]) -> Double {
        var buckets: [[Double]] = [[], [], [], []]
        for a0 in angles {
            var a = Float(a0)
            while a < -45 { a = a + 360 }
            while a >= 315 { a = a - 360 }
            buckets[Int(a + 45) / 90].append(Double(a))
        }
        var best = buckets[0]
        for b in buckets.dropFirst() where b.count > best.count { best = b }
        if best.isEmpty { return 0 }
        let med = best.sorted()[best.count / 2]
        return med < 0 ? med + 360 : med
    }

    private static func readingOrderLess(_ a: [Pt], _ b: [Pt], _ rtl: Bool) -> Bool {
        let ax1 = a[0].x, ax2 = a[1].x, bx1 = b[0].x, bx2 = b[1].x
        let overlap = pmax(0, pmin(ax2, bx2) - pmax(ax1, bx1)) / abs(pmax(ax2, bx2) - pmin(ax1, bx1) + 1)
        let ya: Float, yb: Float, ka: Float, kb: Float, h: Float
        if rtl {
            (ya, yb, ka, kb) = (a[1].y, b[1].y, a[1].x, b[1].x)
            h = pmin(abs(a[2].y - a[1].y), abs(b[2].y - b[1].y))
        } else {
            (ya, yb, ka, kb) = (a[0].y, b[0].y, a[0].x, b[0].x)
            h = pmin(abs(a[3].y - a[0].y), abs(b[3].y - b[0].y))
        }
        if overlap > Float(0.2) || abs(ya - yb) > h { return ya < yb }
        return rtl ? ka > kb : ka < kb
    }

    /// The line indices in reading order.
    static func sortLines(_ quads: [[Pt]], _ scripts: [Int], _ angle: Double) -> [Int] {
        let n = quads.count
        let rtl = Double(scripts.filter { $0 == scriptArabic || $0 == scriptHebrew }.count) > 0.4 * Double(n)
        let r = Float(Double(Float(angle)) * .pi / 180)
        let c = CRT.cosf(r), s = CRT.sinf(r)
        let rotated = quads.map { q in q.map { Pt($0.x * c + $0.y * s, $0.y * c - $0.x * s) } }
        var order = Array(0..<n)
        MSVC.sort(&order) { readingOrderLess(rotated[$0], rotated[$1], rtl) }
        return order
    }
}
