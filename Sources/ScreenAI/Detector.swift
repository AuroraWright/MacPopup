import Accelerate
import CoreML
import Foundation

// Text line detection (google_ocr GocrGroupRpnTextDetectionMutator with GroupRpnDetectorV2): gray page -> LINE
// entities with rotated boxes and PhotoOcrTextDetectionInfo, in the order the original emits them.

private let configPath = "gocr/gocr_models/detection/gocr_group_rpn_text_detection_config_2024_q4_chrome.binarypb"
private let radToDeg: Float = 57.2957763671875  // 0x42652EE0

/// google_ocr.GroupRpnTextDetectionMutatorConfig (the fields the Chrome config sets and the code reads).
struct DetectorConfig {
    var inputNames: [String] = [], outputNames: [String] = []
    var confidenceThreshold: Float = 0.5
    var heatmapWidthScaling: [Float] = [], heatmapHeightScaling: [Float] = [], maxWidth: [Float] = [],
        maxHeight: [Float] = []
    var subsampling: [Int] = []
    var heatmapLogScaling = false, applySigmoid = false, projectCosSin = false
    var anchorXCenter: Float = 0, anchorYCenter: Float = 0

    struct Level1 {
        var maxHeightRatio: Float = 0, searchRadiusFactor: Float = 0, maximumAngleDifference: Float = 0,
            maxCentersRelativeDistance: Float = 0, optimalCentersRelativeDistance: Float = 0, minOverlap: Float = 0,
            minOverlapWithOptimalCentersAlignment: Float = 0
    }
    var level1 = Level1()
    /// GocrDetectorMergeLevel1Config fields 1...18 (index = field - 1).
    var merge = [Float](repeating: 0, count: 19)
    /// input_image_config.predefined_shapes (width, height).
    var predefinedShapes: [(Int, Int)] = []
    var boxWidthPadding: Float = 0, boxTopHeightPadding: Float = 0, boxBottomHeightPadding: Float = 0,
        boxWidthPaddingLeftPortion: Float = 0
    var packingSequence: [Int] = [], centerBoxPackingSequence: [Int] = []

    init(resources: Resources) throws {
        guard let bytes = resources.read(configPath) else { throw ScreenAIError("The detector config is missing") }
        var any = ProtoReader(bytes)
        var cfg: ArraySlice<UInt8> = []
        while any.next() {
            if any.field == 2 { cfg = any.bytes }
        }
        var r = ProtoReader(cfg)
        while r.next() {
            switch r.field {
            case 1:
                var mr = ProtoReader(r.bytes)
                while mr.next() {
                    guard mr.field == 7 else { continue }  // tflite_model_pooled_cached_runner_config
                    var t = ProtoReader(mr.bytes)
                    while t.next() {
                        if t.field == 8 { outputNames.append(t.string) }
                        if t.field == 12 { inputNames.append(t.string) }
                    }
                }
            case 2: parseModelSettings(r.bytes)
            case 3: parseOptions(r.bytes)
            default: break
            }
        }
        guard r.ok, !outputNames.isEmpty, !packingSequence.isEmpty, !predefinedShapes.isEmpty,
              centerBoxPackingSequence.count == packingSequence.count
        else { throw ScreenAIError("The detector config can't be read") }
    }

    private static func floats(_ r: ProtoReader) -> [Float] {
        if r.wireType != .len { return [r.float32] }
        let b = Array(r.bytes)
        return stride(from: 0, to: b.count - 3, by: 4).map {
            Float(bitPattern: UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24)
        }
    }

    private static func ints(_ r: ProtoReader) -> [Int] {
        if r.wireType != .len { return [r.int] }
        var out: [Int] = []
        var v: UInt64 = 0
        var shift: UInt64 = 0
        for c in r.bytes {
            v |= UInt64(c & 0x7F) << shift
            shift += 7
            if c & 0x80 == 0 {
                out.append(Int(Int32(truncatingIfNeeded: v)))
                v = 0
                shift = 0
            }
        }
        return out
    }

    private mutating func parseModelSettings(_ b: ArraySlice<UInt8>) {
        var r = ProtoReader(b)
        while r.next() {
            switch r.field {
            case 1: confidenceThreshold = r.float32
            case 4: heatmapWidthScaling += Self.floats(r)
            case 5: heatmapHeightScaling += Self.floats(r)
            case 6: heatmapLogScaling = r.varint != 0
            case 7: applySigmoid = r.varint != 0
            case 8: anchorXCenter = r.float32
            case 9: anchorYCenter = r.float32
            case 11: projectCosSin = r.varint != 0
            case 12: subsampling += Self.ints(r)
            case 19: maxWidth += Self.floats(r)
            case 20: maxHeight += Self.floats(r)
            default: break
            }
        }
    }

    private mutating func parseOptions(_ b: ArraySlice<UInt8>) {
        var r = ProtoReader(b)
        while r.next() {
            switch r.field {
            case 2:
                var l = ProtoReader(r.bytes)
                while l.next() {
                    switch l.field {
                    case 1: level1.maxHeightRatio = l.float32
                    case 2: level1.searchRadiusFactor = l.float32
                    case 3: level1.maximumAngleDifference = l.float32
                    case 4: level1.maxCentersRelativeDistance = l.float32
                    case 5: level1.optimalCentersRelativeDistance = l.float32
                    case 6: level1.minOverlap = l.float32
                    case 7: level1.minOverlapWithOptimalCentersAlignment = l.float32
                    default: break
                    }
                }
            case 4:
                var m = ProtoReader(r.bytes)
                while m.next() {
                    if m.field >= 1 && m.field <= 18 { merge[m.field - 1] = m.float32 }
                }
            case 6:
                var ic = ProtoReader(r.bytes)
                while ic.next() {
                    guard ic.field == 6 else { continue }
                    var s = (0, 0)
                    var sr = ProtoReader(ic.bytes)
                    while sr.next() {
                        if sr.field == 1 { s.0 = sr.int } else { s.1 = sr.int }
                    }
                    predefinedShapes.append(s)
                }
            case 7:
                var p = ProtoReader(r.bytes)
                while p.next() {
                    switch p.field {
                    case 2: boxWidthPadding = p.float32
                    case 3: boxTopHeightPadding = p.float32
                    case 4: boxBottomHeightPadding = p.float32
                    case 5: boxWidthPaddingLeftPortion = p.float32
                    default: break
                    }
                }
            case 13: packingSequence += Self.ints(r)
            case 16: centerBoxPackingSequence += Self.ints(r)
            default: break
            }
        }
    }
}

// MARK: - Image pyramid

/// One level of the detector's image pyramid: its scale relative to the page, and its image (none for the
/// reference level, which is never used, and for a level whose image the next one reused).
struct PyramidLevel {
    var scale: Float
    var image: GrayImage?
}

/// google_ocr::ScaleImage: sides rintf(scale * side), at least 1.
private func scaleImage(_ src: GrayImage, _ scale: Float, _ filter: FilterMode) -> GrayImage {
    let w = max(1, Int(rintf(scale * Float(src.width))))
    let h = max(1, Int(rintf(scale * Float(src.height))))
    return src.scaled(to: w, h, filter)
}

/// The image pyramid of GroupRpnDetectorV2: [reference, fit to the first shape, then halvings]; one level per
/// packing_sequence entry. The reference level's image is dropped (it is never fed to the model, and gone when the
/// lines are cropped).
func buildPyramid(_ c: DetectorConfig, _ src: GrayImage) -> [PyramidLevel] {
    let W = Float(src.width), H = Float(src.height)
    // Reference image: box-filtered to fit the largest predefined shape, upscaled (if at all) only up to the first.
    let first = c.predefinedShapes.first!, last = c.predefinedShapes.last!
    var up = Float(first.0) / W
    if Float(first.1) / H < up { up = Float(first.1) / H }
    if up <= 1 { up = 1 }
    var s0 = Float(last.1) / H
    if s0 >= Float(last.0) / W { s0 = Float(last.0) / W }
    if s0 >= up { s0 = up }
    let n = c.packingSequence.count
    var images = [GrayImage?](repeating: nil, count: n)
    var scales = [Float](repeating: 0, count: n)
    images[0] = scaleImage(src, s0, .box)
    scales[0] = s0
    for k in 1..<max(n, 1) {
        let prev = images[k - 1]!
        var s: Float
        if k == 1 {
            s = Float(first.1) / Float(prev.height)
            if s >= Float(first.0) / Float(prev.width) { s = Float(first.0) / Float(prev.width) }
        } else {
            s = 0.5
        }
        if abs(s + -1) < 0.001 {
            images[k] = images[k - 1]  // reused: the previous level's slot becomes empty
            images[k - 1] = nil
        } else {
            images[k] = scaleImage(prev, s, k == 1 ? .box : .bilinear)
        }
        scales[k] = s * scales[k - 1]
    }
    images[0] = nil
    return (0..<n).map { PyramidLevel(scale: scales[$0], image: images[$0]) }
}

// MARK: - Raw boxes

/// google_ocr::RawBox.
private struct RawBox {
    var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0, angle: Float = 0
    /// Corners: (x, y), (x + w cos, y + w sin), + (-sin h, cos h), (x - sin h, y + cos h).
    var pts = [Float](repeating: 0, count: 8)
    var cx: Float = 0, cy: Float = 0
    var score: Float = 0
    var rbox: RBox { RBox(x: x, y: y, w: w, h: h, angle: angle) }
}

/// ocr::photo::HeatmapToBoundingBoxes + google_ocr::TensorsToRawBoxes over one head [1, H, W, 7]: logit, dx, dy,
/// log w, log h, cos, sin.
private func heatmapToRawBoxes(_ t: UnsafePointer<Float>, _ H: Int, _ W: Int, _ head: Int, _ c: DetectorConfig) -> [RawBox] {
    var out: [RawBox] = []
    let minLogit = -logf(1 / c.confidenceThreshold + -1)
    let sub = Float(c.subsampling[head])
    let wscale = c.heatmapWidthScaling[head], hscale = c.heatmapHeightScaling[head]
    let maxW = c.maxWidth[head], maxH = c.maxHeight[head]
    for y in 0..<H {
        for x in 0..<W {
            let p = t + (y * W + x) * 7
            var score = p[0]
            if c.applySigmoid {
                if !(score > minLogit) { continue }
                score = 1 / (expf(-score) + 1)
            } else if !(score > c.confidenceThreshold) {
                continue
            }
            let dx = p[1], dy = p[2], lw = p[3], lh = p[4], cs = p[5], sn = p[6]
            var angle: Float
            if c.projectCosSin {
                let n = sqrtf(cs * cs + sn * sn) + 0.00001
                angle = Float(Double(atan2f(sn / n, cs / n) * 180) / 3.141592653589793)
            } else {
                var v = sn <= 1 ? sn : 1
                if v < -1 { v = -1 }
                var a = Double(asinf(v) * 180) / 3.141592653589793
                if cs <= 0 { a = a + 180 }
                angle = Float(a)
            }
            let rad = Double(angle) * 3.141592653589793 / 180.0
            let scd = sinCos(rad)
            var w: Float, h: Float
            if c.heatmapLogScaling {
                w = expf(lw) * wscale
                h = expf(lh) * hscale
            } else {
                w = lw * wscale
                h = lh * hscale
            }
            if !(w >= 1) || !(h >= 1) { continue }
            let bcx = (c.anchorXCenter + (dx + Float(x))) * sub
            let bcy = (c.anchorYCenter + (dy + Float(y))) * sub
            let c64 = Double(Float(scd.cos)), s64 = Double(Float(scd.sin))
            let hw = Double(w) * 0.5, hh = Double(h) * 0.5
            var b = RawBox()
            b.x = Float((Double(bcx) - c64 * hw) + s64 * hh)
            b.y = Float((Double(bcy) - s64 * hw) - c64 * hh)
            b.w = w
            b.h = h
            b.angle = angle
            b.score = score
            if (b.w > maxW && maxW > 0) || (b.h > maxH && maxH > 0) { continue }
            var p1x: Float, p1y: Float, p2x: Float, p2y: Float, p3x: Float, p3y: Float
            if b.angle == 0 {
                p1x = b.x + b.w
                p1y = b.y
                p2x = b.x + b.w
                p2y = b.y + b.h
                p3x = b.x
                p3y = b.y + b.h
            } else {
                let sc = sinCos(b.angle * degToRad)
                let sa = sc.sin, ca = sc.cos
                p1x = b.x + b.w * ca
                p1y = b.y + b.w * sa
                let t2 = -sa * b.h
                p2x = t2 + p1x
                p2y = ca * b.h + p1y
                p3x = b.x + t2
                p3y = b.y + ca * b.h
            }
            b.pts = [b.x, b.y, p1x, p1y, p2x, p2y, p3x, p3y]
            b.cx = (((b.x + 0) + p1x) + p2x + p3x) * 0.25
            b.cy = (((b.y + 0) + p1y) + p2y + p3y) * 0.25
            out.append(b)
        }
    }
    return out
}

// MARK: - Geometry (google_ocr::box_util, rotation_util)

/// rotation_util::RobustAngleEstimation<float>: the median of the directions relative to the dominant quadrant.
private func robustAngleEstimation(_ angles: [Float]) -> Float {
    if angles.isEmpty { return 0 }
    let dirs: [(Float, Float)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    var hist = [0, 0, 0, 0]
    var cs: [(c: Float, s: Float)] = []
    cs.reserveCapacity(angles.count)
    for a in angles {
        let sc = sinCos(a * degToRad)
        let s = sc.sin, c = sc.cos
        var best = 0
        for k in 1..<4 {
            let db = (c * dirs[best].0 + 0) + s * dirs[best].1
            let dk = (c * dirs[k].0 + 0) + s * dirs[k].1
            if db < dk { best = k }
        }
        hist[best] += 1
        cs.append((c, s))
    }
    var dom = 0
    for k in 1..<4 where hist[dom] < hist[k] { dom = k }
    let dx = dirs[dom].0, dy = dirs[dom].1
    var v = cs.map { (c: $0.c, s: $0.s, key: atan2f(dx * $0.s - dy * $0.c, (dx * $0.c + 0) + dy * $0.s)) }
    v.libcxxSort { $0.key < $1.key }
    let n = v.count
    var mc: Float, ms: Float
    if n & 1 != 0 {
        mc = v[n / 2].c
        ms = v[n / 2].s
    } else {
        mc = (v[n / 2].c + v[n / 2 - 1].c) * 0.5
        ms = (v[n / 2].s + v[n / 2 - 1].s) * 0.5
    }
    let a = atan2f(ms, mc) * radToDeg
    return ms == 0 && mc == 0 ? 0 : a
}

/// Mean direction of two angles (degrees): atan2 of the summed unit vectors; for opposite directions, the one
/// closer to 0.
private func meanAngle(_ a0: Float, _ a1: Float) -> Float {
    let s0 = sinCos(a0 * degToRad), s1 = sinCos(a1 * degToRad)
    let c = (s0.cos + 0) + s1.cos
    let s = (s0.sin + 0) + s1.sin
    if abs(c) > 0.00001 || abs(s) > 0.00001 {
        return abs(s) > 0.00001 || c > Float(bitPattern: 0xBFFF_FF58) ? atan2f(s, c) * radToDeg : 180
    }
    var a = normalizeAngle(a0)
    var aa = abs(a)
    if aa >= 180 {
        a = 180
        aa = 180
    }
    let b = normalizeAngle(a1)
    if b == -a { a = abs(a) }
    if abs(b) < aa { a = b }
    return a
}

/// box_util::ExpandBoxToContainBox(src, dst): grows dst (keeping its angle) to contain src.
private func expandBoxToContainBox(_ src: RBox, _ dst: inout RBox) {
    if dst.w <= 0 || dst.h <= 0 {
        dst = src
        dst.angle = normalizeAngle(src.angle)
        return
    }
    let sa = normalizeAngle(src.angle), da = normalizeAngle(dst.angle)
    if sa == 0 && da == 0 {
        var x = src.x, w = dst.w, h = dst.h
        let dxl = dst.x - src.x
        if dxl <= 0 {
            x = dst.x
        } else {
            dst.x = x
            w = w + dxl
            dst.w = w
        }
        var y = src.y
        let dyt = dst.y - src.y
        if dyt <= 0 {
            y = dst.y
        } else {
            dst.y = y
            h = h + dyt
            dst.h = h
        }
        let r = src.x + src.w
        if r > x + w { dst.w = r - x }
        let b = src.y + src.h
        if b > y + h { dst.h = b - y }
        return
    }
    let ox = dst.x, oy = dst.y, ow = dst.w, oh = dst.h
    let sc1 = sinCos(da * -0.017453292)
    let s1 = sc1.sin, c1 = sc1.cos
    let ddy = src.y - oy
    let k = normalizeAngle(src.angle - da)
    let p0x = (ox + c1 * (src.x - ox)) - s1 * ddy
    let p0y = (oy + s1 * (src.x - ox)) + c1 * ddy
    var px: [Float] = [p0x, 0, 0, 0], py: [Float] = [p0y, 0, 0, 0]
    if k == 0 {
        px[1] = src.w + p0x
        py[1] = p0y
        px[2] = src.w + p0x
        py[2] = src.h + p0y
        px[3] = p0x
        py[3] = src.h + p0y
    } else {
        let sc2 = sinCos(k * degToRad)
        let s2 = sc2.sin, c2 = sc2.cos
        px[1] = p0x + src.w * c2
        py[1] = p0y + src.w * s2
        px[2] = px[1] - s2 * src.h
        py[2] = src.h * c2 + py[1]
        px[3] = p0x - s2 * src.h
        py[3] = p0y + src.h * c2
    }
    var mnx = ox, mny = oy, mxx = ox + ow, mxy = oy + oh
    for i in 0..<4 {
        if mnx > px[i] { mnx = px[i] }
        if mny > py[i] { mny = py[i] }
        if px[i] > mxx { mxx = px[i] }
        if py[i] > mxy { mxy = py[i] }
    }
    let sc3 = sinCos(da * degToRad)
    let s3 = sc3.sin, c3 = sc3.cos
    let ex = mnx - ox, ey = mny - oy
    dst.x = (ox + c3 * ex) - s3 * ey
    dst.y = (oy + s3 * ex) + c3 * ey
    dst.w = mxx - mnx
    dst.h = mxy - mny
}

/// box_util::FindContainingBoxWithRobustAngle over raw boxes.
private func findContainingBoxWithRobustAngle(_ boxes: [RawBox]) -> RBox {
    let angle = robustAngleEstimation(boxes.map(\.angle))
    var r = RBox()
    for b in boxes {
        if r.w <= 0 || r.h <= 0 { r = RBox(x: b.x, y: b.y, w: 1, h: 1, angle: angle) }
        expandBoxToContainBox(b.rbox, &r)
    }
    return r
}

// MARK: - KdTree

/// cityscan::KdTree<Vector2<float>, 2> (nanoflann KDTreeSingleIndexAdaptor, leaf size 10, L2_Simple): only the
/// unsorted radius search the detector uses. The order of the neighbors matters (it decides union-find roots).
private final class KdTree2 {
    private struct Node {
        var divfeat = 0
        var divlow: Float = 0, divhigh: Float = 0
        var left = 0, right = 0
        /// 0 for leaves; the first child is the next node.
        var child2 = 0
    }

    private let xs: [Float], ys: [Float]
    private var vind: [Int]
    private var nodes: [Node] = []
    private var rootBbox: [Float] = [0, 0, 0, 0]

    init(_ points: [(Float, Float)]) {
        xs = points.map(\.0)
        ys = points.map(\.1)
        let n = points.count
        vind = Array(0..<n)
        if n == 0 { return }
        var bb = [xs[0], xs[0], ys[0], ys[0]]
        for i in 1..<n {
            let x = xs[i], y = ys[i]
            if x < bb[0] { bb[0] = x }
            if x > bb[1] { bb[1] = x }
            if y < bb[2] { bb[2] = y }
            if y > bb[3] { bb[3] = y }
        }
        rootBbox = bb
        nodes.reserveCapacity(2 * n)
        _ = divideTree(0, n, &bb)
    }

    private func coord(_ vi: Int, _ d: Int) -> Float { d == 0 ? xs[vind[vi]] : ys[vind[vi]] }

    /// Returns the node index; bbox (low0, high0, low1, high1) becomes the subtree's point bounds.
    private func divideTree(_ left: Int, _ right: Int, _ bbox: inout [Float]) -> Int {
        let id = nodes.count
        nodes.append(Node())
        let count = right - left
        if count <= 10 {
            nodes[id].left = left
            nodes[id].right = right
            var lo0 = coord(left, 0), hi0 = lo0, lo1 = coord(left, 1), hi1 = lo1
            for k in (left + 1)..<max(right, left + 1) {
                let x = coord(k, 0), y = coord(k, 1)
                if lo0 > x { lo0 = x }
                if hi0 < x { hi0 = x }
                if lo1 > y { lo1 = y }
                if hi1 < y { hi1 = y }
            }
            bbox = [lo0, hi0, lo1, hi1]
            return id
        }
        // middleSplit_
        var maxSpan = bbox[1] - bbox[0]
        if bbox[3] - bbox[2] > maxSpan { maxSpan = bbox[3] - bbox[2] }
        let lim = maxSpan * 0.99999
        func minMax(_ d: Int) -> (Float, Float) {
            var mn = coord(left, d), mx = mn
            for k in (left + 1)..<right {
                let v = coord(k, d)
                if v < mn { mn = v }
                if mx < v { mx = v }
            }
            return (mn, mx)
        }
        var cutfeat = 0
        var mn0: Float = 0, mx0: Float = 0, spread0: Float = 0
        let use0 = bbox[1] - bbox[0] >= lim
        if use0 {
            (mn0, mx0) = minMax(0)
            spread0 = mx0 - mn0
        }
        var mn = mn0, mx = mx0
        if bbox[3] - bbox[2] >= lim {
            let (mn1, mx1) = minMax(1)
            if !(use0 && mx1 - mn1 <= spread0) {
                cutfeat = 1
                mn = mn1
                mx = mx1
            }
        }
        let lo = bbox[2 * cutfeat], span = bbox[2 * cutfeat + 1] - lo
        var cutval = lo + span * 0.5
        if cutval < mn { cutval = mn }
        if cutval > mx { cutval = mx }
        // Three-way partition around cutval.
        var lt = 0, i = 0, gt = count
        while i < gt {
            let v = cutfeat == 0 ? xs[vind[left + i]] : ys[vind[left + i]]
            if v < cutval {
                vind.swapAt(left + lt, left + i)
                lt += 1
                i += 1
            } else if v > cutval {
                gt -= 1
                vind.swapAt(left + i, left + gt)
            } else {
                i += 1
            }
        }
        let idx = lt > count / 2 ? lt : (i < count / 2 ? i : count / 2)
        var lb = bbox
        lb[2 * cutfeat + 1] = cutval
        _ = divideTree(left, left + idx, &lb)
        var rb = bbox
        rb[2 * cutfeat] = cutval
        let c2 = divideTree(left + idx, right, &rb)
        nodes[id].divfeat = cutfeat
        nodes[id].divlow = lb[2 * cutfeat + 1]
        nodes[id].divhigh = rb[2 * cutfeat]
        nodes[id].child2 = c2
        for d in 0..<2 {
            bbox[2 * d] = lb[2 * d] > rb[2 * d] ? rb[2 * d] : lb[2 * d]
            bbox[2 * d + 1] = lb[2 * d + 1] > rb[2 * d + 1] ? lb[2 * d + 1] : rb[2 * d + 1]
        }
        return id
    }

    /// Indices with squared distance < r2, in traversal order.
    func radiusSearch(_ qx: Float, _ qy: Float, _ r2: Float) -> [Int] {
        var out: [Int] = []
        if xs.isEmpty { return out }
        var dists: [Float] = [0, 0]
        var distsq: Float = 0
        if qx < rootBbox[0] {
            dists[0] = (qx - rootBbox[0]) * (qx - rootBbox[0])
            distsq = dists[0]
        } else if qx > rootBbox[1] {
            dists[0] = (qx - rootBbox[1]) * (qx - rootBbox[1])
            distsq = dists[0]
        }
        if qy < rootBbox[2] {
            dists[1] = (qy - rootBbox[2]) * (qy - rootBbox[2])
            distsq = distsq + dists[1]
        } else if qy > rootBbox[3] {
            dists[1] = (qy - rootBbox[3]) * (qy - rootBbox[3])
            distsq = distsq + dists[1]
        }
        searchLevel([qx, qy], r2, 0, distsq, &dists, &out)
        return out
    }

    private func searchLevel(_ q: [Float], _ r2: Float, _ node: Int, _ mindistsq0: Float, _ dists: inout [Float],
                             _ out: inout [Int]) {
        let nd = nodes[node]
        if nd.child2 == 0 {
            for i in nd.left..<nd.right {
                let dx = q[0] - xs[vind[i]], dy = q[1] - ys[vind[i]]
                if dx * dx + dy * dy < r2 { out.append(vind[i]) }
            }
            return
        }
        let f = nd.divfeat
        let val = q[f]
        let diff1 = val - nd.divlow, diff2 = val - nd.divhigh
        let best: Int, other: Int
        let cutDist: Float
        if diff1 + diff2 < 0 {
            best = node + 1
            other = nd.child2
            cutDist = diff2 * diff2
        } else {
            best = nd.child2
            other = node + 1
            cutDist = diff1 * diff1
        }
        searchLevel(q, r2, best, mindistsq0, &dists, &out)
        let dst = dists[f]
        let mindistsq = (mindistsq0 + cutDist) - dst
        dists[f] = cutDist
        if !(1 * mindistsq > r2) { searchLevel(q, r2, other, mindistsq, &dists, &out) }
        dists[f] = dst
    }
}

// MARK: - Level-1 grouping

/// google_ocr::Level1GroupedBox (the fields used downstream).
private struct Level1Box {
    var box = RBox()
    /// Indices into the raw boxes.
    var members: [Int] = []
    var avgHeight: Float = 0, avgScore: Float = 0
    /// Best and runner-up overlapping paragraph prediction.
    var paragraph = -1, paragraph2 = -1
    /// Set by constructLines: corners, rounded axis-aligned bounds, corner centroid.
    var pts = [Float](repeating: 0, count: 8)
    var ax = 0, ay = 0, aw = 0, ah = 0
    var cx: Float = 0, cy: Float = 0
}

private final class DisjointSet {
    private var parent: [Int], rank: [Int]

    init(_ n: Int) {
        parent = Array(0..<n)
        rank = [Int](repeating: 0, count: n)
    }

    func root(_ i: Int) -> Int {
        if parent[i] != i { parent[i] = root(parent[i]) }
        return parent[i]
    }

    func union(_ a: Int, _ b: Int) {
        let ra = root(a), rb = root(b)
        if ra == rb { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else {
            parent[rb] = ra
            if rank[ra] <= rank[rb] { rank[ra] += 1 }
        }
    }

    /// Clusters ordered by root index, members ascending.
    func clusters() -> [[Int]] {
        var id: [Int: Int] = [:]
        var out: [[Int]] = []
        for i in parent.indices where root(i) == i {
            id[i] = out.count
            out.append([])
        }
        for i in parent.indices { out[id[root(i)]!].append(i) }
        return out
    }
}

/// adjacency[i]: the boxes j (in search order) box i connects to.
private func pairwiseConnections(_ cfg: DetectorConfig.Level1, _ raw: [RawBox]) -> [[Int]] {
    let n = raw.count
    let tree = KdTree2(raw.map { ($0.cx, $0.cy) })
    var adj = [[Int]](repeating: [], count: n)
    var seen = Set<IndexPair>()
    for i in 0..<n {
        let bi = raw[i]
        var r = Int(bi.h)
        if r <= Int(bi.w) { r = Int(bi.w) }
        let rr = cfg.searchRadiusFactor * Float(r)
        for j in tree.radiusSearch(bi.cx, bi.cy, rr * rr) {
            if !seen.insert(IndexPair(a: min(i, j), b: max(i, j))).inserted { continue }
            let bj = raw[j]
            let hminF = bj.h >= bi.h ? bi.h : bj.h
            let hmin = Int(hminF)
            if cfg.maxHeightRatio > 0 {
                let hmax = bi.h < bj.h ? bj.h : bi.h
                if Float(Int(hmax)) / Float(hmin) > cfg.maxHeightRatio { continue }
            }
            var d = fmodf(abs(bi.angle - bj.angle), 360)
            if d > 180 { d = 360 - d }
            if !(d <= cfg.maximumAngleDifference) { continue }
            var centersDist: Float = 1
            if cfg.maxCentersRelativeDistance > 0 {
                let mean = meanAngle(bi.angle, bj.angle)
                let scm = sinCos(mean * degToRad)
                let px = scm.sin * (bi.cx - bj.cx), py = scm.cos * (bi.cy - bj.cy)
                centersDist = abs(py - px) / Float(hmin)
                if centersDist > cfg.maxCentersRelativeDistance { continue }
            }
            let ov = boxOverlapArea(bi.rbox, bj.rbox)
            if ov == 0 { continue }
            let oi = ov / (bi.w * bi.h), oj = ov / (bj.w * bj.h)
            let thr = centersDist < cfg.optimalCentersRelativeDistance
                ? cfg.minOverlapWithOptimalCentersAlignment : cfg.minOverlap
            if oi > thr || oj > thr { adj[i].append(j) }
        }
    }
    return adj
}

private func level1Boxes(_ cfg: DetectorConfig.Level1, _ raw: [RawBox]) -> [Level1Box] {
    let adj = pairwiseConnections(cfg, raw)
    let ds = DisjointSet(raw.count)
    for i in adj.indices {
        for j in adj[i] { ds.union(i, j) }
    }
    return ds.clusters().map { cl in
        var l = Level1Box()
        l.box = findContainingBoxWithRobustAngle(cl.map { raw[$0] })
        l.members = cl
        var sh: Float = 0, ss: Float = 0
        for i in cl {
            ss = ss + raw[i].score
            sh = sh + raw[i].h
        }
        l.avgHeight = sh / Float(cl.count)
        l.avgScore = ss / Float(cl.count)
        return l
    }
}

// MARK: - Paragraph predictions

private struct ParagraphPrediction {
    var box: RBox
    var score: Float
}

private func paragraphNms(_ lists: [[RawBox]]) -> [ParagraphPrediction] {
    var p = lists.flatMap { $0.map { ParagraphPrediction(box: $0.rbox, score: $0.score) } }
    p.libcxxSort { $0.score > $1.score }
    var suppressed = [Bool](repeating: false, count: p.count)
    var kept: [ParagraphPrediction] = []
    for i in p.indices {
        if suppressed[i] { continue }
        kept.append(p[i])
        for j in p.indices {
            let ov = boxOverlapArea(p[i].box, p[j].box)
            if ov == 0 { continue }
            if ov / (p[i].box.w * p[i].box.h) > 0.75 || ov / (p[j].box.w * p[j].box.h) > 0.75 { suppressed[j] = true }
        }
    }
    return kept
}

/// Tags each level-1 box with the paragraph predictions covering most of it.
private func assignParagraphs(_ paras: [ParagraphPrediction], _ l1: inout [Level1Box]) {
    let n1 = l1.count
    let ov = computeOverlaps(l1.map(\.box) + paras.map(\.box), split: n1)
    for i in 0..<n1 {
        var best = -1, second = -1
        var vbest: Float = 0.4, vsecond: Float = 0.4
        for j in paras.indices {
            guard let o = ov[IndexPair(a: i, b: n1 + j)] else { continue }
            let r = o.overFirst
            if r > vbest {
                if best > -1 {
                    vsecond = vbest
                    second = best
                }
                vbest = r
                best = j
            } else if r > vsecond {
                vsecond = r
                second = j
            }
        }
        if best < 0 { continue }
        l1[i].paragraph = best
        if second < 0 { continue }
        if vbest - vsecond < 0.25 && paras[best].score <= paras[second].score { swap(&best, &second) }
        l1[i].paragraph = best
        l1[i].paragraph2 = second
    }
}

// MARK: - Lines

/// google_ocr::MergedBoxesStruct (the fields used downstream).
private struct MergedLine {
    var box = RBox()
    /// Indices of the level-1 boxes, in cluster order.
    var l1: [Int] = []
    /// The number of raw boxes.
    var count = 0
    var avgHeight: Float = 0, avgScore: Float = 0, minCos: Float = 1
    var leftPadding: Float = 0, rightPadding: Float = 0
    var paragraph = -1
    var curved = false
    var thickness: Float = 0
    var top: [(Float, Float)] = [], bottom: [(Float, Float)] = []
}

private func mergedBoxesStruct(_ l1: [Level1Box], _ raw: [RawBox], _ members: [Int]) -> MergedLine {
    var m = MergedLine()
    m.l1 = members
    var boxes: [RawBox] = []
    var sh: Float = 0, ss: Float = 0
    for i in members {
        for r in l1[i].members { boxes.append(raw[r]) }
        let n = l1[i].members.count
        ss = ss + l1[i].avgScore * Float(n)
        m.count += n
        sh = sh + l1[i].avgHeight * Float(n)
    }
    m.avgScore = ss / Float(m.count)
    m.avgHeight = sh / Float(m.count)
    let angles = boxes.map(\.angle)
    let angle = robustAngleEstimation(angles)
    let sr = sinCos(angle * degToRad)
    for a in angles {
        let sa = sinCos(a * degToRad)
        let d = sr.sin * sa.sin + (sr.cos * sa.cos + 0)
        if d < m.minCos { m.minCos = d }
    }
    m.box = RBox(angle: angle)
    for b in boxes {
        if m.box.w <= 0 || m.box.h <= 0 { m.box = RBox(x: b.x, y: b.y, w: 1, h: 1, angle: angle) }
        expandBoxToContainBox(b.rbox, &m.box)
    }
    return m
}

/// PointsToAxisAlignedBox<..., AlignedBox<int>> rounding.
private func roundToInt(_ v: Float) -> Int {
    let r = roundf(v)
    if r >= 2_147_500_032 { return Int(Int32.max) }
    if truncf(r) < -2_147_500_032 { return Int(Int32.min) }
    return Int(r)
}

private func normalizedCentersDistance(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ angle: Float,
                                       _ norm: Float) -> Float {
    let sc = sinCos(Float(Double(angle) * 3.141592653589793 / 180.0))
    let mx = (ax + bx) * -0.5, my = (ay + by) * -0.5
    return (abs(sc.cos * (ay + my) - sc.sin * (ax + mx)) + abs(sc.cos * (by + my) - sc.sin * (bx + mx))) / norm
}

/// CreateCurveRepresentation: the line's raw boxes give their left and right edge midpoints; sorted along the line
/// and smoothed with a 6-point moving average (keeping a point once it moved more than half the thickness), they
/// make the mid line, offset by half the thickness to both sides into the top and bottom polylines.
private func createCurveRepresentation(_ raws: [RawBox], _ dirX: Float, _ dirY: Float, _ ox: Float, _ oy: Float,
                                       _ m: inout MergedLine) {
    let window = 6
    m.curved = true
    var pts: [(Float, Float)] = []
    var t: Float = 0
    for r in raws {
        pts.append(((r.pts[0] + r.pts[6]) * 0.5, (r.pts[1] + r.pts[7]) * 0.5))
        pts.append(((r.pts[2] + r.pts[4]) * 0.5, (r.pts[3] + r.pts[5]) * 0.5))
        if t < r.h { t = r.h }
    }
    m.thickness = t
    func key(_ p: (Float, Float)) -> Float { (dirX * (p.0 - ox) + 0) + dirY * (p.1 - oy) }
    pts.libcxxSort { key($0) < key($1) }
    var mid: [(Float, Float)] = []
    let n = pts.count
    if n == 0 { return }
    if n > 1 {
        var buf = [(Float, Float)](repeating: (0, 0), count: window)
        var next = 0, count = 0
        var sx: Float = 0, sy: Float = 0
        func add(_ p: (Float, Float)) -> (Float, Float) {
            sx = (sx - buf[next].0) + p.0
            sy = (sy - buf[next].1) + p.1
            buf[next] = p
            count = count + 1 <= window ? count + 1 : window
            next = (next + 1) % window
            let c = Float(count)
            return (sx / c, sy / c)
        }
        mid.append(add(pts[0]))
        for i in 1..<(n - 1) {
            let a = add(pts[i])
            let dx = a.0 - mid.last!.0, dy = a.1 - mid.last!.1
            if dx * dx + dy * dy > t * (t * 0.25) { mid.append(a) }
        }
    }
    mid.append(pts[n - 1])
    let half = t * 0.5
    for i in 1..<max(mid.count, 1) {
        let p = mid[i - 1], q = mid[i]
        let sc = sinCos(atan2f(q.0 - p.0, p.1 - q.1))
        let ox2 = sc.cos * half, oy2 = sc.sin * half
        m.top.append((p.0 - ox2, p.1 - oy2))
        m.bottom.append((ox2 + p.0, oy2 + p.1))
        if i + 1 == mid.count {
            m.top.append((q.0 - ox2, q.1 - oy2))
            m.bottom.append((ox2 + q.0, oy2 + q.1))
        }
    }
}

/// geometry2d::RTreeBase<R2BoundingBox, MergedBox const*> (Guttman R-tree, at most 10 entries per node, linear
/// split), for its query result order: neighbor pairs are evaluated in find() order.
private final class RTree {
    struct Box {
        var x0: Double, y0: Double, x1: Double, y1: Double
    }

    private struct Entry {
        var box: Box
        var child: Int  // node index, or -1
        var item: Int
    }

    private struct Node {
        /// 0 = leaf, -1 = a new root not yet filled.
        var height: Int
        var entries: [Entry] = []
        var parent = -1
    }

    private static let splitSize = 11
    private var nodes: [Node] = []
    private var root = -1

    private func newNode(_ height: Int) -> Int {
        nodes.append(Node(height: height))
        return nodes.count - 1
    }

    private static func isEmpty(_ b: Box) -> Bool { b.x1 - b.x0 == 0 && b.y1 - b.y0 == 0 }

    private func bounds(_ n: Int) -> Box {
        var u = Box(x0: 0, y0: 0, x1: 0, y1: 0)
        for e in nodes[n].entries {
            if Self.isEmpty(u) {
                u = e.box
            } else if !Self.isEmpty(e.box) {
                if u.x0 > e.box.x0 { u.x0 = e.box.x0 }
                if u.y0 > e.box.y0 { u.y0 = e.box.y0 }
                if u.x1 < e.box.x1 { u.x1 = e.box.x1 }
                if !(u.y1 >= e.box.y1) { u.y1 = e.box.y1 }
            }
        }
        return u
    }

    private static func union(_ a: Box, _ e: Box) -> Box {
        if isEmpty(a) { return e }
        if isEmpty(e) { return a }
        return Box(x0: e.x0 >= a.x0 ? a.x0 : e.x0, y0: e.y0 >= a.y0 ? a.y0 : e.y0, x1: a.x1 >= e.x1 ? a.x1 : e.x1,
                   y1: a.y1 >= e.y1 ? a.y1 : e.y1)
    }

    func insert(_ b: Box, _ item: Int) {
        if root < 0 {
            root = newNode(0)
            nodes[root].entries.append(Entry(box: b, child: -1, item: item))
            return
        }
        var node = root
        while nodes[node].height != 0 {
            var best = -1
            var bestGrowth = 0.0, bestArea = 0.0
            for e in nodes[node].entries {
                let w = e.box.x1 - e.box.x0, h = e.box.y1 - e.box.y0
                var u = e.box
                if w == 0 && h == 0 {
                    u = b
                } else if b.x1 - b.x0 != 0 || b.y1 - b.y0 != 0 {
                    if b.x0 < u.x0 { u.x0 = b.x0 }
                    if b.y0 < u.y0 { u.y0 = b.y0 }
                    if u.x1 < b.x1 { u.x1 = b.x1 }
                    if u.y1 < b.y1 { u.y1 = b.y1 }
                }
                let area = (u.y1 - u.y0) * (u.x1 - u.x0)
                let growth = area - w * h
                if best < 0 || growth < bestGrowth || (growth == bestGrowth && area < bestArea) {
                    best = e.child
                    bestGrowth = growth
                    bestArea = area
                }
            }
            node = best
        }
        nodes[node].entries.append(Entry(box: b, child: -1, item: item))
        adjustTree(node, nodes[node].entries.count >= Self.splitSize ? split(node) : -1)
    }

    private func pickSplitSeeds(_ n: Int) -> (Int, Int) {
        let v = nodes[n].entries
        var maxX0 = v[0].box.x0, maxY0 = v[0].box.y0, minX1 = v[0].box.x1, minY1 = v[0].box.y1
        var iMaxX0 = 0, iMaxY0 = 0, iMinX1 = 0, iMinY1 = 0
        for k in 1..<v.count {
            let b = v[k].box
            if b.x0 <= maxX0 {
                if b.x1 < minX1 {
                    minX1 = b.x1
                    iMinX1 = k
                }
            } else {
                maxX0 = b.x0
                iMaxX0 = k
            }
            if b.y0 > maxY0 {
                maxY0 = b.y0
                iMaxY0 = k
            } else if b.y1 < minY1 {
                minY1 = b.y1
                iMinY1 = k
            }
        }
        let all = bounds(n)
        var sx = abs(maxX0 - minX1) / (all.x1 - all.x0)
        let sy = abs(maxY0 - minY1) / (all.y1 - all.y0)
        if iMaxX0 == iMinX1 { sx = 0 }
        let ty = iMaxY0 != iMinY1 ? sy : 0
        var s1: Int, s2: Int
        if sx <= ty {
            s1 = iMaxY0
            s2 = iMinY1
        } else {
            s1 = iMaxX0
            s2 = iMinX1
        }
        if s1 == s2 { s2 = v.count - 1 }
        return (s1, s2)
    }

    /// Moves part of n's entries into a new sibling, which is returned.
    private func split(_ n: Int) -> Int {
        let (s1, s2) = pickSplitSeeds(n)
        let entries = nodes[n].entries
        var a = [entries[s1]], b = [entries[s2]]
        var ba = a[0].box, bb = b[0].box
        for k in entries.indices where k != s1 && k != s2 {
            let e = entries[k]
            if a.count == 8 {
                b.append(e)
                continue
            }
            if b.count == 8 {
                a.append(e)
                continue
            }
            let ua = Self.union(ba, e.box), ub = Self.union(bb, e.box)
            let areaA = (ua.y1 - ua.y0) * (ua.x1 - ua.x0)
            let growA = areaA - (ba.y1 - ba.y0) * (ba.x1 - ba.x0)
            let areaB = (ub.y1 - ub.y0) * (ub.x1 - ub.x0)
            let growB = areaB - (bb.y1 - bb.y0) * (bb.x1 - bb.x0)
            if growA > growB || (growA == growB && areaA >= areaB) {
                b.append(e)
                bb = ub
            } else {
                a.append(e)
                ba = ua
            }
        }
        let sib = newNode(nodes[n].height)
        nodes[n].entries = a
        nodes[sib].entries = b
        if nodes[sib].height != 0 {
            for e in b { nodes[e.child].parent = sib }
        }
        return sib
    }

    private func addNode(_ n: Int, _ child: Int) {
        if nodes[n].entries.isEmpty && nodes[n].height == -1 { nodes[n].height = nodes[child].height + 1 }
        nodes[n].entries.append(Entry(box: bounds(child), child: child, item: -1))
        nodes[child].parent = n
    }

    private func adjustTree(_ start: Int, _ split0: Int) {
        var n = start, splitNode = split0
        while n != root {
            let parent = nodes[n].parent
            if let k = nodes[parent].entries.firstIndex(where: { $0.child == n }) { nodes[parent].entries[k].box = bounds(n) }
            if splitNode >= 0 {
                addNode(parent, splitNode)
                splitNode = nodes[parent].entries.count >= Self.splitSize ? split(parent) : -1
            }
            n = parent
        }
        if splitNode >= 0 {
            let r = newNode(-1)
            addNode(r, root)
            addNode(r, splitNode)
            root = r
        }
    }

    /// Items whose boxes intersect q (closed), depth first in entry order.
    func find(_ q: Box) -> [Int] {
        var out: [Int] = []
        if root >= 0 { find(root, q, &out) }
        return out
    }

    private func find(_ n: Int, _ q: Box, _ out: inout [Int]) {
        for e in nodes[n].entries
        where e.box.x0 <= q.x1 && !(e.box.x1 < q.x0 || e.box.y0 > q.y1) && e.box.y1 >= q.y0 {
            if nodes[n].height != 0 {
                find(e.child, q, &out)
            } else {
                out.append(e.item)
            }
        }
    }
}

private struct PairAndCost {
    var left: Int, right: Int
    var cost: Float
}

/// ConstructLines: level-1 boxes are chained left to right by the cheapest admissible neighbor pairs; each chain
/// becomes a line.
private func constructLines(_ cfg: [Float], _ raw: [RawBox], _ l1: inout [Level1Box]) -> [MergedLine] {
    let n = l1.count
    for i in 0..<n {
        let b = l1[i].box
        var p = [Float](repeating: 0, count: 8)
        p[0] = b.x
        p[1] = b.y
        if b.angle == 0 {
            p[2] = b.x + b.w
            p[3] = b.y
            p[4] = p[2]
            p[5] = b.y + b.h
            p[6] = b.x
            p[7] = p[5]
        } else {
            let sc = sinCos(b.angle * degToRad)
            p[2] = b.x + sc.cos * b.w
            p[3] = b.y + sc.sin * b.w
            p[4] = p[2] - sc.sin * b.h
            p[5] = p[3] + sc.cos * b.h
            p[6] = b.x - sc.sin * b.h
            p[7] = b.y + sc.cos * b.h
        }
        var mnx = p[0], mny = p[1], mxx = p[0], mxy = p[1]
        for k in 1..<4 {
            if mnx > p[2 * k] { mnx = p[2 * k] }
            if mny > p[2 * k + 1] { mny = p[2 * k + 1] }
            if p[2 * k] > mxx { mxx = p[2 * k] }
            if p[2 * k + 1] > mxy { mxy = p[2 * k + 1] }
        }
        l1[i].pts = p
        l1[i].ax = roundToInt(mnx)
        l1[i].ay = roundToInt(mny)
        l1[i].aw = roundToInt(mnx + (mxx - mnx)) - l1[i].ax
        l1[i].ah = roundToInt(mny + (mxy - mny)) - l1[i].ay
        l1[i].cx = ((((0 + p[0]) + p[2]) + p[4]) + p[6]) * 0.25
        l1[i].cy = ((((0 + p[1]) + p[3]) + p[5]) + p[7]) * 0.25
    }

    // Candidate neighbors: R-tree query with the box widened along its reading direction.
    var query: [RTree.Box] = []
    for l in l1 {
        var a = l.box.angle
        while a <= -180 { a = a + 360 }
        while a > 180 { a = a + -360 }
        if a < 0 { a = a + 360 }
        let quadrant = Int64(rintf(a / 90))
        var q = RTree.Box(x0: Double(l.ax), y0: Double(l.ay), x1: Double(l.aw + l.ax), y1: Double(l.ah + l.ay))
        let e = l.box.h * cfg[0]  // neighbor_search_expansion
        if quadrant & 1 != 0 {
            q.y0 = q.y0 - Double(e)
            q.y1 = Double(e) + q.y1
        } else {
            q.x0 = q.x0 - Double(e)
            q.x1 = Double(e) + q.x1
        }
        query.append(q)
    }
    let tree = RTree()
    for (i, l) in l1.enumerated() {
        tree.insert(RTree.Box(x0: Double(l.ax), y0: Double(l.ay), x1: Double(l.aw + l.ax), y1: Double(l.ah + l.ay)), i)
    }

    // Pairs in the original's discovery order (which decides the order of equal-cost links in the sort below).
    var pairs: [PairAndCost] = []
    var seen = Set<IndexPair>()
    for i in 0..<n {
        for j in tree.find(query[i]) {
            if j == i { continue }
            let lo = min(i, j), hi = max(i, j)
            if !seen.insert(IndexPair(a: lo, b: hi)).inserted { continue }
            let a = l1[lo], b = l1[hi]
            let hmax = a.avgHeight >= b.avgHeight ? a.avgHeight : b.avgHeight
            let hmin = b.avgHeight < a.avgHeight ? b.avgHeight : a.avgHeight
            var d = fmodf(abs(a.box.angle - b.box.angle), 360)
            if d > 180 { d = 360 - d }
            if !(d <= 45) { continue }
            let mean = meanAngle(a.box.angle, b.box.angle)
            let centers = normalizedCentersDistance(a.cx, a.cy, b.cx, b.cy, mean, hmin)
            let sc = sinCos(Float(Double(mean) * 3.141592653589793 / -180.0))
            // Corners in the frame turned by -mean: (y', x') per corner; min and max over each box.
            func extent(_ l: Level1Box) -> ([Float], [Float]) {
                var mn: [Float] = [3.4028235e38, 3.4028235e38], mx: [Float] = [-3.4028235e38, -3.4028235e38]
                for k in 0..<4 {
                    let px = l.pts[2 * k], py = l.pts[2 * k + 1]
                    let r = [sc.sin * px + sc.cos * py, sc.cos * px - sc.sin * py]
                    for c in 0..<2 {
                        if mn[c] > r[c] { mn[c] = r[c] }
                        if r[c] > mx[c] { mx[c] = r[c] }
                    }
                }
                return (mn, mx)
            }
            let (bmn, bmx) = extent(b)
            let (amn, amx) = extent(a)
            let bRight = bmn[1] > amn[1]
            var lo2: [Float] = [0, 0], hi2: [Float] = [0, 0]
            for c in 0..<2 {
                lo2[c] = bmn[c] > amn[c] ? bmn[c] : amn[c]
                hi2[c] = amx[c] > bmx[c] ? bmx[c] : amx[c]
            }
            let xov: Float = lo2[1] < hi2[1] ? hi2[1] - lo2[1] : 0
            let yovAbs: Float = hi2[0] > lo2[0] ? hi2[0] - lo2[0] : 0
            let gapAbs: Float = hi2[1] > lo2[1] ? 0 : lo2[1] - hi2[1]
            let hminBox = b.box.h < a.box.h ? b.box.h : a.box.h
            let yov = yovAbs / hminBox
            let gap = gapAbs / hmin
            let wmin = b.box.w < a.box.w ? b.box.w : a.box.w
            let xovr = xov / wmin
            var reject = yov == 0
            let pa = a.paragraph, pb = b.paragraph, pa2 = a.paragraph2, pb2 = b.paragraph2
            if pa == -1 {
                if gap > 0.5 && pb != -1 { reject = true }
            } else if pb == -1 {
                if gap > 0.5 { reject = true }
            } else {
                let share = pa == pb || (pb2 != -1 && pa == pb2) || (pa2 != -1 && (pa2 == pb || pa2 == pb2))
                if !share { reject = true }
            }
            if reject { continue }
            if xovr > cfg[6] && yov < cfg[7] { continue }  // overlapping_not_aligned_pair_*
            if xovr > cfg[4] && yov > cfg[5] { continue }  // duplicate_pair_*
            if yov < cfg[2] && centers > cfg[3] { continue }  // not_aligned_pair_*
            let ratio = hmin / hmax
            let cost = Float(Double(1 - ratio) * 0.5 + Double(gap + centers))
            pairs.append(PairAndCost(left: bRight ? lo : hi, right: bRight ? hi : lo, cost: cost))
        }
    }
    pairs.libcxxSort { $0.cost < $1.cost }
    let ds = DisjointSet(n)
    var hasRight = Set<Int>(), hasLeft = Set<Int>()
    for p in pairs {
        if hasRight.contains(p.left) || hasLeft.contains(p.right) { continue }
        hasRight.insert(p.left)
        hasLeft.insert(p.right)
        if p.cost < -cfg[1] { ds.union(p.left, p.right) }  // minimum_box_dissimilarity
    }

    var lines: [MergedLine] = []
    for cl in ds.clusters() {
        var m = mergedBoxesStruct(l1, raw, cl)
        if m.minCos >= 0.99 && m.box.h <= m.avgHeight * cfg[9] {  // split_merged_box_height_ratio
            lines.append(m)
            continue
        }
        // The level-1 boxes along the line, by the projection of their left edge midpoints.
        let sc = sinCos(m.box.angle * degToRad)
        var order: [(Float, Int)] = cl.map { i in
            let l = l1[i]
            let px = ((l.pts[0] + l.pts[6]) * 0.5 - m.box.x) * sc.cos
            let py = ((l.pts[1] + l.pts[7]) * 0.5 - m.box.y) * sc.sin
            return ((px + 0) + py, i)
        }
        order.libcxxSort { $0.0 < $1.0 }
        if m.minCos < 0.99 {
            let raws = order.flatMap { o in l1[o.1].members.map { raw[$0] } }
            createCurveRepresentation(raws, sc.cos, sc.sin, m.box.x, m.box.y, &m)
            lines.append(m)
            continue
        }
        let first = order[0].1
        if l1[first].avgHeight <= m.avgHeight + m.avgHeight {
            lines.append(m)
            continue
        }
        // A leading box much taller than the line becomes its own line.
        lines.append(mergedBoxesStruct(l1, raw, [first]))
        lines.append(mergedBoxesStruct(l1, raw, order.dropFirst().map(\.1)))
    }
    return lines
}

// MARK: - Cropping and padding

/// GroupRpnDetectorV2 CropDetections cuts every line image for the recognizer, and in doing so changes the line's
/// box: the line is cut from the most downscaled pyramid image that keeps it at least 64 px tall, or from the page
/// itself when that image's scale is >= 0.999 (the scale is reported as detection_image_scale, per mille). The box
/// is scaled into a downscaled image with integer truncation and back, which can move its edges by a pixel; an
/// unrotated, uncurved box is also clipped to the image it is cut from.
private let cropLineHeight = 64

private func scaleDetectionBox(_ s: Float, _ b: inout RotatedBox, _ curve: inout Curve?) {
    let right = Int(s * Float(b.left + b.width))
    let bottom = Int(s * Float(b.top + b.height))
    b.left = Int(s * Float(b.left))
    b.top = Int(s * Float(b.top))
    b.width = right - b.left
    b.height = bottom - b.top
    guard var c = curve else { return }
    let sd = Double(s)
    c.thickness = c.thickness * sd
    c.points = c.points.map { ($0.x * sd, $0.y * sd) }
    curve = c
}

/// Leptonica boxCreate + boxClipToRectangle, as the crop uses them; false when nothing of the box is inside.
@discardableResult
private func clipToImage(_ w: Int, _ h: Int, _ b: inout RotatedBox) -> Bool {
    var x = b.left, y = b.top, bw = b.width, bh = b.height
    if bw < 0 || bh < 0 { return false }
    if x < 0 {
        bw += x
        x = 0
        if bw < 1 { return false }
    }
    if y < 0 {
        bh += y
        y = 0
        if bh < 1 { return false }
    }
    if x >= w || y >= h || bw + x < 1 || bh + y < 1 { return false }
    if bw + x > w { bw = w - x }
    if bh + y > h { bh = h - y }
    if bw != b.width || bh != b.height {
        b.left = x
        b.top = y
        b.width = bw
        b.height = bh
    }
    return true
}

/// Returns detection_image_scale; adjusts the box (and curve) as the crop does.
private func cropDetection(_ pyramid: [PyramidLevel], _ pageW: Int, _ pageH: Int, _ box: inout RotatedBox,
                           _ curve: inout Curve?) -> Int {
    let height = curve?.thickness ?? Double(box.height)
    let minScale = Float(cropLineHeight) / Float(Int(height)) + -0.001
    var chosen = -1
    for (k, l) in pyramid.enumerated() where l.image != nil && l.scale >= minScale { chosen = k }
    let scaled = chosen >= 0 && pyramid[chosen].scale < 0.999
    let s: Float = scaled ? pyramid[chosen].scale : 1
    if scaled { scaleDetectionBox(s, &box, &curve) }
    if curve == nil && box.angle == 0 {
        clipToImage(scaled ? pyramid[chosen].image!.width : pageW, scaled ? pyramid[chosen].image!.height : pageH, &box)
    }
    if scaled { scaleDetectionBox(1 / s, &box, &curve) }
    return Int(s * 1000)
}

/// PostProcessConfig: pads the line box and rounds it to whole pixels.
private func padLine(_ c: DetectorConfig, _ m: inout MergedLine) {
    var b = m.box
    let a = normalizeAngle(b.angle)
    let sn = sinCos(a * degToRad)
    let h = b.h, w = b.w
    let cx = (b.x - (h * 0.5) * sn.sin) + sn.cos * (w * 0.5)
    let cy = (b.y + (h * 0.5) * sn.cos) + sn.sin * (w * 0.5)
    var pad = c.boxWidthPadding * h
    if pad > 16 { pad = 16 }
    if pad < 4 { pad = 4 }
    let so = sinCos(b.angle * degToRad)
    var top = c.boxTopHeightPadding * h
    if top > 8 { top = 8 }
    let ht = h * 0.5 + top
    let left = c.boxWidthPaddingLeftPortion * pad
    let wl = w * 0.5 + left
    let x = (cx + so.sin * ht) - so.cos * wl
    let y = (cy - so.cos * ht) - so.sin * wl
    var bottom = c.boxBottomHeightPadding * h
    if bottom > 8 { bottom = 8 }
    if bottom < 1 { bottom = 1 }
    let hh = Float((Double(h) * 0.5 + Double(ht)) + Double(bottom))
    b.w = Float(Int64(rintf(w + pad)))
    b.x = Float(Int64(rintf(x)))
    b.y = Float(Int64(rintf(y)))
    b.h = Float(Int64(rintf(hh)))
    m.box = b
    m.leftPadding = left
    m.rightPadding = pad - left
    if !m.curved { return }
    // Curved: thickened by the vertical paddings, both polyline ends extended along their end segments.
    let t = m.thickness
    var ct = c.boxTopHeightPadding * t
    if ct > 8 { ct = 8 }
    var cb = c.boxBottomHeightPadding * t
    if cb > 8 { cb = 8 }
    if cb < 1 { cb = 1 }
    m.thickness = t + (ct + cb)
    let n = m.top.count
    if n < 2 { return }
    var cw = c.boxWidthPadding * t
    if cw > 16 { cw = 16 }
    if cw < 4 { cw = 4 }
    func dir(_ a: (Float, Float), _ b: (Float, Float)) -> (x: Float, y: Float, inv: Float) {
        let dx = a.0 - b.0, dy = a.1 - b.1
        let l = dx * dx + dy * dy
        let r = sqrtf(l)
        return (dx, dy, l == 0 ? r : 1 / r)
    }
    let t0 = dir(m.top[0], m.top[1]), tn = dir(m.top[n - 1], m.top[n - 2])
    let b0 = dir(m.bottom[0], m.bottom[1]), bn = dir(m.bottom[n - 1], m.bottom[n - 2])
    let cl = c.boxWidthPaddingLeftPortion * cw, cr = cw - cl
    func move(_ p: inout (Float, Float), _ d: (x: Float, y: Float, inv: Float), _ len: Float) {
        p.0 = (d.x * d.inv) * len + p.0
        p.1 = (d.y * d.inv) * len + p.1
    }
    move(&m.top[0], t0, cl)
    move(&m.top[n - 1], tn, cr)
    move(&m.bottom[0], b0, cl)
    move(&m.bottom[n - 1], bn, cr)
}

/// The paragraph of a line: the one whose level-1 boxes cover the largest area.
private func lineParagraph(_ l1: [Level1Box], _ m: MergedLine) -> Int {
    var v = m.l1.map { l1[$0] }
    v.libcxxSort { $0.paragraph < $1.paragraph }
    var best = -1
    var vbest: Float = -1, run: Float = 0
    for k in v.indices {
        let acc = run + v[k].box.w * v[k].box.h
        if k + 1 < v.count && v[k].paragraph == v[k + 1].paragraph {
            run = acc
        } else {
            run = 0
            if acc > vbest {
                best = v[k].paragraph
                vbest = acc
            }
        }
    }
    return best
}

// MARK: - Detector

final class TextDetector {
    let config: DetectorConfig
    /// Per model input name, its Core ML model (converted from the detector with one model per input).
    private let models: [String: CoreMLModel]

    init(resources: Resources) throws {
        config = try DetectorConfig(resources: resources)
        var models: [String: CoreMLModel] = [:]
        for name in config.inputNames {
            models[name] = try CoreMLModel(resources.url("coreml/det_\(name).mlmodelc"), cpuOnly: resources.cpuOnly, reshapes: true)
        }
        self.models = models
    }

    /// Detected lines (each LINE entity followed by its PARAGRAPH, unless an earlier line has it), and the pyramid
    /// the recognizer cuts lines of large text from.
    func detect(_ gray: GrayImage) throws -> (PageLayout, [PyramidLevel]) {
        // Core ML's autoreleased objects (its output buffers among them) are freed after each call.
        try autoreleasepool { try detectLines(gray) }
    }

    private func detectLines(_ gray: GrayImage) throws -> (PageLayout, [PyramidLevel]) {
        let c = config
        let W = gray.width, H = gray.height
        var out = PageLayout(width: W, height: H)
        // google_ocr::ScaleImage refuses sides >= 32768, which fails the whole call.
        guard W >= 1, H >= 1, W < 32768, H < 32768 else { throw ScreenAIError("The image is too large") }
        let levels = buildPyramid(c, gray)
        let numLevels = levels.count

        // Inputs: one per level with heads, padded with 0 to multiples of 32. A level without an image would get a
        // 32 x 32 zero tensor, and its heads' boxes are dropped, so it isn't run.
        var inputLevel: [Int] = []
        for k in 0..<numLevels where c.packingSequence[k] != 0 || c.centerBoxPackingSequence[k] != 0 {
            inputLevel.append(k)
        }
        guard inputLevel.count == c.inputNames.count else { throw ScreenAIError("Unexpected detector config") }
        var jobs: [(model: CoreMLModel, input: String, image: GrayImage)] = []
        for (i, k) in inputLevel.enumerated() {
            if let image = levels[k].image, let model = models[c.inputNames[i]] {
                jobs.append((model, c.inputNames[i], image))
            }
        }
        var results = [[String: MLMultiArray]?](repeating: nil, count: jobs.count)
        var failure: Error?
        let lock = NSLock()
        func runJob(_ j: Int) throws {
            let job = jobs[j]
            let p = job.image
            let iw = (p.width + 31) / 32 * 32, ih = (p.height + 31) / 32 * 32
            let input = try MLMultiArray(shape: [1, NSNumber(value: ih), NSNumber(value: iw), 1], dataType: .float32)
            let d = input.dataPointer.assumingMemoryBound(to: Float.self)
            d.initialize(repeating: 0, count: ih * iw)
            p.data.withUnsafeBufferPointer { src in
                for y in 0..<p.height {
                    vDSP_vfltu8(src.baseAddress! + y * p.width, 1, d + y * iw, 1, vDSP_Length(p.width))
                }
            }
            let r = try job.model.predict([job.input: input])
            lock.withLock { results[j] = r }
        }
        DispatchQueue.concurrentPerform(iterations: jobs.count) { j in
            do {
                try autoreleasepool { try runJob(j) }
            } catch {
                lock.withLock { failure = error }
            }
        }
        if let failure { throw failure }
        var outputs: [String: MLMultiArray] = [:]
        for r in results { outputs.merge(r ?? [:]) { a, _ in a } }

        // Decode the horizontal heads (packing_sequence), then the vertical ones (center_box_packing_sequence), in
        // output order, back in page coordinates.
        var all: [RawBox] = []
        var vlists: [[RawBox]] = []
        var head = 0
        for pass in 0..<2 {
            let seq = pass == 0 ? c.packingSequence : c.centerBoxPackingSequence
            var local = 0
            for k in 0..<numLevels {
                for _ in 0..<seq[k] {
                    defer {
                        head += 1
                        local += 1
                    }
                    guard levels[k].image != nil else { continue }
                    let name = coreMLName(c.outputNames[head])
                    guard let t = outputs[name], t.shape.count == 4 else {
                        throw ScreenAIError("The detector has no output \(name)")
                    }
                    let h = t.shape[1].intValue, w = t.shape[2].intValue
                    var boxes = withContiguousFloats(t) { heatmapToRawBoxes($0, h, w, local, c) }
                    let inv = 1 / levels[k].scale
                    for i in boxes.indices {
                        boxes[i].x *= inv
                        boxes[i].y *= inv
                        boxes[i].w *= inv
                        boxes[i].h *= inv
                        for q in 0..<8 { boxes[i].pts[q] *= inv }
                        boxes[i].cx *= inv
                        boxes[i].cy *= inv
                    }
                    if pass == 0 { all += boxes } else { vlists.append(boxes) }
                }
            }
        }

        let paragraphs = paragraphNms(vlists)
        var l1 = level1Boxes(c.level1, all)
        assignParagraphs(paragraphs, &l1)
        var lines = constructLines(c.merge, all, &l1)

        // LINE entities, each followed by its PARAGRAPH unless an earlier line has the same dominant paragraph.
        var paragraphEntity: [Int: Int] = [:]
        for li in lines.indices {
            padLine(c, &lines[li])
            lines[li].paragraph = lineParagraph(l1, lines[li])
            let m = lines[li]
            let lineIndex = out.entities.count
            out.entities.append(Entity())
            let parent: Int
            if m.paragraph != -1, let p = paragraphEntity[m.paragraph] {
                parent = p
            } else {
                parent = out.entities.count
                out.entities.append(Entity(type: .paragraph))
                if m.paragraph != -1 { paragraphEntity[m.paragraph] = parent }
            }
            var box = RotatedBox()
            box.left = Int(m.box.x)
            box.top = Int(m.box.y)
            box.width = Int(Int64(rintf(m.box.w)))
            box.height = Int(Int64(rintf(m.box.h)))
            box.angle = m.box.angle
            var curve: Curve?
            if m.curved {  // TransformBoxesToPhotoOCR: the mid line is the deduplicated midpoints of the polylines
                var cv = Curve(thickness: Double(m.thickness))
                for k in 0..<min(m.top.count, m.bottom.count) {
                    let x = (m.top[k].0 + m.bottom[k].0) * 0.5
                    let y = (m.top[k].1 + m.bottom[k].1) * 0.5
                    if k > 0, let last = cv.points.last, Float(last.x) == x && Float(last.y) == y { continue }
                    cv.points.append((Double(x), Double(y)))
                }
                curve = cv
            }
            let imageScale = cropDetection(levels, W, H, &box, &curve)
            var e = Entity(type: .line, parent: parent)
            e.box = box
            if var cv = curve, cv.points.count >= 2 {  // a curved_box needs at least 2 points
                cv.topToBottom = false
                e.box!.curve = cv
            }
            e.detectionConfidence = m.avgScore
            var d = DetectionInfo()
            d.detectionBox = box
            d.detectionBox.curve = curve
            d.averageRawDetectionsHeight = m.avgHeight
            d.detectionNmsScore = m.avgScore
            d.numRawBoxes = m.count
            d.sumRawBoxesScores = m.avgScore * Float(m.count)
            d.leftPadding = m.leftPadding
            d.rightPadding = m.rightPadding
            d.detectionImageScale = imageScale
            e.detection = d
            out.entities[lineIndex] = e
        }
        return (out, levels)
    }
}
