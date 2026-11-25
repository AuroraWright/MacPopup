import CoreGraphics
import Foundation

/// Screen AI OCR: Chrome's OCR models (text line detector, line recognizers per script, language identifier),
/// converted to Core ML by scripts/convert-screenai.py, with the original's pre- and post-processing.
public final class ScreenAIEngine: @unchecked Sendable {
    /// A line of recognized text. Boxes are in image pixels (origin at the top left), before rotation.
    public struct Line {
        public var text: String
        public var box: Box
        public var words: [Word]
        /// BCP 47.
        public var language: String
        public var confidence: Float
        /// The line is read top to bottom (vertical Japanese or Chinese).
        public var vertical: Bool
    }

    public struct Word {
        public var text: String
        public var box: Box
        public var symbols: [(text: String, box: Box)]
        /// Followed by a space.
        public var space: Bool
    }

    /// A rotated rectangle: (left, top) is its top-left corner before the rotation about it, by `angle` degrees
    /// clockwise.
    public struct Box {
        public var left: Int, top: Int, width: Int, height: Int
        public var angle: Float

        /// Its corners: top left, top right, bottom right, bottom left.
        public var corners: [CGPoint] {
            let r = Double(angle) * .pi / 180, c = cos(r), s = sin(r)
            let w = Double(width), h = Double(height), x = Double(left), y = Double(top)
            return [CGPoint(x: x, y: y), CGPoint(x: x + w * c, y: y + w * s),
                    CGPoint(x: x + w * c - h * s, y: y + w * s + h * c), CGPoint(x: x - h * s, y: y + h * c)]
        }

        /// The axis-aligned rectangle around it.
        public var bounds: CGRect {
            if angle == 0 { return CGRect(x: left, y: top, width: width, height: height) }
            let r = Double(angle) * .pi / 180, c = cos(r), s = sin(r)
            let w = Double(width), h = Double(height), x = Double(left), y = Double(top)
            let xs = [x, x + w * c, x + w * c - h * s, x - h * s]
            let ys = [y, y + w * s, y + w * s + h * c, y + h * c]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    private let resources: Resources
    private let detector: TextDetector
    private let recognizer: LineRecognizer
    /// The layout analysis' graph network, which only stageDumps runs: loaded when it first does.
    private var loadedLayoutModel: LayoutModel?
    /// One OCR call at a time.
    private let lock = NSLock()

    /// Loads the models from an unpacked models archive. They run on the GPU, or on the CPU with `cpuOnly`.
    public init(modelsDirectory: URL, cpuOnly: Bool = false) throws {
        resources = Resources(root: modelsDirectory, cpuOnly: cpuOnly)
        detector = try TextDetector(resources: resources)
        recognizer = try LineRecognizer(resources: resources)
    }

    /// The layout model, loaded the first time (called with `lock` held).
    private func layoutModel() throws -> LayoutModel {
        if let loadedLayoutModel { return loadedLayoutModel }
        let model = try LayoutModel(resources: resources)
        loadedLayoutModel = model
        return model
    }

    /// The layout after each stage, as goodoc.PageLayoutProto (named like the C++ port's SCREENAI_STAGE_DUMP files:
    /// "001_rec_in" is the detector's output, "002_lay_in" the recognizer's). The layout analysis' steps follow, as
    /// the C++ port's run_layout gives them one --step at a time: "002_filtered" after pre, ConfidenceFilter,
    /// WordPruning, FillSymbolGaps and CurvedOverlaps; "003_sorted" after ClusterSort; "004_lines" after
    /// EstimateLines and AnalyzerEnd. "003_features" holds ClusterSort's graph network inputs and outputs, as run_layout
    /// --features writes them.
    public func stageDumps(_ image: CGImage) throws -> [String: [UInt8]] {
        try lock.withLock {
            let gray = try Self.gray(image)
            let (detected, pyramid) = try detector.detect(gray)
            let recognized = try recognizer.recognize(gray, detected, pyramid: pyramid, colors: true)
            var layout = Self.filtered(recognized)
            var dumps = ["001_rec_in": detected.goodocProto(), "002_lay_in": recognized.goodocProto(),
                         "002_filtered": layout.goodocProto()]
            let graph = layout.lineGraph()
            let features = lineNodeFeatures(graph, scale: Float(layout.width))
            var blob: [UInt8] = []
            func append<T>(_ v: [T]) { v.withUnsafeBytes { blob += $0 } }
            append([Int32(graph.lines.count), Int32(graph.edges.count)])
            append(features)
            append(graph.edges.map { Int64($0.a) })
            append(graph.edges.map { Int64($0.b) })
            if !graph.edges.isEmpty {
                append(try layoutModel().nodeLogits(senders: graph.edges.map(\.a), receivers: graph.edges.map(\.b),
                                                  features: features, lines: graph.lines.count))
            }
            dumps["003_features"] = blob
            try layout.clusterSort(layoutModel())
            dumps["003_sorted"] = layout.goodocProto()
            layout.estimateLines()
            layout.recomputeLineTexts()
            dumps["004_lines"] = layout.goodocProto()
            return dumps
        }
    }

    private static func filtered(_ layout: PageLayout) -> PageLayout {
        var layout = layout
        layout.setDetectionConfidence()
        layout.confidenceFilter()
        layout.pruneOverlappingWords()
        layout.fillSymbolGaps()
        layout.removeOverlapsWithCurvedLines()
        return layout
    }

    /// The layout analysis as OCR mode needs it: the filters above, then each line's box fitted to its symbols. The
    /// rest of it (ClusterSort's graph network and reading order, EstimateLines' line merging) changed nothing OCR mode
    /// shows once it ordered lines itself (2026-11-25), and runs only in stageDumps.
    private func analyzed(_ layout: PageLayout) -> PageLayout {
        var layout = Self.filtered(layout)
        var lines: [Int] = []
        layout.fitBoxes(tracking: &lines)
        // Each entity after its parent again (sorting a paragraph's lines moves them), as recognize reads them.
        layout.reorderUsingDfs()
        layout.recomputeLineTexts()
        return layout
    }

    /// The text lines of the image (not in reading order: OCR mode puts them in it, see OCRLayout.inParagraphs).
    /// - Parameter recognizers: The script recognizers to use besides the general one (ISO 15924 codes, e.g. "Jpan"), or
    ///   nil for all of them (see LineRecognizer.recognize).
    public func recognize(_ image: CGImage, recognizers: Set<String>? = nil) throws -> [Line] {
        let layout = try lock.withLock {
            try autoreleasepool {
                let gray = try Self.gray(image)
                let (detected, pyramid) = try detector.detect(gray)
                return analyzed(try recognizer.recognize(gray, detected, pyramid: pyramid, keys: recognizers))
            }
        }
        func box(_ b: RotatedBox) -> Box { Box(left: b.left, top: b.top, width: b.width, height: b.height, angle: b.angle) }
        var lines: [Line] = []
        var lineOf: [Int: Int] = [:], wordOf: [Int: (line: Int, word: Int)] = [:]
        let children = layout.childLists()
        for (i, e) in layout.entities.enumerated() {
            switch e.type {
            case .line:
                let text = layout.text(of: i, children, ownText: false)
                guard !text.isEmpty, let b = e.box else { continue }
                lineOf[i] = lines.count
                lines.append(Line(text: text, box: box(b), words: [], language: e.languages.first ?? "und",
                                  confidence: e.confidence ?? 0, vertical: e.writingDirection == 2))
            case .word:
                guard let l = lineOf[e.parent], let b = e.box else { continue }
                wordOf[i] = (l, lines[l].words.count)
                lines[l].words.append(Word(text: e.text ?? "", box: box(b), symbols: [],
                                           space: e.wordBreak?.type == 2 || e.wordBreak?.type == 3))
            case .symbol:
                guard let w = wordOf[e.parent], let b = e.box else { continue }
                lines[w.line].words[w.word].symbols.append((e.text ?? "", box(b)))
            default:
                break
            }
        }
        return lines
    }

    /// The image's pixels as the original reads them: 8-bit RGBA, converted to gray. When the image's own bytes are
    /// what that drawing would give (see grayWeights), their gray is taken from them as they are: for a 1080p capture,
    /// about 0.3 ms instead of 2.8 (the same bytes on 1200 pictures in several layouts and crops).
    static func gray(_ image: CGImage) throws -> GrayImage {
        let w = image.width, h = image.height
        if let weights = grayWeights(image), let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * (h - 1) + 4 * w {
            return GrayImage(pixels, width: w, height: h, bytesPerRow: image.bytesPerRow, weights: weights)
        }
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        // Drawn over without blending, so every byte is written.
        var rgba = [UInt8](unsafeUninitializedCapacity: w * h * 4) { _, count in count = w * h * 4 }
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ScreenAIError("Can't read the image") }
        return rgba.withUnsafeBufferPointer { GrayImage(rgba: $0.baseAddress!, width: w, height: h, bytesPerRow: 4 * w) }
    }

    /// The gray weights of each byte of a pixel of `image`, when drawing it into RGBA in its own color space would copy
    /// its bytes as they are: 8-bit RGB with alpha premultiplied or none, 32 bits per pixel. Nil for other layouts.
    private static func grayWeights(_ image: CGImage) -> [Int16]? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.colorSpace?.model == .rgb,
              !image.bitmapInfo.contains(.floatComponents) else { return nil }
        let alphaFirst: Bool
        switch image.alphaInfo {
        case .premultipliedFirst, .noneSkipFirst: alphaFirst = true
        case .premultipliedLast, .noneSkipLast: alphaFirst = false
        default: return nil
        }
        let littleEndian: Bool
        switch image.bitmapInfo.intersection(.byteOrderMask) {
        case [], .byteOrder32Big: littleEndian = false
        case .byteOrder32Little: littleEndian = true
        default: return nil
        }
        // In memory: ARGB, RGBA, BGRA (a capture's) or ABGR.
        switch (alphaFirst, littleEndian) {
        case (true, false): return [0, 77, 150, 29]
        case (false, false): return [77, 150, 29, 0]
        case (true, true): return [29, 150, 77, 0]
        case (false, true): return [0, 29, 150, 77]
        }
    }
}
