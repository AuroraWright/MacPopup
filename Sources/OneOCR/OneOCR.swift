import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// OneOCR, the OCR of Windows' Snipping Tool: its text detector, script and layout classifiers and line recognizers,
/// converted to Core ML by scripts/convert-oneocr.py, with the original's pre- and post-processing reimplemented so
/// the results match it.
public final class OneOCREngine: @unchecked Sendable {
    /// A line of recognized text, in reading order. Quads are four corners in image pixels (origin at the top left).
    public struct Line {
        public var text: String
        public var quad: [CGPoint]
        public var words: [Word]
        /// Degrees, [0, 360).
        public var angle: Double
        /// The line is read top to bottom.
        public var vertical: Bool
        public var confidence: Double
    }

    public struct Word {
        public var text: String
        public var quad: [CGPoint]
        public var confidence: Float
    }

    public struct Result {
        public var lines: [Line]
        /// The text's angle on the page in degrees, 0 without lines.
        public var angle: Double
    }

    static let minImageSide = 50, maxImageSide = 10000
    static let maxLineCount = 1000

    private let detector: TextDetector
    private let analyzer: TextAnalyzer
    private let recognizer: TextRecognizer
    private let enableFilterXY: Bool
    /// One OCR call at a time.
    private let lock = NSLock()

    /// On iOS the detector runs on the CPU: on the GPU its first prediction grew the app past its memory limit (3.3 GB
    /// on an iPhone 15 Pro Max, iOS 27.2), where the Mac stays under 0.5 GB.
    #if os(iOS)
    private static let detectorUnits = MLComputeUnits.cpuOnly
    #else
    private static let detectorUnits = MLComputeUnits.cpuAndGPU
    #endif

    /// Loads the models from an unpacked models archive; with `cpuOnly`, the detector runs on the CPU on the Mac too (the
    /// other models always do).
    public init(modelsDirectory: URL, cpuOnly: Bool = false) throws {
        let files = ModelFiles(root: modelsDirectory)
        let cfg = try files.json("config.json")
        detector = try TextDetector(model: files.model("Detector", units: cpuOnly ? .cpuOnly : Self.detectorUnits),
                                    quantization: files.json("detector.json"),
                                    config: (cfg["det_model"] as? [[String: Any]])?.first)
        analyzer = try TextAnalyzer(files: files, config: cfg)
        recognizer = try TextRecognizer(files: files, config: cfg)
        enableFilterXY = cfg["enable_filterxy"] as? Bool ?? false
    }

    public func recognize(_ image: CGImage) throws -> Result {
        try recognize(bgr: Self.bgr(image))
    }

    /// The image's pixels as 8-bit BGR.
    static func bgr(_ image: CGImage) throws -> ImageU8 {
        let w = image.width, h = image.height
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw OneOCRError("Can't read the image") }
        var out = ImageU8(width: w, height: h, channels: 3)
        rgba.withUnsafeMutableBytes { rgba in
            out.data.withUnsafeMutableBytes { bgr in
                let (height, width) = (vImagePixelCount(h), vImagePixelCount(w))
                var source = vImage_Buffer(data: rgba.baseAddress, height: height, width: width, rowBytes: 4 * w)
                var destination = vImage_Buffer(data: bgr.baseAddress, height: height, width: width, rowBytes: 3 * w)
                // RGBA to BGRA in place, then without the alpha.
                vImagePermuteChannels_ARGB8888(&source, &source, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
                vImageConvert_RGBA8888toRGB888(&source, &destination, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    private struct OcrLine {
        var text: String
        var quad: [Pt]
        var words: [(text: String, quad: [Pt], confidence: Float)]
        var angle: Double
        var script: Int
        var vertical: Bool
        var confidence: Double
    }

    func recognize(bgr: ImageU8) throws -> Result {
        try recognizeIfSupported(bgr) ?? Result(lines: [], angle: 0)
    }

    static func supportsSize(_ width: Int, _ height: Int) -> Bool {
        [width, height].allSatisfy { $0 >= minImageSide && $0 <= maxImageSide }
    }

    /// Nil for an unsupported size or a failed CHECK, where oneocr returns nothing.
    func recognizeIfSupported(_ bgr: ImageU8) throws -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard Self.supportsSize(bgr.width, bgr.height) else { return nil }
        do {
            return try run(bgr)
        } catch is GeometryCheckError {
            return nil
        }
    }

    private func run(_ bgr: ImageU8) throws -> Result {
        let detected = try detector.detect(bgr)
        let all = detected.map { Normalizer.buildTextLine(bgr, $0) }
        DispatchQueue.concurrentPerform(iterations: all.count) { Normalizer.normalize(all[$0], bgr) }
        if !all.isEmpty { try analyzer.analyze(all) }
        let lines = all.filter { $0.script != Script.nonText }

        let accepted = try recognizeLines(lines)
        var kept = accepted
        if enableFilterXY {
            let records = accepted.map { tl, o in
                FilterLine(polygon: tl.polygon, isHorizontal: tl.isHorizontal, isAmbiguous: tl.ambiguous,
                           wordTexts: o.words.map(\.text), lineScore: o.confidence, script: tl.script, category: tl.category)
            }
            kept = try PostFilter.filterXY(records).map { accepted[$0] }
        }
        let final = kept.map(\.1).filter { !$0.words.isEmpty }
        let angle = Layout.pageAngle(final.map(\.angle))
        let order = Layout.sortLines(final.map(\.quad), final.map(\.script), angle)
        func points(_ q: [Pt]) -> [CGPoint] { q.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) } }
        return Result(lines: order.map { i in
            let l = final[i]
            return Line(text: l.text, quad: points(l.quad), words: l.words.map { Word(text: $0.text, quad: points($0.quad), confidence: $0.confidence) },
                        angle: l.angle, vertical: l.vertical, confidence: l.confidence)
        }, angle: final.isEmpty ? 0 : angle)
    }

    /// Recognizes the lines; with more than maxLineCount, by clusters of overlapping lines until that many are accepted.
    private func recognizeLines(_ lines: [TextLine]) throws -> [(TextLine, OcrLine)] {
        let n = lines.count
        if n <= Self.maxLineCount { return try recognizeBatch(lines) }
        var sorted = lines
        MSVC.sort(&sorted) { a, b in
            let ay = a.quad.map(\.y).min()!, by = b.quad.map(\.y).min()!
            return ay < by || (ay == by && a.quad.map(\.x).min()! < b.quad.map(\.x).min()!)
        }
        let polys = try sorted.map { try DetPoly($0.polygon, score: 0, hori: $0.isHorizontal, level: 0) }
        func overlap(_ a: Int, _ b: Int) throws -> Bool {
            let pa = polys[a], pb = polys[b]
            if pa.xmin > pb.xmax || pa.ymin > pb.ymax || pa.xmax < pb.xmin || pa.ymax < pb.ymin { return false }
            let w = pmax(Float(pmin(pa.xmax, pb.xmax) - pmax(pa.xmin, pb.xmin)) + 1, 0)
            let h = pmax(Float(pmin(pa.ymax, pb.ymax) - pmax(pa.ymin, pb.ymin)) + 1, 0)
            if w * h <= 0 { return false }
            return try Geom32.stripIntersection(pa.strip(), pb.strip()) > 0
        }
        let hori = (0..<n).filter { sorted[$0].isHorizontal }, vert = (0..<n).filter { !sorted[$0].isHorizontal }
        var seen = [Bool](repeating: false, count: n)
        var clusters: [[Int]] = []
        for i in 0..<n where !seen[i] {
            seen[i] = true
            var cl = [i]
            var k = 0
            while k < cl.count {
                let x = cl[k]
                for j in sorted[x].isHorizontal ? vert : hori where !seen[j] {
                    if try overlap(x, j) {
                        seen[j] = true
                        cl.append(j)
                    }
                }
                k += 1
            }
            clusters.append(cl)
        }
        var out: [(TextLine, OcrLine)] = []
        var ci = 0
        let ratio = Double(ProcessInfo.processInfo.environment["MAX_LINE_COUNT_BATCH_SIZE_RATIO"] ?? "") ?? 1.1
        while out.count < Self.maxLineCount {
            let target = max(4, Int((Double(Self.maxLineCount - out.count) * ratio + 0.5).rounded(.down)))
            var batch: [Int] = []
            while ci < clusters.count && batch.count < target {
                batch += clusters[ci]
                ci += 1
            }
            if batch.isEmpty { break }
            out += try recognizeBatch(batch.map { sorted[$0] })
        }
        return out
    }

    /// Recognizes lines in parallel; the accepted ones in order.
    private func recognizeBatch(_ lines: [TextLine]) throws -> [(TextLine, OcrLine)] {
        let results = try concurrentMap(lines.count) { try recognizeLine(lines[$0]) }
        return zip(lines, results).compactMap { tl, o in o.map { (tl, $0) } }
    }

    private func recognizeLine(_ tl: TextLine) throws -> OcrLine? {
        guard let charModel = analyzer.charModelName(tl.ocrMode) else { return nil }
        let mode = OCRMode.name[tl.ocrMode] ?? recognizer.resolveMode(charModel)
        let rec = try recognizer.recognize(tl.lineImage, charModel: charModel, mode: mode)
        if rec.rejected || rec.words.isEmpty { return nil }
        var quad = Normalizer.lineOutputQuad(tl)
        let words = rec.words.map { w in (text: w.text, quad: Normalizer.wordOutputQuad(tl, Double(w.start), Double(w.end)),
                                          confidence: w.confidence) }
        if Layout.angleDifference(Layout.quadAngle(quad), Layout.quadAngle(words[0].quad)) > 90 {
            quad = [quad[2], quad[3], quad[0], quad[1]]
        }
        return OcrLine(text: rec.text, quad: quad, words: words, angle: Layout.quadAngle(quad), script: tl.script,
                       vertical: tl.layout == LineLayout.vertical, confidence: rec.confidence)
    }
}
