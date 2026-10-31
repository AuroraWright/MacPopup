import CoreGraphics
import Foundation

/// A grayscale copy of a captured image, for measuring where text actually is.
struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        // Locals, since the closure below can't capture self before every property is set.
        let (width, height) = (image.width, image.height)
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    /// Whether the picture has detail that a copy at half the resolution loses, i.e. it was drawn at
    /// this resolution rather than enlarged (like a window drawn at 1x on a Retina display). Nil when
    /// it has too few edges to tell (e.g. no text in it yet).
    var hasFineDetail: Bool? {
        let halfWidth = width / 2, halfHeight = height / 2
        guard halfWidth > 2, halfHeight > 2 else { return nil }
        // Each half-resolution pixel is the sum of the 2x2 pixels it covers.
        var half = [Int](repeating: 0, count: halfWidth * halfHeight)
        for y in 0..<halfHeight {
            for x in 0..<halfWidth {
                let index = 2 * y * width + 2 * x
                half[y * halfWidth + x] = Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + width]) + Int(pixels[index + width + 1])
            }
        }
        // Enlarged back (bilinear): a full pixel lies a quarter of a half pixel off the nearest one's
        // center, so it takes 3/4 of that one and 1/4 of the next one toward it.
        let neighbors = { (full: Int, count: Int) -> (Int, Int) in
            full % 2 == 0 ? (full / 2, max(full / 2 - 1, 0)) : (full / 2, min(full / 2 + 1, count - 1))
        }
        var edges = 0, lost = 0
        for y in 0..<(2 * halfHeight - 1) {
            let (y0, y1) = neighbors(y, halfHeight)
            for x in 0..<(2 * halfWidth - 1) {
                let (x0, x1) = neighbors(x, halfWidth)
                let row0 = 3 * half[y0 * halfWidth + x0] + half[y0 * halfWidth + x1]
                let row1 = 3 * half[y1 * halfWidth + x0] + half[y1 * halfWidth + x1]
                let enlarged = (3 * row0 + row1) / 64
                let index = y * width + x
                let pixel = Int(pixels[index])
                if abs(Int(pixels[index + 1]) - pixel) + abs(Int(pixels[index + width]) - pixel) > 40 { edges += 1 }
                if abs(enlarged - pixel) > 40 { lost += 1 }
            }
        }
        guard edges >= max(200, width * height / 500) else { return nil }
        // Measured: about 0.75 for text drawn at 2x, under 0.01 for 1x text enlarged by macOS.
        return Double(lost) / Double(edges) > 0.15
    }
}

/// Live Text's boxes for individual characters are estimates: in a line of evenly spaced Japanese
/// text they drift by up to most of a character, and a character it missed is absorbed by its
/// neighbor. Games and most Japanese text put every full-width character in a cell of the same
/// size, so the cells are found from the picture instead (where the gaps between glyphs are) and
/// the recognized characters are assigned to them in order.
enum OCRLayout {
    struct Char {
        var text: String
        /// In image pixels.
        var box: CGRect
    }

    static func isFullWidth(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first?.value else { return false }
        return scalar >= 0x2000 && !(0xFF61...0xFF9F).contains(scalar)
    }

    /// Returns the characters moved to the line's cells, or nil if the line doesn't look like evenly
    /// spaced full-width text (then Live Text's boxes are kept).
    static func snapToGrid(_ chars: [Char], line: CGRect, vertical: Bool, image: GrayImage) -> [Char]? {
        let visible = chars.filter { !$0.text.allSatisfy(\.isWhitespace) }
        guard visible.count >= 3,
              Double(visible.filter { isFullWidth($0.text) }.count) >= Double(visible.count) * 0.7 else { return nil }

        // Along the line (a) and across it (c), in pixels.
        let a0 = Int(vertical ? line.minY : line.minX), a1 = Int(vertical ? line.maxY : line.maxX)
        let c0 = Int(vertical ? line.minX : line.minY), c1 = Int(vertical ? line.maxX : line.maxY)
        let crossSize = c1 - c0
        guard a1 - a0 > 8, crossSize > 4 else { return nil }
        let pixel = { (a: Int, c: Int) -> Int in
            let x = min(max(vertical ? c : a, 0), image.width - 1), y = min(max(vertical ? a : c, 0), image.height - 1)
            return Int(image.pixels[y * image.width + x])
        }

        // Text is usually drawn in one fill color, the lightest or darkest in its line (edges aren't
        // usable: what's behind a game's text box often has more of them than the glyphs).
        var histogram = [Int](repeating: 0, count: 256)
        for a in stride(from: a0, through: a1, by: 2) {
            for c in stride(from: c0, to: c1, by: 2) { histogram[pixel(a, c)] += 1 }
        }
        let total = histogram.reduce(0, +)
        func percentile(_ fraction: Double) -> Int {
            var count = 0
            for (level, n) in histogram.enumerated() {
                count += n
                if Double(count) >= Double(total) * fraction { return level }
            }
            return 255
        }
        let levels = [percentile(0.98), percentile(0.02)]

        var best: (score: Double, pitch: Double, phase: Double, level: Int)?
        for level in levels {
            // Pixels of the text's color in each column across the line (rows for vertical text).
            let ink = { (a: Int, c: Int) in abs(pixel(a, c) - level) <= 32 }
            var raw = [Double](repeating: 0, count: a1 - a0 + 1)
            for a in a0...a1 {
                var count = 0
                for c in c0..<c1 where ink(a, c) { count += 1 }
                raw[a - a0] = Double(count)
            }
            let energy = raw.indices.map { index in
                let range = max(0, index - 1)...min(raw.count - 1, index + 1)
                return raw[range].reduce(0, +) / Double(range.count)
            }
            let mean = energy.reduce(0, +) / Double(energy.count)
            guard mean > 0 else { continue }

            // The cell size and offset whose boundaries fall in the gaps. Full-width cells are about
            // as long as the line is thick.
            let length = Double(a1 - a0)
            var pitch = Double(crossSize) * 0.6
            while pitch <= Double(crossSize) * 1.3 {
                if length / pitch >= 2.5 {
                    var phase = 0.0
                    while phase < pitch {
                        var sum = 0.0, count = 0
                        var t = phase
                        while t <= length {
                            sum += energy[Int(t)]
                            count += 1
                            t += pitch
                        }
                        let score = sum / Double(max(count, 1)) / mean
                        if score < best?.score ?? .infinity { best = (score, pitch, phase, level) }
                        phase += 1
                    }
                }
                pitch += max(0.25, pitch / 400)
            }
        }
        guard let best, best.score < 0.25 else { return nil }
        let length = Double(a1 - a0)

        // Assign the characters to half-cells in order (a half-width character takes one, a full-width
        // one two). A character goes in a cell with text in it, and a cell with text is left empty only
        // when that helps match where Live Text put the characters (the text there wasn't recognized).
        // Live Text's boxes can all be off by most of a cell, so they're compared after removing a
        // common offset, and by their start, since a box that absorbed a missed character grows past it.
        let half = best.pitch / 2
        let origin = Double(a0) + best.phase - best.pitch
        let units = Int(((length - best.phase) / best.pitch + 2).rounded(.up)) * 2
        let widths = chars.map { isFullWidth($0.text) || $0.text.allSatisfy(\.isWhitespace) ? 2 : 1 }
        let starts = chars.map { vertical ? Double($0.box.minY) : Double($0.box.minX) }
        let unitInk = (0..<units).map { unit -> Bool in
            let start = max(Int(origin + Double(unit) * half), a0), end = max(min(Int(origin + Double(unit + 1) * half), a1), start)
            var count = 0
            for a in start..<end {
                for c in stride(from: c0, to: c1, by: 2) where abs(pixel(a, c) - best.level) <= 32 { count += 1 }
            }
            return Double(count) > Double(crossSize) * 0.03 * half / 2
        }
        let n = chars.count
        guard n > 0, units > 0 else { return nil }
        let emptyCost = best.pitch
        let skipInkCost = best.pitch * 0.6
        let inkSkipped = { (from: Int, to: Int) -> Double in
            Double((from..<to).filter { unitInk[$0] }.count) / 2 * skipInkCost
        }

        func assign(offset: Double) -> (cost: Double, units: [Int])? {
            // cost[i][u]: best cost placing characters 0...i with character i starting at unit u.
            var cost = [[Double]](repeating: [Double](repeating: .infinity, count: units + 1), count: n)
            var from = [[Int]](repeating: [Int](repeating: -1, count: units + 1), count: n)
            for i in 0..<n {
                // Full-width characters start on a cell, half-width ones on either half.
                for u in stride(from: 0, through: units - widths[i], by: widths[i]) {
                    var place = abs(starts[i] - offset - (origin + Double(u) * half))
                    if !chars[i].text.allSatisfy(\.isWhitespace), !(u..<(u + widths[i])).contains(where: { unitInk[$0] }) {
                        place += emptyCost
                    }
                    if i == 0 {
                        cost[i][u] = place + inkSkipped(0, u)
                        continue
                    }
                    for previous in 0...u where cost[i - 1][previous].isFinite {
                        let end = previous + widths[i - 1]
                        guard end <= u else { break }
                        let total = cost[i - 1][previous] + inkSkipped(end, u) + place
                        if total < cost[i][u] {
                            cost[i][u] = total
                            from[i][u] = previous
                        }
                    }
                }
            }
            // Text after the last character that it didn't take counts as skipped too.
            let finalCost = cost[n - 1].indices.map { u in cost[n - 1][u] + inkSkipped(min(u + widths[n - 1], units), units) }
            guard var u = finalCost.indices.min(by: { finalCost[$0] < finalCost[$1] }), finalCost[u].isFinite else { return nil }
            let total = finalCost[u]
            var result = [Int](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) {
                result[i] = u
                u = from[i][u]
            }
            return (total, result)
        }
        var assignment: (cost: Double, units: [Int])?
        for step in -18...18 {
            if let candidate = assign(offset: Double(step) * best.pitch / 20), candidate.cost < assignment?.cost ?? .infinity {
                assignment = candidate
            }
        }
        guard let assignment else { return nil }

        // Across the line, keep only the part with strokes (the line box often reaches below them).
        // Only ever shrink it: beyond it are the neighboring lines.
        let crossRange = c0...c1
        let crossEnergy = crossRange.map { c in
            stride(from: a0, through: a1, by: 2).reduce(0) { $0 + (abs(pixel($1, c) - best.level) <= 32 ? 1 : 0) }
        }
        let peak = crossEnergy.max() ?? 0
        var cross = (Double(c0), Double(c1))
        if peak > 0, let first = crossEnergy.firstIndex(where: { Double($0) > Double(peak) * 0.12 }),
           let last = crossEnergy.lastIndex(where: { Double($0) > Double(peak) * 0.12 }),
           last - first >= crossSize / 2 {
            cross = (Double(crossRange.lowerBound + first), Double(crossRange.lowerBound + last + 1))
        }

        return zip(chars, zip(assignment.units, widths)).map { char, placement in
            let start = origin + Double(placement.0) * half
            let size = Double(placement.1) * half
            let box = vertical
                ? CGRect(x: cross.0, y: start, width: cross.1 - cross.0, height: size)
                : CGRect(x: start, y: cross.0, width: size, height: cross.1 - cross.0)
            return Char(text: char.text, box: box)
        }
    }
}
