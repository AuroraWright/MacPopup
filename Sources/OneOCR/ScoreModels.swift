import Foundation

/// A word confidence or line rejection model: 21 features -> (x + mean) / std -> Gemm + ReLU layers -> softmax, and
/// for confidence models a piecewise linear calibration of softmax[1] between the two nearest points of a grid.
/// Computed as ONNX Runtime does (MLAS SGEMM: fused multiply-adds along K, then the bias; MLAS softmax).
struct ScoreModel {
    let mean: [Float], std: [Float]
    let layers: [(weight: [[Float]], bias: [Float])]
    let grid: [Float]?, table: [Float]?

    init(_ json: [String: Any]) throws {
        func fl(_ v: Any?) -> [Float]? { (v as? [NSNumber])?.map(\.floatValue) }
        guard let m = fl(json["mean"]), let s = fl(json["std"]), m.count == 21, s.count == 21,
              let ls = json["layers"] as? [[String: Any]], !ls.isEmpty else { throw OneOCRError("Invalid score model") }
        mean = m
        std = s
        var k = 21
        layers = try ls.map { l in
            guard let w = (l["weight"] as? [[NSNumber]])?.map({ $0.map(\.floatValue) }), let b = fl(l["bias"]),
                  w.count == b.count, w.allSatisfy({ $0.count == k }) else { throw OneOCRError("Invalid score model") }
            k = b.count
            return (w, b)
        }
        guard k == 2 else { throw OneOCRError("Invalid score model") }
        if let c = json["calibration"] as? [String: Any] {
            guard let g = fl(c["grid"]), let t = fl(c["table"]), g.count == t.count, g.count >= 2
            else { throw OneOCRError("Invalid score model") }
            grid = g
            table = t
        } else {
            grid = nil
            table = nil
        }
    }

    func prob1(_ feats: [Float]) -> Float {
        var x = (0..<21).map { (feats[$0] + mean[$0]) / std[$0] }
        for (li, l) in layers.enumerated() {
            x = zip(l.weight, l.bias).map { w, b in
                var acc: Float = 0
                for k in 0..<w.count { acc = acc.addingProduct(x[k], w[k]) }
                let y = acc + b
                return li < layers.count - 1 ? max(y, 0) : y
            }
        }
        let p = MLAS.softmax(x)[1]
        guard let G = grid, let table else { return p }
        // TopK(k = 2) of -|grid - p|: the two nearest grid points, ties to the lower index
        let d = G.map { -abs($0 - p) }
        var i1 = 0
        for i in d.indices where d[i] > d[i1] { i1 = i }
        var i2 = i1 == 0 ? 1 : 0
        for i in d.indices where i != i1 && d[i] > d[i2] { i2 = i }
        let lo = min(i1, i2), hi = max(i1, i2)
        let vlo = min(table[i1], table[i2]), vhi = max(table[i1], table[i2])
        return ((vhi - vlo) / (G[hi] - G[lo])) * (p - G[lo]) + vlo
    }
}
