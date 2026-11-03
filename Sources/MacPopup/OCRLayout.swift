import CoreGraphics
import Foundation

/// A line of recognized text. Boxes are normalized to the image (0–1, origin at the top left).
struct RecognizedLine {
    var text: String
    var box: CGRect
    /// Its words in order (for Japanese, usually single characters).
    var words: [(text: String, box: CGRect)]
}

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
        /// In image pixels, or window points in a Line.
        var box: CGRect
    }

    /// A recognized line, in window points.
    struct Line {
        var text: String
        var box: CGRect
        var vertical: Bool
        var chars: [Char]
    }

    /// The lines in reading order: rows from the top, each from the left, or in vertical text (most of the lines)
    /// columns from the right, each from the top. Live Text and OneOCR don't always give them so (OneOCR lists
    /// vertical columns from the left), and the page matches WebSocket lines through them in this order. Screen AI's
    /// lines keep the order its layout analysis gives them.
    static func inReadingOrder(_ lines: [Line]) -> [Line] {
        let vertical = lines.filter(\.vertical).count * 2 > lines.count
        // Across the rows (top to bottom, or right to left), and along them.
        let across = { (box: CGRect) in vertical ? (start: -box.maxX, end: -box.minX) : (start: box.minY, end: box.maxY) }
        let along = { (box: CGRect) in vertical ? box.minY : box.minX }
        var rows: [(start: CGFloat, end: CGFloat, lines: [Line])] = []
        for line in lines.sorted(by: { across($0.box).start < across($1.box).start }) {
            let extent = across(line.box)
            // In the last row when that covers at least half of the line across.
            if let row = rows.last, min(extent.end, row.end) - max(extent.start, row.start) >= (extent.end - extent.start) / 2 {
                rows[rows.count - 1].lines.append(line)
                rows[rows.count - 1].end = max(row.end, extent.end)
            } else {
                rows.append((extent.start, extent.end, [line]))
            }
        }
        return rows.flatMap { row in row.lines.sorted { along($0.box) < along($1.box) } }
    }

    /// Screen AI's lines in its reading order, except that a line the engine split where it goes on along its row (e.g.
    /// "…分厚い、" and "絆創", whose furigana made it a block of its own) is kept together: the layout analysis sometimes
    /// puts the second part after the lines below it, and the page matches WebSocket lines through the lines in order.
    static func keepingRowsTogether(_ lines: [Line]) -> [Line] {
        var rest = lines
        var ordered: [Line] = []
        while !rest.isEmpty {
            var line = rest.removeFirst()
            ordered.append(line)
            while let next = rest.firstIndex(where: { continues($0, line) }) {
                line = rest.remove(at: next)
                ordered.append(line)
            }
        }
        return ordered
    }

    /// Whether `next` starts where `line` ends, on the same row and at about the same size.
    private static func continues(_ next: Line, _ line: Line) -> Bool {
        guard next.vertical == line.vertical else { return false }
        let vertical = line.vertical
        let end = vertical ? line.box.maxY : line.box.maxX
        let nextStart = vertical ? next.box.minY : next.box.minX
        let across = { (box: CGRect) in vertical ? (box.minX, box.maxX) : (box.minY, box.maxY) }
        let (near, far) = across(line.box), (nextNear, nextFar) = across(next.box)
        let size = far - near, nextSize = nextFar - nextNear
        guard size > 0, nextSize > 0 else { return false }
        return min(far, nextFar) - max(near, nextNear) >= min(size, nextSize) / 2
            && max(size, nextSize) <= min(size, nextSize) * 1.5
            && nextStart >= end - size / 2 && nextStart <= end + size
    }

    /// A line with one box per character, in window points. The engines give boxes per word (Live Text: single characters
    /// for Japanese; meikiocr and Screen AI: always characters); longer words are divided evenly, and the spaces between
    /// words fill the gaps. Lines of evenly spaced full-width text are then snapped to their cells (see
    /// snapToGrid).
    /// - Parameters:
    ///   - image: The image that was read, whose pixels the line's normalized boxes refer to.
    ///   - toWindow: Converts a box normalized to `image` to window points.
    static func layOut(_ line: RecognizedLine, image: GrayImage?, size: CGSize, toWindow: (CGRect) -> CGRect) -> Line {
        // Work in image pixels, which keep the aspect ratio.
        let toPixels = { (box: CGRect) in
            CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        let lineBox = toPixels(line.box)
        let wordBoxes = line.words.map { toPixels($0.box) }
        let isVertical: Bool = {
            if let first = wordBoxes.first, let last = wordBoxes.last, wordBoxes.count > 1 {
                return abs(last.midY - first.midY) > abs(last.midX - first.midX)
            }
            return lineBox.height > lineBox.width * 1.5
        }()
        var chars: [Char] = []
        func add(_ text: String, in box: CGRect) {
            let characters = text.map(String.init)
            guard !characters.isEmpty else { return }
            let count = CGFloat(characters.count)
            for (index, character) in characters.enumerated() {
                let i = CGFloat(index)
                let rect = isVertical
                    ? CGRect(x: box.minX, y: box.minY + box.height * i / count, width: box.width, height: box.height / count)
                    : CGRect(x: box.minX + box.width * i / count, y: box.minY, width: box.width / count, height: box.height)
                chars.append(Char(text: character, box: rect))
            }
        }
        if line.words.isEmpty {
            add(line.text, in: lineBox)
        } else {
            var remaining = Substring(line.text)
            var previous: CGRect?
            for (word, box) in zip(line.words, wordBoxes) {
                if let range = remaining.range(of: word.text) {
                    // Text between words (spaces) goes in the gap between their boxes.
                    let between = String(remaining[remaining.startIndex..<range.lowerBound])
                    if !between.isEmpty, let previous {
                        let gap = isVertical
                            ? CGRect(x: box.minX, y: previous.maxY, width: box.width, height: max(1, box.minY - previous.maxY))
                            : CGRect(x: previous.maxX, y: box.minY, width: max(1, box.minX - previous.maxX), height: box.height)
                        add(between, in: gap)
                    }
                    remaining = remaining[range.upperBound...]
                }
                add(word.text, in: box)
                previous = box
            }
        }
        if let image, let snapped = snapToGrid(chars, line: lineBox, vertical: isVertical, image: image) {
            chars = snapped
        }
        func toWindowFromPixels(_ box: CGRect) -> CGRect {
            toWindow(CGRect(x: box.minX / size.width, y: box.minY / size.height, width: box.width / size.width, height: box.height / size.height))
        }
        return Line(
            text: chars.map(\.text).joined(),
            box: toWindow(line.box),
            vertical: isVertical,
            chars: chars.map { Char(text: $0.text, box: toWindowFromPixels($0.box)) }
        )
    }

    static func isFullWidth(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first?.value else { return false }
        return scalar >= 0x2000 && !(0xFF61...0xFF9F).contains(scalar)
    }

    /// Returns the characters moved to the line's cells, or nil if the line doesn't look like full-width
    /// text (then the engine's boxes are kept). When the cells can't be found (e.g. the glyphs are too
    /// unevenly spaced, or the engine's line box takes in too much else), the boxes are only narrowed
    /// across the line to where the text's strokes are.
    ///
    /// Whitespace takes no cell of its own: OCR puts spaces between words where the text has none (OneOCR
    /// around an ellipsis, e.g. "「 …… 厄介"), and a blank cell is skipped anyway. It goes in the gap
    /// between the cells of the characters around it, which is empty where they touch.
    static func snapToGrid(_ chars: [Char], line: CGRect, vertical: Bool, image: GrayImage) -> [Char]? {
        let isBlank = { (char: Char) in char.text.allSatisfy(\.isWhitespace) }
        guard let snapped = snapVisible(chars.filter { !isBlank($0) }, line: line, vertical: vertical, image: image) else { return nil }
        var result: [Char] = []
        var next = 0
        var index = chars.startIndex
        while index < chars.endIndex {
            guard isBlank(chars[index]) else {
                result.append(snapped[next])
                next += 1
                index += 1
                continue
            }
            // A run of whitespace shares the gap evenly.
            let run = chars[index...].prefix(while: isBlank)
            let before = next > 0 ? snapped[next - 1].box : nil
            let after = next < snapped.count ? snapped[next].box : nil
            let neighbor = (before ?? after)!
            let start = before.map { vertical ? $0.maxY : $0.maxX } ?? (vertical ? neighbor.minY : neighbor.minX)
            let end = max(start, after.map { vertical ? $0.minY : $0.minX } ?? start)
            let size = (end - start) / CGFloat(run.count)
            for (offset, char) in run.enumerated() {
                let a = start + CGFloat(offset) * size
                let box = vertical
                    ? CGRect(x: neighbor.minX, y: a, width: neighbor.width, height: size)
                    : CGRect(x: a, y: neighbor.minY, width: size, height: neighbor.height)
                result.append(Char(text: char.text, box: box))
            }
            index += run.count
        }
        return result
    }

    /// snapToGrid for characters without whitespace.
    private static func snapVisible(_ chars: [Char], line: CGRect, vertical: Bool, image: GrayImage) -> [Char]? {
        guard chars.count >= 3,
              Double(chars.filter { isFullWidth($0.text) }.count) >= Double(chars.count) * 0.7 else { return nil }

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

        // Where the text's strokes are across the line: the engines' line boxes often reach well past
        // them (Live Text's up to twice their thickness), and can take in the furigana over the line or
        // what's next to it. Those are beyond a gap without ink, which the line's own glyphs together
        // never leave, so the part with the most ink between such gaps is the line's.
        func strokes(level: Int) -> (first: Int, last: Int)? {
            let energy = (c0...c1).map { c in
                stride(from: a0, through: a1, by: 2).reduce(0) { $0 + (abs(pixel($1, c) - level) <= 32 ? 1 : 0) }
            }
            let peak = Double(energy.max() ?? 0)
            guard peak > 0 else { return nil }
            var parts: [ClosedRange<Int>] = []
            var start: Int?
            for (index, value) in energy.enumerated() {
                if Double(value) > peak * 0.03 {
                    if start == nil { start = index }
                } else if let first = start {
                    parts.append(first...(index - 1))
                    start = nil
                }
            }
            if let start { parts.append(start...(energy.count - 1)) }
            let ink = { (part: ClosedRange<Int>) in part.reduce(0) { $0 + energy[$1] } }
            guard let part = parts.max(by: { ink($0) < ink($1) }),
                  let first = part.first(where: { Double(energy[$0]) > peak * 0.12 }),
                  let last = part.last(where: { Double(energy[$0]) > peak * 0.12 }),
                  last - first >= crossSize / 3 else { return nil }
            return (c0 + first, c0 + last)
        }

        // Without cells: the boxes across the line cover the strokes of the text's color, which is the one
        // that doesn't fill the whole line box (the other one is the background's).
        func narrowed() -> [Char]? {
            guard let band = levels.compactMap({ strokes(level: $0) }).min(by: { $0.last - $0.first < $1.last - $1.first }),
                  band.last - band.first < crossSize * 9 / 10 else { return nil }
            return chars.map { char in
                var box = char.box
                if vertical {
                    box.origin.x = CGFloat(band.first)
                    box.size.width = CGFloat(band.last + 1 - band.first)
                } else {
                    box.origin.y = CGFloat(band.first)
                    box.size.height = CGFloat(band.last + 1 - band.first)
                }
                return Char(text: char.text, box: box)
            }
        }

        // How many cells the characters take at least (a run of dots, dashes or tildes one).
        var cells = 0.0
        for (index, char) in chars.enumerated() {
            let kind = lookalikeKind(char.text)
            if kind == nil || index == 0 || kind != lookalikeKind(chars[index - 1].text) { cells += isFullWidth(char.text) ? 1 : 0.5 }
        }
        // The line box only reaches the ink, which punctuation at either end has in a part of its cell.
        let isPunctuation = { (char: Char) in char.text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) } }
        cells -= 0.7 * Double([chars.first, chars.last].compactMap { $0 }.filter(isPunctuation).count)

        var best: (score: Double, pitch: Double, phase: Double, level: Int)?
        for level in levels {
            // Pixels of the text's color in each column across the line (rows for vertical text), only
            // where its strokes are.
            let ink = { (a: Int, c: Int) in abs(pixel(a, c) - level) <= 32 }
            let band = strokes(level: level).map { $0.first...$0.last } ?? c0...(c1 - 1)
            var raw = [Double](repeating: 0, count: a1 - a0 + 1)
            for a in a0...a1 {
                var count = 0
                for c in band where ink(a, c) { count += 1 }
                raw[a - a0] = Double(count)
            }
            let energy = raw.indices.map { index in
                let range = max(0, index - 1)...min(raw.count - 1, index + 1)
                return raw[range].reduce(0, +) / Double(range.count)
            }
            let mean = energy.reduce(0, +) / Double(energy.count)
            guard mean > 0 else { continue }
            // The text's color is in every character that was read. Semi-transparent text takes on the
            // brightness of what's behind it, so where that changes along the line, the color of some of its
            // characters is only the background's elsewhere: their boxes have a glyph, of another color.
            // Thin glyphs (ー, 。) have less of it than most characters, but not just stray pixels, and a
            // character without it but without much of a glyph either is one whose box missed it.
            let spans = chars.map { char -> ClosedRange<Int>? in
                let start = max(Int(vertical ? char.box.minY : char.box.minX), a0)
                let end = min(Int(vertical ? char.box.maxY : char.box.maxX), a1)
                return start <= end ? start...end : nil
            }
            let amounts = spans.map { span in span.map { raw[($0.lowerBound - a0)...($0.upperBound - a0)].reduce(0, +) } ?? 0 }
            let typical = amounts.sorted()[amounts.count / 2]
            let missing = amounts.indices.filter { amounts[$0] <= typical * 0.05 }
            guard Double(missing.count) <= Double(chars.count) * 0.1 else { continue }
            if !missing.isEmpty {
                // Pixels away from the brightness most of the box has.
                let glyph = spans.map { span -> Double in
                    guard let span else { return 0 }
                    var values: [Int] = []
                    for a in span { for c in band { values.append(pixel(a, c)) } }
                    let median = values.sorted()[values.count / 2]
                    return Double(values.filter { abs($0 - median) > 32 }.count)
                }
                let typicalGlyph = glyph.sorted()[glyph.count / 2]
                guard !missing.contains(where: { glyph[$0] >= typicalGlyph * 0.5 }) else { continue }
            }

            // The cell size and offset whose boundaries fall in the gaps. Full-width cells are about
            // as long as the text is thick (kana and flat kanji like 一 less), and the line has at least
            // about as many cells as characters (fewer only where a run of dots or dashes was read as
            // more characters than are drawn): a size of several cells can fit the gaps too.
            let length = Double(a1 - a0)
            let thickness = Double(band.count)
            var pitch = thickness * 0.6
            while pitch <= min(thickness * 1.5, length / cells * 1.2) {
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
        guard let best, best.score < 0.25 else { return narrowed() }
        let length = Double(a1 - a0)

        // Assign the characters to half-cells in order (a half-width character takes one, a full-width
        // one two). A character goes in a cell with text in it, and a cell with text is left empty only
        // when that helps match where Live Text put the characters (the text there wasn't recognized).
        // Live Text's boxes can all be off by most of a cell, so they're compared after removing a
        // common offset, and by their start, since a box that absorbed a missed character grows past it.
        let half = best.pitch / 2
        let origin = Double(a0) + best.phase - best.pitch
        let units = Int(((length - best.phase) / best.pitch + 2).rounded(.up)) * 2
        let widths = chars.map { isFullWidth($0.text) ? 2 : 1 }
        let starts = chars.map { vertical ? Double($0.box.minY) : Double($0.box.minX) }
        let ends = chars.map { vertical ? Double($0.box.maxY) : Double($0.box.maxX) }
        let strokeBand = strokes(level: best.level)
        let band = strokeBand.map { $0.first...$0.last } ?? c0...(c1 - 1)
        let unitInk = (0..<units).map { unit -> Bool in
            let start = max(Int(origin + Double(unit) * half), a0), end = max(min(Int(origin + Double(unit + 1) * half), a1), start)
            var count = 0
            for a in start..<end {
                for c in stride(from: band.lowerBound, through: band.upperBound, by: 2) where abs(pixel(a, c) - best.level) <= 32 { count += 1 }
            }
            // Thin glyphs (an ellipsis's dots, a closing bracket) have little ink in a half-cell.
            return Double(count) > Double(band.count) * 0.015 * half / 2
        }
        guard !chars.isEmpty, units > 0 else { return narrowed() }
        // A run of dots, dashes or tildes is one item, which takes from one cell up to one per character:
        // Live Text often reads an ellipsis or a long dash as more characters than the cells it's drawn
        // in (e.g. "……" as seven "・"). As when matching WebSocket lines (see web/src/lib/ocr-layer.js).
        var items: [Range<Int>] = []
        for index in chars.indices {
            if let last = items.last, let kind = lookalikeKind(chars[index].text), kind == lookalikeKind(chars[last.lowerBound].text) {
                items[items.count - 1] = last.lowerBound..<(index + 1)
            } else {
                items.append(index..<(index + 1))
            }
        }
        let m = items.count
        let emptyCost = best.pitch
        let skipInkCost = best.pitch * 0.6
        // Full-width characters half a cell off the grid: a half-width character puts the ones before or
        // after it there (e.g. "「8時"), so they can be, but only next to one, and starting off the grid
        // costs a little (lines without half-width characters stay on it). The grid fits most of the line,
        // so the characters off it before a half-width one are fewer than half of them.
        let offGridCost = best.pitch * 0.3
        let inkSkipped = { (from: Int, to: Int) -> Double in
            from < to ? Double((from..<to).filter { unitInk[$0] }.count) / 2 * skipInkCost : 0
        }

        func assign(offset: Double) -> (cost: Double, placements: [(start: Int, width: Int)])? {
            // cost[i][e * 3 + p]: best cost placing items 0...i with item i ending at unit e, where p is 0 on
            // the grid, 1 off it before a half-width character and 2 off it after one (see offGridCost).
            var cost = [[Double]](repeating: [Double](repeating: .infinity, count: (units + 1) * 3), count: m)
            var from = [[(state: Int, start: Int)]](repeating: [(state: Int, start: Int)](repeating: (-1, -1), count: (units + 1) * 3), count: m)
            // How many items up to `item` are off the grid on the best way to its `state`: fewer than half.
            func isMinority(_ item: Int, _ state: Int) -> Bool {
                var count = 0, item = item, state = state
                while item >= 0, state >= 0, state % 3 != 0 {
                    count += 1
                    state = from[item][state].state
                    item -= 1
                }
                return count * 2 < m
            }
            for i in 0..<m {
                let first = items[i].lowerBound
                // Full-width characters take whole cells, half-width ones half.
                let step = widths[first]
                for width in stride(from: step, through: step * items[i].count, by: step) {
                    for start in stride(from: 0, through: units - width, by: 1) {
                        let end = start + width
                        var place = abs(starts[first] - offset - (origin + Double(start) * half))
                        if !(start..<(start + width)).contains(where: { unitInk[$0] }) {
                            place += emptyCost
                        }
                        // How many cells a run takes is otherwise a tie when its cells look alike (e.g.
                        // an ellipsis's dots are too thin to count as text): then it ends where it was read.
                        if items[i].count > 1 {
                            place += abs(ends[items[i].upperBound - 1] - offset - (origin + Double(end) * half)) * 0.01
                        }
                        func consider(_ total: Double, _ p: Int, from previous: Int) {
                            let state = end * 3 + p
                            if total < cost[i][state] {
                                cost[i][state] = total
                                from[i][state] = (previous, start)
                            }
                        }
                        let offGrid = step == 2 && start % 2 == 1
                        if i == 0 {
                            consider(place + inkSkipped(0, start) + (offGrid ? offGridCost : 0), offGrid ? 1 : 0, from: -1)
                            continue
                        }
                        for previousEnd in 0...start {
                            for p in 0..<3 {
                                let state = previousEnd * 3 + p
                                guard cost[i - 1][state].isFinite else { continue }
                                let total = cost[i - 1][state] + inkSkipped(previousEnd, start) + place
                                let adjacent = start == previousEnd
                                if !offGrid {
                                    // Back on the grid: off-grid characters before a half-width one need it
                                    // right after them.
                                    if p == 0 || p == 2 && isMinority(i - 1, state) || p == 1 && step == 1 && adjacent && isMinority(i - 1, state) {
                                        consider(total, 0, from: state)
                                    }
                                } else if p == 1 {
                                    if adjacent { consider(total, 1, from: state) }
                                } else if p == 2 || previousEnd % 2 == 1 {
                                    // After a half-width character (an odd end on the grid is one).
                                    consider(total, 2, from: state)
                                } else {
                                    consider(total + offGridCost, 1, from: state)
                                }
                            }
                        }
                    }
                }
            }
            // Text after the last item that it didn't take counts as skipped too.
            let finalCost = (0...units).map { end -> (cost: Double, state: Int) in
                let candidates = [end * 3, end * 3 + 2].filter { cost[m - 1][$0].isFinite && ($0 % 3 == 0 || isMinority(m - 1, $0)) }
                let best = candidates.min { cost[m - 1][$0] < cost[m - 1][$1] } ?? end * 3
                return (cost[m - 1][best] + inkSkipped(end, units), best)
            }
            guard let bestEnd = finalCost.indices.min(by: { finalCost[$0].cost < finalCost[$1].cost }), finalCost[bestEnd].cost.isFinite else { return nil }
            let total = finalCost[bestEnd].cost
            var state = finalCost[bestEnd].state
            var end = bestEnd
            var placements = [(start: Int, width: Int)](repeating: (0, 0), count: m)
            for i in stride(from: m - 1, through: 0, by: -1) {
                let start = from[i][state].start
                placements[i] = (start, end - start)
                state = from[i][state].state
                end = state / 3
            }
            return (total, placements)
        }
        var assignment: (cost: Double, placements: [(start: Int, width: Int)])?
        for step in -18...18 {
            if let candidate = assign(offset: Double(step) * best.pitch / 20), candidate.cost < assignment?.cost ?? .infinity {
                assignment = candidate
            }
        }
        guard let assignment else { return narrowed() }

        // Across the line, keep only the part with strokes. Only ever shrink it: beyond it are the
        // neighboring lines.
        let cross = strokeBand.map { (Double($0.first), Double($0.last + 1)) } ?? (Double(c0), Double(c1))

        // The characters of a run share its cells evenly.
        var result: [Char] = []
        for (item, placement) in zip(items, assignment.placements) {
            let size = Double(placement.width) * half / Double(item.count)
            for (offset, index) in item.enumerated() {
                let start = origin + Double(placement.start) * half + Double(offset) * size
                let box = vertical
                    ? CGRect(x: cross.0, y: start, width: cross.1 - cross.0, height: size)
                    : CGRect(x: start, y: cross.0, width: size, height: cross.1 - cross.0)
                result.append(Char(text: chars[index].text, box: box))
            }
        }
        return result
    }

    /// Which of dots, dashes or tildes a character is (also an ellipsis, as dots), or nil: Live Text
    /// reads runs of them as more or fewer characters than are drawn. The same kinds as LOOKALIKES in
    /// web/src/lib/ocr-layer.js.
    static func lookalikeKind(_ text: String) -> Int? {
        let key = text.precomposedStringWithCompatibilityMapping
        guard !key.isEmpty else { return nil }
        return [".・·⋯", "-‐‑‒–—―─━ー", "~〜"].firstIndex { kind in key.allSatisfy { kind.contains($0) } }
    }
}
