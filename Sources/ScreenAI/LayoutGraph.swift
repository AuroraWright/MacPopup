import Foundation

// The line graph the layout GCN reads (google_ocr::box_beta_skeleton): edges between line boxes that are neighbours
// in the beta-skeleton (beta = 1, the Gabriel graph) of points sampled on the box outlines, plus edges between boxes
// that touch or contain one another. Same float and integer arithmetic, and the same edge order, as the original.

struct GraphEdge {
    var a: Int, b: Int
    /// Squared distance of the points that connect them (beta-skeleton edges only).
    var weight: Float = 0
}

/// box_util::AppendBoxPoints: the corners top left, top right, bottom right, bottom left.
func boxCorners(_ b: RBox) -> [(x: Float, y: Float)] {
    if b.angle == 0 { return [(b.x, b.y), (b.x + b.w, b.y), (b.x + b.w, b.y + b.h), (b.x, b.y + b.h)] }
    let r = sinCos(b.angle * degToRad)
    let x1 = b.x + (r.cos * b.w), y1 = b.y + (r.sin * b.w)
    return [(b.x, b.y), (x1, y1), (x1 - (r.sin * b.h), y1 + (r.cos * b.h)),
            (b.x - (r.sin * b.h), b.y + (r.cos * b.h))]
}

private struct BoxPoint {
    var x: Int, y: Int
    /// The boxes this (scaled, rounded) outline point belongs to.
    var boxes: [Int] = []
}

private struct PointKey: Hashable {
    var x: Int, y: Int
}

/// GetScaledPointsFromBoxes: points along each box's outline (corners, `nv` per vertical side, `nh` per horizontal
/// side, and a middle line along the longer side), scaled so that the largest coordinate stays under 2^30 and
/// rounded. Points shared by several boxes appear once.
private func scaledPoints(_ boxes: [RBox], _ nh: Int, _ nv: Int)
    -> (points: [BoxPoint], boxPoints: [[Int]], scale: Float) {
    var maxCoordinate: Float = 0
    for b in boxes {
        for p in boxCorners(b) {
            var v = abs(p.x)
            let v2 = abs(p.y)
            if v < v2 { v = v2 }
            if maxCoordinate < v { maxCoordinate = v }
        }
    }
    let scale: Float = 1_073_741_824 / (maxCoordinate + 1)
    var points: [BoxPoint] = []
    var boxPoints = [[Int]](repeating: [], count: boxes.count)
    var index: [PointKey: Int] = [:]
    let vdiv = Float(nv + 1)
    for (bi, b) in boxes.enumerated() {
        let w = b.w, h = b.h
        if !(w >= 1e-4) || !(h >= 1e-4) { continue }
        var pts: [(x: Float, y: Float)] = [(b.x, b.y), (b.x + w, b.y), (b.x, b.y + h), (b.x + w, b.y + h)]
        let stepV = h / vdiv
        if nv >= 1 {
            for k in 1...nv {
                let d = stepV * Float(k)
                pts.append((b.x, d + b.y))
                pts.append((b.x + w, d + b.y))
                if w <= h { pts.append((b.x + (w * 0.5), d + b.y)) }
            }
        }
        let n = nh < 0 ? Int(ceilf(w / stepV)) - 1 : nh
        if n >= 1 {
            let stepH = w / Float(n + 1)
            for k in 1...n {
                let d = stepH * Float(k)
                pts.append((d + b.x, b.y))
                pts.append((d + b.x, b.y + h))
                if w > h { pts.append((d + b.x, b.y + (h * 0.5))) }
            }
        }
        if b.angle != 0 {
            for k in 1..<pts.count {
                let r = sinCos(b.angle * degToRad)
                let dx = pts[k].x - b.x, dy = pts[k].y - b.y
                pts[k] = ((b.x + (dx * r.cos)) - (r.sin * dy), (r.cos * dy) + (b.y + (dx * r.sin)))
            }
        }
        for p in pts {
            let x = Int(Int32(truncatingIfNeeded: Int64((Double(p.x) * Double(scale)).rounded(.toNearestOrAwayFromZero))))
            let y = Int(Int32(truncatingIfNeeded: Int64((Double(scale) * Double(p.y)).rounded(.toNearestOrAwayFromZero))))
            let key = PointKey(x: x, y: y)
            let k: Int
            if let existing = index[key] {
                k = existing
            } else {
                k = points.count
                index[key] = k
                points.append(BoxPoint(x: x, y: y))
            }
            points[k].boxes.append(bi)
            boxPoints[bi].append(k)
        }
    }
    return (points, boxPoints, scale)
}

/// GetDelaunay: the neighbours of each point, from the Voronoi diagram's vertices. Like the original, only the
/// first three cells around a vertex are connected (several points on one circle make one vertex).
private func delaunay(_ points: [BoxPoint]) -> [[Int]] {
    let diagram = VoronoiDiagram(points: points.map { (Int32(truncatingIfNeeded: $0.x), Int32(truncatingIfNeeded: $0.y)) })
    var neighbours = [[Int]](repeating: [], count: points.count)
    for v in diagram.vertices {
        let e0 = v.incidentEdge
        let e1 = diagram.rotNext(e0)
        if e1 == e0 { continue }
        let e2 = diagram.rotNext(e1)
        if e2 == e0 { continue }
        func source(_ e: Int) -> Int { diagram.cells[diagram.edges[e].cell].source }
        let c0 = source(e0), c1 = source(e1), c2 = source(e2)
        for k in 0..<3 {
            let (p, q) = k == 0 ? (c0, c1) : k == 1 ? (c1, c2) : (c2, c0)
            let a = min(p, q), b = max(p, q)
            // Each pair once (the neighbour lists are short).
            if neighbours[a].contains(b) { continue }
            neighbours[a].append(b)
            neighbours[b].append(a)
        }
    }
    return neighbours
}

/// box_util::BoxContainsPoint for a (rotated) box.
private func boxContainsPoint(_ b: RBox, _ px: Float, _ py: Float) -> Bool {
    let r = sinCos(b.angle * -degToRad)
    let dx = px - b.x, dy = py - b.y
    let x = (b.x + (dx * r.cos)) - (r.sin * dy)
    let y = (r.cos * dy) + (b.y + (dx * r.sin))
    return !(x < b.x || y < b.y) && x < b.x + b.w && y < b.y + b.h
}

private func norm2(_ dx: Int, _ dy: Int) -> Float {
    let fx = Float(dx), fy = Float(dy)
    return fx * fx + fy * fy
}

/// GenerateBoxNeighborEdges(boxes, nh, nv): boxes sharing an outline point, boxes with other boxes' points inside
/// them, then the beta-skeleton edges, shortest first. Each pair once, as (lower index, higher index) for the first
/// two kinds.
func boxNeighborEdges(_ boxes: [RBox], pointsHorizontal nh: Int, pointsVertical nv: Int) -> [GraphEdge] {
    let (points, boxPoints, scale) = scaledPoints(boxes, nh, nv)
    let adjacent = delaunay(points)
    var edges: [GraphEdge] = []
    var seen = Set<Int>()  // lower index * boxes + higher index
    func add(_ a: Int, _ b: Int) {
        if seen.insert(min(a, b) * boxes.count + max(a, b)).inserted { edges.append(GraphEdge(a: min(a, b), b: max(a, b))) }
    }
    // ProcessOverlappingPoints.
    for p in points {
        for i in p.boxes.indices {
            for j in (i + 1)..<p.boxes.count { add(p.boxes[i], p.boxes[j]) }
        }
    }
    // MarkInsidePoints: other boxes' points reachable through Delaunay edges inside a box.
    var inside = [Bool](repeating: false, count: points.count)
    var member = [Int](repeating: -1, count: points.count)  // the box whose found points include it
    for (bi, box) in boxes.enumerated() {
        var sb = box
        sb.x *= scale
        sb.y *= scale
        sb.w *= scale
        sb.h *= scale
        var found = boxPoints[bi]
        for p in found { member[p] = bi }
        var k = 0
        while k < found.count {
            for q in adjacent[found[k]] where member[q] != bi {
                if boxContainsPoint(sb, Float(points[q].x), Float(points[q].y)) {
                    found.append(q)
                    member[q] = bi
                }
            }
            k += 1
        }
        for p in found[boxPoints[bi].count...] {
            inside[p] = true
            for other in points[p].boxes { add(bi, other) }
        }
    }
    // AddBetaSkeletonEdges (beta = 1): Delaunay edges whose diametral circle holds no neighbouring point.
    let invScale2 = 1 / (scale * scale)
    var candidates: [GraphEdge] = []
    for p in points.indices where !inside[p] && !adjacent[p].isEmpty {
        let P = points[p]
        for q in adjacent[p] where p <= q && !inside[q] {
            let Q = points[q]
            let r2 = norm2(P.x - Q.x, P.y - Q.y) * 0.25
            let mx = (Q.x + P.x) / 2, my = (Q.y + P.y) / 2
            let blocked = adjacent[p].contains { $0 != q && norm2(points[$0].x - mx, points[$0].y - my) < r2 }
                || adjacent[q].contains { $0 != p && norm2(points[$0].x - mx, points[$0].y - my) < r2 }
            if blocked { continue }
            for a in P.boxes {
                for b in Q.boxes where a != b {
                    candidates.append(GraphEdge(a: a, b: b, weight: invScale2 * norm2(P.x - Q.x, P.y - Q.y)))
                }
            }
        }
    }
    candidates.libcxxSort { $0.weight < $1.weight }
    for e in candidates where seen.insert(min(e.a, e.b) * boxes.count + max(e.a, e.b)).inserted { edges.append(e) }
    return edges
}
