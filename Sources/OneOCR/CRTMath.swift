import Foundation

// Bit-exact ports of the CRT math routines statically linked into oneocr.dll (ARM64): ARM optimized-routines
// powf, expf, logf, sinf, cosf and pow (FMA builds), and AMD libm atan2, atan2f, sin and cos. They aren't always
// correctly rounded, so the platform libm can differ from them in the last bit, which the pipeline's thresholds
// can see. errno isn't modelled.
enum CRT {
    private static func d(_ u: UInt64) -> Double { Double(bitPattern: u) }
    private static func f(_ u: UInt32) -> Float { Float(bitPattern: u) }
    private static func dbl(_ t: [UInt64]) -> [Double] { t.map(Double.init(bitPattern:)) }

    private static let log2T = dbl(CRTTables.log2T)
    private static let log2A = dbl(CRTTables.log2A)
    private static let exp2T = CRTTables.exp2T
    private static let exp2C = dbl(CRTTables.exp2C)
    private static let logfT = dbl(CRTTables.logfT)
    private static let logfA = dbl(CRTTables.logfA)
    private static let atanLead = CRTTables.atanLead
    private static let atanTail = CRTTables.atanTail
    private static let atanfT = CRTTables.atanfT
    private static let sincosf0 = dbl(CRTTables.sincosf0)
    private static let sincosf1 = dbl(CRTTables.sincosf1)
    private static let sinS = dbl(CRTTables.sinS)
    private static let cosC = dbl(CRTTables.cosC)
    private static let invPio4 = CRTTables.invPio4.map { UInt64($0) }
    private static let piBits = CRTTables.piBits.map { UInt64($0) }
    private static let powLogHdr = dbl(CRTTables.powLogHdr)
    private static let powLogTab = dbl(CRTTables.powLogTab)
    private static let powExpHdr = dbl(CRTTables.powExpHdr)
    private static let powExpTab = CRTTables.powExpTab

    @inline(__always) private static func fma(_ a: Double, _ b: Double, _ c: Double) -> Double {
        c.addingProduct(a, b)
    }

    /// FRINTA: round half away from zero.
    @inline(__always) private static func rinta(_ x: Double) -> Double { x.rounded(.toNearestOrAwayFromZero) }

    private static func issignalingf(_ i: UInt32) -> Bool { 2 &* (i ^ 0x0040_0000) > 0xFF80_0000 }

    private static func checkintf(_ iy: UInt32) -> Int {
        let e = Int((iy >> 23) & 0xFF)
        if e < 0x7F { return 0 }
        if e > 0x7F + 23 { return 2 }
        if iy & ((1 << UInt32(0x7F + 23 - e)) - 1) != 0 { return 0 }
        if iy & (1 << UInt32(0x7F + 23 - e)) != 0 { return 1 }
        return 2
    }

    private static func xflowf(_ sign: UInt64, _ y: Double) -> Float {
        let y = Float(y)
        return (sign != 0 ? -y : y) * y
    }

    // MARK: powf, expf, logf

    static func powf(_ x: Float, _ y: Float) -> Float {
        var ix = x.bitPattern
        let iy = y.bitPattern
        var signBias: UInt64 = 0
        if ix &- 0x0080_0000 >= 0x7F00_0000 || 2 &* iy &- 1 >= 2 * 0x7F80_0000 - 1 {
            if 2 &* iy &- 1 >= 2 * 0x7F80_0000 - 1 {                  // y is 0, inf or nan
                if 2 &* iy == 0 { return issignalingf(ix) ? x + y : 1 }
                if ix == 0x3F80_0000 { return issignalingf(iy) ? x + y : 1 }
                if 2 &* ix > 0xFF00_0000 || 2 &* iy > 0xFF00_0000 { return x + y }
                if 2 &* ix == 0x7F00_0000 { return 1 }
                if (2 &* ix < 0x7F00_0000) == (iy & 0x8000_0000 == 0) { return 0 }
                return y * y
            }
            if 2 &* ix &- 1 >= 2 * 0x7F80_0000 - 1 {                  // x is 0, inf or nan
                var x2 = x * x
                if ix & 0x8000_0000 != 0 && checkintf(iy) == 1 {
                    x2 = -x2
                    signBias = 1
                }
                if 2 &* ix == 0 && iy & 0x8000_0000 != 0 { return signBias != 0 ? -.infinity : .infinity }
                return iy & 0x8000_0000 != 0 ? 1 / x2 : x2
            }
            if ix & 0x8000_0000 != 0 {                                 // x < 0
                let yint = checkintf(iy)
                if yint == 0 { return (x - x) / (x - x) }
                if yint == 1 { signBias = 1 << (5 + 11) }
                ix &= 0x7FFF_FFFF
            }
            if ix < 0x0080_0000 {                                      // subnormal
                ix = (Float(bitPattern: ix) * 8388608).bitPattern & 0x7FFF_FFFF
                ix &-= 23 << 23
            }
        }
        // log2_inline, scaled by 32
        let tmp = ix &- 0x3F33_0000
        let i = Int((tmp >> 19) & 15)
        let top = tmp & 0xFF80_0000
        let iz = ix &- top
        let k = Int32(bitPattern: top) >> 18
        let invc = log2T[2 * i], logc = log2T[2 * i + 1]
        let z = Double(f(iz))
        let r = fma(invc, z, -1)
        let y0 = logc + Double(k)
        let r2 = r * r
        var q = fma(log2A[4], r, y0)
        let p = fma(log2A[2], r, log2A[3])
        q = fma(p, r2, q)
        let yy = fma(log2A[0], r, log2A[1])
        let logx = fma(yy, r2 * r2, q)
        let ylogx = logx * Double(y)
        if (ylogx.bitPattern >> 47) & 0xFFFF >= 0x815F {               // |y*log2(x)| >= 126
            if ylogx > 0x1.fffffffd1d571p+11 { return xflowf(signBias, 0x1p97) }
            if ylogx <= -4800 { return xflowf(signBias, 0x1p-95) }
            if ylogx < -4768 { return xflowf(signBias, 1.25 * 0x1p-75) }
        }
        // exp2_inline
        let kd = rinta(ylogx)
        let ki = UInt64(bitPattern: Int64(kd))
        let rr = ylogx - kd
        let t = exp2T[Int(ki & 31)] &+ ((ki &+ signBias) << 47)
        let zz = fma(rr, exp2C[0], exp2C[1])
        var yv = fma(rr, exp2C[2], 1)
        yv = fma(zz, rr * rr, yv)
        return Float(yv * d(t))
    }

    static func expf(_ x: Float) -> Float {
        let ix = x.bitPattern
        let top12 = (ix >> 20) & 0x7FF
        if top12 >= 0x42B {
            if ix == 0xFF80_0000 { return 0 }
            if top12 >= 0x7F8 { return x + x }
            if x > f(0x42B1_7217) { return .infinity }
            if x < f(0xC2CF_F1B4) { return 0 }
        }
        let z = exp2C[3] * Double(x)
        let kd = rinta(z)
        let ki = UInt64(bitPattern: Int64(kd))
        let r = z - kd
        let t = exp2T[Int(ki & 31)] &+ (ki << 47)
        let zz = fma(exp2C[0], r, exp2C[1])
        var y = fma(exp2C[2], r, 1)
        y = fma(zz, r * r, y)
        return Float(y * d(t))
    }

    static func logf(_ x: Float) -> Float {
        var ix = x.bitPattern
        if ix == 0x3F80_0000 { return 0 }
        if ix &- 0x0080_0000 >= 0x7F80_0000 - 0x0080_0000 {
            if ix &* 2 == 0 { return -.infinity }
            if ix == 0x7F80_0000 { return x }
            if ix & 0x8000_0000 != 0 || ix &* 2 >= 0xFF00_0000 { return (x - x) / (x - x) }
            ix = (x * 8388608).bitPattern &- (23 << 23)                // subnormal
        }
        let tmp = ix &- 0x3F33_0000
        let i = Int((tmp >> 19) & 15)
        let k = Int32(bitPattern: tmp) >> 23
        let iz = ix &- (tmp & 0xFF80_0000)
        let invc = logfT[2 * i], logc = logfT[2 * i + 1]
        let z = Double(f(iz))
        let r = fma(invc, z, -1)
        let y0 = fma(Double(k), logfA[3], logc)
        let r2 = r * r
        var y = fma(logfA[1], r, logfA[2])
        y = fma(logfA[0], r2, y)
        y = fma(y, r2, y0 + r)
        return Float(y)
    }

    // MARK: atan2, atan2f

    private static let pi = d(0x4009_21FB_5444_2D18)
    private static let piBy2 = d(0x3FF9_21FB_5444_2D18)

    /// AMD libm's NaN return: the argument's bits with the quiet bit set.
    private static func amdNaN(_ x: Double) -> Double { d(x.bitPattern | 0x0008_0000_0000_0000) }

    /// y / x with a subnormal result, rounded by hand as AMD libm does.
    private static func subnormalQuotient(_ y: Double, _ x: Double) -> Double {
        var r = (0x1p100 * y / x).bitPattern
        let sign = r & 0x8000_0000_0000_0000
        r &= 0x7FFF_FFFF_FFFF_FFFF
        let e = Int(r >> 52)
        if e > 100 {
            r = (r & 0x000F_FFFF_FFFF_FFFF) | (UInt64(e - 100) << 52)
        } else if 101 - e > 54 {
            r = 0
        } else {
            var m = (r & 0x000F_FFFF_FFFF_FFFF) | (1 << 52)
            m >>= UInt64(100 - e)
            r = (m & 1) + (m >> 1)
        }
        return d(sign | r)
    }

    static func atan2(_ y: Double, _ x: Double) -> Double {
        var x = x, y = y
        if x.isNaN { return amdNaN(x) }
        if y.isNaN { return amdNaN(y) }
        var ux = x.bitPattern, uy = y.bitPattern
        let xneg = ux >> 63 != 0, yneg = uy >> 63 != 0
        let xexp = Int((ux >> 52) & 0x7FF), yexp = Int((uy >> 52) & 0x7FF)
        var diff = yexp - xexp
        if uy & 0x7FFF_FFFF_FFFF_FFFF == 0 { return !xneg ? y : (yneg ? -pi : pi) }
        if ux & 0x7FFF_FFFF_FFFF_FFFF == 0 { return yneg ? -piBy2 : piBy2 }
        if xexp < 0x3FD && yexp < 0x3FD {                                   // both tiny: scale by 2^1024
            func up(_ u: UInt64) -> UInt64 {
                if u & 0x7FF0_0000_0000_0000 != 0 { return u &+ 0x4000_0000_0000_0000 }
                var v = d(u | 0x4010_0000_0000_0000)
                v = u >> 63 != 0 ? v + 4 : v - 4
                return v.bitPattern
            }
            ux = up(ux); uy = up(uy)
            x = d(ux); y = d(uy)
            diff = Int((uy >> 52) & 0x7FF) - Int((ux >> 52) & 0x7FF)
        }
        if diff > 56 { return yneg ? -piBy2 : piBy2 }
        if diff < -28 && !xneg {
            if diff < -1074 { return yneg ? -0.0 : 0.0 }
            if diff < -1022 { return subnormalQuotient(y, x) }
            return y / x
        }
        if diff < -56 && xneg { return yneg ? -pi : pi }
        if x.isInfinite && y.isInfinite {
            if xneg { return yneg ? d(0xC002_D97C_7F33_21D2) : d(0x4002_D97C_7F33_21D2) }
            return yneg ? d(0xBFE9_21FB_5444_2D18) : d(0x3FE9_21FB_5444_2D18)
        }
        let ax = abs(x), ay = abs(y)
        let swap = ax < ay
        let num = swap ? ax : ay, den = swap ? ay : ax
        let u = num / den
        var lead: Double, lo: Double
        if u > 0.0625 {
            let idx = Int(fma(u, 256, 0.5))
            let c = Double(idx) * 0.00390625
            lead = d(atanLead[idx - 16])
            let m = 0x3FF - Int((den.bitPattern >> 52) & 0x7FF)
            let h = m / 2                                          // int(m / 2) truncates toward zero
            let s1 = Double(sign: .plus, exponent: h, significand: 1), s2 = Double(sign: .plus, exponent: m - h, significand: 1)
            let denS = s1 * den * s2
            let numS = s1 * num * s2
            let denHi = d(denS.bitPattern & 0xFFFF_FFFF_F800_0000)
            var t = fma(-c, denHi, numS)
            t = fma(-(denS - denHi), c, t)
            let v = t / fma(c, numS, denS)
            let v2 = v * v
            let q = fma(-v2, d(0x3FC9_9992_B980_2D7D), d(0x3FD5_5555_5555_0877)) * v2
            lo = fma(-q, v, d(atanTail[idx - 16]) + v)
        } else {
            lead = 0
            if u < d(0x3E45_798E_E230_8C3A) {
                lo = u
            } else {
                let u2 = u * u
                let denHi = d(den.bitPattern & 0xFFFF_FFFF_0000_0000)
                let uHi = d(u.bitPattern & 0xFFFF_FFFF_0000_0000)
                var r = fma(-uHi, denHi, num)
                r = fma(-(den - denHi), uHi, r)
                r = fma(-(u - uHi), den, r) / den
                var p = fma(-u2, d(0x3FB7_0C31_92D7_51C2), d(0x3FBC_7188_39B8_C4EB))
                p = fma(-p, u2, d(0x3FC2_4924_82BD_6BE1))
                p = fma(-p, u2, d(0x3FC9_9999_9996_43A3))
                p = fma(-p, u2, d(0x3FD5_5555_5555_5538))
                lo = fma(-p, u2 * u, r) + u
            }
        }
        if swap {
            lead = piBy2 - lead
            lo = d(0x3C91_A626_3314_5C07) - lo
        }
        if xneg {
            lead = d(0x4009_21FB_5000_0000) - lead
            lo = d(0x3E61_10B4_611A_6263) - lo
        }
        let res = lo + lead
        return yneg ? -res : res
    }

    static func atan2f(_ yf: Float, _ xf: Float) -> Float {
        let y = Double(yf), x = Double(xf)
        if x.isNaN || y.isNaN { return Float(x + y) }
        let ux = x.bitPattern, uy = y.bitPattern
        let xneg = ux >> 63 != 0, yneg = uy >> 63 != 0
        let diff = Int((uy >> 52) & 0x7FF) - Int((ux >> 52) & 0x7FF)
        if uy & 0x7FFF_FFFF_FFFF_FFFF == 0 { return !xneg ? Float(y) : (yneg ? f(0xC049_0FDB) : f(0x4049_0FDB)) }
        if ux & 0x7FFF_FFFF_FFFF_FFFF == 0 && yneg { return f(0xBFC9_0FDB) }
        if diff > 26 { return yneg ? f(0xBFC9_0FDB) : f(0x3FC9_0FDB) }
        if diff < -13 && !xneg {
            if diff < -150 { return yneg ? -0.0 : 0.0 }
            if diff < -126 { return Float(subnormalQuotient(y, x)) }
            return Float(y / x)
        }
        if diff < -26 && xneg { return yneg ? f(0xC049_0FDB) : f(0x4049_0FDB) }
        if x.isInfinite && y.isInfinite {
            if xneg { return yneg ? f(0xC016_CBE4) : f(0x4016_CBE4) }
            return yneg ? f(0xBF49_0FDB) : f(0x3F49_0FDB)
        }
        let ax = abs(x), ay = abs(y)
        let swap = ax < ay
        let num = swap ? ax : ay, den = swap ? ay : ax
        let u = num / den
        var r: Double
        if u > 0.0625 {
            let idx = Int(fma(u, 256, 0.5))
            let c = Double(idx)
            let v = fma(-den, c, num * 256) / fma(den, 256, num * c)
            r = fma(-(v * v * v), d(0x3FD5_5555_5555_0877), d(atanfT[idx - 16]) + v)
        } else if u < d(0x3F1A_36E2_EB1C_432D) {
            r = u
        } else {
            let u2 = u * u
            var p = fma(-u2, d(0x3FC2_4924_82BD_6BE1), d(0x3FC9_9999_9996_43A3))
            p = fma(-p, u2, d(0x3FD5_5555_5555_5538))
            r = fma(-p, u2 * u, u)
        }
        if swap { r = piBy2 - r }
        if xneg { r = pi - r }
        return Float(yneg ? -r : r)
    }

    // MARK: sinf, cosf

    private static func sinfPoly(_ x: Double, _ x2: Double, _ p: [Double], _ n: Int) -> Float {
        if n & 1 == 0 {
            let x3 = x * x2
            let s1 = fma(p[13], x2, p[12])
            return Float(fma(s1, x3 * x2, fma(p[11], x3, x)))
        }
        let x4 = x2 * x2
        let c = fma(p[8], x4, fma(p[7], x2, p[6]))
        let c2 = fma(p[10], x2, p[9])
        return Float(fma(c2, x4 * x2, c))
    }

    /// (reduced x, x², table, n) for |y| >= pi/4.
    private static func sincosfReduce(_ y: Double, _ xi: UInt32) -> (Double, Double, [Double], Int) {
        var x: Double, n: Int, q: Int
        if xi & 0x7FF0_0000 < 0x42F0_0000 {
            let p = sincosf0
            let r = y * p[4]
            n = Int(rinta(r))
            x = fma(-Double(n), p[5], y)
            q = n
        } else {
            let arr = Int((xi >> 26) & 15)
            let v = UInt64((xi & 0x7F_FFFF) | 0x80_0000) << UInt64((xi >> 23) & 7)
            var res0 = (v &* invPio4[arr]) & 0xFFFF_FFFF
            let res1 = v &* invPio4[arr + 4]
            let res2 = v &* invPio4[arr + 8]
            res0 = ((res2 >> 32) | (res0 << 32)) &+ res1
            let nn = (res0 &+ (1 << 61)) >> 62
            res0 = res0 &- (nn << 62)
            x = Double(Int64(bitPattern: res0)) * d(0x3C19_21FB_5444_2D18)
            n = Int(nn)
            q = n + Int(xi >> 31)
        }
        let p = q & 2 != 0 ? sincosf1 : sincosf0
        return (x * sincosf0[q & 3], x * x, p, n)
    }

    static func sinf(_ yf: Float) -> Float {
        let y = Double(yf)
        let xi = Float(y).bitPattern
        let top = xi & 0x7FF0_0000
        if top < 0x3F40_0000 {
            if top < 0x3980_0000 { return yf }
            return sinfPoly(y, y * y, sincosf0, 0)
        }
        if top >= 0x7F80_0000 { return (yf - yf) / (yf - yf) }
        let (x, x2, p, n) = sincosfReduce(y, xi)
        return sinfPoly(x, x2, p, n)
    }

    static func cosf(_ yf: Float) -> Float {
        let y = Double(yf)
        let xi = yf.bitPattern
        let top = xi & 0x7FF0_0000
        if top < 0x3F40_0000 {
            if top < 0x3980_0000 { return 1 }
            return sinfPoly(y, y * y, sincosf0, 1)
        }
        if top >= 0x7F80_0000 { return (yf - yf) / (yf - yf) }
        let (x, x2, p, n) = sincosfReduce(y, xi)
        return sinfPoly(x, x2, p, n ^ 1)
    }

    // MARK: sin, cos (double)

    private static func sinKernel(_ x: Double, _ xx: Double) -> Double {
        let S = sinS
        let z = x * x
        let v = z * x
        var r = fma(z, S[5], -S[4])
        r = fma(r, z, S[3])
        r = fma(r, z, -S[2])
        r = fma(r, z, S[1])
        if xx == 0 { return fma(fma(r, z, -S[0]), v, x) }
        var t = fma(-r, v, xx * 0.5)
        t = fma(t, z, -xx)
        return x - fma(-v, -S[0], t)
    }

    private static func cosKernel(_ x: Double, _ xx: Double) -> Double {
        let C = cosC
        let z = x * x
        let r = fma(-z, 0.5, 1)
        var p = fma(-z, C[5], C[4])
        p = fma(p, z, -C[3])
        p = fma(p, z, C[2])
        p = fma(p, z, -C[1])
        p = fma(p, z, C[0])
        var t = fma(-z, 0.5, 1 - r)
        t = fma(-x, xx, t)
        return fma(p, z * z, t) + r
    }

    /// pi/4 <= x < 5e5: (r, rr, n & 3) with x = n*pi/2 + r + rr.
    private static func reducePiBy2(_ x: Double, _ ax: UInt64) -> (Double, Double, Int) {
        var n: Int
        if ax <= 0x400F_6A7A_2955_385E {
            n = ax > 0x4002_D97C_7F33_21D2 ? 2 : 1
        } else if ax <= 0x401C_463A_BECC_B2BB {
            n = ax > 0x4015_FDBB_E9BB_A775 ? 4 : 3
        } else {
            n = Int(fma(x, d(0x3FE4_5F30_6DC9_C883), 0.5))
        }
        let dn = Double(n)
        var r = fma(-dn, d(0x3FF9_21FB_5440_0000), x)
        var rt = dn * d(0x3DD0_B461_1A62_6331)
        let expdiff = (ax >> 52) &- ((r.bitPattern >> 52) & 0x7FF)
        if expdiff > 15 {
            var t = r
            r = fma(-dn, d(0x3DD0_B461_1A60_0000), t)
            rt = fma(dn, d(0x3BA3_198A_2E03_7073), -fma(-dn, d(0x3DD0_B461_1A60_0000), t - r))
            if expdiff > 48 {
                t = r
                r = fma(-dn, d(0x3BA3_198A_2E00_0000), t)
                rt = fma(dn, d(0x397B_839A_2520_49C1), -fma(-dn, d(0x3BA3_198A_2E00_0000), t - r))
            }
        }
        let r2 = r - rt
        return (r2, (r - r2) - rt, n & 3)
    }

    /// __amd_remainder_piby2: x >= 5e5, finite.
    private static func remainderPiBy2(_ x: Double) -> (Double, Double, Int) {
        var ux = x.bitPattern
        let xexp = Int((ux >> 52) & 0x7FF) - 1023
        ux = (ux & 0xF_FFFF_FFFF_FFFF) | 0x10_0000_0000_0000
        let first = xexp / 10                                   // xexp >= 18 here, so floor == truncation
        let resexp = xexp - first * 10
        let last = first + 18
        var res = [UInt64](repeating: 0, count: 20)
        var carry: UInt64 = 0
        for k in stride(from: 18, through: 0, by: -1) {
            let u = piBits[last - (18 - k)] &* ux &+ carry
            res[k] = u & 0x3FF
            carry = u >> 10
        }
        let ltb = (((res[0] << 10) | res[1]) >> UInt64(9 - resexp)) & 7
        let determ = ltb & 1 != 0
        var i = 1
        let lowmask: UInt64 = (1 << UInt64(10 - resexp)) - 1
        var region: Int, mant: UInt64, high: UInt64
        if determ {
            region = Int((ltb >> 1) + 1) & 3
            mant = ~res[1] & lowmask
            while mant < 0x20_0000_0000_0000 {
                i += 1
                mant = (mant << 10) | (~res[i] & 0x3FF)
            }
            high = ~res[i + 1] << 54
        } else {
            region = Int(ltb >> 1)
            mant = res[1] & lowmask
            while mant < 0x20_0000_0000_0000 {
                i += 1
                mant = (mant << 10) | res[i]
            }
            high = res[i + 1] << 54
        }
        var rexp = 52 + resexp - i * 10
        while mant >= 0x20_0000_0000_0000 {
            rexp += 1
            high = (high >> 1) | ((mant & 1) << 63)
            mant >>= 1
        }
        var bits = ((UInt64(bitPattern: Int64(rexp + 1023)) << 52) & 0xFFF0_0000_0000_0000) | (mant & 0xF_FFFF_FFFF_FFFF)
        if determ { bits |= 0x8000_0000_0000_0000 }
        let xr = d(bits)
        let tb = (UInt64(bitPattern: Int64(rexp)) << 52) &+ 0x3CA0_0000_0000_0000
        var xx = d(tb | (high >> 12)) - d(tb)
        xx = determ ? xx * -2 : xx + xx
        let lead = d(0x3FF9_21FB_5444_2D18), p1 = d(0x3FF9_21FB_5000_0000)
        let p2 = d(0x3E51_10B4_6000_0000), p3 = d(0x3C91_A626_3314_5C06)
        let hx = d(bits & 0xFFFF_FFFF_F800_0000)
        let tx = xr - hx
        let c = xr * lead
        var cc = fma(hx, p1, -c)
        cc = fma(tx, p1, cc)
        cc = fma(hx, p2, cc)
        cc = fma(tx, p2, cc)
        cc = cc + fma(xr, p3, xx * lead)
        let r = cc + c
        return (r, (c - r) + cc, region)
    }

    private static let amdInfArg = d(0xFFF8_0000_0000_0000)

    static func cos(_ x: Double) -> Double {
        let ax = x.bitPattern & 0x7FFF_FFFF_FFFF_FFFF
        if ax <= 0x3FE9_21FB_5444_2D18 {
            if ax < 0x3F20_0000_0000_0000 { return ax < 0x3E40_0000_0000_0000 ? 1 : fma(-(x * x), 0.5, 1) }
            return cosKernel(x, 0)
        }
        if ax >= 0x7FF0_0000_0000_0000 { return ax > 0x7FF0_0000_0000_0000 ? amdNaN(x) : amdInfArg }
        let x = abs(x)
        let (r, rr, region) = x >= 5e5 ? remainderPiBy2(x) : reducePiBy2(x, ax)
        switch region {
        case 0: return cosKernel(r, rr)
        case 1: return -sinKernel(r, rr)
        case 2: return -cosKernel(r, rr)
        default: return sinKernel(r, rr)
        }
    }

    static func sin(_ x: Double) -> Double {
        let ax = x.bitPattern & 0x7FFF_FFFF_FFFF_FFFF
        if ax <= 0x3FE9_21FB_5444_2D18 {
            if ax < 0x3F20_0000_0000_0000 { return ax < 0x3E40_0000_0000_0000 ? x : fma(-(x * x * x), sinS[0], x) }
            return sinKernel(x, 0)
        }
        if ax >= 0x7FF0_0000_0000_0000 { return ax > 0x7FF0_0000_0000_0000 ? amdNaN(x) : amdInfArg }
        let neg = x < 0
        let x = abs(x)
        let (r, rr, region) = x >= 5e5 ? remainderPiBy2(x) : reducePiBy2(x, ax)
        let v: Double
        switch region {
        case 0: v = sinKernel(r, rr)
        case 1: v = cosKernel(r, rr)
        case 2: v = -sinKernel(r, rr)
        default: v = -cosKernel(r, rr)
        }
        return neg ? -v : v
    }

    // MARK: pow (double)

    private static func powCheckint(_ iy: UInt64) -> Int {
        let e = Int((iy >> 52) & 0x7FF)
        if e < 0x3FF { return 0 }
        if e > 0x3FF + 52 { return 2 }
        if iy & ((1 << UInt64(0x3FF + 52 - e)) - 1) != 0 { return 0 }
        if iy & (1 << UInt64(0x3FF + 52 - e)) != 0 { return 1 }
        return 2
    }

    private static func powSpecialcase(_ tmp: Double, _ sbits0: UInt64, _ ki: UInt64) -> Double {
        if ki & 0x8000_0000 == 0 {
            let scale = d(sbits0 &- (1009 << 52))
            return fma(scale, tmp, scale) * d(0x7F00_0000_0000_0000)
        }
        let sbits = sbits0 &+ (1022 << 52)
        let scale = d(sbits)
        var y = fma(scale, tmp, scale)
        if abs(y) < 1 {
            let one: Double = y < 0 ? -1 : 1
            var lo = fma(scale, tmp, scale - y)
            let hi = one + y
            lo = lo + ((one - hi) + y)
            y = (lo + hi) - one
            if y == 0 { y = d(sbits & 0x8000_0000_0000_0000) }
        }
        return y * d(0x0010_0000_0000_0000)
    }

    static func pow(_ x: Double, _ y: Double) -> Double {
        var ix = x.bitPattern
        let iy = y.bitPattern
        var topx = ix >> 52
        let topy = iy >> 52
        var signBias: UInt64 = 0
        if UInt32(truncatingIfNeeded: topx &- 1) >= 0x7FE || UInt32(truncatingIfNeeded: (topy & 0x7FF) &- 0x3BE) >= 0x80 {
            if 2 &* iy &- 1 >= 0xFFDF_FFFF_FFFF_FFFF {                     // y is 0, inf or nan
                if 2 &* iy == 0 { return (ix ^ 0x0008_0000_0000_0000) &* 2 > 0xFFF0_0000_0000_0000 ? x + y : 1 }
                if ix == 0x3FF0_0000_0000_0000 {
                    return (iy ^ 0x0008_0000_0000_0000) &* 2 > 0xFFF0_0000_0000_0000 ? x + y : 1
                }
                if 2 &* ix > 0xFFE0_0000_0000_0000 || 2 &* iy > 0xFFE0_0000_0000_0000 { return x + y }
                if 2 &* ix == 0x7FE0_0000_0000_0000 { return 1 }
                if (2 &* ix < 0x7FE0_0000_0000_0000) == (iy >> 63 == 0) { return 0 }
                return y * y
            }
            if 2 &* ix &- 1 >= 0xFFDF_FFFF_FFFF_FFFF {                     // x is 0, inf or nan
                var x2 = x * x
                if ix >> 63 != 0 && powCheckint(iy) == 1 {
                    x2 = -x2
                    signBias = 1
                }
                if 2 &* ix == 0 && iy >> 63 != 0 { return signBias != 0 ? -.infinity : .infinity }
                return iy >> 63 != 0 ? 1 / x2 : x2
            }
            if ix >> 63 != 0 {
                let yint = powCheckint(iy)
                if yint == 0 { return .nan }
                if yint == 1 { signBias = 0x800 << 8 }
                ix &= 0x7FFF_FFFF_FFFF_FFFF
                topx &= 0x7FF
            }
            if UInt32(truncatingIfNeeded: (topy & 0x7FF) &- 0x3BE) >= 0x80 {
                if ix == 0x3FF0_0000_0000_0000 { return 1 }
                if (topy & 0x7FF) < 0x3BE { return ix > 0x3FF0_0000_0000_0000 ? 1 + y : 1 - y }
                return (ix > 0x3FF0_0000_0000_0000) == (topy < 0x800) ? .infinity : 0
            }
            if topx == 0 {
                ix = (d(ix) * 0x1p52).bitPattern & 0x7FFF_FFFF_FFFF_FFFF
                ix &-= 52 << 52
            }
        }
        // log_inline
        let tmp = ix &- 0x3FE6_9555_0000_0000
        let i = Int((tmp >> 45) & 127)
        let k = Int64(bitPattern: tmp) >> 52
        let z = d(ix &- (tmp & 0xFFF0_0000_0000_0000))
        let kd = Double(k)
        let invc = powLogTab[3 * i], logc = powLogTab[3 * i + 1], logctail = powLogTab[3 * i + 2]
        let ln2hi = powLogHdr[0], ln2lo = powLogHdr[1]
        let A = Array(powLogHdr[2...])
        let r = fma(z, invc, -1)
        let t1 = fma(kd, ln2hi, logc)
        let t2 = t1 + r
        let lo1 = fma(kd, ln2lo, logctail)
        let lo2 = t1 - t2 + r
        let ar = A[0] * r
        let ar2 = r * ar
        let ar3 = r * ar2
        let hi = t2 + ar2
        let lo3 = fma(ar, r, -ar2)
        let lo4 = t2 - hi + ar2
        let q = fma(fma(fma(A[6], r, A[5]), ar2, fma(A[4], r, A[3])), ar2, fma(A[2], r, A[1]))
        let lo = fma(q, ar3, ((lo1 + lo2) + lo3) + lo4)
        let lhi = lo + hi
        let ltail = hi - lhi + lo
        let ehi = y * lhi
        let elo = fma(ltail, y, fma(y, lhi, -ehi))
        // exp_inline
        var abstop = Int((ehi.bitPattern >> 52) & 0x7FF)
        if !(0 <= abstop - 0x3C9 && abstop - 0x3C9 < 0x3F) {
            if abstop < 0x3C9 {
                let one = 1 + ehi
                return signBias != 0 ? -one : one
            }
            if abstop >= 0x409 {
                if ehi.sign == .minus { return signBias != 0 ? -0.0 : 0.0 }
                return signBias != 0 ? -.infinity : .infinity
            }
            abstop = 0
        }
        let invln2n = powExpHdr[0], nl2hi = powExpHdr[2], nl2lo = powExpHdr[3]
        let C2 = powExpHdr[4], C3 = powExpHdr[5], C4 = powExpHdr[6], C5 = powExpHdr[7]
        let kd2 = rinta(invln2n * ehi)
        let ki = UInt64(bitPattern: Int64(kd2))
        let rr = fma(kd2, nl2lo, fma(kd2, nl2hi, ehi)) + elo
        let idx = Int(ki & 255) * 2
        let tail = d(powExpTab[idx])
        let sbits = powExpTab[idx + 1] &+ ((ki &+ signBias) << 44)
        let r2 = rr * rr
        let t = fma(fma(C5, rr, C4), r2 * r2, fma(fma(C3, rr, C2), r2, tail + rr))
        if abstop == 0 { return powSpecialcase(t, sbits, ki & 0xFFFF_FFFF) }
        let scale = d(sbits)
        return fma(t, scale, scale)
    }
}
