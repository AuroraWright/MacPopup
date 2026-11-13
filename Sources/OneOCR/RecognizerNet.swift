import Accelerate
import CoreML
import Foundation
import OneOCRKernels
import simd

// The recognizer network: the CNN (up to "convfeat") on Core ML, then what ONNX Runtime computes on the CPU, emulated
// bit for bit as its arm64 MLAS kernels do: two bidirectional DynamicQuantizeLSTMs (dynamic uint8 quantization,
// integer GEMMs, MLAS logistic/tanh), the QuantizeLinear + MatMulIntegerToFloat output layer and LogSoftmax.

private typealias V8 = SIMD8<Float>

private extension SIMD8 where Scalar == Float {
    /// max then min, as MLAS's vmaxnmq/vminnmq.
    @inline(__always) func clamped(_ lo: V8, _ hi: V8) -> V8 { simd_min(simd_max(self, lo), hi) }
}

/// MLAS logistic (logistic.cpp): clamp to ±18, odd/even polynomials with fused multiply-adds.
@inline(__always) private func logistic(_ x: V8) -> V8 {
    let v = x.clamped(V8(repeating: -18), V8(repeating: 18)), v2 = v * v
    var p = V8(repeating: 6.08574864600143e-05)
        .addingProduct(V8(repeating: 1.15627324459942e-07).addingProduct(v2, V8(repeating: 4.37031012579801e-11)), v2)
    p = V8(repeating: 8.51377133304701e-03).addingProduct(p, v2)
    p = V8(repeating: 2.48287947061529e-01).addingProduct(p, v2)
    p = p * v
    var q = V8(repeating: 5.76102136993427e-09).addingProduct(v2, V8(repeating: 6.10247389755681e-13))
    q = V8(repeating: 6.29106785017040e-06).addingProduct(q, v2)
    q = V8(repeating: 1.70198817374094e-03).addingProduct(q, v2)
    q = V8(repeating: 1.16817656904453e-01).addingProduct(q, v2)
    q = V8(repeating: 9.93151921023180e-01).addingProduct(q, v2)
    return (p / q + 0.5).clamped(V8(repeating: 0), V8(repeating: 1))
}

/// MLAS tanh (tanh.cpp): clamp to ±9.
@inline(__always) private func tanhMlas(_ x: V8) -> V8 {
    let v = x.clamped(V8(repeating: -9), V8(repeating: 9)), v2 = v * v
    var p = V8(repeating: 2.00018790482477e-13).addingProduct(v2, V8(repeating: -2.76076847742355e-16))
    p = V8(repeating: -8.60467152213735e-11).addingProduct(p, v2)
    p = V8(repeating: 5.12229709037114e-08).addingProduct(p, v2)
    p = V8(repeating: 1.48572235717979e-05).addingProduct(p, v2)
    p = V8(repeating: 6.37261928875436e-04).addingProduct(p, v2)
    p = V8(repeating: 4.89352455891786e-03).addingProduct(p, v2)
    p = p * v
    var q = V8(repeating: 1.18534705686654e-04).addingProduct(v2, V8(repeating: 1.19825839466702e-06))
    q = V8(repeating: 2.26843463243900e-03).addingProduct(q, v2)
    q = V8(repeating: 4.89352518554385e-03).addingProduct(q, v2)
    return p / q
}

/// GetQuantizationParameter<uint8_t> + MlasQuantizeLinear: uint8 codes of a (into out, which has room for n rounded
/// up to 16, the padding zeroed), the scale, the zero point and the codes' sum.
@inline(__always) private func quantizeU8(_ a: UnsafePointer<Float>, _ n: Int, _ out: UnsafeMutablePointer<UInt8>)
    -> (scale: Float, zp: Int, sum: Int) {
    var mn: Float = 0, mx: Float = 0
    for i in 0..<n {
        mn = min(mn, a[i])
        mx = max(mx, a[i])
    }
    let scale: Float = mx == mn ? 1 : (mx - mn) / 255
    let zp = min(max(0 - mn / scale, 0), 255).rounded(.toNearestOrEven)
    var sum = 0
    for i in 0..<n {
        let v = UInt8(min(max(a[i] / scale, -zp), 255 - zp).rounded(.toNearestOrEven) + zp)
        out[i] = v
        sum += Int(v)
    }
    for i in n..<padded(n) { out[i] = 0 }
    return (scale, Int(zp), sum)
}

@inline(__always) private func padded(_ n: Int) -> Int { (n + 15) & ~15 }

/// int8 weights [K][N] as rows [N][K padded] of uint8 (w + 128), and each row's sum, for oneocr_dot_u8_rows:
/// Σ (q - zp) w = q·wu - 128 Σq - zp Σwu + 128 zp K.
private struct U8Matrix {
    let rows: Int, k: Int, kp: Int
    let data: [UInt8]
    let sums: [Int]

    init(_ w: UnsafePointer<Int8>, k: Int, n: Int) {
        rows = n
        self.k = k
        kp = padded(k)
        var d = [UInt8](repeating: 0, count: n * kp), s = [Int](repeating: 0, count: n)
        for kk in 0..<k {
            for r in 0..<n {
                let v = Int(w[kk * n + r]) + 128
                d[r * kp + kk] = UInt8(v)
                s[r] += v
            }
        }
        data = d
        sums = s
    }

    /// acc[r] = Σ (q - zp) w[., r] for the codes q (kp long, zero padded) with sum qsum.
    @inline(__always) func products(_ q: UnsafePointer<UInt8>, zp: Int, qsum: Int, _ dot: UnsafeMutablePointer<UInt32>,
                                    _ out: (Int, Int) -> Void) {
        data.withUnsafeBufferPointer { oneocr_dot_u8_rows(q, $0.baseAddress!, Int32(rows), Int32(kp), dot) }
        let corr = -128 * qsum + 128 * zp * k
        for r in 0..<rows { out(r, Int(dot[r]) + corr - zp * sums[r]) }
    }

    /// y[t * rows + r] = Float(acc) mul[r] + bias[r], acc the products for every code vector t of `count` (kp apart, sums
    /// qsums) and every row r: a block of rows at a time (their weights stay in the cache while all the vectors go by,
    /// four at a time), the blocks on all cores.
    func affine(_ q: UnsafePointer<UInt8>, count: Int, zp: Int, qsums: [Int], mul: UnsafePointer<Float>,
                bias: UnsafePointer<Float>, into y: UnsafeMutablePointer<Float>) {
        let blockRows = 256, blocks = (rows + blockRows - 1) / blockRows
        // In 32 bits, which hold every term (|acc| < 2^26), so the loop below vectorizes.
        let corrs = qsums.map { Int32(-128 * $0 + 128 * zp * k) }, zsums = sums.map { Int32(zp * $0) }
        data.withUnsafeBufferPointer { w in zsums.withUnsafeBufferPointer { zsums in
            let (w, zsums) = (w.baseAddress!, zsums.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: blocks) { b in
                let r0 = b * blockRows, n = min(rows, r0 + blockRows) - r0
                let dot = UnsafeMutablePointer<UInt32>.allocate(capacity: 4 * n)
                defer { dot.deallocate() }
                var t = 0
                while t < count {
                    let frames = min(4, count - t)
                    if frames == 4 {
                        oneocr_dot_u8_rows4(q + t * kp, w + r0 * kp, Int32(n), Int32(kp), dot)
                    } else {
                        for j in 0..<frames { oneocr_dot_u8_rows(q + (t + j) * kp, w + r0 * kp, Int32(n), Int32(kp), dot + j * n) }
                    }
                    for j in 0..<frames {
                        let corr = corrs[t + j], d = dot + j * n
                        let (row, m, b, z) = (y + (t + j) * rows + r0, mul + r0, bias + r0, zsums + r0)
                        for r in 0..<n { row[r] = Float(Int32(bitPattern: d[r]) &+ corr &- z[r]) * m[r] + b[r] }
                    }
                    t += 4
                }
            }
        } }
    }

    /// The same for four code vectors kp apart; dot holds 4 * rows.
    @inline(__always) func products4(_ q: UnsafePointer<UInt8>, zp: Int, qsums: (Int, Int, Int, Int),
                                     _ dot: UnsafeMutablePointer<UInt32>, _ out: (Int, Int, Int) -> Void) {
        data.withUnsafeBufferPointer { oneocr_dot_u8_rows4(q, $0.baseAddress!, Int32(rows), Int32(kp), dot) }
        let corrs = [qsums.0, qsums.1, qsums.2, qsums.3].map { -128 * $0 + 128 * zp * k }
        for j in 0..<4 {
            let d = dot + j * rows, corr = corrs[j]
            for r in 0..<rows { out(j, r, Int(d[r]) + corr - zp * sums[r]) }
        }
    }
}

private struct LSTMDirection {
    let W: U8Matrix, R: U8Matrix
    let wScale: [Float], rScale: [Float], bias: [Float]
}

private struct LSTMLayer {
    let hidden: Int, input: Int
    let dirs: [LSTMDirection]
}

/// MLAS's exp for SumExp (MlasComputeSumExpVector), one lane.
@inline(__always) private func mlasSumExp(_ x: Float, _ negMax: Float) -> Float {
    var v = max(-88.3762626647949, x + negMax)
    let bias: Float = 12_582_912
    let biased = bias.addingProduct(v, 1.44269504088896341)
    let m = biased - bias
    v = v.addingProduct(m, -6.93145752e-1)
    v = v.addingProduct(m, -1.42860677e-6)
    let normal = Float(bitPattern: (biased.bitPattern << 23) &+ 0x3F80_0000)
    var p: Float = 0x1.694000p-10
    p = Float(0x1.125edcp-7).addingProduct(p, v)
    p = Float(0x1.555b5ap-5).addingProduct(p, v)
    p = Float(0x1.555450p-3).addingProduct(p, v)
    p = Float(0x1.fffff6p-2).addingProduct(p, v)
    p = Float(1).addingProduct(p, v)
    p = Float(1).addingProduct(p, v)
    return p * normal
}

/// The same for four lanes (the same operations in each).
@inline(__always) private func mlasSumExp(_ x: SIMD4<Float>, _ negMax: Float) -> SIMD4<Float> {
    typealias V4 = SIMD4<Float>
    var v = simd_max(V4(repeating: -88.3762626647949), x + negMax)
    let bias = V4(repeating: 12_582_912)
    let biased = bias.addingProduct(v, V4(repeating: 1.44269504088896341))
    let m = biased - bias
    v = v.addingProduct(m, V4(repeating: -6.93145752e-1))
    v = v.addingProduct(m, V4(repeating: -1.42860677e-6))
    let normal = unsafeBitCast((unsafeBitCast(biased, to: SIMD4<UInt32>.self) &<< 23) &+ 0x3F80_0000, to: V4.self)
    var p = V4(repeating: 0x1.694000p-10)
    p = V4(repeating: 0x1.125edcp-7).addingProduct(p, v)
    p = V4(repeating: 0x1.555b5ap-5).addingProduct(p, v)
    p = V4(repeating: 0x1.555450p-3).addingProduct(p, v)
    p = V4(repeating: 0x1.fffff6p-2).addingProduct(p, v)
    p = V4(repeating: 1).addingProduct(p, v)
    p = V4(repeating: 1).addingProduct(p, v)
    return p * normal
}

/// MlasComputeSumExpF32Kernel: (sum, exps).
private func mlasSumExp(_ x: UnsafeBufferPointer<Float>, _ negMax: Float, _ out: UnsafeMutablePointer<Float>?) -> Float {
    var n = x.count, i = 0
    var acc: Float = 0
    if n >= 4 {
        var a = SIMD4<Float>(repeating: 0)
        let lanes = UnsafeRawPointer(x.baseAddress!)
        func load(_ i: Int) -> SIMD4<Float> { lanes.loadUnaligned(fromByteOffset: 4 * i, as: SIMD4<Float>.self) }
        while n >= 8 {
            let v0 = mlasSumExp(load(i), negMax), v1 = mlasSumExp(load(i + 4), negMax)
            a = a + v0
            a = a + v1
            if let o = out { for l in 0..<4 { o[i + l] = v0[l]; o[i + 4 + l] = v1[l] } }
            i += 8
            n -= 8
        }
        while n >= 4 {
            let v = mlasSumExp(load(i), negMax)
            a = a + v
            if let o = out { for l in 0..<4 { o[i + l] = v[l] } }
            i += 4
            n -= 4
        }
        acc = (a[0] + a[1]) + (a[2] + a[3])
    }
    while n > 0 {
        let v = mlasSumExp(x[i], negMax)
        acc += v
        out?[i] = v
        i += 1
        n -= 1
    }
    return acc
}

private func mlasMax(_ x: UnsafeBufferPointer<Float>) -> Float {
    guard !x.isEmpty else { return -Float.greatestFiniteMagnitude }
    var m: Float = 0
    vDSP_maxv(x.baseAddress!, 1, &m, vDSP_Length(x.count))
    return max(m, -Float.greatestFiniteMagnitude)
}

enum MLAS {
    /// LogSoftmax over each row of length d (in place).
    static func logSoftmax(_ x: inout [Float], _ d: Int) {
        x.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            forEachRange(buf.count / d, size: d) { rows in
                for r in rows {
                    let row = p + r * d
                    let negMax = -mlasMax(UnsafeBufferPointer(start: row, count: d))
                    let lg = logf(mlasSumExp(UnsafeBufferPointer(start: row, count: d), negMax, nil))
                    for i in 0..<d { row[i] = (row[i] + negMax) - lg }
                }
            }
        }
    }

    /// Softmax of one short row.
    static func softmax(_ x: [Float]) -> [Float] {
        var e = [Float](repeating: 0, count: x.count)
        let sum = x.withUnsafeBufferPointer { b in e.withUnsafeMutableBufferPointer { mlasSumExp(b, -mlasMax(b), $0.baseAddress!) } }
        let scale = 1 / sum
        return e.map { $0 * scale }
    }
}

final class CharNet: @unchecked Sendable {
    private let cnn: CoreMLModel
    private let layers: [LSTMLayer]
    private let linScale: Float, linZero: Int, linMul: [Float], linBias: [Float]
    private let linB: U8Matrix
    let classes: Int

    init(files: ModelFiles, name: String) throws {
        cnn = try files.model("Character_\(name)", units: .cpuOnly)
        let manifest = try files.json("tail/\(name).json")
        guard let blob = try? Data(contentsOf: files.url("tail/\(name).bin")) else { throw OneOCRError("tail/\(name).bin missing") }
        func entry(_ d: Any?, _ size: Int) throws -> (Int, Int) {
            guard let e = d as? [String: Any], let o = e["offset"] as? Int, let c = e["count"] as? Int,
                  o >= 0, c >= 0, o + c * size <= blob.count else { throw OneOCRError("tail/\(name).json is invalid") }
            return (o, c)
        }
        func f32(_ d: Any?) throws -> [Float] {
            let (o, c) = try entry(d, 4)
            return blob.withUnsafeBytes { raw in (0..<c).map { raw.loadUnaligned(fromByteOffset: o + 4 * $0, as: Float.self) } }
        }
        func i8(_ d: Any?) throws -> [Int8] {
            let (o, c) = try entry(d, 1)
            return blob.withUnsafeBytes { raw in (0..<c).map { raw.load(fromByteOffset: o + $0, as: Int8.self) } }
        }
        guard let ls = manifest["layers"] as? [[String: Any]], let lin = manifest["linear"] as? [String: Any]
        else { throw OneOCRError("tail/\(name).json is invalid") }
        layers = try ls.map { (l: [String: Any]) throws -> LSTMLayer in
            guard let H = l["hidden"] as? Int, let K = l["input"] as? Int, H % 8 == 0 else {
                throw OneOCRError("tail/\(name).json is invalid")
            }
            let G: Int = 4 * H
            let W = try i8(l["W"]), R = try i8(l["R"]), B = try f32(l["B"])
            let ws = try f32(l["w_scale"]), rs = try f32(l["r_scale"])
            let sizesOK: Bool = W.count == 2 * K * G && R.count == 2 * H * G && B.count == 4 * G
            guard sizesOK, ws.count == 2 * G, rs.count == 2 * G
            else { throw OneOCRError("tail/\(name).json is invalid") }
            let dirs = (0..<2).map { Self.direction($0, K, H, W, R, B, ws, rs) }
            return LSTMLayer(hidden: H, input: K, dirs: dirs)
        }
        guard let s = lin["scale"] as? NSNumber, let z = lin["zero_point"] as? Int, let sa = lin["a_scale"] as? NSNumber,
              let c = lin["classes"] as? Int, let last = layers.last else { throw OneOCRError("tail/\(name).json is invalid") }
        let B = try i8(lin["B"]), sb = try f32(lin["b_scale"]), bias = try f32(lin["bias"])
        let K = 2 * last.hidden
        guard B.count == K * c, sb.count == c, bias.count == c else { throw OneOCRError("tail/\(name).json is invalid") }
        linScale = s.floatValue
        linZero = z
        linMul = sb.map { sa.floatValue * $0 }
        linBias = bias
        linB = B.withUnsafeBufferPointer { U8Matrix($0.baseAddress!, k: K, n: c) }
        classes = c
    }

    private static func direction(_ d: Int, _ K: Int, _ H: Int, _ W: [Int8], _ R: [Int8], _ B: [Float], _ ws: [Float],
                                  _ rs: [Float]) -> LSTMDirection {
        let G = 4 * H
        let w = W.withUnsafeBufferPointer { U8Matrix($0.baseAddress! + d * K * G, k: K, n: G) }
        let r = R.withUnsafeBufferPointer { U8Matrix($0.baseAddress! + d * H * G, k: H, n: G) }
        var bias = [Float](repeating: 0, count: G)
        for n in 0..<G { bias[n] = B[d * 2 * G + n] + B[d * 2 * G + G + n] }
        return LSTMDirection(W: w, R: r, wScale: Array(ws[(d * G)..<(d * G + G)]), rScale: Array(rs[(d * G)..<(d * G + G)]),
                             bias: bias)
    }

    /// One direction of an LSTM layer over x [T, K] into out[t * 2H + offset ..< + H].
    private func runDirection(_ d: LSTMDirection, _ H: Int, _ x: [Float], _ T: Int, _ K: Int, reverse: Bool,
                              _ out: UnsafeMutablePointer<Float>, offset: Int) {
        let G = 4 * H
        let kp = padded(K)
        // The input GEMM over the whole (time-reversed) sequence, quantized together.
        var xs = x
        if reverse {
            for t in 0..<T { for k in 0..<K { xs[t * K + k] = x[(T - 1 - t) * K + k] } }
        }
        let codes = UnsafeMutablePointer<UInt8>.allocate(capacity: T * kp + 16)
        defer { codes.deallocate() }
        let dot = UnsafeMutablePointer<UInt32>.allocate(capacity: 4 * G)
        defer { dot.deallocate() }
        let flat = UnsafeMutablePointer<UInt8>.allocate(capacity: padded(T * K))
        defer { flat.deallocate() }
        let (s, zp, _) = xs.withUnsafeBufferPointer { quantizeU8($0.baseAddress!, T * K, flat) }
        var gx = [Float](repeating: 0, count: T * G)
        let mul = d.wScale.map { s * $0 }
        var qsums = [Int](repeating: 0, count: T)
        for t in 0..<T {
            let q = codes + t * kp
            var qsum = 0
            for k in 0..<K {
                q[k] = flat[t * K + k]
                qsum += Int(q[k])
            }
            for k in K..<kp { q[k] = 0 }
            qsums[t] = qsum
        }
        var t0 = 0
        while t0 + 4 <= T {
            d.W.products4(codes + t0 * kp, zp: zp, qsums: (qsums[t0], qsums[t0 + 1], qsums[t0 + 2], qsums[t0 + 3]), dot) {
                j, n, acc in gx[(t0 + j) * G + n] = Float(acc) * mul[n]
            }
            t0 += 4
        }
        for t in t0..<T {
            d.W.products(codes + t * kp, zp: zp, qsum: qsums[t], dot) { n, acc in gx[t * G + n] = Float(acc) * mul[n] }
        }
        // The recurrence.
        let state = UnsafeMutablePointer<Float>.allocate(capacity: 2 * H + 2 * G)
        defer { state.deallocate() }
        state.initialize(repeating: 0, count: 2 * H + 2 * G)
        let h = state, c = state + H, racc = state + 2 * H, rmul = state + 2 * H + G
        let hq = UnsafeMutablePointer<UInt8>.allocate(capacity: padded(H))
        defer { hq.deallocate() }
        let hv = UnsafeMutableRawPointer(h).assumingMemoryBound(to: V8.self)
        let cv = UnsafeMutableRawPointer(c).assumingMemoryBound(to: V8.self)
        let rv = UnsafeMutableRawPointer(racc).assumingMemoryBound(to: V8.self)
        let mv = UnsafeMutableRawPointer(rmul).assumingMemoryBound(to: V8.self)
        d.rScale.withUnsafeBufferPointer { rs in d.bias.withUnsafeBufferPointer { bias in gx.withUnsafeMutableBufferPointer { gxb in
            let rsv = UnsafeRawPointer(rs.baseAddress!).assumingMemoryBound(to: V8.self)
            let bv = UnsafeRawPointer(bias.baseAddress!).assumingMemoryBound(to: V8.self)
            for step in 0..<T {
                let (rsc, rzp, qsum) = quantizeU8(h, H, hq)
                d.R.products(hq, zp: rzp, qsum: qsum, dot) { n, acc in racc[n] = Float(acc) }
                let gv = UnsafeMutableRawPointer(gxb.baseAddress! + step * G).assumingMemoryBound(to: V8.self)
                let sv = V8(repeating: rsc)
                for n in 0..<(G / 8) { mv[n] = sv * rsv[n] }
                for n in 0..<(G / 8) { gv[n] = gv[n].addingProduct(rv[n], mv[n]) + bv[n] }
                let t = reverse ? T - 1 - step : step
                let o8 = UnsafeMutableRawPointer(out + t * 2 * H + offset).assumingMemoryBound(to: V8.self)
                for j in 0..<(H / 8) {  // gates i, o, f, c
                    let i = logistic(gv[j]), o = logistic(gv[H / 8 + j]), f = logistic(gv[2 * H / 8 + j])
                    let cc = tanhMlas(gv[3 * H / 8 + j])
                    cv[j] = (i * cc).addingProduct(cv[j], f)
                    hv[j] = tanhMlas(cv[j]) * o
                    o8[j] = hv[j]
                }
            }
        } } }
    }

    /// LSTM input [T, K] -> log probabilities [T, classes].
    func tail(_ x0: [Float], _ T: Int) -> [Float] {
        var x = x0
        for l in layers {
            let H = l.hidden
            var out = [Float](repeating: 0, count: T * 2 * H)
            out.withUnsafeMutableBufferPointer { ob in
                let p = ob.baseAddress!
                DispatchQueue.concurrentPerform(iterations: 2) { d in
                    runDirection(l.dirs[d], H, x, T, l.input, reverse: d == 1, p, offset: d * H)
                }
            }
            x = out
        }
        let K = linB.k, kp = linB.kp
        var y = [Float](unsafeUninitializedCapacity: T * classes) { _, count in count = T * classes }
        let codes = UnsafeMutablePointer<UInt8>.allocate(capacity: T * kp)
        defer { codes.deallocate() }
        var qsums = [Int](repeating: 0, count: T)
        let z = Float(linZero)
        for t in 0..<T {
            let q = codes + t * kp
            var qsum = 0
            for k in 0..<K {
                let v = UInt8(min(max(x[t * K + k] / linScale, -z), 255 - z).rounded(.toNearestOrEven) + z)
                q[k] = v
                qsum += Int(v)
            }
            for k in K..<kp { q[k] = 0 }
            qsums[t] = qsum
        }
        y.withUnsafeMutableBufferPointer { yb in
            linMul.withUnsafeBufferPointer { mul in linBias.withUnsafeBufferPointer { bias in
                linB.affine(codes, count: T, zp: linZero, qsums: qsums, mul: mul.baseAddress!, bias: bias.baseAddress!,
                            into: yb.baseAddress!)
            } }
        }
        MLAS.logSoftmax(&y, classes)
        return y
    }

    /// Log probabilities [T, classes] of a 60-pixel-high BGR line image whose width is a multiple of the frame width.
    func run(_ img: ImageU8) throws -> (logp: [Float], T: Int) {
        let k = Float(1.0 / 255.0)
        let input = try makeInput(img.height, img.width) { dst in
            let n = img.width * img.height
            for c in 0..<3 { for i in 0..<n { dst[c * n + i] = Float(img.data[i * 3 + c]) * k } }
        }
        guard let f = try cnn.predict(["data": input])["convfeat"] else { throw OneOCRError("The recognizer has no convfeat output") }
        let (shape, data) = floats(f)
        guard shape.count == 4, shape[0] == 1 else { throw OneOCRError("Unexpected convfeat shape") }
        let C = shape[1], Hc = shape[2], T = shape[3]
        let K = C * Hc
        guard let first = layers.first, first.input == K else { throw OneOCRError("convfeat doesn't fit the LSTM") }
        var x = [Float](repeating: 0, count: T * K)
        for ch in 0..<K { for t in 0..<T { x[t * K + ch] = data[ch * T + t] } }
        return (tail(x, T), T)
    }
}
