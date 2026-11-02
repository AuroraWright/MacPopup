import Foundation

// libyuv::ScalePlane (8-bit, one channel), bit for bit: the code paths reachable for positive sizes, with the
// arithmetic of libyuv's C row kernels (which its NEON kernels match).

enum FilterMode: Int {
    case none = 0, linear = 1, bilinear = 2, box = 3
}

private typealias Src = UnsafePointer<UInt8>
private typealias Dst = UnsafeMutablePointer<UInt8>

@inline(__always) private func wrap(_ v: Int) -> Int { Int(Int32(truncatingIfNeeded: v)) }
@inline(__always) private func fixedDiv(_ num: Int, _ div: Int) -> Int { Int(Int32(truncatingIfNeeded: (num << 16) / div)) }
@inline(__always) private func fixedDiv1(_ num: Int, _ div: Int) -> Int {
    Int(Int32(truncatingIfNeeded: ((num << 16) - 0x0001_0001) / (div - 1)))
}
@inline(__always) private func centerStart(_ d: Int) -> Int { d >= 0 ? (d >> 1) - 0x8000 : 0x8000 - ((-d) >> 1) }
@inline(__always) private func min1(_ v: Int) -> Int { v < 1 ? 1 : v }

private func filterReduce(_ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int, _ filter: FilterMode) -> FilterMode {
    var f = filter
    if f == .box && (dw * 2 >= sw || dh * 2 >= sh) { f = .bilinear }
    if f == .bilinear {
        if sh == 1 { f = .linear }
        if dh == sh || dh * 3 == sh { f = .linear }
        if sw == 1 { f = .none }
    }
    if f == .linear {
        if sw == 1 { f = .none }
        if dw == sw || dw * 3 == sw { f = .none }
    }
    return f
}

private func scaleSlope(_ sw: Int, _ sh: Int, _ dw0: Int, _ dh0: Int, _ f: FilterMode) -> (x: Int, y: Int, dx: Int, dy: Int) {
    var dw = dw0, dh = dh0
    if dw == 1 && sw >= 32768 { dw = sw }
    if dh == 1 && sh >= 32768 { dh = sh }
    var x = 0, y = 0, dx = 0, dy = 0
    switch f {
    case .box:
        dx = fixedDiv(sw, dw)
        dy = fixedDiv(sh, dh)
    case .bilinear, .linear:
        if dw <= sw {
            dx = fixedDiv(sw, dw)
            x = centerStart(dx)
        } else if sw > 1 && dw > 1 {
            dx = fixedDiv1(sw, dw)
        }
        if f == .linear {
            dy = fixedDiv(sh, dh)
            y = dy >> 1
        } else if dh <= sh {
            dy = fixedDiv(sh, dh)
            y = centerStart(dy)
        } else if sh > 1 && dh > 1 {
            dy = fixedDiv1(sh, dh)
        }
    case .none:
        dx = fixedDiv(sw, dw)
        dy = fixedDiv(sh, dh)
        x = dx >= 0 ? dx >> 1 : -((-dx) >> 1)
        y = dy >= 0 ? dy >> 1 : -((-dy) >> 1)
    }
    return (x, y, dx, dy)
}

// MARK: - Row kernels

/// InterpolateRow_C: f in [0, 255] is the weight of r1. The sums fit in 16 bits.
private func interpolateRow(_ dst: Dst, _ r0: Src, _ r1: Src, _ w: Int, _ f: Int) {
    if f == 0 {
        dst.update(from: r0, count: w)
    } else if f == 128 {
        for i in 0..<w { dst[i] = UInt8(truncatingIfNeeded: (UInt16(r0[i]) &+ UInt16(r1[i]) &+ 1) >> 1) }
    } else {
        let f0 = UInt16(256 - f), f1 = UInt16(f)
        for i in 0..<w {
            dst[i] = UInt8(truncatingIfNeeded: (UInt16(r0[i]) &* f0 &+ UInt16(r1[i]) &* f1 &+ 128) >> 8)
        }
    }
}

/// ScaleFilterCols_C's columns: for each output pixel, the source pixel and the weight of the one after it.
private struct FilterColumns {
    var index: [Int32], fraction: [Int32]

    init(_ dw: Int, _ x: Int, _ dx: Int) {
        index = [Int32](repeating: 0, count: dw)
        fraction = [Int32](repeating: 0, count: dw)
        var xx = x
        for j in 0..<dw {
            index[j] = Int32(truncatingIfNeeded: xx >> 16)
            fraction[j] = Int32(truncatingIfNeeded: xx & 0xFFFF)
            xx += dx
        }
    }

    /// ScaleFilterCols_C; `row` holds w + 1 readable bytes (the last pixel duplicated).
    func filter(_ dst: Dst, _ row: Src) {
        index.withUnsafeBufferPointer { ix in
            fraction.withUnsafeBufferPointer { fr in
                for j in 0..<ix.count {
                    let xi = Int(ix[j])
                    let a = Int32(row[xi]), b = Int32(row[xi + 1])
                    dst[j] = UInt8(truncatingIfNeeded: a &+ (((b &- a) &* fr[j] &+ 0x8000) >> 16))
                }
            }
        }
    }
}

private struct Plane {
    let p: Src
    let stride: Int, w: Int, h: Int
    func row(_ y: Int) -> Src { p + y * stride }
}

/// A source row with its last pixel duplicated (for filterCols).
private func paddedRow(_ r: Src, _ w: Int, _ buf: inout [UInt8]) -> [UInt8] {
    buf.removeAll(keepingCapacity: true)
    buf.append(contentsOf: UnsafeBufferPointer(start: r, count: w))
    buf.append(r[w - 1])
    return buf
}

// MARK: - Plane scalers

private func vertical(_ s: Plane, _ dst: Dst, _ ds: Int, _ dh: Int, _ y0: Int, _ dy: Int, _ f: FilterMode) {
    var y = y0
    let maxY = s.h > 1 ? (s.h << 16) - 0x10000 - (f == .bilinear ? 1 : 0) : 0
    for j in 0..<dh {
        if y >= maxY { y = maxY }
        let yi = y >> 16
        let yf = f == .bilinear ? (y >> 8) & 255 : 0
        let r1 = yf != 0 && yi + 1 < s.h ? s.row(yi + 1) : s.row(yi)
        interpolateRow(dst + j * ds, s.row(yi), r1, s.w, yf)
        y = wrap(y + dy)
    }
}

private func down2(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int, _ f: FilterMode) {
    for j in 0..<dh {
        let d = dst + j * ds
        let a = s.row(2 * j), b = s.row(2 * j + 1)
        switch f {
        case .none:
            for i in 0..<dw { d[i] = b[2 * i + 1] }
        case .linear:
            for i in 0..<dw { d[i] = UInt8(truncatingIfNeeded: (UInt16(a[2 * i]) &+ UInt16(a[2 * i + 1]) &+ 1) >> 1) }
        default:
            for i in 0..<dw {
                let sum = UInt16(a[2 * i]) &+ UInt16(a[2 * i + 1]) &+ UInt16(b[2 * i]) &+ UInt16(b[2 * i + 1]) &+ 2
                d[i] = UInt8(truncatingIfNeeded: sum >> 2)
            }
        }
    }
}

private func down4(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int, _ f: FilterMode) {
    for j in 0..<dh {
        let d = dst + j * ds
        for i in 0..<dw {
            if f == .none {
                d[i] = s.row(4 * j + 2)[4 * i + 2]
            } else {
                var sum = 0
                for r in 0..<4 {
                    for c in 0..<4 { sum += Int(s.row(4 * j + r)[4 * i + c]) }
                }
                d[i] = UInt8((sum + 8) >> 4)
            }
        }
    }
}

private func down34(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int, _ f: FilterMode) {
    let strideF = f == .linear ? 0 : 1
    let n = dw / 3
    var ha = [Int](repeating: 0, count: dw), hb = [Int](repeating: 0, count: dw)
    func hrow(_ r: Src, _ o: inout [Int]) {
        for k in 0..<n {
            let q0 = Int(r[4 * k]), q1 = Int(r[4 * k + 1]), q2 = Int(r[4 * k + 2]), q3 = Int(r[4 * k + 3])
            o[3 * k] = (q0 * 3 + q1 + 2) >> 2
            o[3 * k + 1] = (q1 + q2 + 1) >> 1
            o[3 * k + 2] = (q2 + q3 * 3 + 2) >> 2
        }
    }
    func pick(_ d: Dst, _ r: Int) {
        let row = s.row(r)
        for k in 0..<n {
            d[3 * k] = row[4 * k]
            d[3 * k + 1] = row[4 * k + 1]
            d[3 * k + 2] = row[4 * k + 3]
        }
    }
    func k0(_ d: Dst, _ r: Int, _ off: Int) {
        if f == .none { return pick(d, r) }
        hrow(s.row(r), &ha)
        hrow(s.row(r + off * strideF), &hb)
        for i in 0..<3 * n { d[i] = UInt8((ha[i] * 3 + hb[i] + 2) >> 2) }
    }
    func k1(_ d: Dst, _ r: Int, _ off: Int) {
        if f == .none { return pick(d, r) }
        hrow(s.row(r), &ha)
        hrow(s.row(r + off * strideF), &hb)
        for i in 0..<3 * n { d[i] = UInt8((ha[i] + hb[i] + 1) >> 1) }
    }
    func out(_ j: Int) -> Dst { dst + j * ds }
    var r = 0, j = 0
    while j < dh - 2 {
        k0(out(j), r, 1)
        k1(out(j + 1), r + 1, 1)
        k0(out(j + 2), r + 3, -1)
        r += 4
        j += 3
    }
    if dh % 3 == 1 {
        k0(out(j), r, 0)
    } else if dh % 3 == 2 {
        k0(out(j), r, 1)
        k1(out(j + 1), r + 1, 0)
    }
}

private func down38(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int, _ f: FilterMode) {
    let strideF = f == .linear ? 0 : 1
    let n = dw / 3
    var q = [Int](repeating: 0, count: 8 * n)
    func pick(_ d: Dst, _ r: Int) {
        let row = s.row(r)
        for k in 0..<n {
            d[3 * k] = row[8 * k]
            d[3 * k + 1] = row[8 * k + 3]
            d[3 * k + 2] = row[8 * k + 6]
        }
    }
    func k3(_ d: Dst, _ r: Int, _ use: Int) {
        if f == .none { return pick(d, r) }
        for i in q.indices { q[i] = 0 }
        for rr in [r, r + use * strideF, r + 2 * use * strideF] {
            let row = s.row(rr)
            for i in 0..<8 * n { q[i] += Int(row[i]) }
        }
        for k in 0..<n {
            let p = 8 * k
            d[3 * k] = UInt8(truncatingIfNeeded: ((q[p] + q[p + 1] + q[p + 2]) * (65536 / 9)) >> 16)
            d[3 * k + 1] = UInt8(truncatingIfNeeded: ((q[p + 3] + q[p + 4] + q[p + 5]) * (65536 / 9)) >> 16)
            d[3 * k + 2] = UInt8(truncatingIfNeeded: ((q[p + 6] + q[p + 7]) * (65536 / 6)) >> 16)
        }
    }
    func k2(_ d: Dst, _ r: Int, _ use: Int) {
        if f == .none { return pick(d, r) }
        let a = s.row(r), b = s.row(r + use * strideF)
        for i in 0..<8 * n { q[i] = Int(a[i]) + Int(b[i]) }
        for k in 0..<n {
            let p = 8 * k
            d[3 * k] = UInt8(truncatingIfNeeded: ((q[p] + q[p + 1] + q[p + 2]) * (65536 / 6)) >> 16)
            d[3 * k + 1] = UInt8(truncatingIfNeeded: ((q[p + 3] + q[p + 4] + q[p + 5]) * (65536 / 6)) >> 16)
            d[3 * k + 2] = UInt8(truncatingIfNeeded: (q[p + 6] + q[p + 7]) >> 2)
        }
    }
    func out(_ j: Int) -> Dst { dst + j * ds }
    var r = 0, j = 0
    while j < dh - 2 {
        k3(out(j), r, 1)
        k3(out(j + 1), r + 3, 1)
        k2(out(j + 2), r + 6, 1)
        r += 8
        j += 3
    }
    if dh % 3 == 1 {
        k3(out(j), r, 0)
    } else if dh % 3 == 2 {
        k3(out(j), r, 1)
        k3(out(j + 1), r + 3, 0)
    }
}

private func box(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int) {
    let slope = scaleSlope(s.w, s.h, dw, dh, .box)
    let x = slope.x, dx = slope.dx, dy = slope.dy
    var y = slope.y
    let maxY = s.h << 16
    let row = UnsafeMutablePointer<UInt16>.allocate(capacity: s.w)
    defer { row.deallocate() }
    let minbox = dx >> 16
    for j in 0..<dh {
        let iy = y >> 16
        y = wrap(y + dy)
        if y >= maxY { y = maxY }
        let bh = max(1, (y >> 16) - iy)
        row.update(repeating: 0, count: s.w)
        for k in 0..<bh {  // ScaleAddRow accumulates in 16 bits
            let r = s.row(iy + k)
            for i in 0..<s.w { row[i] = row[i] &+ UInt16(r[i]) }
        }
        let d = dst + j * ds
        if dx == 0x10000 {  // ScaleAddCols0_C
            let sv = UInt32(65536 / bh)
            let x0 = x >> 16
            for i in 0..<dw { d[i] = UInt8(truncatingIfNeeded: (UInt32(row[x0 + i]) &* sv) >> 16) }
        } else if dx & 0xFFFF == 0 {  // ScaleAddCols1_C
            let bw = min1(minbox)
            let sv = UInt32(65536 / (bw * bh))
            var xi = x >> 16
            for i in 0..<dw {
                var sum: UInt32 = 0
                for k in 0..<bw { sum &+= UInt32(row[xi + k]) }
                d[i] = UInt8(truncatingIfNeeded: (sum &* sv) >> 16)
                xi += bw
            }
        } else {  // ScaleAddCols2_C
            let sv0 = UInt32(65536 / (min1(minbox) * bh)), sv1 = UInt32(65536 / (min1(minbox + 1) * bh))
            let narrow = max(minbox, 0)
            var xx = x
            for i in 0..<dw {
                let ix = xx >> 16
                xx += dx
                let bw = min1((xx >> 16) - ix)
                var sum: UInt32 = 0
                for k in 0..<bw { sum &+= UInt32(row[ix + k]) }
                d[i] = UInt8(truncatingIfNeeded: (sum &* (bw == narrow ? sv0 : sv1)) >> 16)
            }
        }
    }
}

private func bilinearDown(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int, _ f: FilterMode) {
    let slope = scaleSlope(s.w, s.h, dw, dh, f)
    let x = slope.x, dx = slope.dx, dy = slope.dy
    var y = slope.y
    let maxY = (s.h << 16) - 0x10000
    if y > maxY { y = maxY }
    let columns = FilterColumns(dw, x, dx)
    let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: s.w + 1)
    defer { tmp.deallocate() }
    for j in 0..<dh {
        let yi = y >> 16
        if f == .linear {
            tmp.update(from: s.row(yi), count: s.w)
        } else {
            let yf = (y >> 8) & 255
            let r1 = yf != 0 && yi + 1 < s.h ? s.row(yi + 1) : s.row(yi)
            interpolateRow(tmp, s.row(yi), r1, s.w, yf)
        }
        tmp[s.w] = tmp[s.w - 1]
        columns.filter(dst + j * ds, tmp)
        y = wrap(y + dy)
        if y >= maxY { y = maxY }
    }
}

private func bilinearUp(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int, _ f: FilterMode) {
    let slope = scaleSlope(s.w, s.h, dw, dh, f)
    let x = slope.x, dx = slope.dx, dy = slope.dy
    var y = slope.y
    let maxY = (s.h << 16) - 0x10000
    if y > maxY { y = maxY }
    var yi = y >> 16
    // libyuv's two-row ring buffer, including the source pointer that stops advancing
    var sp = yi
    var bufs = [[UInt8](repeating: 0, count: dw), [UInt8](repeating: 0, count: dw)]
    let columns = FilterColumns(dw, x, dx)
    var pad: [UInt8] = []
    func fill(_ k: Int, _ r: Int) {
        let p = paddedRow(s.row(r), s.w, &pad)
        p.withUnsafeBufferPointer { src in
            bufs[k].withUnsafeMutableBufferPointer { columns.filter($0.baseAddress!, src.baseAddress!) }
        }
    }
    fill(0, sp)
    if s.h > 1 { sp += 1 }
    fill(1, sp)
    if s.h > 2 { sp += 1 }
    var cur = 0, lasty = yi
    for j in 0..<dh {
        if y > maxY { y = maxY }
        yi = y >> 16
        if yi != lasty {
            fill(cur, sp)
            cur ^= 1
            if y + 0x10000 < maxY { sp += 1 }
            lasty = yi
        }
        let d = dst + j * ds
        bufs[cur].withUnsafeBufferPointer { a in
            if f == .linear {
                d.update(from: a.baseAddress!, count: dw)
            } else {
                bufs[cur ^ 1].withUnsafeBufferPointer { b in
                    interpolateRow(d, a.baseAddress!, b.baseAddress!, dw, (y >> 8) & 255)
                }
            }
        }
        y = wrap(y + dy)
    }
}

private func up2LinearRow(_ out: Dst, _ r: Src, _ dw: Int) {
    out[0] = r[0]
    let work = (dw - 1) & ~1
    for k in 0..<work / 2 {
        let a = Int(r[k]), b = Int(r[k + 1])
        out[1 + 2 * k] = UInt8((a * 3 + b + 2) >> 2)
        out[2 + 2 * k] = UInt8((a + b * 3 + 2) >> 2)
    }
    out[dw - 1] = r[(dw - 1) / 2]
}

private func up2Linear(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int) {
    if dh == 1 { return up2LinearRow(dst, s.row((s.h - 1) / 2), dw) }
    let dy = fixedDiv(s.h - 1, dh - 1)
    var y = 0x7FFF
    for j in 0..<dh {
        up2LinearRow(dst + j * ds, s.row(y >> 16), dw)
        y = wrap(y + dy)
    }
}

/// ScaleRowUp2_Bilinear_Any: two output rows from source rows a (upper) and b (lower).
private func up2BilinearRows(_ da: Dst, _ db: Dst?, _ a: Src, _ b: Src, _ dw: Int) {
    da[0] = UInt8((3 * Int(a[0]) + Int(b[0]) + 2) >> 2)
    if let db { db[0] = UInt8((Int(a[0]) + 3 * Int(b[0]) + 2) >> 2) }
    let work = (dw - 1) & ~1
    for k in 0..<work / 2 {
        let s0 = Int(a[k]), s1 = Int(a[k + 1]), t0 = Int(b[k]), t1 = Int(b[k + 1])
        da[1 + 2 * k] = UInt8((s0 * 9 + s1 * 3 + t0 * 3 + t1 + 8) >> 4)
        da[2 + 2 * k] = UInt8((s0 * 3 + s1 * 9 + t0 + t1 * 3 + 8) >> 4)
        if let db {
            db[1 + 2 * k] = UInt8((s0 * 3 + s1 + t0 * 9 + t1 * 3 + 8) >> 4)
            db[2 + 2 * k] = UInt8((s0 + s1 * 3 + t0 * 3 + t1 * 9 + 8) >> 4)
        }
    }
    let k = (dw - 1) / 2
    da[dw - 1] = UInt8((3 * Int(a[k]) + Int(b[k]) + 2) >> 2)
    if let db { db[dw - 1] = UInt8((Int(a[k]) + 3 * Int(b[k]) + 2) >> 2) }
}

private func up2Bilinear(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int) {
    func out(_ j: Int) -> Dst { dst + j * ds }
    up2BilinearRows(out(0), nil, s.row(0), s.row(0), dw)
    var o = 1
    for i in 1..<max(s.h, 1) {
        up2BilinearRows(out(o), out(o + 1), s.row(i - 1), s.row(i), dw)
        o += 2
    }
    if dh & 1 == 0 { up2BilinearRows(out(o), nil, s.row(s.h - 1), s.row(s.h - 1), dw) }
}

private func simple(_ s: Plane, _ dst: Dst, _ ds: Int, _ dw: Int, _ dh: Int) {
    let slope = scaleSlope(s.w, s.h, dw, dh, .none)
    let x = slope.x, dx = slope.dx, dy = slope.dy
    var y = slope.y
    for j in 0..<dh {
        let row = s.row(y >> 16)
        let d = dst + j * ds
        if dx < 0x8000 && 2 * s.w == dw {  // ScaleColsUp2_C
            for i in 0..<dw { d[i] = row[i >> 1] }
        } else {
            var xx = x
            for i in 0..<dw {
                d[i] = row[xx >> 16]
                xx += dx
            }
        }
        y = wrap(y + dy)
    }
}

/// Scales a sw x sh plane (rows `srcStride` bytes apart) into dst (rows `dstStride` bytes apart).
func scalePlane(_ src: UnsafePointer<UInt8>, srcStride: Int, _ sw: Int, _ sh: Int, _ dst: UnsafeMutablePointer<UInt8>,
                dstStride: Int, _ dw: Int, _ dh: Int, _ filtering: FilterMode) {
    let s = Plane(p: src, stride: srcStride, w: sw, h: sh)
    let f = filterReduce(sw, sh, dw, dh, filtering)
    if dw == sw && dh == sh {
        for j in 0..<dh { (dst + j * dstStride).update(from: s.row(j), count: sw) }
        return
    }
    if dw == sw && f != .box {
        var y = 0, dy = 0
        if dh <= sh {
            dy = fixedDiv(sh, dh)
            y = centerStart(dy)
        } else if sh > 1 && f != .none {
            dy = fixedDiv1(sh, dh)
        } else if sh > 1 {
            dy = fixedDiv(sh, dh)
            y = dy >= 0 ? dy >> 1 : -((-dy) >> 1)
        }
        return vertical(s, dst, dstStride, dh, y, dy, f)
    }
    if dw <= sw && dh <= sh {
        if 4 * dw == 3 * sw && 4 * dh == 3 * sh { return down34(s, dst, dstStride, dw, dh, f) }
        if 2 * dw == sw && 2 * dh == sh { return down2(s, dst, dstStride, dw, dh, f) }
        if 8 * dw == 3 * sw && 8 * dh == 3 * sh { return down38(s, dst, dstStride, dw, dh, f) }
        if 4 * dw == sw && 4 * dh == sh && (f == .box || f == .none) { return down4(s, dst, dstStride, dw, dh, f) }
    }
    if f == .box && 2 * dh < sh { return box(s, dst, dstStride, dw, dh) }
    if f == .linear && (dw + 1) / 2 == sw { return up2Linear(s, dst, dstStride, dw, dh) }
    if (f == .bilinear || f == .box) && (dh + 1) / 2 == sh && (dw + 1) / 2 == sw {
        return up2Bilinear(s, dst, dstStride, dw, dh)
    }
    if f != .none && dh > sh { return bilinearUp(s, dst, dstStride, dw, dh, f) }
    if f != .none { return bilinearDown(s, dst, dstStride, dw, dh, f) }
    simple(s, dst, dstStride, dw, dh)
}

extension GrayImage {
    /// The whole image scaled to w x h.
    func scaled(to w: Int, _ h: Int, _ filter: FilterMode) -> GrayImage {
        var out = GrayImage(width: w, height: h)
        data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                scalePlane(src.baseAddress!, srcStride: width, width, height, dst.baseAddress!, dstStride: w, w, h, filter)
            }
        }
        return out
    }
}
