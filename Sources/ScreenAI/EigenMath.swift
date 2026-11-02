import Foundation

// Float math as compiled into the original library, where its results depend on the exact instructions.

/// std::max / std::min (the first argument wins ties and NaN comparisons).
@inline(__always) func cmax<T: Comparable>(_ a: T, _ b: T) -> T { a < b ? b : a }
@inline(__always) func cmin<T: Comparable>(_ a: T, _ b: T) -> T { b < a ? b : a }

/// std::fma(a, b, c).
@inline(__always) func fma(_ a: Float, _ b: Float, _ c: Float) -> Float { c.addingProduct(a, b) }
@inline(__always) func fma(_ a: Double, _ b: Double, _ c: Double) -> Double { c.addingProduct(a, b) }

/// One lane of Eigen's NEON pexp<Packet4f> (with fused multiply-adds).
func eigenPexp(_ x0: Float) -> Float {
    let x = cmin(cmax(x0, Float(bitPattern: 0xC2D0_0000)), Float(bitPattern: 0x42B1_722D))
    let t = x * Float(bitPattern: 0x3FB8_AA3B)
    let m = t.rounded(.toNearestOrEven)
    var r = fma(Float(bitPattern: 0xBF31_8000), m, x)
    r = fma(Float(bitPattern: 0x395E_8083), m, r)
    let r2 = r * r
    let a = fma(Float(bitPattern: 0x3AB4_2872), r2, Float(bitPattern: 0x3D2A_ADCC))
    let b = fma(Float(bitPattern: 0x3C09_1DE6), r2, Float(bitPattern: 0x3E2A_AA47))
    var c = fma(a, r2, Float(bitPattern: 0x3EFF_FFFC))
    let low = r + 1
    c = fma(b, r, c)
    let y = fma(c, r2, low)
    let e = UInt32(bitPattern: Int32(m) &+ 254)
    let h = e >> 1
    let out = (y * Float(bitPattern: h << 23)) * Float(bitPattern: (e &- h) << 23)
    return cmax(out, x0)
}

/// Eigen's inner-most SumReducer over exp(x): packets of 4 (pexp, pairwise reduction), then a scalar expf tail.
func eigenSumExp(_ x: [Float]) -> Float {
    let n = x.count
    let vec = n / 4 * 4
    var p: [Float] = [0, 0, 0, 0]
    for i in stride(from: 0, to: vec, by: 4) {
        for k in 0..<4 { p[k] = p[k] + eigenPexp(x[i + k]) }
    }
    var s: Float = 0
    for i in vec..<n { s = s + expf(x[i]) }
    return s + ((p[0] + p[1]) + (p[2] + p[3]))
}

/// Eigen redux<scalar_sum_op> over a 16-byte aligned float vector (NEON, four packet accumulators).
func eigenSum(_ v: [Float]) -> Float {
    let n = v.count
    let aligned = n & ~3
    if aligned == 0 {
        var res = v[0]
        for i in 1..<n { res += v[i] }
        return res
    }
    typealias P = (Float, Float, Float, Float)
    func load(_ i: Int) -> P { (v[i], v[i + 1], v[i + 2], v[i + 3]) }
    func add(_ a: P, _ b: P) -> P { (a.0 + b.0, a.1 + b.1, a.2 + b.2, a.3 + b.3) }
    var r0 = load(0)
    let blocks = n & ~15
    if blocks != 0 {
        var r1 = load(4), r2 = load(8), r3 = load(12)
        for i in stride(from: 16, to: blocks, by: 16) {
            r0 = add(r0, load(i))
            r1 = add(r1, load(i + 4))
            r2 = add(r2, load(i + 8))
            r3 = add(r3, load(i + 12))
        }
        let rest = n & 0xC
        if rest != 0 {
            r0 = add(r0, load(blocks))
            if rest >= 8 { r1 = add(r1, load(blocks + 4)) }
            if rest == 12 { r2 = add(r2, load(blocks + 8)) }
        }
        r0 = add(add(r3, r2), add(r1, r0))
    } else {
        if aligned >= 5 { r0 = add(r0, load(4)) }
        if aligned >= 9 { r0 = add(r0, load(8)) }
    }
    var res = (r0.0 + r0.1) + (r0.2 + r0.3)
    for i in aligned..<n { res += v[i] }
    return res
}

/// Apple libm's __sincosf_stret / __sincos_stret, which the original calls (their last bits differ from sinf/cosf).
@inline(__always) func sinCos(_ x: Float) -> (sin: Float, cos: Float) {
    let r = __sincosf_stret(x)
    return (r.__sinval, r.__cosval)
}

@inline(__always) func sinCos(_ x: Double) -> (sin: Double, cos: Double) {
    let r = __sincos_stret(x)
    return (r.__sinval, r.__cosval)
}
