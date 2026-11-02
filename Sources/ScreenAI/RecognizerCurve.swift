import Foundation

// Curved text lines (LINE polygons that are a goodoc.CurvedBoundingBox):
//   ocr::photo::ImageUtil::ImageCropCurvedPatch (box_util::CurvedBoxCentersAndAngles + ApplyThinPlateSplineWarp: a
//   thin-plate-spline solve, then the ThinPlateSplineInterpolation / BilinearInterpolationFloat /
//   BilinearInterpolationU8 Halide pipelines) straightens the line into the recognizer's line image, and
//   aksara::box_utils::BoundingBoxCoordinateMapper (InitFromMidLineCurve, MapToSourceCoordinates) maps boxes found in
//   that image back onto the page (BoxRelativeToPageRelativeVec, curved branch).

private struct Correspondence {
    /// line image (normalized, later sample grid) coordinates
    var tx: Float, ty: Float
    /// page coordinates
    var sx: Float, sy: Float
}

/// box_util::CurvedBoxCentersAndAngles: n + 1 (center, normal angle) triples: the first point, the midpoints of the
/// segments and the last point, each with the angle of its segment turned to point "down" across the line.
private func centersAndAngles(_ p: [(x: Double, y: Double)]) -> [Float]? {
    let n = p.count
    if n < 2 { return nil }
    var out: [Float] = []
    func push(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ j: Int) {
        let ang = atan2(p[j].x - p[j - 1].x, p[j - 1].y - p[j].y)
        out.append(Float((a.x + b.x) * 0.5))
        out.append(Float((a.y + b.y) * 0.5))
        out.append(Float(ang))
    }
    push(p[0], p[0], 1)
    for i in 1...n {
        let j = min(i, n - 1)
        push(p[i - 1], p[j], j)
    }
    return out
}

/// Halide's float log (range reduction to [0.75, 1.5) + odd/even polynomial), times r2: the TPS kernel r2 log r2.
private func tpsKernel(_ r2: Float) -> Float {
    let c0 = Float(bitPattern: 0x3D9C7946), c2 = Float(bitPattern: 0x3E5333C6), c4 = Float(bitPattern: 0x3EAA99CD)
    let c1 = Float(bitPattern: 0xBE266E2A), c3 = Float(bitPattern: 0xBE809085), c5 = Float(bitPattern: 0xBEFFFCBE)
    let ln2 = Float(bitPattern: 0x3F317218)
    if !(r2 > 0) { return 0 }
    let bits = Int32(bitPattern: r2.bitPattern)
    let m = bits & Int32(bitPattern: 0x807F_FFFF)
    let t = m >> 22
    let rb = m - (t << 23) + 0x3F80_0000
    let x1 = Float(bitPattern: UInt32(bitPattern: rb)) + -1
    let e = Float((bits >> 23) + t + -127)
    let x2 = x1 * x1
    let odd = x1 * (x2 * (x2 * (x2 * c0 + c2) + c4) + 1)
    let even = x2 * (x2 * (x2 * c1 + c3) + c5)
    return r2 * (e * ln2 + (even + odd))
}

/// BilinearInterpolationFloatHalide: samples (pixel centers at +0.5, edges clamped), along y first.
private func sampleF(_ src: [Float], _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
    let px = x + -0.5, py = y + -0.5
    let fx = floorf(px), fy = floorf(py)
    let ix = Int(fx), iy = Int(fy)
    let x0 = max(min(ix, w - 1), 0), x1 = max(min(ix + 2, w) - 1, 0)
    let y0 = max(min(iy, h - 1), 0), y1 = max(min(iy + 2, h) - 1, 0)
    let wx = px - fx, wy = py - fy
    let a = src[y0 * w + x0] * (1 - wy) + wy * src[y1 * w + x0]
    let b = (1 - wy) * src[y0 * w + x1] + wy * src[y1 * w + x1]
    return (1 - wx) * a + wx * b
}

private func div255(_ v: Int) -> Int { (v + ((v + 128) >> 8) + 128) >> 8 }

/// BilinearInterpolationU8Halide: 8-bit weights, exact /255 rounding, along y first.
private func sampleU8(_ img: GrayImage, _ x: Float, _ y: Float) -> UInt8 {
    let px = x + -0.5, py = y + -0.5
    let fx = floorf(px), fy = floorf(py)
    let ix = Int(fx), iy = Int(fy)
    let wx = Int((px - fx) * 255), wy = Int((py - fy) * 255)
    let w = img.width, h = img.height
    let x0 = max(min(ix, w - 1), 0), x1 = max(min(ix + 2, w) - 1, 0)
    let y0 = max(min(iy, h - 1), 0), y1 = max(min(iy + 2, h) - 1, 0)
    func at(_ xx: Int, _ yy: Int) -> Int { Int(img.data[yy * w + xx]) }
    let c0 = div255(at(x0, y0) * (255 - wy) + at(x0, y1) * wy)
    let c1 = div255(at(x1, y0) * (255 - wy) + at(x1, y1) * wy)
    return UInt8(div255(c0 * (255 - wx) + c1 * wx))
}

/// Line image of a curved line: (int)(center-line length + 1.5) x (int)thickness pixels. Empty when the original
/// fails (degenerate curve, or less than 3 pixels thick).
func curvedLineImage(_ page: GrayImage, _ curve: Curve, floatThickness: Bool = true) -> GrayImage {
    guard page.width > 0, page.height > 0, let ca = centersAndAngles(curve.points) else { return GrayImage() }
    // A goodoc polygon's thickness reaches the ocr::photo::CurvedBoundingBox as (double)(float); the detector's own
    // box (pyramid crops) keeps the double.
    let thickF = Float(curve.thickness)
    let thick = floatThickness ? Double(thickF) : curve.thickness
    var corr: [Correspondence] = []
    var len: Float = 0
    for i in stride(from: 0, to: ca.count, by: 3) {
        let cx = ca[i], cy = ca[i + 1]
        let sc = sinCos(ca[i + 2])
        if i > 0 { len = len + hypotf(cx - ca[i - 3], cy - ca[i - 2]) }
        let half = thick * 0.5
        let dx = Float(half * Double(sc.cos)), dy = Float(half * Double(sc.sin))
        corr.append(Correspondence(tx: len, ty: 0, sx: cx - dx, sy: cy - dy))
        corr.append(Correspondence(tx: len, ty: thickF, sx: cx + dx, sy: cy + dy))
    }
    let W = Int(len + 1.5), H = Int(thickF)
    if W < 1 || H < 1 { return GrayImage() }
    // ApplyThinPlateSplineWarp: the spline lives on a (W/4 + 2) x (H/4 + 2) grid (plus a one-sample border).
    let sw = W / 4 + 2, sh = H / 4 + 2
    if sw > W || sh > H { return GrayImage() }
    for k in corr.indices {
        corr[k].tx = corr[k].tx / Float(W) * Float(sw) + 1
        corr[k].ty = corr[k].ty / Float(H) * Float(sh) + 1
    }
    // ComputeSplineCoefficients: [K P; P^T 0] [w; a] = [src; 0], K_ij = r2 log r2.
    let n = corr.count, N = n + 3
    var A = [Float](repeating: 0, count: N * N)  // column-major
    var coef = [Float](repeating: 0, count: N * 2)
    for i in 0..<n {
        for j in 0..<n where i != j {
            let dx = corr[i].tx - corr[j].tx, dy = corr[i].ty - corr[j].ty
            let r2 = dx * dx + dy * dy
            if r2 > 0 { A[j * N + i] = r2 * logf(r2) }
        }
        A[i * N + n] = 1
        A[n * N + i] = 1
        A[i * N + n + 1] = corr[i].tx
        A[(n + 1) * N + i] = corr[i].tx
        A[i * N + n + 2] = corr[i].ty
        A[(n + 2) * N + i] = corr[i].ty
        coef[i] = corr[i].sx
        coef[N + i] = corr[i].sy
    }
    luSolve(&A, N, &coef, 2)
    func c(_ i: Int, _ ch: Int) -> Float { coef[ch * N + i] }

    // ThinPlateSplineInterpolationHalide: page coordinates at the grid samples (centers at +0.5).
    let gw = sw + 2, gh = sh + 2
    var grid0 = [Float](repeating: 0, count: gw * gh), grid1 = grid0
    var acc0 = [Float](repeating: 0, count: gw), acc1 = acc0
    for gy in 0..<gh {
        let y = Float(gy) + 0.5
        for gx in 0..<gw {
            acc0[gx] = 0
            acc1[gx] = 0
        }
        for i in 0..<n {
            let dy = corr[i].ty - y
            let dy2 = dy * dy
            let w0 = c(i, 0), w1 = c(i, 1)
            for gx in 0..<gw {
                let dx = corr[i].tx - (Float(gx) + 0.5)
                let u = tpsKernel(dx * dx + dy2)
                acc0[gx] = acc0[gx] + w0 * u
                acc1[gx] = acc1[gx] + w1 * u
            }
        }
        let ya0 = y * c(n + 2, 0), ya1 = y * c(n + 2, 1)
        for gx in 0..<gw {
            let x = Float(gx) + 0.5
            grid0[gy * gw + gx] = ((acc0[gx] + c(n, 0)) + x * c(n + 1, 0)) + ya0
            grid1[gy * gw + gx] = ((acc1[gx] + c(n, 1)) + x * c(n + 1, 1)) + ya1
        }
    }

    // Each output pixel: its grid position, the interpolated page position there, the page pixel at that position.
    let fx = Float(sw) / Float(W), fy = Float(sh) / Float(H)
    var out = GrayImage(width: W, height: H)
    for v in 0..<H {
        let gy = fy * (Float(v) + 0.5) + 1
        for u in 0..<W {
            let gx = fx * (Float(u) + 0.5) + 1
            let px = sampleF(grid0, gw, gh, gx, gy)
            let py = sampleF(grid1, gw, gh, gx, gy)
            out.data[v * W + u] = sampleU8(page, px, py)
        }
    }
    return out
}

/// Line-image -> page coordinates along the mid-line curve, one sample per pixel of arc length.
struct CurveMapper {
    /// samples along the curve, thickness
    private var along = 0, across = 0
    private var topToBottom = false
    private var mid: [(x: Double, y: Double)] = []
    private var dxDown: [Double] = [], dyDown: [Double] = []
    private var firstCos = 0.0, firstSin = 0.0, lastCos = 0.0, lastSin = 0.0

    init(_ curve: Curve) {
        let p = curve.points
        topToBottom = curve.topToBottom ?? false
        let n = p.count
        if n < 2 { return }  // never mapped: the original leaves the mapper without samples
        let offset = 0.0  // BoundingBoxCoordinateMapper(Box<double>, 0)
        var ang: [Double] = []
        for i in 0..<(n - 1) { ang.append(atan2(p[i + 1].y - p[i].y, p[i + 1].x - p[i].x)) }
        let f = sinCos(ang.first!), l = sinCos(ang.last!)
        firstCos = f.cos
        firstSin = f.sin
        lastCos = l.cos
        lastSin = l.sin
        // GetAverageAngle: linear blend, taking the short way around.
        func average(_ a2In: Double, _ a3In: Double, _ t: Double) -> Double {
            var a2 = a2In, a3 = a3In
            if abs(a3 - a2) > .pi {
                if a2 >= a3 { a3 += 2 * .pi } else { a2 += 2 * .pi }
            }
            return (1.0 - t) * a3 + t * a2
        }
        let last = ang.count - 1
        var cum = 0.0
        var k = 0
        for i in 0..<(n - 1) {
            let sx = p[i + 1].x - p[i].x, sy = p[i + 1].y - p[i].y
            let seg = (sx * sx + sy * sy).squareRoot()
            let prev = cum
            cum = cum + seg
            if !(cum > Double(k)) { continue }
            let bx = p[i].x + offset * (sx / seg), by = p[i].y + offset * (sy / seg)
            repeat {
                let t = (Double(k) - prev) / seg
                let a = t >= 0.5
                    ? average(i != last ? ang[i + 1] : ang[i], ang[i], t + -0.5)
                    : average(ang[i], i != 0 ? ang[i - 1] : ang[i], t + 0.5)
                let sc = sinCos(a + .pi / 2)
                dxDown.append(sc.cos)
                dyDown.append(sc.sin)
                mid.append((bx + sx * t + sc.cos * offset, by + sy * t + offset * sc.sin))
                k += 1
            } while cum > Double(k)
        }
        along = k
        across = Int(curve.thickness)
    }

    func mapToSource(_ x: Int, _ y: Int) -> (x: Double, y: Double) {
        if along < 1 || across < 1 { return (0, 0) }
        let a = topToBottom ? y : x
        let acrossPos = topToBottom ? across + ~x : y
        let d = Double(acrossPos) + Double(UInt32(truncatingIfNeeded: across)) * -0.5
        if a < 0 {
            return ((mid[0].x + firstCos * Double(a)) + d * dxDown[0], (mid[0].y + firstSin * Double(a)) + d * dyDown[0])
        }
        if a >= along {
            let e = Double(UInt32(truncatingIfNeeded: a - along + 1))
            return ((mid.last!.x + lastCos * e) + d * dxDown.last!, (mid.last!.y + lastSin * e) + d * dyDown.last!)
        }
        return (mid[a].x + d * dxDown[a], mid[a].y + d * dyDown[a])
    }
}

/// BoxRelativeToPageRelativeVec for a curved line: the box's top-left and (rotated) top-right corners are mapped;
/// the size is kept, the angle follows the mapped top edge.
func curveToPage(_ mapper: CurveMapper, _ rel: RotatedBox) -> RotatedBox {
    // aksara::box_utils::Point::Rotate of the top-right corner about the top-left one.
    let ox = Double(rel.left), oy = Double(rel.top)
    let dx = Double(rel.left + rel.width) - ox, dy = oy - oy
    let sc = sinCos(Double(rel.angle) * .pi / 180.0)
    let rx = ox + (sc.cos * dx - sc.sin * dy), ry = oy + (sc.sin * dx + sc.cos * dy)
    let p0 = mapper.mapToSource(Int(ox), Int(oy))
    let p1 = mapper.mapToSource(Int(rx), Int(ry))
    var out = rel
    out.left = Int(p0.x)
    out.top = Int(p0.y)
    out.angle = Float(atan2(p1.y - p0.y, p1.x - p0.x) * 57.29577951308232)
    return out
}
