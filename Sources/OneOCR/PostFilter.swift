import Foundation

// FilterXY: the detector keeps ambiguous regions as both a horizontal and a vertical line. Overlapping horizontal and
// vertical lines are grouped, the group votes on which orientation reads better (character counts, recognition
// scores), and the losing orientation's lines that are mostly covered by the winning one are dropped.

struct FilterLine {
    var polygon: [Pt]
    var isHorizontal: Bool
    var isAmbiguous: Bool
    var wordTexts: [String]
    var lineScore: Double
    var script: Int
    var category: Int
}

private struct FilterPoly {
    let upperCount: Int
    let area: Float
    let box: RTree.Rect
    let strips: [Geom32.StripPair]
    let ambiguous: Bool

    init(_ pts: [Pt], ambiguous: Bool) throws {
        if pts.count % 2 != 0 { throw GeometryCheckError() }
        let h = pts.count / 2
        upperCount = h
        var x0 = pts[0].x, x1 = pts[0].x, y0 = pts[0].y, y1 = pts[0].y
        for p in pts.dropFirst() {
            x0 = pmin(x0, p.x)
            x1 = pmax(x1, p.x)
            y0 = pmin(y0, p.y)
            y1 = pmax(y1, p.y)
        }
        box = RTree.Rect(x0.rounded(.down), y0.rounded(.down), x1.rounded(.up), y1.rounded(.up))
        area = abs(Geom32.shoelace(pts))
        strips = try Geom32.stripPairs(Array(pts[0..<h]), Array(pts[h...]))
        self.ambiguous = ambiguous
    }
}

enum PostFilter {
    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { c in cjkRanges.contains { $0.contains(c.value) } }
    }

    private static func ratio(_ a: Double, _ b: Double) -> Double {
        let m = a >= b ? a : b
        return m > 1e-6 ? (a - b) / m : 0
    }

    private static func pairCover(_ ph: FilterPoly, _ pv: FilterPoly, _ th: String, _ tv: String) throws -> (Bool, Float, Float) {
        let inter = try Geom32.stripIntersection(ph.strips, pv.strips)
        let ch = inter / ph.area, cv = inter / pv.area
        let m = ch < cv ? cv : ch
        let linked: Bool
        if abs(m - Float(0.2)) <= Float(0.1) {
            linked = !Set(th.unicodeScalars).isDisjoint(with: Set(tv.unicodeScalars))
        } else {
            linked = m > Float(0.2)
        }
        return (linked, ch, cv)
    }

    /// The indices of the lines FilterXY keeps, in order.
    static func filterXY(_ lines: [FilterLine]) throws -> [Int] {
        let n = lines.count
        let texts = lines.map { $0.wordTexts.joined() }
        let polys = try lines.map { try FilterPoly($0.polygon, ambiguous: $0.isAmbiguous) }
        let counts = texts.map { $0.unicodeScalars.count }
        func good(_ i: Int) -> Bool { counts[i] > 1 && polys[i].upperCount > 2 && !polys[i].ambiguous }
        let H = (0..<n).filter { lines[$0].isHorizontal }, V = (0..<n).filter { !lines[$0].isHorizontal }
        let nHGood = H.filter(good).count, nVGood = V.filter(good).count
        let nCJKHW = lines.filter { $0.script == Script.cjk && $0.category == Category.handwritten }.count
        let cjkHWMode = Float(nCJKHW) >= Float(Double(Float(n)) * Double(Float(0.1)))

        let tree = RTree()
        for h in H { tree.insert(polys[h].box, h) }
        var cover = [Float](repeating: 0, count: n)
        var adj = [[Int]](repeating: [], count: n)
        for v in V {
            for h in tree.search(polys[v].box) {
                let (linked, ch, cv) = try pairCover(polys[h], polys[v], texts[h], texts[v])
                cover[h] = cover[h] + ch
                cover[v] = cover[v] + cv
                if linked {
                    adj[h].append(v)
                    adj[v].append(h)
                }
            }
        }
        var removed = [Bool](repeating: false, count: n), visited = [Bool](repeating: false, count: n)
        for i in 0..<n where !visited[i] {
            var comp = [i]
            visited[i] = true
            var k = 0
            while k < comp.count {
                for j in adj[comp[k]] where !visited[j] {
                    visited[j] = true
                    comp.append(j)
                }
                k += 1
            }
            let hx = comp.filter { lines[$0].isHorizontal }, vy = comp.filter { !lines[$0].isHorizontal }
            if hx.isEmpty || vy.isEmpty { continue }
            // the language-model scores are 0 without decoder models
            let confX = hx.reduce(0.0) { $0 + lines[$1].lineScore } / Double(hx.count)
            let confY = vy.reduce(0.0) { $0 + lines[$1].lineScore } / Double(vy.count)
            let charsX = Double(hx.reduce(0) { $0 + counts[$1] }), charsY = Double(vy.reduce(0) { $0 + counts[$1] })
            var score = -ratio(0, 0) + ratio(charsX, charsY)
            score = score + ratio(confX, confY)
            if cjkHWMode { score = 0.5 * ratio(Double(nHGood), Double(nVGood)) + score }
            let half = comp.count >> 1
            let nShort = comp.filter { polys[$0].upperCount <= 2 || counts[$0] == 1 }.count
            let nCJK = comp.filter { containsCJK(texts[$0]) }.count
            let horizontalWins = nCJK >= half || half >= nShort ? score > 0 : nHGood >= nVGood
            for m in comp where lines[m].isHorizontal != horizontalWins { removed[m] = cover[m] >= Float(0.4) }
        }
        return (0..<n).filter { !removed[$0] }
    }
}
