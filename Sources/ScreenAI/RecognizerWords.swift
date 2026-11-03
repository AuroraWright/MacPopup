import Foundation

// A recognized line's word and symbol geometry (line-relative until toPage):
//   aksara::api_internal::GenerateLineWordEntities (WordBuilder, SPACE word splitter),
//   layout_analyzer::RecomputeSpaceWordBreakBoxes, google_ocr::EstimateWordColorsSymbolAware,
//   aksara::box_utils::BoxRelativeToPageRelativeVec and goodoc::RecomputeBoxFromChildren.

struct RecSymbol {
    var text: String
    var confidence: Float = 0
    var box = RotatedBox()
    /// TextReorderer::IsMirrored: one label whose glyph was mirrored (the symbol is RTL).
    var mirrored = false
}

struct RecWord {
    /// Indices into the line's symbols (whitespace symbols belong to no word).
    var symbols: [Int] = []
    var text = ""
    var confidence: Float = 0
    var box = RotatedBox()
    var brk: WordBreak?
    /// Set by the word builder (0 LTR, 1 RTL).
    var writingDirection: Int?
    var colors: Colors?
}

private func inTable(_ table: [UInt32], _ cp: UInt32) -> Bool {
    var lo = 0, hi = table.count / 2
    while lo < hi {
        let mid = (lo + hi) / 2
        if cp < table[2 * mid] {
            hi = mid
        } else if cp > table[2 * mid + 1] {
            lo = mid + 1
        } else {
            return true
        }
    }
    return false
}

/// Every code point is a separator (Z*).
func isWhitespaceText(_ s: String) -> Bool {
    !s.isEmpty && s.unicodeScalars.allSatisfy { inTable(kSeparator, $0.value) }
}

/// Every code point is punctuation (P*).
func isPunctuationText(_ s: String) -> Bool {
    !s.isEmpty && s.unicodeScalars.allSatisfy { inTable(kPunctuation, $0.value) }
}

/// Bidi R, AL, RLE, RLO.
func hasAnyRtl(_ s: String) -> Bool { s.unicodeScalars.contains { inTable(kBidiRtl, $0.value) } }

/// Bidi L, EN, AN, LRE, LRO.
func hasAnyLtr(_ s: String) -> Bool { s.unicodeScalars.contains { inTable(kBidiLtr, $0.value) } }

/// The conversion after box_util's explicit +-2147500000 clamps.
private func saturatingInt(_ v: Float) -> Int {
    if v >= 2_147_500_032 { return Int(Int32.max) }
    if v <= -2_147_500_032 { return Int(Int32.min) }
    return Int(v)
}

private let recDegToRad: Float = 0.0174532924

private func unionStart(_ b: RotatedBox) -> RotatedBox { RotatedBox(left: b.left, top: b.top, width: 1, height: 1) }

/// box_util::ExpandBoxToContainBox(src, dst) for integer boxes.
func expandBoxToContainBox(_ src: RotatedBox, _ dst: inout RotatedBox) {
    var w = dst.width, h = dst.height
    if w < 1 || h < 1 {
        dst = src
        dst.angle = normalizeAngle(src.angle)
        return
    }
    let j = normalizeAngle(src.angle)
    let k = normalizeAngle(dst.angle)
    if j == 0 && k == 0 {
        var left = dst.left
        if left - src.left >= 1 {
            w += left - src.left
            dst.width = w
            left = src.left
            dst.left = left
        }
        var top = dst.top
        if top - src.top >= 1 {
            h += top - src.top
            dst.height = h
            top = src.top
            dst.top = top
        }
        if src.width + src.left > w + left { dst.width = src.width + src.left - left }
        if src.height + src.top > h + top { dst.height = src.height + src.top - top }
        return
    }
    // src in dst's frame (turned by -k about dst's origin)
    let ox = Float(dst.left), oy = Float(dst.top)
    let sx = Float(src.left), sy = Float(src.top)
    let sc1 = sinCos(k * -recDegToRad)
    let s1 = sc1.sin, c1 = sc1.cos
    let ty = (s1 * (sx - ox) + oy) + c1 * (sy - oy)
    let L = saturatingInt(roundf((c1 * (sx - ox) + ox) - s1 * (sy - oy)))
    let T = saturatingInt(roundf(ty))
    let m = normalizeAngle(src.angle - k)
    var p0x: Float, p0y: Float, p1x: Float, p1y: Float, p2x: Float, p2y: Float, p3x: Float, p3y: Float
    if m == 0 {
        p0x = Float(L)
        p0y = Float(T)
        p1x = Float(src.width + L)
        p1y = Float(T)
        p2x = p1x
        p2y = Float(src.height + T)
        p3x = Float(L)
        p3y = p2y
    } else {
        let sc2 = sinCos(m * recDegToRad)
        let s2 = sc2.sin, c2 = sc2.cos
        let fw = Float(src.width), fh = Float(src.height)
        p0x = Float(L)
        p0y = Float(T)
        p1x = c2 * fw + Float(L)
        p1y = s2 * fw + Float(T)
        let ch = c2 * fh
        p2x = p1x - s2 * fh
        p2y = p1y + ch
        p3x = Float(L) - s2 * fh
        p3y = ch + Float(T)
    }
    let fx = Float(dst.width + dst.left), fy = Float(dst.height + dst.top)
    func mn(_ a: Float, _ b: Float) -> Float { a > b ? b : a }
    func mx(_ a: Float, _ b: Float) -> Float { a > b ? a : b }
    var minx = mn(ox, p0x), miny = mn(oy, p0y)
    var maxx = mx(p0x, fx), maxy = mx(p0y, fy)
    minx = mn(minx, p1x)
    miny = mn(miny, p1y)
    maxx = mx(p1x, maxx)
    maxy = mx(p1y, maxy)
    minx = mn(minx, p2x)
    miny = mn(miny, p2y)
    maxx = mx(p2x, maxx)
    maxy = mx(p2y, maxy)
    minx = mn(minx, p3x)
    miny = mn(miny, p3y)
    maxx = mx(p3x, maxx)
    maxy = mx(p3y, maxy)
    let sc3 = sinCos(k * recDegToRad)
    let s3 = sc3.sin, c3 = sc3.cos
    let d = minx - ox
    let ny = (s3 * d + oy) + c3 * (miny - oy)
    dst.width = saturatingInt(roundf(maxx)) - saturatingInt(roundf(minx))
    dst.height = saturatingInt(roundf(maxy)) - saturatingInt(roundf(miny))
    dst.left = saturatingInt(roundf((c3 * d + ox) - s3 * (miny - oy)))
    dst.top = saturatingInt(roundf(ny))
}

/// goodoc::RecomputeBoxFromChildren for rotated children (FindContainingBoxWithAverageAngle).
func containingBoxWithAverageAngle(_ boxes: [RotatedBox]) -> RotatedBox {
    var acc = RotatedBox()
    if boxes.isEmpty { return acc }
    var angle: Float
    let n = boxes.count
    if n == 1 {
        angle = normalizeAngle(boxes[0].angle)
    } else {
        var s: Float = 0, c: Float = 0
        for b in boxes {
            let sc = sinCos(b.angle * recDegToRad)
            s += sc.sin
            c += sc.cos
        }
        if abs(c) > 1e-5 || abs(s) > 1e-5 {
            if abs(s) > 1e-5 || c > Float(n) * -0.99999 {
                angle = normalizeAngle(atan2f(s, c) * 57.2957763671875)
            } else {
                angle = 180
            }
        } else {
            angle = boxes[0].angle
            for b in boxes where abs(b.angle) < abs(angle) { angle = b.angle }
        }
    }
    acc.angle = angle
    for b in boxes {
        if acc.width < 1 || acc.height < 1 {
            acc.left = b.left
            acc.top = b.top
            acc.width = 1
            acc.height = 1
        }
        expandBoxToContainBox(b, &acc)
    }
    return acc
}

/// A line-relative box to a page box (BoxRelativeToPageRelativeVec, rounded).
func toPage(_ lineBox: RotatedBox, _ rel: RotatedBox) -> RotatedBox {
    let cx = Double(lineBox.left), cy = Double(lineBox.top)
    let px = cx + Double(rel.left), py = cy + Double(rel.top)
    let dx = px - cx, dy = py - cy
    let rad = Double(lineBox.angle) * 3.14159265358979311600 / 180.0
    let sc = sinCos(rad)
    let sn = sc.sin, cs = sc.cos
    let x = cx + (cs * dx - sn * dy)
    let y = cy + (sn * dx + cs * dy)
    var out = rel
    out.left = Int(x.rounded(.toNearestOrAwayFromZero))
    out.top = Int(y.rounded(.toNearestOrAwayFromZero))
    // aksara::box_utils::NormalizedAngle
    var a = fmod(Double(Float(lineBox.angle + rel.angle)), 360.0)
    a = a > 180 ? a + -360 : (a > -180 ? a : a + 360)
    out.angle = Float(a)
    return out
}

/// WordBuilder over the line's symbols (in logical order); `lineText` is their concatenation.
func buildWords(_ symbols: [RecSymbol], _ lineText: String) -> [RecWord] {
    // SplitBySpace: the byte offsets where a space-delimited token ends.
    let bytes = Array(lineText.utf8)
    var tokenEnds = Set<Int>()
    for i in bytes.indices where bytes[i] != 0x20 && (i + 1 == bytes.count || bytes[i + 1] == 0x20) {
        tokenEnds.insert(i + 1)
    }
    var words: [RecWord] = []
    var cur = -1, last = -1
    var rtl = false, ltr = false
    func finalize() {
        var w = words[cur]
        if w.brk == nil { w.brk = WordBreak() }
        w.brk!.type = 1
        if rtl {
            w.writingDirection = 1
        } else if ltr {
            w.writingDirection = 0
        }
        var sum = 0.0
        for si in w.symbols {
            w.text += symbols[si].text
            sum += Double(symbols[si].confidence)
        }
        w.box = unionStart(symbols[w.symbols[0]].box)
        for si in w.symbols { expandBoxToContainBox(symbols[si].box, &w.box) }
        w.confidence = Float(sum / Double(w.symbols.count))
        words[cur] = w
        if !w.text.isEmpty { last = cur }
        cur = -1
    }
    // Whitespace after the last word gives it no break (e.g. a recognized trailing space).
    var end = symbols.count
    while end > 0 && isWhitespaceText(symbols[end - 1].text) { end -= 1 }
    var offset = 0
    for i in 0..<end {
        let s = symbols[i]
        offset += s.text.utf8.count
        if cur < 0 && last >= 0 && words[last].brk == nil { words[last].brk = WordBreak() }
        if isWhitespaceText(s.text) {
            if cur >= 0 { finalize() }
            if last >= 0 {
                var b = words[last].brk!
                b.type = b.type == 2 ? 3 : 2
                if b.box == nil { b.box = RotatedBox() }
                expandBoxToContainBox(s.box, &b.box!)
                words[last].brk = b
            }
            continue
        }
        if cur < 0 {
            words.append(RecWord())
            cur = words.count - 1
            rtl = false
            ltr = false
        }
        let punct = isPunctuationText(s.text)
        rtl = rtl || (hasAnyRtl(s.text) && !punct)
        ltr = ltr || (hasAnyLtr(s.text) && !punct)
        words[cur].symbols.append(i)
        if tokenEnds.contains(offset) { finalize() }
    }
    if cur >= 0 { finalize() }
    return words
}

/// RecomputeSpaceWordBreakBoxes(words, layout, true) for angle-0 line-relative words; `vertical`: the line is written
/// top-to-bottom.
func recomputeSpaceWordBreakBoxes(_ symbols: [RecSymbol], vertical: Bool, _ words: inout [RecWord]) {
    for i in 0..<max(words.count - 1, 0) {
        let b = words[i + 1]
        guard let brk = words[i].brk, brk.type == 2 || brk.type == 3, brk.box != nil, !words[i].symbols.isEmpty,
              !b.symbols.isEmpty
        else { continue }
        let la = symbols[words[i].symbols.last!].box
        let fb = symbols[b.symbols.first!].box
        var u = unionStart(la)
        expandBoxToContainBox(la, &u)
        expandBoxToContainBox(fb, &u)
        // LineLength along the writing direction of the line (top-to-bottom lines measure heights, although their
        // line-relative boxes are horizontal here).
        let gap = vertical ? u.height - la.height - fb.height : u.width - la.width - fb.width
        let len = max(1, max(0, gap))
        if vertical {
            words[i].brk!.box!.top = words[i].box.top + words[i].box.height
            words[i].brk!.box!.height = len
        } else {
            words[i].brk!.box!.left = words[i].box.left + words[i].box.width
            words[i].brk!.box!.width = len
        }
    }
}

// MARK: - Word colors

/// ocr::photo::line_metrics_util::ComputeOtsuThresholdOfVector: the threshold, and the count at or below it.
private func otsu(_ hist: [Int], _ n: Int) -> (threshold: Int, below: Int) {
    var cum = [Int](repeating: 0, count: 256), mom = [Int](repeating: 0, count: 256)
    cum[0] = hist[0]
    for i in 1..<256 {
        cum[i] = cum[i - 1] + hist[i]
        mom[i] = mom[i - 1] + hist[i] * i
    }
    let total = cum[255], totalMom = mom[255]
    let N = Float(n <= 1 ? 1 : n)
    var best: Float = -1
    var t = -1
    for i in 0..<256 {
        let c = cum[i]
        if c == 0 || c == total { continue }
        let rest = totalMom - mom[i]
        let d = Float(Int32(truncatingIfNeeded: mom[i] / c)) - Float(Int32(truncatingIfNeeded: rest / (total - c)))
        let s = d * (((Float(c) / N) * (Float(rest) / N)) * d)
        if s > best {
            best = s
            t = i
        }
    }
    return (t, t < 0 ? 0 : cum[t])
}

/// Sampling steps for a region of `count` pixels: doubles the x, then the y step, ... until <= 5000 samples.
private func steps(_ count: Int) -> (Int, Int) {
    var xs = 1, ys = 1
    if count < 5001 { return (xs, ys) }
    var i = 0
    let fc = Float(UInt32(truncatingIfNeeded: count))
    repeat {
        ys <<= (i & 1)
        xs <<= (i & 1 == 0 ? 1 : 0)
        i += 1
    } while fc / Float(xs * ys) > 5000
    return (xs, ys)
}

/// EstimateWordColorsSymbolAware on the (unscaled) gray line image.
func estimateWordColors(_ img: GrayImage, _ symbols: [RecSymbol], _ words: inout [RecWord]) {
    let W = img.width, H = img.height
    func clamp(_ b: RotatedBox) -> (top: Int, bottom: Int, left: Int, right: Int) {
        func c(_ v: Int, _ hi: Int) -> Int { v < 0 ? 0 : min(v, hi) }
        return (c(b.top, H - 1), c(b.top + b.height, H - 1), c(b.left, W - 1), c(b.left + b.width, W - 1))
    }
    let none = [(Int, Int)](repeating: (-1, -1), count: 256)
    for wi in words.indices {
        let word = words[wi]
        var bgHist = [Int](repeating: 0, count: 256), fgHist = [Int](repeating: 0, count: 256)
        var lists = [[(Int, Int)]](repeating: none, count: 4)
        var fgCoords = none
        let cb = clamp(word.box)
        let m = Float(word.box.height) * 0.3
        func sample(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ count: Int, _ hist: inout [Int],
                    _ coords: inout [(Int, Int)]) -> Int {
            let (xs, ys) = steps(count)
            var n = 0
            if y1 <= y0 || x1 <= x0 { return 0 }
            img.data.withUnsafeBufferPointer { px in
                hist.withUnsafeMutableBufferPointer { h in
                    coords.withUnsafeMutableBufferPointer { c in
                        for y in stride(from: y0, to: y1, by: ys) {
                            for x in stride(from: x0, to: x1, by: xs) {
                                let v = Int(px[y * W + x])
                                h[v] += 1
                                c[v] = (x, y)
                                n += 1
                            }
                        }
                    }
                }
            }
            return n
        }
        // above
        let a0 = max(0, Int(Float(cb.top) - m))
        var bgN = sample(cb.left, cb.right, a0, cb.top, (cb.top - a0) * (cb.right - cb.left), &bgHist, &lists[1])
        // below
        let b1 = min(H, Int(m + Float(cb.bottom)))
        bgN += sample(cb.left, cb.right, cb.bottom + 1, b1, (b1 - (cb.bottom + 1)) * (cb.right - cb.left), &bgHist,
                      &lists[2])
        // right, up to this word's break
        var lim = W
        if let bb = word.brk?.box { lim = min(lim, bb.left + bb.width) }
        lim = min(lim, Int(m + Float(cb.right)))
        bgN += sample(cb.right + 1, lim, cb.top, cb.bottom, (lim - (cb.right + 1)) * (cb.bottom - cb.top), &bgHist,
                      &lists[3])
        // left, from the previous word's break
        var prev = 0
        if wi > 0, let pb = words[wi - 1].brk?.box { prev = max(0, pb.left) }
        let lo = max(prev, Int(Float(cb.left) - m))
        bgN += sample(lo, cb.left, 0, cb.bottom, (cb.left - lo) * cb.bottom, &bgHist, &lists[2])
        let bgRegions = bgN
        if bgN == 0 {
            bgN = sample(cb.left, cb.right, cb.top, cb.bottom, (cb.right - cb.left) * (cb.bottom - cb.top), &bgHist,
                         &lists[0])
        }
        var fgN = 0
        for si in word.symbols {
            let c = clamp(symbols[si].box)
            fgN += sample(c.left, c.right, c.top, c.bottom, (c.right - c.left) * (c.bottom - c.top), &fgHist, &fgCoords)
        }
        let all = (0..<256).map { bgHist[$0] + fgHist[$0] }
        let T = otsu(all, fgN + bgN).threshold
        var bgBelow = 0, fgBelow = 0
        if T >= 0 {
            for v in 0...min(T, 255) {
                bgBelow += bgHist[v]
                fgBelow += fgHist[v]
            }
        }
        let fbg = Float(bgN)
        var dark = Float(bgN) / 2 < Float(bgBelow)
        if bgRegions != 0 && fbg * 0.3 < Float(bgBelow) && fbg * 0.6 >= Float(bgBelow) {
            var wordHist = [Int](repeating: 0, count: 256)
            var unused = none
            let cnt = sample(cb.left, cb.right, cb.top, cb.bottom, (cb.right - cb.left) * (cb.bottom - cb.top), &wordHist,
                             &unused)
            let (T2, below2) = otsu(wordHist, cnt)
            var fgBelow2 = 0
            if T2 >= 0 {
                for v in 0...min(T2, 255) { fgBelow2 += fgHist[v] }
            }
            let r1 = Float(below2) / Float(cnt)
            let r2 = Float(fgBelow2) / Float(fgN)
            dark = r1 >= r2 + 0.1 || (dark && r1 > r2 + -0.1)
        }
        let nb = dark ? bgBelow : bgN - bgBelow
        let nf = dark ? fgN - fgBelow : fgBelow
        let hb = nb / 2, hf = nf / 2
        var cbg = 0, cfg = 0, bg = -1, fg = -1
        var bgSamples: [(Int, Int)] = []
        var fgSample = (-1, -1)
        for v in 0..<256 {
            if dark {
                if v > T { cfg += fgHist[v] } else { cbg += bgHist[v] }
            } else {
                if v > T { cbg += bgHist[v] } else { cfg += fgHist[v] }
            }
            if cbg >= hb && bg == -1 {
                for l in lists where l[v].0 != -1 && l[v].1 != -1 { bgSamples.append(l[v]) }
                bg = v
            }
            if cfg >= hf && fg == -1 {
                fgSample = fgCoords[v]
                fg = v
            }
        }
        if bg == -1 || fg == -1 { continue }
        var colors = Colors()
        colors.foregroundGray = fg
        colors.backgroundGray = bg
        colors.foregroundGrayThreshold = T
        colors.foregroundSamples = [fgSample]
        colors.backgroundSamples = bgSamples
        words[wi].colors = colors
    }
}
