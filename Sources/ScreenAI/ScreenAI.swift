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
    /// One OCR call at a time.
    private let lock = NSLock()

    /// Loads the models from an unpacked models archive.
    public init(modelsDirectory: URL) throws {
        resources = Resources(root: modelsDirectory)
        detector = try TextDetector(resources: resources)
        recognizer = try LineRecognizer(resources: resources)
    }

    /// The layout after each stage, as goodoc.PageLayoutProto (named like the C++ port's SCREENAI_STAGE_DUMP files:
    /// "001_rec_in" is the detector's output, "002_lay_in" the recognizer's; "002_filtered" is the recognizer's after
    /// the layout analysis' first steps, as the C++ port's run_layout gives it with --step pre, ConfidenceFilter,
    /// WordPruning, FillSymbolGaps, then CurvedOverlaps).
    public func stageDumps(_ image: CGImage) throws -> [String: [UInt8]] {
        try lock.withLock {
            let gray = try Self.gray(image)
            let (detected, pyramid) = try detector.detect(gray)
            let recognized = try recognizer.recognize(gray, detected, pyramid: pyramid)
            return ["001_rec_in": detected.goodocProto(), "002_lay_in": recognized.goodocProto(),
                    "002_filtered": Self.filtered(recognized).goodocProto()]
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

    /// The text lines of the image, in reading order of the detector's paragraphs.
    public func recognize(_ image: CGImage) throws -> [Line] {
        let layout = try lock.withLock {
            try autoreleasepool {
                let gray = try Self.gray(image)
                let (detected, pyramid) = try detector.detect(gray)
                return Self.filtered(try recognizer.recognize(gray, detected, pyramid: pyramid))
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

    /// The image's pixels as the original reads them: 8-bit RGBA, converted to gray.
    static func gray(_ image: CGImage) throws -> GrayImage {
        let w = image.width, h = image.height
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
}
