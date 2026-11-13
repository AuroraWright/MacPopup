import Accelerate
import Foundation

/// An interleaved 8-bit image (rows of width × channels bytes), BGR when it has 3 channels.
struct ImageU8 {
    var width: Int
    var height: Int
    var channels: Int
    var data: [UInt8]

    /// The image's key in a LineCache, with what else the cached result depends on.
    func cacheKey<Value>(_ extra: String = "") -> LineCache<Value>.Key {
        data.withUnsafeBytes { LineCache<Value>.Key($0, "\(width) \(height) \(channels) \(extra)") }
    }

    init(width: Int, height: Int, channels: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    init(width: Int, height: Int, channels: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, channels: channels,
                  data: [UInt8](repeating: fill, count: width * height * channels))
    }

    /// The rectangle (x, y, w, h), which must lie inside the image.
    func crop(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> ImageU8 {
        var out = ImageU8(width: w, height: h, channels: channels)
        let rowBytes = w * channels
        for r in 0..<h {
            let s = ((y + r) * width + x) * channels
            out.data.replaceSubrange(r * rowBytes..<(r + 1) * rowBytes, with: data[s..<s + rowBytes])
        }
        return out
    }

    /// cv::rotate(ROTATE_180).
    func rotated180() -> ImageU8 {
        var out = self
        let n = width * height
        for i in 0..<n {
            for c in 0..<channels { out.data[i * channels + c] = data[(n - 1 - i) * channels + c] }
        }
        return out
    }
}

/// An interleaved float image.
struct ImageF32 {
    var width: Int
    var height: Int
    var channels: Int
    var data: [Float]

    init(width: Int, height: Int, channels: Int, data: [Float]) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    init(width: Int, height: Int, channels: Int) {
        self.init(width: width, height: height, channels: channels,
                  data: [Float](repeating: 0, count: width * height * channels))
    }

    init(_ u: ImageU8) {
        var data = [Float](repeating: 0, count: u.data.count)
        u.data.withUnsafeBufferPointer { s in
            data.withUnsafeMutableBufferPointer { d in vDSP_vfltu8(s.baseAddress!, 1, d.baseAddress!, 1, vDSP_Length(s.count)) }
        }
        self.init(width: u.width, height: u.height, channels: u.channels, data: data)
    }
}

/// body over 0..<count, split into ranges run on all cores when there are more than `work` values in all (each of the
/// count items has `size` values); otherwise in one go.
func forEachRange(_ count: Int, size: Int, work: Int = 1 << 16, _ body: (Range<Int>) -> Void) {
    let parts = count * size > work ? min(count, ProcessInfo.processInfo.activeProcessorCount * 2) : 1
    if parts <= 1 {
        body(0..<count)
        return
    }
    DispatchQueue.concurrentPerform(iterations: parts) { part in body(count * part / parts..<count * (part + 1) / parts) }
}

/// Python's floor division and modulo (rounding toward -inf).
@inline(__always) func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

@inline(__always) func floorMod(_ a: Int, _ b: Int) -> Int { a - floorDiv(a, b) * b }

/// np.rint for doubles that fit an Int.
@inline(__always) func rintInt(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

// The OpenCV 4.10 routines inside oneocr.dll, as its scalar build computes them (no SIMD, no FMA contraction), so
// the results match bit for bit.
enum CV {
    // MARK: resize

    /// cv::resize's INTER_LINEAR coordinate table: fx = (float)((d + 0.5) * scale - 0.5); x clamps at both borders.
    private static func linearCoeffs(_ ssize: Int, _ dsize: Int, clamp: Bool) -> (sx: [Int], a0: [Float], a1: [Float]) {
        let scale = 1.0 / (Double(dsize) / Double(ssize))
        var sx = [Int](repeating: 0, count: dsize), a0 = [Float](repeating: 0, count: dsize)
        var a1 = [Float](repeating: 0, count: dsize)
        for d in 0..<dsize {
            var fx = Float((Double(d) + 0.5) * scale - 0.5)
            var s = Int(fx.rounded(.down))
            fx = fx - Float(s)
            if clamp {
                if s < 0 {
                    fx = 0
                    s = 0
                }
                if s >= ssize - 1 {
                    fx = 0
                    s = ssize - 1
                }
            }
            sx[d] = s
            a0[d] = 1 - fx
            a1[d] = fx
        }
        return (sx, a0, a1)
    }

    /// cv::resize(INTER_LINEAR) of a float image, unfused: (src[x0] a0 + src[x1] a1) per row, then the same down. Only
    /// the source rows used are resized across.
    static func resizeLinear(_ src: ImageF32, _ width: Int, _ height: Int) -> ImageF32 {
        let (x0, a0, a1) = linearCoeffs(src.width, width, clamp: true)
        let (y0, b0, b1) = linearCoeffs(src.height, height, clamp: true)
        let c = src.channels, w = src.width, h = src.height, length = width * c
        // Per value of a row: the offsets of its two source values in their row, and their weights.
        var offsets0 = [Int](repeating: 0, count: length), offsets1 = [Int](repeating: 0, count: length)
        var weights0 = [Float](repeating: 0, count: length), weights1 = [Float](repeating: 0, count: length)
        for x in 0..<width {
            for k in 0..<c {
                offsets0[x * c + k] = x0[x] * c + k
                offsets1[x * c + k] = min(x0[x] + 1, w - 1) * c + k
                weights0[x * c + k] = a0[x]
                weights1[x * c + k] = a1[x]
            }
        }
        var used = [Bool](repeating: false, count: h)
        for y in 0..<height {
            used[y0[y]] = true
            used[min(y0[y] + 1, h - 1)] = true
        }
        var rows = [Float](repeating: 0, count: h * length)
        var out = ImageF32(width: width, height: height, channels: c)
        src.data.withUnsafeBufferPointer { s in
            rows.withUnsafeMutableBufferPointer { r in
                let (s, r) = (s.baseAddress!, r.baseAddress!)
                offsets0.withUnsafeBufferPointer { o0 in offsets1.withUnsafeBufferPointer { o1 in
                    weights0.withUnsafeBufferPointer { w0 in weights1.withUnsafeBufferPointer { w1 in
                        forEachRange(h, size: length) { ys in
                            for y in ys where used[y] {
                                let line = s + y * w * c, row = r + y * length
                                for i in 0..<length { row[i] = line[o0[i]] * w0[i] + line[o1[i]] * w1[i] }
                            }
                        }
                    } }
                } }
                out.data.withUnsafeMutableBufferPointer { o in
                    let o = o.baseAddress!
                    forEachRange(height, size: length) { ys in
                        for y in ys {
                            let row0 = r + y0[y] * length, row1 = r + min(y0[y] + 1, h - 1) * length, row = o + y * length
                            let (wt0, wt1) = (b0[y], b1[y])
                            for i in 0..<length { row[i] = row0[i] * wt0 + row1[i] * wt1 }
                        }
                    }
                }
            }
        }
        return out
    }

    /// cv::resize(INTER_LINEAR) of an 8-bit image: 11-bit fixed-point weights (HResizeLinear / VResizeLinear with
    /// FixedPtCast<int, uchar, 22>). An exact 2× reduction is INTER_AREA's (a + b + c + d + 2) >> 2.
    static func resizeLinear(_ src: ImageU8, _ width: Int, _ height: Int) -> ImageU8 {
        let w = src.width, h = src.height, c = src.channels
        if w == width && h == height { return src }
        if w == 2 * width && h == 2 * height {
            var out = ImageU8(width: width, height: height, channels: c)
            for y in 0..<height {
                for x in 0..<width {
                    for k in 0..<c {
                        let s0 = ((2 * y) * w + 2 * x) * c + k, s1 = ((2 * y + 1) * w + 2 * x) * c + k
                        let sum = Int(src.data[s0]) + Int(src.data[s0 + c]) + Int(src.data[s1]) + Int(src.data[s1 + c])
                        out.data[(y * width + x) * c + k] = UInt8((sum + 2) >> 2)
                    }
                }
            }
            return out
        }
        let (sx, a0, a1) = linearCoeffs(w, width, clamp: true)
        let (sy, b0, b1) = linearCoeffs(h, height, clamp: false)
        let ia0 = a0.map { rintInt(Double($0 * 2048)) }, ia1 = a1.map { rintInt(Double($0 * 2048)) }
        let ib0 = b0.map { rintInt(Double($0 * 2048)) }, ib1 = b1.map { rintInt(Double($0 * 2048)) }
        var rows = [Int](repeating: 0, count: h * width * c)
        src.data.withUnsafeBufferPointer { s in
            for y in 0..<h {
                for x in 0..<width {
                    let p0 = (y * w + sx[x]) * c, p1 = (y * w + min(sx[x] + 1, w - 1)) * c
                    for k in 0..<c { rows[(y * width + x) * c + k] = Int(s[p0 + k]) * ia0[x] + Int(s[p1 + k]) * ia1[x] }
                }
            }
        }
        var out = ImageU8(width: width, height: height, channels: c)
        for y in 0..<height {
            let r0 = min(max(sy[y], 0), h - 1) * width * c, r1 = min(max(sy[y] + 1, 0), h - 1) * width * c
            for i in 0..<(width * c) {
                let v = rows[r0 + i] * ib0[y] + rows[r1 + i] * ib1[y]
                out.data[y * width * c + i] = UInt8(min(max((v + (1 << 21)) >> 22, 0), 255))
            }
        }
        return out
    }

    /// computeResizeAreaTab: per destination index its (source index, weight) list.
    private static func areaTab(_ ssize: Int, _ dsize: Int, _ scale: Double) -> [[(Int, Float)]] {
        var tab = [[(Int, Float)]](repeating: [], count: dsize)
        for dx in 0..<dsize {
            let fsx1 = Double(dx) * scale
            let fsx2 = fsx1 + scale
            let cell = min(scale, Double(ssize) - fsx1)
            var sx1 = Int(fsx1.rounded(.up)), sx2 = Int(fsx2.rounded(.down))
            sx2 = min(sx2, ssize - 1)
            sx1 = min(sx1, sx2)
            if Double(sx1) - fsx1 > 1e-3 { tab[dx].append((sx1 - 1, Float((Double(sx1) - fsx1) / cell))) }
            if sx1 < sx2 {
                for sx in sx1..<sx2 { tab[dx].append((sx, Float(1.0 / cell))) }
            }
            if fsx2 - Double(sx2) > 1e-3 { tab[dx].append((sx2, Float(min(min(fsx2 - Double(sx2), 1.0), cell) / cell))) }
        }
        return tab
    }

    /// cv::resize(INTER_AREA) of a float image when both scales are >= 1.
    static func resizeArea(_ src: ImageF32, _ width: Int, _ height: Int) -> ImageF32 {
        let w = src.width, h = src.height, c = src.channels
        let sx = 1.0 / (Double(width) / Double(w)), sy = 1.0 / (Double(height) / Double(h))
        let isx = rintInt(sx), isy = rintInt(sy)
        if abs(sx - Double(isx)) < Double.ulpOfOne && abs(sy - Double(isy)) < Double.ulpOfOne {
            return resizeAreaFast(src, width, height, isx, isy)
        }
        // ResizeArea_Invoker: per source row, sums along x (S * alpha), then down (beta * buf), each product rounded
        let tx = areaTab(w, width, sx), ty = areaTab(h, height, sy)
        var rows = [Float](repeating: 0, count: h * width * c)
        for y in 0..<h {
            for x in 0..<width {
                for k in 0..<c {
                    var acc: Float = 0
                    for (j, (s, wt)) in tx[x].enumerated() {
                        let t = wt * src.data[(y * w + s) * c + k]
                        acc = j == 0 ? t : acc + t
                    }
                    rows[(y * width + x) * c + k] = acc
                }
            }
        }
        var out = ImageF32(width: width, height: height, channels: c)
        for y in 0..<height {
            for i in 0..<(width * c) {
                var acc: Float = 0
                for (j, (s, wt)) in ty[y].enumerated() {
                    let t = rows[s * width * c + i] * wt
                    acc = j == 0 ? t : acc + t
                }
                out.data[y * width * c + i] = acc
            }
        }
        return out
    }

    /// resizeAreaFast_<float>: the window summed row-major, four at a time (CV_ENABLE_UNROLLED), times 1/area.
    private static func resizeAreaFast(_ src: ImageF32, _ width: Int, _ height: Int, _ isx: Int, _ isy: Int) -> ImageF32 {
        let w = src.width, h = src.height, c = src.channels
        let area = isx * isy
        let scale = 1 / Float(area)
        var ofs: [Int] = []
        for y in 0..<isy {
            for x in 0..<isx { ofs.append((y * w + x) * c) }
        }
        let dwidth1 = (w / isx) * c
        var out = ImageF32(width: width, height: height, channels: c)
        for dy in 0..<height {
            let sy0 = dy * isy
            let base = sy0 * w * c
            let full = sy0 + isy <= h ? dwidth1 : 0
            for dx in 0..<(width * c) {
                let xofs = (dx / c) * isx * c + dx % c
                if dx < full {
                    var sum: Float = 0
                    var k = 0
                    while k <= area - 4 {
                        let s = src.data[base + xofs + ofs[k]] + src.data[base + xofs + ofs[k + 1]]
                            + src.data[base + xofs + ofs[k + 2]] + src.data[base + xofs + ofs[k + 3]]
                        sum += s
                        k += 4
                    }
                    while k < area {
                        sum += src.data[base + xofs + ofs[k]]
                        k += 1
                    }
                    out.data[dy * width * c + dx] = sum * scale
                } else {
                    // The partial windows at the right and bottom edges: the plain average of what's inside.
                    var sum: Float = 0
                    var count = 0
                    let sx0 = xofs
                    for yy in 0..<isy where sy0 + yy < h {
                        var sx = 0
                        while sx < isx * c && sx0 + sx < w * c {
                            sum += src.data[(sy0 + yy) * w * c + sx0 + sx]
                            count += 1
                            sx += c
                        }
                    }
                    out.data[dy * width * c + dx] = count > 0 ? sum / Float(count) : 0
                }
            }
        }
        return out
    }

    // MARK: affine transforms

    /// hal::LU64f with one right-hand side: partial pivoting, unfused.
    private static func luSolve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let m = b.count
        for i in 0..<m {
            var k = i
            for j in (i + 1)..<m where abs(a[j][i]) > abs(a[k][i]) { k = j }
            if abs(a[k][i]) < Double.ulpOfOne * 10 { return nil }
            if k != i {
                a.swapAt(i, k)
                b.swapAt(i, k)
            }
            let d = -1.0 / a[i][i]
            for j in (i + 1)..<m {
                let alpha = a[j][i] * d
                for c in (i + 1)..<m { a[j][c] = a[j][c] + alpha * a[i][c] }
                b[j] = b[j] + alpha * b[i]
            }
            a[i][i] = -d
        }
        for i in stride(from: m - 1, through: 0, by: -1) {
            var s = b[i]
            for c in (i + 1)..<m { s = s - a[i][c] * b[c] }
            b[i] = s * a[i][i]
        }
        return b
    }

    /// cv::getAffineTransform: 2×3, row-major.
    static func affineTransform(_ src: [Pt], _ dst: [Pt]) -> [Double] {
        var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        var b = [Double](repeating: 0, count: 6)
        for i in 0..<3 {
            let x = Double(src[i].x), y = Double(src[i].y)
            a[2 * i][0] = x
            a[2 * i][1] = y
            a[2 * i][2] = 1
            a[2 * i + 1][3] = x
            a[2 * i + 1][4] = y
            a[2 * i + 1][5] = 1
            b[2 * i] = Double(dst[i].x)
            b[2 * i + 1] = Double(dst[i].y)
        }
        return luSolve(a, b) ?? [Double](repeating: 0, count: 6)
    }

    /// WarpAffineInvoker: per destination pixel the source cell and the 1/32-pixel table index.
    private static func warpCoords(_ M: [Double], _ width: Int, _ height: Int) -> (sx: [Int], sy: [Int], tab: [Int]) {
        var m = M
        var D = m[0] * m[4] - m[1] * m[3]
        D = D != 0 ? 1.0 / D : 0
        let a11 = m[4] * D, a22 = m[0] * D
        m[0] = a11
        m[1] *= -D
        m[3] *= -D
        m[4] = a22
        let b1 = -m[0] * m[2] - m[1] * m[5]
        let b2 = -m[3] * m[2] - m[4] * m[5]
        m[2] = b1
        m[5] = b2
        let adelta = (0..<width).map { rintInt(m[0] * Double($0) * 1024) }
        let bdelta = (0..<width).map { rintInt(m[3] * Double($0) * 1024) }
        var sx = [Int](repeating: 0, count: width * height), sy = sx, tab = sx
        for y in 0..<height {
            let X0 = rintInt((m[1] * Double(y) + m[2]) * 1024) + 16
            let Y0 = rintInt((m[4] * Double(y) + m[5]) * 1024) + 16
            for x in 0..<width {
                let X = (X0 + adelta[x]) >> 5, Y = (Y0 + bdelta[x]) >> 5
                let i = y * width + x
                sx[i] = min(max(X >> 5, -32768), 32767)
                sy[i] = min(max(Y >> 5, -32768), 32767)
                tab[i] = (Y & 31) * 32 + (X & 31)
            }
        }
        return (sx, sy, tab)
    }

    /// The bilinear weights of the 1/32-pixel table, [iy * 32 + ix][4].
    private static let wtab: [[Float]] = {
        let t = (0..<32).map { Float($0) * Float(1.0 / 32) }
        let tab = t.map { [1 - $0, $0] }
        var w: [[Float]] = []
        for iy in 0..<32 {
            for ix in 0..<32 {
                w.append([tab[iy][0] * tab[ix][0], tab[iy][0] * tab[ix][1], tab[iy][1] * tab[ix][0], tab[iy][1] * tab[ix][1]])
            }
        }
        return w
    }()
    private static let wtabFlat: [Float] = wtab.flatMap { $0 }
    private static let wtabI: [Int32] = wtab.flatMap { $0.map { Int32(rintInt(Double($0) * 32768)) } }

    @inline(__always) private static func reflect101(_ p: Int, _ n: Int) -> Int {
        if n == 1 { return 0 }
        let q = floorMod(p, 2 * n - 2)
        return q >= n ? 2 * n - 2 - q : q
    }

    /// cv::warpAffine(INTER_LINEAR, BORDER_REFLECT_101) of a float image (remapBilinear, unfused, left to right).
    static func warpAffine(_ src: ImageF32, _ M: [Double], _ width: Int, _ height: Int) -> ImageF32 {
        let (sx, sy, tab) = warpCoords(M, width, height)
        let c = src.channels, sw = src.width, sh = src.height
        var out = ImageF32(width: width, height: height, channels: c)
        src.data.withUnsafeBufferPointer { s in
            wtabFlat.withUnsafeBufferPointer { wt in
                out.data.withUnsafeMutableBufferPointer { o in
                    for i in 0..<(width * height) {
                        let w = 4 * tab[i]
                        let w0 = wt[w], w1 = wt[w + 1], w2 = wt[w + 2], w3 = wt[w + 3]
                        let x0 = reflect101(sx[i], sw), x1 = reflect101(sx[i] + 1, sw)
                        let y0 = reflect101(sy[i], sh), y1 = reflect101(sy[i] + 1, sh)
                        let p00 = (y0 * sw + x0) * c, p01 = (y0 * sw + x1) * c
                        let p10 = (y1 * sw + x0) * c, p11 = (y1 * sw + x1) * c
                        for k in 0..<c {
                            var v = s[p00 + k] * w0
                            v = v + s[p01 + k] * w1
                            v = v + s[p10 + k] * w2
                            v = v + s[p11 + k] * w3
                            o[i * c + k] = v
                        }
                    }
                }
            }
        }
        return out
    }

    /// cv::warpAffine(INTER_LINEAR, BORDER_CONSTANT) of an 8-bit image: 15-bit fixed-point weights; neighbours
    /// outside the source take the border value.
    static func warpAffine(_ src: ImageU8, _ M: [Double], _ width: Int, _ height: Int, border: UInt8 = 255) -> ImageU8 {
        let (sx, sy, tab) = warpCoords(M, width, height)
        let c = src.channels, sw = src.width, sh = src.height
        var out = ImageU8(width: width, height: height, channels: c)
        let bv = Int32(border)
        src.data.withUnsafeBufferPointer { s in
            wtabI.withUnsafeBufferPointer { wt in
                out.data.withUnsafeMutableBufferPointer { o in
                    for i in 0..<(width * height) {
                        let x = sx[i], y = sy[i]
                        if x >= sw || x + 1 < 0 || y >= sh || y + 1 < 0 {
                            for k in 0..<c { o[i * c + k] = border }
                            continue
                        }
                        let w = 4 * tab[i]
                        let w0 = wt[w], w1 = wt[w + 1], w2 = wt[w + 2], w3 = wt[w + 3]
                        if x >= 0 && x + 1 < sw && y >= 0 && y + 1 < sh {
                            let p00 = (y * sw + x) * c, p10 = p00 + sw * c
                            for k in 0..<c {
                                let acc = Int32(s[p00 + k]) * w0 + Int32(s[p00 + c + k]) * w1
                                    + Int32(s[p10 + k]) * w2 + Int32(s[p10 + c + k]) * w3
                                o[i * c + k] = UInt8(min(max((acc + (1 << 14)) >> 15, 0), 255))
                            }
                        } else {
                            let in0 = x >= 0, in1 = x + 1 < sw, inY0 = y >= 0, inY1 = y + 1 < sh
                            for k in 0..<c {
                                let v00 = in0 && inY0 ? Int32(s[(y * sw + x) * c + k]) : bv
                                let v01 = in1 && inY0 ? Int32(s[(y * sw + x + 1) * c + k]) : bv
                                let v10 = in0 && inY1 ? Int32(s[((y + 1) * sw + x) * c + k]) : bv
                                let v11 = in1 && inY1 ? Int32(s[((y + 1) * sw + x + 1) * c + k]) : bv
                                let acc = v00 * w0 + v01 * w1 + v10 * w2 + v11 * w3
                                o[i * c + k] = UInt8(min(max((acc + (1 << 14)) >> 15, 0), 255))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// cv::invertAffineTransform of a CV_32F matrix (softfloat path): float32 determinant, D = 1/det in double,
    /// the 2×2 part f32(M * f32(D)), the translation in double.
    static func invertAffine32(_ m: [Float]) -> [Float] {
        let M = m.map { Double($0) }
        let det = Double(Float(Double(Float(M[0] * M[4])) - Double(Float(M[1] * M[3]))))
        let D = det == 0 ? 0.0 : 1.0 / det
        let fD = Double(Float(D))
        let a11 = Double(Float(M[4] * fD)), a22 = Double(Float(M[0] * fD))
        let a12 = Double(Float(-M[1] * fD)), a21 = Double(Float(-M[3] * fD))
        let b1 = -a11 * M[2] - a12 * M[5]
        let b2 = -a21 * M[2] - a22 * M[5]
        return [Float(a11), Float(a12), Float(b1), Float(a21), Float(a22), Float(b2)]
    }

    /// Mat::inv(DECOMP_LU) of a 2×2 double matrix (row-major).
    static func invert2x2(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2], e = m[3]
        let d = e * a - b * c
        if d == 0 { return [0, 0, 0, 0] }
        let r = 1.0 / d
        return [r * e, -b * r, -c * r, a * r]
    }

    // MARK: eigen

    private static func tridiagQRStep(_ diag: inout [Double], _ sub: inout [Double], _ start: Int, _ end: Int,
                                      _ q: inout [[Double]], _ n: Int) {
        let td = (diag[end - 1] - diag[end]) * 0.5
        let e = sub[end - 1]
        var mu = diag[end]
        if td == 0 {
            mu = mu - abs(e)
        } else {
            let a = abs(td), b = abs(e)
            let mx = max(a, b), mn = min(a, b)
            let h = mx == 0 ? 0.0 : (mn / mx * (mn / mx) + 1.0).squareRoot() * mx
            let e2 = e * e
            if e2 == 0 {
                mu = mu - e / ((td > 0 ? 1.0 : -1.0) + td) * (e / h)
            } else {
                mu = mu - e2 / ((td > 0 ? h : -h) + td)
            }
        }
        var x = diag[start] - mu
        var z = sub[start]
        for k in start..<end {
            var c: Double, s: Double
            if z == 0 {
                c = x >= 0 ? 1 : -1
                s = 0
            } else if x == 0 {
                c = 0
                s = z >= 0 ? -1 : 1
            } else if abs(x) <= abs(z) {
                let t = x / z
                var u = (t * t + 1).squareRoot()
                if z < 0 { u = -u }
                s = -1 / u
                c = -t * s
            } else {
                let t = z / x
                var u = (t * t + 1).squareRoot()
                if x < 0 { u = -u }
                c = 1 / u
                s = -t * c
            }
            let sk = sub[k], dk = diag[k], dk1 = diag[k + 1]
            let sdk = dk * s + sk * c
            let dkp1 = dk1 * c + sk * s
            diag[k] = (dk * c - sk * s) * c - (sk * c - dk1 * s) * s
            diag[k + 1] = c * dkp1 + s * sdk
            sub[k] = c * sdk - s * dkp1
            x = sub[k]
            if k > start { sub[k - 1] = sub[k - 1] * c - s * z }
            if k < end - 1 {
                z = -s * sub[k + 1]
                sub[k + 1] = sub[k + 1] * c
            }
            if c != 1 || -s != 0 {
                for i in 0..<n {
                    let xi = q[i][k], yi = q[i][k + 1]
                    q[i][k] = c * xi + yi * -s
                    q[i][k + 1] = c * yi - xi * -s
                }
            }
        }
    }

    /// cv::eigen of a symmetric 2×2 matrix (Eigen 3.3 SelfAdjointEigenSolver in oneocr's OpenCV): eigenvalues
    /// descending and the eigenvectors as rows, or nil when Eigen doesn't converge.
    static func eigenSym2(_ a00: Double, _ a10: Double, _ a11: Double) -> ([Double], [[Double]])? {
        var scale = 0.0
        for v in [a00, a10, 0.0, a11] where abs(v) > scale { scale = abs(v) }
        if scale == 0 { scale = 1 }
        var diag = [a00 / scale, a11 / scale]
        var sub = [a10 / scale]
        var q: [[Double]] = [[1, 0], [0, 1]]
        let n = 2
        var end = 1, start = 0, it = 0
        while end > 0 {
            for i in start..<end {
                if abs(sub[i]) <= (abs(diag[i + 1]) + abs(diag[i])) * 4.440892098500626e-16
                    || abs(sub[i]) <= 2.2250738585072014e-308 {
                    sub[i] = 0
                }
            }
            while end > 0 && sub[end - 1] == 0 { end -= 1 }
            if end <= 0 { break }
            it += 1
            if it > 30 * n { break }
            start = end - 1
            while start > 0 && sub[start - 1] != 0 { start -= 1 }
            tridiagQRStep(&diag, &sub, start, end, &q, n)
        }
        if it > 30 * n { return nil }
        if diag[1] < diag[0] {
            diag.swapAt(0, 1)
            for r in 0..<2 { q[r].swapAt(0, 1) }
        }
        return ([diag[1] * scale, diag[0] * scale], [[q[0][1], q[1][1]], [q[0][0], q[1][0]]])
    }

    // MARK: polygon tests

    /// cv::pointPolygonTest(measureDist = false): +1 inside, -1 outside, 0 on an edge.
    static func pointPolygonTest(_ contour: [Pt], _ px: Float, _ py: Float) -> Double {
        if contour.isEmpty { return -1 }
        let ptx = Double(px), pty = Double(py)
        var counter = 0
        var vx = Double(contour[contour.count - 1].x), vy = Double(contour[contour.count - 1].y)
        for p in contour {
            let v0x = vx, v0y = vy
            vx = Double(p.x)
            vy = Double(p.y)
            if (v0y <= pty && vy <= pty) || (v0y > pty && vy > pty) || (v0x < ptx && vx < ptx) {
                if pty == vy && (ptx == vx || (pty == v0y && ((v0x <= ptx && ptx <= vx) || (vx <= ptx && ptx <= v0x)))) {
                    return 0
                }
                continue
            }
            var dist = Double(Float(pty - v0y)) * Double(Float(vx - v0x)) - Double(Float(ptx - v0x)) * Double(Float(vy - v0y))
            if dist == 0 { return 0 }
            if vy < v0y { dist = -dist }
            if dist > 0 { counter += 1 }
        }
        return counter % 2 == 0 ? -1 : 1
    }

    // MARK: drawing

    /// The pixels of an 8-connected line (LineIterator, left to right), clipped to the image.
    private static func line(_ w: Int, _ h: Int, _ p1: (Int, Int), _ p2: (Int, Int), _ set: (Int, Int) -> Void) {
        var (x1, y1) = p1, (x2, y2) = p2
        if x1 < 0 || x1 >= w || x2 < 0 || x2 >= w || y1 < 0 || y1 >= h || y2 < 0 || y2 >= h {
            if !clipLine(w, h, &x1, &y1, &x2, &y2) { return }
        }
        var dx = x2 - x1, dy = y2 - y1
        var px = x1, py = y1
        var deltaX = 1, deltaY = 1
        if dx < 0 {
            dx = -dx
            dy = -dy
            px = x2
            py = y2
        }
        if dy < 0 {
            dy = -dy
            deltaY = -1
        }
        let vert = dy > dx
        if vert {
            swap(&dx, &dy)
            swap(&deltaX, &deltaY)
        }
        var err = dx - (dy + dy)
        let plusDelta = dx + dx, minusDelta = -(dy + dy)
        // The step along the major axis (minus), and the extra minor step when err < 0 (plus).
        let minusX = vert ? 0 : deltaX, minusY = vert ? deltaX : 0
        let plusX = vert ? deltaY : 0, plusY = vert ? 0 : deltaY
        for _ in 0...dx {
            set(px, py)
            let neg = err < 0
            err += minusDelta + (neg ? plusDelta : 0)
            px += minusX + (neg ? plusX : 0)
            py += minusY + (neg ? plusY : 0)
        }
    }

    /// cv::clipLine.
    private static func clipLine(_ w: Int, _ h: Int, _ x1: inout Int, _ y1: inout Int, _ x2: inout Int,
                                 _ y2: inout Int) -> Bool {
        let right = w - 1, bottom = h - 1
        if w <= 0 || h <= 0 { return false }
        func code(_ x: Int, _ y: Int) -> Int {
            (x < 0 ? 1 : 0) + (x > right ? 2 : 0) + (y < 0 ? 4 : 0) + (y > bottom ? 8 : 0)
        }
        var c1 = code(x1, y1), c2 = code(x2, y2)
        if c1 & c2 == 0 && c1 | c2 != 0 {
            if c1 & 12 != 0 {
                let a = c1 < 8 ? 0 : bottom
                x1 += Int(Double(a - y1) * Double(x2 - x1) / Double(y2 - y1))
                y1 = a
                c1 = (x1 < 0 ? 1 : 0) + (x1 > right ? 2 : 0)
            }
            if c2 & 12 != 0 {
                let a = c2 < 8 ? 0 : bottom
                x2 += Int(Double(a - y2) * Double(x2 - x1) / Double(y2 - y1))
                y2 = a
                c2 = (x2 < 0 ? 1 : 0) + (x2 > right ? 2 : 0)
            }
            if c1 & c2 == 0 && c1 | c2 != 0 {
                if c1 != 0 {
                    let a = c1 == 1 ? 0 : right
                    y1 += Int(Double(a - x1) * Double(y2 - y1) / Double(x2 - x1))
                    x1 = a
                    c1 = 0
                }
                if c2 != 0 {
                    let a = c2 == 1 ? 0 : right
                    y2 += Int(Double(a - x2) * Double(y2 - y1) / Double(x2 - x1))
                    x2 = a
                    c2 = 0
                }
            }
        }
        return c1 | c2 == 0
    }

    /// cv::fillConvexPoly with integer vertices, 8-connected (LINE_AA becomes 8 on float images), shift 0:
    /// the pixels it sets in a w × h image.
    static func fillConvexPoly(_ w: Int, _ h: Int, _ v: [(Int, Int)], _ set: (Int, Int) -> Void) {
        let npts = v.count
        let xyShift = 16, xyOne = 1 << 16
        let delta1 = xyOne >> 1, delta2 = xyOne >> 1
        var imin = 0
        var xmin = v[0].0, xmax = v[0].0, ymin = v[0].1, ymax = v[0].1
        var p0 = v[npts - 1]
        for i in 0..<npts {
            let p = v[i]
            if p.1 < ymin {
                ymin = p.1
                imin = i
            }
            ymax = max(ymax, p.1)
            xmax = max(xmax, p.0)
            xmin = min(xmin, p.0)
            line(w, h, p0, p, set)
            p0 = p
        }
        if npts < 3 || xmax < 0 || ymax < 0 || xmin >= w || ymin >= h { return }
        ymax = min(ymax, h - 1)
        var idx = [imin, imin], di = [1, npts - 1]
        var ex = [-xyOne, -xyOne], edx = [0, 0], ye = [ymin, ymin]
        var y = ymin
        var edges = npts
        repeat {
            for i in 0..<2 where y >= ye[i] {
                var idx0 = idx[i]
                var j = idx0 + di[i]
                if j >= npts { j -= npts }
                while true {                   // for (; edges-- > 0; )
                    let more = edges > 0
                    edges -= 1
                    if !more { break }
                    let ty = v[j].1
                    if ty > y {
                        let xs = v[idx0].0 << xyShift, xe = v[j].0 << xyShift
                        ye[i] = ty
                        edx[i] = ((xe - xs) * 2 + (ty - y)) / (2 * (ty - y))
                        ex[i] = xs
                        idx[i] = j
                        break
                    }
                    idx0 = j
                    j += di[i]
                    if j >= npts { j -= npts }
                }
            }
            if edges < 0 { break }
            if y >= 0 {
                let (l, r) = ex[0] > ex[1] ? (1, 0) : (0, 1)
                var xx1 = (ex[l] + delta1) >> xyShift, xx2 = (ex[r] + delta2) >> xyShift
                if xx2 >= 0 && xx1 < w {
                    if xx1 < 0 { xx1 = 0 }
                    if xx2 >= w { xx2 = w - 1 }
                    if xx1 <= xx2 {
                        for x in xx1...xx2 { set(x, y) }
                    }
                }
            }
            ex[0] += edx[0]
            ex[1] += edx[1]
            y += 1
        } while y <= ymax
    }

    // MARK: color, threshold

    /// cvtColor(BGR2GRAY) of an 8-bit image: 15-bit coefficients, rounded. swapRB: the image is RGB.
    static func bgrToGray(_ src: ImageU8, swapRB: Bool = false) -> [UInt8] {
        let bi = swapRB ? 2 : 0, ri = swapRB ? 0 : 2
        return (0..<(src.width * src.height)).map { i in
            let b: Int = Int(src.data[3 * i + bi]) * 3735
            let g: Int = Int(src.data[3 * i + 1]) * 19235
            let r: Int = Int(src.data[3 * i + ri]) * 9798
            return UInt8((b + g + r + (1 << 14)) >> 15)
        }
    }

    /// adaptiveThreshold(MEAN_C, THRESH_BINARY_INV): boxFilter(BORDER_REPLICATE) = cvRound(window sum / block²) in
    /// double, then src - mean <= -floor(delta) -> 255.
    static func adaptiveThresholdMeanInv(_ g: [UInt8], _ w: Int, _ h: Int, block: Int, delta: Double) -> [UInt8] {
        let r = block / 2
        let pw = w + 2 * r, ph = h + 2 * r
        var integral = [Int](repeating: 0, count: (pw + 1) * (ph + 1))
        for y in 0..<ph {
            let sy = min(max(y - r, 0), h - 1)
            var rowSum = 0
            for x in 0..<pw {
                let sx = min(max(x - r, 0), w - 1)
                rowSum += Int(g[sy * w + sx])
                integral[(y + 1) * (pw + 1) + x + 1] = integral[y * (pw + 1) + x + 1] + rowSum
            }
        }
        let inv = 1.0 / Double(block * block)
        let idelta = Int(delta.rounded(.down))
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let s = integral[(y + block) * (pw + 1) + x + block] - integral[y * (pw + 1) + x + block]
                    - integral[(y + block) * (pw + 1) + x] + integral[y * (pw + 1) + x]
                let mean = min(max(rintInt(Double(s) * inv), 0), 255)
                out[y * w + x] = Int(g[y * w + x]) - mean <= -idelta ? 255 : 0
            }
        }
        return out
    }
}
