import Foundation

/// The Guttman R-tree (quadratic split) compiled into oneocr: the classic single-header RTree.h with 2-D float
/// rectangles, 8 branches per node at most and 4 at least. Search results come out in the same order as oneocr's,
/// which matters wherever a caller stops at the first hit or sums floats in hit order.
final class RTree {
    struct Rect {
        var x0, y0, x1, y1: Float

        init(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }

        func combined(_ b: Rect) -> Rect {
            Rect(pmin(x0, b.x0), pmin(y0, b.y0), pmax(x1, b.x1), pmax(y1, b.y1))
        }

        var volume: Float { (x1 - x0) * (y1 - y0) }

        func overlaps(_ b: Rect) -> Bool { !(x0 > b.x1 || b.x0 > x1 || y0 > b.y1 || b.y0 > y1) }
    }

    private final class Node {
        var level: Int
        var branches: [Branch] = []

        init(_ level: Int) { self.level = level }

        var cover: Rect {
            var r = branches[0].rect
            for b in branches.dropFirst() { r = r.combined(b.rect) }
            return r
        }
    }

    private struct Branch {
        var rect: Rect
        var child: Node?
        var data: Int
    }

    private static let maxNodes = 8, minNodes = 4
    private var root = Node(0)

    func insert(_ rect: Rect, _ data: Int) {
        let br = Branch(rect: rect, child: nil, data: data)
        if let split = insertRec(br, root, 0) {
            let r = Node(root.level + 1)
            r.branches.append(Branch(rect: root.cover, child: root, data: -1))
            r.branches.append(Branch(rect: split.cover, child: split, data: -1))
            root = r
        }
    }

    private func insertRec(_ br: Branch, _ node: Node, _ level: Int) -> Node? {
        if node.level > level {
            let idx = Self.pickBranch(br.rect, node)
            let child = node.branches[idx].child!
            guard let other = insertRec(br, child, level) else {
                node.branches[idx].rect = br.rect.combined(node.branches[idx].rect)
                return nil
            }
            node.branches[idx].rect = child.cover
            return addBranch(Branch(rect: other.cover, child: other, data: -1), node)
        }
        return addBranch(br, node)
    }

    private static func pickBranch(_ rect: Rect, _ node: Node) -> Int {
        var best = 0, bestIncr: Float = -1, bestArea: Float = 0, first = true
        for (i, b) in node.branches.enumerated() {
            let area = b.rect.volume
            let incr = rect.combined(b.rect).volume - area
            if first || incr < bestIncr || (incr == bestIncr && area < bestArea) {
                best = i
                bestIncr = incr
                bestArea = area
                first = false
            }
        }
        return best
    }

    private func addBranch(_ br: Branch, _ node: Node) -> Node? {
        if node.branches.count < Self.maxNodes {
            node.branches.append(br)
            return nil
        }
        return splitNode(node, br)
    }

    private func splitNode(_ node: Node, _ br: Branch) -> Node {
        let buf = node.branches + [br]
        let total = buf.count
        var coverSplit = buf[0].rect
        for b in buf.dropFirst() { coverSplit = coverSplit.combined(b.rect) }
        let coverSplitArea = coverSplit.volume
        var part = [Int](repeating: -1, count: total)
        var count = [0, 0]
        var cover = [Rect](repeating: Rect(0, 0, 0, 0), count: 2)
        var area: [Float] = [0, 0]

        func classify(_ i: Int, _ g: Int) {
            part[i] = g
            cover[g] = count[g] == 0 ? buf[i].rect : buf[i].rect.combined(cover[g])
            area[g] = cover[g].volume
            count[g] += 1
        }

        // PickSeeds
        let areas = buf.map { $0.rect.volume }
        var worst = -coverSplitArea - 1
        var s0 = 0, s1 = 0
        for a in 0..<(total - 1) {
            for b in (a + 1)..<total {
                let waste = buf[a].rect.combined(buf[b].rect).volume - areas[a] - areas[b]
                if waste > worst {
                    worst = waste
                    s0 = a
                    s1 = b
                }
            }
        }
        classify(s0, 0)
        classify(s1, 1)
        // ChoosePartition
        while count[0] + count[1] < total && count[0] < total - Self.minNodes && count[1] < total - Self.minNodes {
            var biggest: Float = -1
            var chosen = 0, better = 0
            for i in 0..<total where part[i] == -1 {
                let g0 = buf[i].rect.combined(cover[0]).volume - area[0]
                let g1 = buf[i].rect.combined(cover[1]).volume - area[1]
                var diff = g1 - g0
                let group = diff >= 0 ? 0 : 1
                if group == 1 { diff = -diff }
                if diff > biggest {
                    biggest = diff
                    chosen = i
                    better = group
                } else if diff == biggest && count[group] < count[better] {
                    chosen = i
                    better = group
                }
            }
            classify(chosen, better)
        }
        if count[0] + count[1] < total {
            let group = count[0] >= total - Self.minNodes ? 1 : 0
            for i in 0..<total where part[i] == -1 { classify(i, group) }
        }
        // LoadNodes
        let new = Node(node.level)
        node.branches = []
        for i in 0..<total {
            if part[i] == 0 { node.branches.append(buf[i]) } else { new.branches.append(buf[i]) }
        }
        return new
    }

    func search(_ r: Rect) -> [Int] {
        var out: [Int] = []
        search(root, r, &out)
        return out
    }

    private func search(_ node: Node, _ r: Rect, _ out: inout [Int]) {
        for b in node.branches where r.overlaps(b.rect) {
            if node.level > 0 { search(b.child!, r, &out) } else { out.append(b.data) }
        }
    }
}
