import Foundation

// Text line extraction: the line's crop and quad, then the normalized 60-pixel-high line image (rotated straight
// for quads, warped triangle by triangle for curved polygons) with the mapping from line pixels back to the image.

enum Orientation { static let unknown = 0, normal = 1, flipped = 2 }
enum LineLayout { static let unknown = 0, horizontal = 1, vertical = 2 }

/// Maps line-image pixel coordinates (before any 180-degree flip) to original image coordinates.
struct LineMapper {
    struct Triangle {
        var dst: [Pt]
        var inv: [Float]  // 2×2 row-major
        var t: (Float, Float)
        var r1: (Int, Int)
        var r2: (Int, Int)
    }

    var origin: Pt
    var affine: [Float]?  // 2×3 row-major
    var triangles: [Triangle] = []

    func map(_ x: Double, _ y: Double) -> Pt {
        if let m = affine {
            let xf = Float(x), yf = Float(y)
            let px = (m[0] * xf + m[1] * yf) + m[2], py = (m[3] * xf + m[4] * yf) + m[5]
            let w = (0 * xf + 0 * yf) + Float(1)
            return Pt(px / w + origin.x, py / w + origin.y)
        }
        let tris = triangles
        var k = tris.count - 2
        for j in stride(from: 0, to: tris.count, by: 2) where Float(x) <= tris[j].dst[1].x {
            k = j
            break
        }
        let d = tris[k].dst
        let t: Triangle
        if d[1].x != d[0].x {
            let lim = (d[2].y - d[0].y) * (d[1].x - Float(x)) / (d[1].x - d[0].x)
            t = Float(y) <= lim ? tris[k] : tris[k + 1]
        } else {
            t = y <= 0 ? tris[k] : tris[k + 1]
        }
        let v0 = Float(x - Double(t.r2.0)) - t.t.0, v1 = Float(y - Double(t.r2.1)) - t.t.1
        let s0 = t.inv[0] * v0 + t.inv[1] * v1, s1 = t.inv[2] * v0 + t.inv[3] * v1
        return Pt((s0 + Float(t.r1.0)) + origin.x, (s1 + Float(t.r1.1)) + origin.y)
    }
}

final class TextLine {
    let polygon: [Pt]  // clamped to the image
    let isHorizontal: Bool
    let curved: Bool
    let ambiguous: Bool
    let rect: (x: Int, y: Int, w: Int, h: Int)
    let boundsFloor: (x0: Int, y0: Int, x1: Int, y1: Int)
    var quad: [Pt]
    var lineImage = ImageU8(width: 0, height: 0, channels: 3)
    var lineSize = (0, 0)
    var mapper = LineMapper(origin: Pt(0, 0))
    var sourceHeight = 0.0
    // set by the analyzer
    var ocrMode = OCRMode.auto
    var orientationAmbiguous = false
    var scriptUnknown = false
    var layoutAmbiguous = false
    var orientation = 0
    var category = 0
    var handwrittenProb = 0.0
    var isHandwritten = false
    var script = 0
    var layout = 1

    init(polygon: [Pt], isHorizontal: Bool, curved: Bool, ambiguous: Bool, rect: (Int, Int, Int, Int),
         boundsFloor: (Int, Int, Int, Int), quad: [Pt]) {
        self.polygon = polygon
        self.isHorizontal = isHorizontal
        self.curved = curved
        self.ambiguous = ambiguous
        self.rect = rect
        self.boundsFloor = boundsFloor
        self.quad = quad
    }
}

enum Normalizer {
    static let lineHeight = 60
    static let maxWidth = min(Int((1536.0 * 1536.0 + 768.0 * 768.0).squareRoot() * 7 * 30 + 1), 1_000_000)
    private static let deg2rad = Double(bitPattern: 0x3F91_DF46_A252_9D39)
    private static let rad2deg = Double(bitPattern: 0x404C_A5DC_1A63_C1F8)

    private static func bounds(_ p: [Pt]) -> (Int, Int, Int, Int) {
        var x0 = p[0].x, x1 = p[0].x, y0 = p[0].y, y1 = p[0].y
        for q in p.dropFirst() {
            x0 = min(x0, q.x)
            x1 = max(x1, q.x)
            y0 = min(y0, q.y)
            y1 = max(y1, q.y)
        }
        return (Int(x0.rounded(.down)), Int(x1.rounded(.up)), Int(y0.rounded(.down)), Int(y1.rounded(.up)))
    }

    /// The principal eigenvector of the points (PCA with the CRT pow and OpenCV's Eigen-backed cv::eigen).
    private static func pcaAxis(_ pts: [Pt]) -> (Double, Double) {
        let n = Double(pts.count)
        var sx = 0.0, sy = 0.0
        for p in pts {
            sx += Double(p.x)
            sy += Double(p.y)
        }
        let mx = sx / n, my = sy / n
        var cxx = 0.0, cxy = 0.0, cyy = 0.0
        for p in pts {
            let x = Double(p.x), y = Double(p.y)
            cxx = CRT.pow(x - mx, 2) + cxx
            cxy = (y - my) * (x - mx) + cxy
            cyy = CRT.pow(y - my, 2) + cyy
        }
        guard let (_, vecs) = CV.eigenSym2(cxx / n, cxy / n, cyy / n) else { return (0, 0) }
        return (vecs[0][0], vecs[0][1])
    }

    /// The quad of a curved polygon: its bounding box in the PCA-rotated frame.
    private static func pcaBox(_ pts: [Pt], _ left: Int, _ top: Int) -> [Pt] {
        let (ex, ey) = pcaAxis(pts)
        let theta = Float(-CRT.atan2(-ey, ex))
        let s = CRT.sinf(theta), c = CRT.cosf(theta)
        let ox = Float(left), oy = Float(top)
        var umin = Float.infinity, umax = -Float.infinity, vmin = Float.infinity, vmax = -Float.infinity
        for (i, p) in pts.enumerated() {
            let dx = p.x - ox, dy = p.y - oy
            let u = s * dy + dx * c, v = c * dy + (-s) * dx
            if i == 0 {
                (umin, umax, vmin, vmax) = (u, u, v, v)
            } else {
                umin = min(umin, u)
                umax = max(umax, u)
                vmin = min(vmin, v)
                vmax = max(vmax, v)
            }
        }
        let det = (c * c) - (-s * s)
        var a: Float = 0, b: Float = 0, d: Float = 0
        if det != 0 {
            let inv = 1 / det
            a = inv * c
            b = -s * inv
            d = s * inv
        }
        func corner(_ u: Float, _ v: Float) -> Pt { Pt((a * u + b * v) + ox, (d * u + a * v) + oy) }
        var q = [corner(umin, vmin), corner(umax, vmin), corner(umax, vmax), corner(umin, vmax)]
        if Double(theta) > 0.785398163397448 { q = [q[2], q[3], q[0], q[1]] }
        return q.map { Pt($0.x.rounded(.down), $0.y.rounded(.down)) }
    }

    static func buildTextLine(_ image: ImageU8, _ line: DetectedLine) -> TextLine {
        let cols = Float(image.width - 1), rows = Float(image.height - 1)
        let p = line.polygon.map { Pt(min(max($0.x, 0), cols), min(max($0.y, 0), rows)) }
        let (left, right, top, bottom) = bounds(p)
        let (x0, y0, x1, y1) = (left, top, right, bottom)
        let n = p.count / 2
        var quad = line.isPolygon ? pcaBox(p, left, top)
            : [p[0], p[n - 1], p[n], p[p.count - 1]].map { Pt($0.x.rounded(.down), $0.y.rounded(.down)) }
        quad = quad.map { Pt(min(max($0.x, Float(x0)), Float(x1)), min(max($0.y, Float(y0)), Float(y1))) }
        return TextLine(polygon: p, isHorizontal: line.isHorizontal, curved: line.isPolygon, ambiguous: line.isAmbiguous,
                        rect: (x0, y0, x1 - x0 + 1, y1 - y0 + 1), boundsFloor: (x0, y0, x1, y1), quad: quad)
    }

    // MARK: straight lines

    /// cv::RotatedRect::points.
    private static func rotatedRectPoints(_ cx: Float, _ cy: Float, _ w: Float, _ h: Float, _ angle: Double) -> [Pt] {
        let a = Double(Float(angle)) * .pi / 180
        let b = Float(CRT.cos(a)) * 0.5, s = Float(CRT.sin(a)) * 0.5
        let p0 = Pt(cx - s * h - b * w, cy + b * h - s * w)
        let p1 = Pt(cx + s * h - b * w, cy - b * h - s * w)
        return [p0, p1, Pt(2 * cx - p0.x, 2 * cy - p0.y), Pt(2 * cx - p1.x, 2 * cy - p1.y)]
    }

    /// RotateImage: the image rotated by angle degrees into its full bounding box (border 255), and the transform.
    private static func rotateImage(_ img: ImageU8, _ angle: Double) -> (ImageU8, [Float]) {
        let rows = img.height, cols = img.width
        if angle == 0 || min(rows, cols) < 3 { return (img, [1, 0, 0, 0, 1, 0]) }
        let a = angle * deg2rad
        let alpha = CRT.cos(a), beta = CRT.sin(a)
        let cx = Double(Float(Double(cols - 1) * 0.5)), cy = Double(Float(Double(rows - 1) * 0.5))
        var M = [alpha, beta, cx * (1 - alpha) - cy * beta, -beta, alpha, cy * (1 - alpha) + cx * beta].map { Float($0) }
        let pts = rotatedRectPoints(0, 0, Float(cols), Float(rows), angle)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let bw = xs.max()! - xs.min()!, bh = ys.max()! - ys.min()!
        M[2] = M[2] + (bw - Float(cols)) * 0.5
        M[5] = M[5] + (bh - Float(rows)) * 0.5
        let out = CV.warpAffine(img, M.map(Double.init), Int(bw.rounded(.toNearestOrEven)),
                                Int(bh.rounded(.toNearestOrEven)), border: 255)
        return (out, M)
    }

    private static func quadAngleDeg(_ q: [Pt]) -> Double {
        let a1 = CRT.atan2(Double(q[1].y - q[0].y), Double(q[1].x - q[0].x))
        let a2 = CRT.atan2(Double(q[2].y - q[3].y), Double(q[2].x - q[3].x))
        return (a2 + a1) * 0.5 * rad2deg
    }

    private static func normalizeQuad(_ crop: ImageU8, _ q: [Pt]) -> (ImageU8, [Float], Double) {
        let (rot, M) = rotateImage(crop, quadAngleDeg(q))
        let tx = q.map { Int((M[0] * $0.x + M[1] * $0.y) + M[2]) }
        let ty = q.map { Int((M[3] * $0.x + M[4] * $0.y) + M[5]) }
        var minx = tx.min()!, miny = ty.min()!
        var rw = max(1, tx.max()! - minx), rh = max(1, ty.max()! - miny)
        minx = max(0, min(minx, rot.width - 1))
        miny = max(0, min(miny, rot.height - 1))
        rw = min(rw, rot.width - minx)
        rh = min(rh, rot.height - miny)
        let sub = rot.crop(minx, miny, rw, rh)
        let fScale = Double(lineHeight) / Double(rh)
        let nw = min(max(1, Int(Double(rw) * fScale)), maxWidth)
        let line = CV.resizeLinear(sub, nw, lineHeight)
        var M2 = M
        M2[2] = Float(Double(M[2]) - Double(minx))
        M2[5] = Float(Double(M[5]) - Double(miny))
        let A = M2.map { Float(fScale) * $0 }
        return (line, CV.invertAffine32(A), Double(rh))
    }

    // MARK: curved lines

    private static func boundingRect(_ p: [Pt]) -> (Int, Int, Int, Int) {
        let (x0, x1, y0, y1) = (p.map(\.x).min()!, p.map(\.x).max()!, p.map(\.y).min()!, p.map(\.y).max()!)
        let ix = Int(x0.rounded(.down)), iy = Int(y0.rounded(.down))
        return (ix, iy, Int(x1.rounded(.down)) - ix + 1, Int(y1.rounded(.down)) - iy + 1)
    }

    private static func warpTriangle(_ src: ImageF32, _ dst: inout ImageF32, _ ts: [Pt], _ td: [Pt]) -> LineMapper.Triangle {
        var (x, y, w, h) = boundingRect(ts)
        let r1 = (x, y, min(src.width - x, w + 1), min(src.height - y, h + 1))
        (x, y, w, h) = boundingRect(td)
        let r2 = (x, y, min(dst.width - x, w + 1), min(dst.height - y, h + 1))
        let t1 = ts.map { Pt($0.x - Float(r1.0), $0.y - Float(r1.1)) }
        let t2 = td.map { Pt($0.x - Float(r2.0), $0.y - Float(r2.1)) }
        var mask = [Bool](repeating: false, count: r2.2 * r2.3)
        mask.withUnsafeMutableBufferPointer { m in
            CV.fillConvexPoly(r2.2, r2.3, t2.map { (Int($0.x), Int($0.y)) }) { px, py in m[py * r2.2 + px] = true }
        }
        var img1 = ImageF32(width: r1.2, height: r1.3, channels: 3)
        src.data.withUnsafeBufferPointer { s in
            img1.data.withUnsafeMutableBufferPointer { d in
                for row in 0..<r1.3 {
                    let so = ((r1.1 + row) * src.width + r1.0) * 3
                    (d.baseAddress! + row * r1.2 * 3).update(from: s.baseAddress! + so, count: r1.2 * 3)
                }
            }
        }
        let warp = CV.affineTransform(t1, t2)
        let img2 = CV.warpAffine(img1, warp, r2.2, r2.3)
        let dw = dst.width
        img2.data.withUnsafeBufferPointer { s in
            dst.data.withUnsafeMutableBufferPointer { d in
                for row in 0..<r2.3 {
                    for col in 0..<r2.2 where mask[row * r2.2 + col] {
                        let di = ((r2.1 + row) * dw + r2.0 + col) * 3, si = (row * r2.2 + col) * 3
                        d[di] = s[si]
                        d[di + 1] = s[si + 1]
                        d[di + 2] = s[si + 2]
                    }
                }
            }
        }
        let inv = CV.invert2x2([warp[0], warp[1], warp[3], warp[4]]).map { Float($0) }
        return .init(dst: td, inv: inv, t: (Float(warp[2]), Float(warp[5])), r1: (r1.0, r1.1), r2: (r2.0, r2.1))
    }

    private static func normalizeCurved(_ crop: ImageU8, _ pts: [Pt]) -> (ImageU8, [LineMapper.Triangle], Double) {
        let n = pts.count / 2, m = 2 * n - 1
        var accH: Float = 0
        for i in 0..<n {
            let dx = pts[i].x - pts[m - i].x, dy = pts[i].y - pts[m - i].y
            accH = accH + (dy * dy + dx * dx).squareRoot()
        }
        let avgH = accH / Float(n)
        let scale = Float(lineHeight) / avgH
        let lim = Float(maxWidth) - 1
        var widths: [Float] = []
        var acc: Float = 0
        for k in 0..<(n - 1) {
            let dx = pts[k].x - pts[k + 1].x, dy = pts[k].y - pts[k + 1].y
            acc = (dy * dy + dx * dx).squareRoot() * scale + acc
            widths.append(pmin(acc, lim))
        }
        let hb = Float(lineHeight - 1)
        var dstPts = [Pt](repeating: Pt(0, 0), count: 2 * n)
        for (i, w) in widths.enumerated() {
            dstPts[i + 1] = Pt(w, 0)
            dstPts[m - 1 - i] = Pt(w, hb)
        }
        dstPts[m] = Pt(0, hb)
        let src = ImageF32(crop)
        var dst = ImageF32(width: Int(widths.last! + 1), height: lineHeight, channels: 3)
        var tris: [LineMapper.Triangle] = []
        for i in 0..<(n - 1) {
            for idx in [[i, i + 1, m - i], [m - i, m - i - 1, i + 1]] {
                tris.append(warpTriangle(src, &dst, idx.map { pts[$0] }, idx.map { dstPts[$0] }))
            }
        }
        let line = ImageU8(width: dst.width, height: dst.height, channels: 3,
                           data: dst.data.map { UInt8(min(max($0.rounded(.toNearestOrEven), 0), 255)) })
        return (line, tris, Double(avgH))
    }

    /// Fills the line image, its size, the mapper and the source height.
    static func normalize(_ line: TextLine, _ image: ImageU8) {
        let r = line.rect
        let crop = image.crop(r.x, r.y, r.w, r.h)
        let o = Pt(Float(r.x), Float(r.y))
        if line.curved {
            let (img, tris, h) = normalizeCurved(crop, line.polygon.map { Pt($0.x - o.x, $0.y - o.y) })
            line.mapper = LineMapper(origin: o, affine: nil, triangles: tris)
            line.lineImage = img
            line.sourceHeight = h
        } else {
            let (img, inv, h) = normalizeQuad(crop, line.quad.map { Pt($0.x - o.x, $0.y - o.y) })
            line.mapper = LineMapper(origin: o, affine: inv)
            line.lineImage = img
            line.sourceHeight = h
        }
        line.lineSize = (line.lineImage.width, line.lineImage.height)
    }

    // MARK: output geometry

    /// The line box the API reports (before the word-angle consistency fix).
    static func lineOutputQuad(_ line: TextLine) -> [Pt] {
        var q = line.quad
        if line.orientation == Orientation.flipped { q = [q[2], q[3], q[0], q[1]] }
        if line.layout == LineLayout.vertical { q = [q[3], q[0], q[1], q[2]] }
        return q
    }

    /// A word box from its line-image pixel span (in the possibly flipped line image).
    static func wordOutputQuad(_ line: TextLine, _ startX: Double, _ endX: Double) -> [Pt] {
        let W = Double(line.lineSize.0), H = Double(line.lineSize.1)
        let corners: [(Double, Double)]
        if line.orientation == Orientation.flipped {
            let a = W - startX - 1, b = W - endX
            corners = [(a, H), (b, H), (b, 0), (a, 0)]
        } else {
            corners = [(startX, 0), (endX, 0), (endX, H), (startX, H)]
        }
        let bf = line.boundsFloor
        var q = corners.map { c -> Pt in
            let p = line.mapper.map(c.0, c.1)
            return Pt(min(max(p.x, Float(bf.x0)), Float(bf.x1)), min(max(p.y, Float(bf.y0)), Float(bf.y1)))
        }
        if line.layout == LineLayout.vertical { q = [q[3], q[0], q[1], q[2]] }
        return q
    }
}
