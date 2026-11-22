import Accelerate
import CoreGraphics
import CoreML
import Foundation
import OCRLineCache

/// Text recognition with mida, VOCR6.2-L and VOCR6-V, as meikipop's "mida + VOCR6 (local)" provider has them
/// (github.com/rtr46/meikipop, as of commit c5ca5b1), run with Core ML (converted by scripts/convert-mida-vocr6.py, see
/// vendor/mida-vocr6): mida (rtr46's line detector) finds the text lines, horizontal and vertical, and VOCR6 (from
/// github.com/bee-san/vita-vn-ocr) reads each, with a cell along the line for each character: VOCR6.2-L the
/// horizontal lines, VOCR6-V the vertical ones, turned anticlockwise.
///
/// This follows the provider's mida_detector.py, line_crops.py and vocr_onnx.py step by step, with their integer
/// arithmetic: OpenCV's INTER_AREA resizing of 8-bit images for the detector, vita-vn-ocr's copy of OpenCV's bilinear
/// resizing for the lines, its grey, its check for dark text, and its character cells (with VOCR6-V's own calibration,
/// and for VOCR6.2-L the provider's earlier refit of its own: see scripts/convert-mida-vocr6.py).
public final class MidaVOCR6: @unchecked Sendable {
    public static let shared = MidaVOCR6()

    private struct Models {
        let detection: MLModel
        let horizontal: Recognizer, vertical: Recognizer
    }

    private struct Recognizer {
        let model: MLModel
        let head: Head
    }

    /// The detector's input: the picture, made smaller (never larger) to at most this many pixels.
    private static let detectionPixels = 600_000
    /// The converted detector's longest side (longer strips are made smaller still).
    private static let detectionSide = 4096
    /// The detector's output has a cell for each 8 x 8 pixels of its input.
    private static let detectionStride = 8
    /// A cell is in a line where its line kernel's probability is over this; a line needs this many cells, this
    /// confidence (its cells' average probability) and to be this wide across (in the detector's pixels). At most
    /// maximumLines are kept, the most confident.
    private static let kernelThreshold = 0.5, minimumCells = 2, minimumConfidence = 0.5, minimumAcross = 2.0
    private static let maximumLines = 256
    /// How many lines are read at once.
    private static let concurrentLines = 4

    /// How a detected line becomes the part of the picture its recognizer reads (line_crops.py's CropConfig): its
    /// ends widened by `endGrowth` times its thickness plus `endPadding` pixels, its sides by `acrossGrowth` times
    /// its thickness, then moved across by `shift`. Lines less confident, shorter or thinner (in pixels) are left out.
    private struct CropSettings {
        let endGrowth: Double, endPadding: Double, acrossGrowth: Double, shift: Double
        let minimumConfidence: Double, minimumLength: Double, minimumThickness: Double
    }

    /// line_crops.py's DEFAULT_H and DEFAULT_V.
    private static let horizontalCrop = CropSettings(endGrowth: 0.4, endPadding: 4, acrossGrowth: 0, shift: 0,
                                                     minimumConfidence: 0.5, minimumLength: 12, minimumThickness: 4)
    private static let verticalCrop = CropSettings(endGrowth: 0.15, endPadding: 4, acrossGrowth: 0.2, shift: 2,
                                                   minimumConfidence: 0.5, minimumLength: 12, minimumThickness: 4)

    /// Predictions run one at a time, off the main thread.
    private let queue = DispatchQueue(label: "MidaVOCR6", qos: .userInitiated)
    private var models: Models?
    private let lineCache = LineCache<[LineCharacter]>()

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Loads the models, if they aren't yet. The first prediction takes longer (Core ML prepares the models), so they
    /// predict once on blank input.
    public func prepare() async throws {
        try await run { _ in }
    }

    /// Lets the models go, to free their memory; the next picture loads them again.
    public func unload() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.models = nil
                self.lineCache.clear()
                continuation.resume()
            }
        }
    }

    public func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try await run { [lineCache] models in try Self.recognize(image, models: models, cache: lineCache) }
    }

    private func run<T>(_ body: @escaping (Models) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try autoreleasepool { try body(self.loadedModels()) } })
            }
        }
    }

    private func loadedModels() throws -> Models {
        if let models { return models }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Models") else {
            throw Failure(errorDescription: "The mida + VOCR6 models are missing")
        }
        func load(_ name: String, on computeUnits: MLComputeUnits) throws -> MLModel {
            let url = directory.appendingPathComponent("\(name).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure(errorDescription: "The mida + VOCR6 model \(name) is missing")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("MidaVOCR6.json")),
              let info = try? JSONDecoder().decode([String: Head.Info].self, from: data),
              let horizontal = info["horizontal"], let vertical = info["vertical"] else {
            throw Failure(errorDescription: "The VOCR6 heads are missing")
        }
        // The recognizers run on the CPU, several lines at once.
        let loaded = Models(
            detection: try load("MidaDetection", on: OCRCompute.units(.cpuAndGPU)),
            horizontal: Recognizer(model: try load("VOCR6Recognition", on: .cpuOnly),
                                   head: try Head(horizontal, weights: directory.appendingPathComponent("VOCR6Head.bin"))),
            vertical: Recognizer(model: try load("VOCR6VerticalRecognition", on: .cpuOnly),
                                 head: try Head(vertical, weights: directory.appendingPathComponent("VOCR6VerticalHead.bin")))
        )
        for (model, name, shape) in [(loaded.detection, "images", [1, 3, 544, 960]), (loaded.horizontal.model, "grey", [1, 1, 32, 256]),
                                     (loaded.vertical.model, "grey", [1, 1, 32, 256])] {
            let input = try MLMultiArray(shape: shape as [NSNumber], dataType: .float32)
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in buffer.initialize(repeating: 0) }
            _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: input]))
        }
        models = loaded
        return loaded
    }

    // MARK: Pipeline

    /// A character and its cell along the line, in the line's pixels (from the left of the turned crop in vertical
    /// lines: from their top).
    private struct LineCharacter {
        let text: String
        let x0: Double
        let x1: Double
    }

    private static func recognize(_ cgImage: CGImage, models: Models, cache: LineCache<[LineCharacter]>) throws -> [RecognizedLine] {
        guard let image = RGBImage(cgImage) else { throw Failure(errorDescription: "Couldn't read the image") }
        let (width, height) = (Double(image.width), Double(image.height))
        let normalize = { (x0: Double, y0: Double, x1: Double, y1: Double) in
            CGRect(x: x0 / width, y: y0 / height, width: (x1 - x0) / width, height: (y1 - y0) / height)
        }
        let crops = try detectLines(image, model: models.detection).compactMap {
            crop($0, settings: $0.vertical ? verticalCrop : horizontalCrop, width: image.width, height: image.height)
        }
        var lines = [RecognizedLine?](repeating: nil, count: crops.count)
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: min(concurrentLines, crops.count)) { worker in
            for index in stride(from: worker, to: crops.count, by: concurrentLines) {
                let crop = crops[index]
                let characters: [LineCharacter]
                do {
                    var grey = image.grey(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
                    var (lineWidth, lineHeight) = (crop.width, crop.height)
                    if crop.vertical {
                        grey = turnedAnticlockwise(grey, width: crop.width, height: crop.height)
                        (lineWidth, lineHeight) = (crop.height, crop.width)
                    }
                    let recognizer = crop.vertical ? models.vertical : models.horizontal
                    let key = grey.withUnsafeBytes { LineCache<[LineCharacter]>.Key($0, [lineWidth, lineHeight, crop.vertical ? 1 : 0]) }
                    characters = try cache.value(key) {
                        try read(grey, width: lineWidth, height: lineHeight, recognizer: recognizer)
                    }
                } catch {
                    lock.withLock { failure = error }
                    return
                }
                guard !characters.isEmpty else { continue }
                let (x0, y0) = (Double(crop.x), Double(crop.y))
                let (x1, y1) = (x0 + Double(crop.width), y0 + Double(crop.height))
                // At least a pixel long.
                let words = characters.map { character in
                    let (start, end) = (character.x0, max(character.x1, character.x0 + 1))
                    return (character.text, crop.vertical ? normalize(x0, y0 + start, x1, y0 + end) : normalize(x0 + start, y0, x0 + end, y1))
                }
                let line = RecognizedLine(text: characters.map(\.text).joined(), box: normalize(x0, y0, x1, y1), words: words)
                lock.withLock { lines[index] = line }
            }
        }
        if let failure { throw failure }
        cache.endReading()
        return lines.compactMap { $0 }
    }

    /// A text line as the detector finds it, in the picture's pixels.
    private struct DetectedLine {
        let x0: Double, y0: Double, x1: Double, y1: Double
        let vertical: Bool
        let confidence: Double
    }

    private struct Crop {
        let x: Int, y: Int, width: Int, height: Int
        let vertical: Bool
    }

    /// The part of the picture a line's recognizer reads (line_crops.py's make_crop), or nil to leave it out.
    private static func crop(_ line: DetectedLine, settings: CropSettings, width: Int, height: Int) -> Crop? {
        var (x0, y0, x1, y1) = (line.x0, line.y0, line.x1, line.y1)
        let (length, thickness) = line.vertical ? (y1 - y0, x1 - x0) : (x1 - x0, y1 - y0)
        guard line.confidence >= settings.minimumConfidence, length >= settings.minimumLength,
              thickness >= settings.minimumThickness else { return nil }
        let end = settings.endGrowth * thickness + settings.endPadding
        let across = settings.acrossGrowth * thickness
        if line.vertical {
            (x0, x1) = (x0 - across + settings.shift, x1 + across + settings.shift)
            (y0, y1) = (y0 - end, y1 + end)
        } else {
            (x0, x1) = (x0 - end, x1 + end)
            (y0, y1) = (y0 - across + settings.shift, y1 + across + settings.shift)
        }
        let left = max(0, Int(x0.rounded(.down))), top = max(0, Int(y0.rounded(.down)))
        let right = min(width, Int(x1.rounded(.up))), bottom = min(height, Int(y1.rounded(.up)))
        guard right > left, bottom > top else { return nil }
        return Crop(x: left, y: top, width: right - left, height: bottom - top, vertical: line.vertical)
    }

    /// `grey` (`width` x `height`) turned a quarter anticlockwise (numpy's rot90): `height` x `width`, its top on the
    /// left.
    private static func turnedAnticlockwise(_ grey: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: grey.count)
        for row in 0..<width {
            for column in 0..<height { out[row * height + column] = grey[column * width + width - 1 - row] }
        }
        return out
    }

    /// The picture's size for the detector (mida_detector.py's target_size): at most `maximumPixels`, the sides
    /// shrunk by the same factor and rounded down, then the longer one less a pixel at a time while it's too many.
    static func detectionSize(width: Int, height: Int, maximumPixels: Int) -> (width: Int, height: Int) {
        var (w, h) = (width, height)
        guard w * h > maximumPixels else { return (w, h) }
        let factor = (Double(maximumPixels) / Double(w * h)).squareRoot()
        (w, h) = (max(1, Int(Double(w) * factor)), max(1, Int(Double(h) * factor)))
        while w * h > maximumPixels && (w > 1 || h > 1) {
            if w >= h && w > 1 { w -= 1 } else if h > 1 { h -= 1 }
        }
        return (w, h)
    }

    /// The text lines (mida_detector.py's detect), the most confident first.
    private static func detectLines(_ image: RGBImage, model: MLModel) throws -> [DetectedLine] {
        let (w, h) = (image.width, image.height)
        var (inputWidth, inputHeight) = detectionSize(width: w, height: h, maximumPixels: detectionPixels)
        if max(inputWidth, inputHeight) > detectionSide {
            let factor = Double(detectionSide) / Double(max(w, h))
            (inputWidth, inputHeight) = (max(1, min(detectionSide, Int(Double(w) * factor))),
                                         max(1, min(detectionSide, Int(Double(h) * factor))))
        }
        // The converted model's smallest input.
        guard inputWidth >= 16, inputHeight >= 16 else { return [] }
        let sameSize = (inputWidth, inputHeight) == (w, h)
        let resized = sameSize
            ? image.pixels
            : OpenCVResize.area(image.pixels, width: w, height: h, pixelSize: 4, channels: 3, toWidth: inputWidth, toHeight: inputHeight)
        let pixelSize = sameSize ? 4 : 3
        let input = try MLMultiArray(shape: [1, 3, inputHeight, inputWidth] as [NSNumber], dataType: .float32)
        // Red, green, blue, from 0 to 1 (each value / 255, looked up).
        let levels = (0..<256).map { Float($0) / 255 }
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { output, strides in
            resized.withUnsafeBufferPointer { resized in
                let (channelStride, rowStride) = (strides[1], strides[2])
                for channel in 0..<3 {
                    for y in 0..<inputHeight {
                        let source = resized.baseAddress! + y * inputWidth * pixelSize + channel
                        let target = output.baseAddress! + channel * channelStride + y * rowStride
                        for x in 0..<inputWidth { target[x] = levels[Int(source[x * pixelSize])] }
                    }
                }
            }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["images": input]))
        guard let maps = output.featureValue(for: "maps")?.multiArrayValue else {
            throw Failure(errorDescription: "Unexpected detection output")
        }
        let lines = MLShapedArray<Float>(converting: maps).withUnsafeShapedBufferPointer { values, shape, strides in
            decode(values: values, rows: shape[2], columns: shape[3], strides: strides, width: inputWidth, height: inputHeight)
        }
        let (sx, sy) = (Double(inputWidth) / Double(w), Double(inputHeight) / Double(h))
        return lines.map {
            DetectedLine(x0: $0.x0 / sx, y0: $0.y0 / sy, x1: $0.x1 / sx, y1: $0.y1 / sy, vertical: $0.vertical, confidence: $0.confidence)
        }
    }

    /// The detector's maps as lines in its input's pixels (`width` x `height`), the most confident first
    /// (mida_detector.py's decode). Each 4-connected region of cells whose line kernel (map 0) is likely is a line,
    /// vertical if its cells' orientation (map 1) is on average; across, its sides are its cells' average distances
    /// to them (maps 2 and 3), and along, its ends are its cells'.
    private static func decode(values: UnsafeBufferPointer<Float>, rows: Int, columns: Int, strides: [Int],
                               width: Int, height: Int) -> [DetectedLine] {
        let value = { (map: Int, index: Int) in
            Double(values[map * strides[1] + index / columns * strides[2] + index % columns * strides[3]])
        }
        let sigmoid = { (x: Double) in 1 / (1 + exp(-x)) }
        let kernel = (0..<rows * columns).map { sigmoid(value(0, $0)) }
        var label = kernel.map { $0 > kernelThreshold }
        var lines: [DetectedLine] = []
        var stack: [Int] = []
        let stride = Double(detectionStride)
        for start in 0..<label.count where label[start] {
            label[start] = false
            stack.append(start)
            var cells: [Int] = []
            while let index = stack.popLast() {
                cells.append(index)
                let (row, column) = (index / columns, index % columns)
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let (r, c) = (row + dr, column + dc)
                    guard r >= 0, r < rows, c >= 0, c < columns, label[r * columns + c] else { continue }
                    label[r * columns + c] = false
                    stack.append(r * columns + c)
                }
            }
            // Added up in the provider's order (by row, then column).
            cells.sort()
            let count = Double(cells.count)
            let confidence = cells.reduce(0.0) { $0 + kernel[$1] } / count
            let vertical = cells.reduce(0.0) { $0 + sigmoid(value(1, $1)) } / count > 0.5
            var nearSum = 0.0, farSum = 0.0
            var first = Int.max, last = Int.min
            for index in cells {
                let (row, column) = (index / columns, index % columns)
                let (across, along) = vertical ? (column, row) : (row, column)
                let centre = stride * Double(across) + (stride - 1) / 2
                nearSum += centre - value(2, index) * stride
                farSum += centre + value(3, index) * stride
                first = min(first, along)
                last = max(last, along)
            }
            let near = nearSum / count, far = farSum / count
            guard cells.count >= minimumCells, confidence >= minimumConfidence, far - near >= minimumAcross else { continue }
            let (start, end) = (stride * Double(first), stride * Double(last + 1))
            var (x0, y0, x1, y1) = vertical ? (near, start, far, end) : (start, near, end, far)
            (x0, y0, x1, y1) = (max(0, x0), max(0, y0), min(Double(width), x1), min(Double(height), y1))
            guard x1 > x0, y1 > y0 else { continue }
            lines.append(DetectedLine(x0: x0, y0: y0, x1: x1, y1: y1, vertical: vertical, confidence: confidence))
        }
        // Most confident first; equally confident ones in the order found.
        let order = lines.indices.sorted { (lines[$0].confidence, $1) > (lines[$1].confidence, $0) }
        return order.prefix(maximumLines).map { lines[$0] }
    }

    /// The characters of a line (`grey`, `width` x `height`, vertical ones turned), each with its cell
    /// (vocr_onnx.py's Recognizer.read, with the provider's check for dark text).
    private static func read(_ grey: [UInt8], width: Int, height: Int, recognizer: Recognizer) throws -> [LineCharacter] {
        let head = recognizer.head
        let (input, resizedWidth) = try lineInput(grey, width: width, height: height,
                                                  invert: isDark(grey, width: width, height: height), head: head)
        let output = try recognizer.model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["grey": input]))
        guard let features = output.featureValue(for: "features")?.multiArrayValue else {
            throw Failure(errorDescription: "Unexpected recognition output")
        }
        let classes = head.classes(MLShapedArray<Float>(converting: features))
        // Greedy CTC: each run of the same class (but blank, 0) is a character.
        var spans: [(index: Int, first: Int, last: Int)] = []
        var previous = 0
        for (frame, index) in classes.enumerated() {
            if index != 0 && index == previous {
                spans[spans.count - 1].last = frame
            } else if index != 0 {
                spans.append((index, frame, frame))
            }
            previous = index
        }
        return cells(spans, width: width, height: height, resizedWidth: resizedWidth, head: head)
    }

    /// vita-vn-ocr's check: whether the text in a line is darker than its background (the median of its border).
    private static func isDark(_ grey: [UInt8], width: Int, height: Int) -> Bool {
        var border: [UInt8] = []
        border.reserveCapacity(2 * (width + height))
        border += grey[0..<width]
        border += grey[(height - 1) * width..<height * width]
        for y in 0..<height { border.append(grey[y * width]) }
        for y in 0..<height { border.append(grey[y * width + width - 1]) }
        border.sort()
        let background = Int(border[border.count / 2])
        var histogram = [Int](repeating: 0, count: 256)
        for value in grey { histogram[Int(value)] += 1 }
        // The 2nd and 98th percentiles.
        let count = width * height
        var low = -1, high = -1, cumulative = 0
        for value in 0..<256 {
            cumulative += histogram[value]
            if low < 0 && cumulative >= count * 2 / 100 { low = value }
            if high < 0 && cumulative >= count * 98 / 100 { high = value }
        }
        let distance = max(16, (high - low) / 4)
        var darker = 0, lighter = 0
        for value in grey {
            if Int(value) < background - distance { darker += 1 }
            if Int(value) > background + distance { lighter += 1 }
        }
        return darker > 8 * lighter
    }

    /// The recognizer's input for a line (vocr_onnx.py's preprocess): inverted if its text is dark, resized to the
    /// model's height (with OpenCV's 8-bit bilinear resizing, which vita-vn-ocr copies), and padded to a multiple of the
    /// stride by repeating its last column. Also the resized width.
    private static func lineInput(_ grey: [UInt8], width: Int, height: Int, invert: Bool, head: Head) throws -> (MLMultiArray, Int) {
        let source = invert ? grey.map { 255 - $0 } : grey
        // width * height / line height, rounded half to even, within the model's widths.
        let numerator = width * head.height
        var resized = (2 * numerator + height) / (2 * height)
        if (2 * numerator + height) % (2 * height) == 0 && resized % 2 == 1 { resized -= 1 }
        resized = max(head.minWidth, min(head.maxWidth, resized))
        let padded = (resized + head.stride - 1) / head.stride * head.stride
        let line = OpenCVResize.linear(source, width: width, height: height, pixelSize: 1, channels: 1, toWidth: resized,
                                       toHeight: head.height)
        let input = try MLMultiArray(shape: [1, 1, head.height as NSNumber, padded as NSNumber], dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { output, strides in
            for y in 0..<head.height {
                for x in 0..<padded { output[y * strides[2] + x] = Float(line[y * resized + min(x, resized - 1)]) }
            }
        }
        return (input, resized)
    }

    /// Each character's cell along the line, in the line's pixels (vocr_onnx.py's cells, in 1/16 pixels): its centre
    /// is the middle of its frames, moved by the calibration of its kind of character, and its cell reaches halfway to
    /// its neighbours' centres (the ends half the median distance between centres).
    private static func cells(_ spans: [(index: Int, first: Int, last: Int)], width: Int, height: Int, resizedWidth: Int,
                              head: Head) -> [LineCharacter] {
        guard !spans.isEmpty else { return [] }
        let q = 16
        func divided(_ a: Int, _ b: Int) -> Int { a >= 0 ? (a + b / 2) / b : -((-a + b / 2) / b) }
        let centres = spans.map { span -> Int in
            let r = q * head.stride * (span.first + span.last + 1) / 2 + head.calibration[0] + head.calibration[1 + head.groups[span.index]]
            return min(max(divided(r * width, resizedWidth), 0), width * q)
        }
        let distances = zip(centres, centres.dropFirst()).map { $1 - $0 }.sorted()
        var pitch = distances.isEmpty ? height * q : distances[(distances.count - 1) / 2]
        if pitch <= 0 { pitch = height * q }
        let cuts = zip(centres, centres.dropFirst()).map { divided($0 + $1, 2) }
        let lows = [max(0, centres[0] - pitch / 2)] + cuts
        let highs = cuts + [min(width * q, centres[centres.count - 1] + pitch / 2)]
        return spans.indices.map { i in
            LineCharacter(text: head.vocabulary[spans[i].index], x0: Double(lows[i]) / Double(q), x1: Double(max(lows[i], highs[i])) / Double(q))
        }
    }

    // MARK: The recognizer's head

    /// A recognizer's last step, which the Core ML model leaves out (see scripts/convert-mida-vocr6.py): each frame's
    /// features score the characters. VOCR6.2-L's scores its common characters, and a small gate decides from them
    /// whether the frame also scores the rare ones (the "fast" head that the provider runs); VOCR6-V's scores all.
    private struct Head {
        let vocabulary: [String]
        /// Each character's kind, for its cell's calibration (vocr_onnx.py's char_group).
        let groups: [Int]
        let height: Int, stride: Int, minWidth: Int, maxWidth: Int
        /// Where characters are, in 1/16 resized pixels: for all of them, then by kind (VOCR6-V's own vocr.charbox_cal,
        /// as the provider uses; for VOCR6.2-L, pull 131's refit, which places them better than its own).
        let calibration: [Int]
        let commonClasses: Int
        /// The common and the rare characters' weights ([features][their classes]), and a bias per class.
        let commonWeights: [Float], rareWeights: [Float], bias: [Float]
        let classCount: Int
        let gate: Gate?

        struct Gate: Decodable {
            /// [features][units], integers.
            let weights: [[Int32]]
            let scale: [Float], bias: [Float], commonMax: [Float], blank: [Float], output: [Float]
            let outputBias: Float, threshold: Float
        }

        /// MidaVOCR6.json's "horizontal" and "vertical" (only L has common classes and a gate).
        struct Info: Decodable {
            let vocabulary: [String]
            let height: Int, stride: Int, minWidth: Int, maxWidth: Int
            let calibration: [Int]
            let commonClasses: Int?
            let gate: Gate?
        }

        static let featureCount = 96

        /// The head of `info`, with its weights from `weights` (little-endian floats: [96][classes], then a bias per
        /// class).
        init(_ info: Info, weights: URL) throws {
            guard let weightData = try? Data(contentsOf: weights) else {
                throw Failure(errorDescription: "The VOCR6 head \(weights.lastPathComponent) is missing")
            }
            vocabulary = info.vocabulary
            classCount = info.vocabulary.count
            guard weightData.count == (Self.featureCount + 1) * classCount * 4, info.calibration.count == 9,
                  info.gate.map({ $0.weights.count == Self.featureCount }) ?? true else {
                throw Failure(errorDescription: "The VOCR6 head \(weights.lastPathComponent) doesn't fit its characters")
            }
            let floats = weightData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            (height, stride, minWidth, maxWidth) = (info.height, info.stride, info.minWidth, info.maxWidth)
            calibration = info.calibration
            commonClasses = info.commonClasses ?? classCount
            let classes = classCount, common = commonClasses
            commonWeights = (0..<Self.featureCount).flatMap { floats[$0 * classes..<$0 * classes + common] }
            rareWeights = (0..<Self.featureCount).flatMap { floats[$0 * classes + common..<($0 + 1) * classes] }
            bias = Array(floats[(Self.featureCount * classCount)...])
            gate = info.gate
            groups = info.vocabulary.map(Self.group)
        }

        /// vocr_onnx.py's char_group: 0 other, 1 closing, 2 opening, 3 dots, 4 small kana, 5 long marks, 6 marks,
        /// 7 half-width.
        private static func group(_ text: String) -> Int {
            let scalars = text.unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first else { return 0 }
            let kinds = ["、。，．」』）】〉》〕｝］〙〗”’", "「『（【〈《〔｛［〘〖“‘", "…‥・",
                         "ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ", "ー―─～〜－", "！？♪☆★♥♡※"]
            if let kind = kinds.firstIndex(where: { $0.unicodeScalars.contains(scalar) }) { return kind + 1 }
            return scalar.value < 0x80 || (0xFF61...0xFF9F).contains(scalar.value) ? 7 : 0
        }

        /// Each frame's class (the best score, 0 for no character), from the features [96][frames].
        func classes(_ features: MLShapedArray<Float>) -> [Int] {
            let frames = features.shape[1]
            // [frames][96], contiguous.
            var transposed = [Float](repeating: 0, count: frames * Self.featureCount)
            features.withUnsafeShapedBufferPointer { values, _, strides in
                for k in 0..<Self.featureCount {
                    for t in 0..<frames { transposed[t * Self.featureCount + k] = values[k * strides[0] + t * strides[1]] }
                }
            }
            // The common characters' scores, [frames][commonClasses].
            let common = scores(transposed, frames: frames, weights: commonWeights, classes: 0..<commonClasses)
            var best = [Int](repeating: 0, count: frames)
            var gated: [Int] = []
            for t in 0..<frames {
                let row = Array(common[t * commonClasses..<(t + 1) * commonClasses])
                if let gate, passes(Array(transposed[t * Self.featureCount..<(t + 1) * Self.featureCount]), common: row, gate: gate) {
                    gated.append(t)
                }
                best[t] = Self.argmax(row)
            }
            guard !gated.isEmpty else { return best }
            // The rare characters' scores, for the frames the gate let through.
            let rows = gated.flatMap { transposed[$0 * Self.featureCount..<($0 + 1) * Self.featureCount] }
            let rare = scores(rows, frames: gated.count, weights: rareWeights, classes: commonClasses..<classCount)
            let rareCount = classCount - commonClasses
            for (i, t) in gated.enumerated() {
                let row = rare[i * rareCount..<(i + 1) * rareCount]
                let index = Self.argmax(Array(row))
                let commonBest = common[t * commonClasses + best[t]]
                if row[row.startIndex + index] > commonBest { best[t] = commonClasses + index }
            }
            return best
        }

        /// features ([frames][96]) times `weights` ([96][classes]), plus the biases of `classes`: [frames][classes].
        private func scores(_ features: [Float], frames: Int, weights: [Float], classes: Range<Int>) -> [Float] {
            var out = [Float](repeating: 0, count: frames * classes.count)
            vDSP_mmul(features, 1, weights, 1, &out, 1, vDSP_Length(frames), vDSP_Length(classes.count), vDSP_Length(Self.featureCount))
            let biases = Array(bias[classes])
            for t in 0..<frames {
                out.withUnsafeMutableBufferPointer { out in
                    let row = out.baseAddress! + t * classes.count
                    vDSP_vadd(row, 1, biases, 1, row, 1, vDSP_Length(classes.count))
                }
            }
            return out
        }

        /// The first index of the largest value.
        private static func argmax(_ values: [Float]) -> Int {
            var best: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(values, 1, &best, &index, vDSP_Length(values.count))
            return Int(index)
        }

        /// Whether the gate lets a frame score the rare characters, from its features and its common characters'
        /// scores. Its first layer is an integer product: the features scaled to ±32767 and rounded, as the graph does.
        private func passes(_ features: [Float], common: [Float], gate: Gate) -> Bool {
            let largest = features.reduce(Float(0)) { max($0, abs($1)) }
            let factor = Float(32767) / (largest > 0 ? largest : 1)
            let quantized = features.map { value -> Int32 in
                let scaled = value * factor
                let rounded = (abs(scaled) + 0.5).rounded(.down)
                return Int32(min(max(scaled < 0 ? -rounded : scaled > 0 ? rounded : 0, -32767), 32767))
            }
            let units = gate.scale.count
            var products = [Int32](repeating: 0, count: units)
            for (k, q) in quantized.enumerated() where q != 0 {
                let row = gate.weights[k]
                for j in 0..<units { products[j] &+= q * row[j] }
            }
            // The best character's score and no character's.
            let character = common[1...].max() ?? 0
            let blank = common[0]
            let step = largest / 32767
            // Added up in the graph's order.
            var score = gate.outputBias
            for j in 0..<units {
                var unit = Float(products[j]) * (step * gate.scale[j]) + gate.bias[j]
                unit = unit + character * gate.commonMax[j]
                unit = unit + blank * gate.blank[j]
                score += max(unit, 0) * gate.output[j]
            }
            return score > gate.threshold
        }
    }
}

extension RGBImage {
    /// The grey of a part of the image, as vita-vn-ocr makes it: (77 red + 150 green + 29 blue) / 256.
    fileprivate func grey(x x0: Int, y y0: Int, width cropWidth: Int, height cropHeight: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cropWidth * cropHeight)
        pixels.withUnsafeBufferPointer { pixels in
            for y in 0..<cropHeight {
                for x in 0..<cropWidth {
                    let p = ((y0 + y) * width + x0 + x) * 4
                    let red = 77 * Int(pixels[p]), green = 150 * Int(pixels[p + 1]), blue = 29 * Int(pixels[p + 2])
                    out[y * cropWidth + x] = UInt8((red + green + blue) >> 8)
                }
            }
        }
        return out
    }
}

/// OpenCV's resizing of 8-bit images (cv::resize), in its arithmetic: with INTER_AREA, for the detector, as the
/// provider's cv2.resize gives it; with INTER_LINEAR, for the lines, as vita-vn-ocr's copy of it does
/// (vocr_onnx.py's preprocess).
enum OpenCVResize {
    /// Each output index's first source index and the two 11-bit weights: OpenCV's (float) coordinates, rounded as it
    /// does. Columns (`clamped`) move to the edge with all the weight on it outside the image; rows keep their
    /// weights (their indices are clamped when read).
    static func coefficients(_ outputCount: Int, _ inputCount: Int, clamped: Bool) -> [(index: Int, weight0: Int32, weight1: Int32)] {
        let scale = 1.0 / (Double(outputCount) / Double(inputCount))
        return (0..<outputCount).map { i in
            var f = Float((Double(i) + 0.5) * scale - 0.5)
            var index = Int(f.rounded(.down))
            f -= Float(index)
            if clamped && index < 0 { (f, index) = (0, 0) }
            if clamped && index >= inputCount - 1 { (f, index) = (0, inputCount - 1) }
            return (index, Int32(((1 - f) * 2048).rounded(.toNearestOrEven)), Int32((f * 2048).rounded(.toNearestOrEven)))
        }
    }

    /// The first `channels` of `pixels` (`width` x `height`, `pixelSize` bytes each) resized with INTER_LINEAR,
    /// interleaved.
    static func linear(_ pixels: [UInt8], width: Int, height: Int, pixelSize: Int, channels: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: toWidth * toHeight * channels)
        let rowSize = width * pixelSize, outRowSize = toWidth * channels
        let rows = coefficients(toHeight, height, clamped: false)
        let columns = coefficients(toWidth, width, clamped: true)
        // Each column's two source offsets and weights.
        let offsets = columns.map { ($0.index * pixelSize, ($0.index + 1 < width ? $0.index + 1 : $0.index) * pixelSize) }
        // Each source row resized across (OpenCV's horizontal pass, kept as integers), then two rows mixed down (its
        // vectorized vertical pass, which shifts in steps).
        var across = [Int32](repeating: 0, count: outRowSize)
        var previous = [Int32](repeating: 0, count: outRowSize)
        var cached = (first: -1, second: -1)
        pixels.withUnsafeBufferPointer { pixels in
            func resizeRow(_ row: Int, into buffer: inout [Int32]) {
                let source = pixels.baseAddress! + row * rowSize
                buffer.withUnsafeMutableBufferPointer { buffer in
                    for x in 0..<toWidth {
                        let (s0, s1) = offsets[x]
                        let (a0, a1) = (columns[x].weight0, columns[x].weight1)
                        for c in 0..<channels {
                            buffer[x * channels + c] = Int32(source[s0 + c]) &* a0 &+ Int32(source[s1 + c]) &* a1
                        }
                    }
                }
            }
            for (y, row) in rows.enumerated() {
                let r0 = min(max(row.index, 0), height - 1), r1 = min(max(row.index + 1, 0), height - 1)
                if cached != (r0, r1) {
                    if cached.second == r0 { swap(&previous, &across) } else { resizeRow(r0, into: &previous) }
                    resizeRow(r1, into: &across)
                    cached = (r0, r1)
                }
                let (b0, b1) = (row.weight0, row.weight1)
                out.withUnsafeMutableBufferPointer { out in
                    let target = out.baseAddress! + y * outRowSize
                    for i in 0..<outRowSize {
                        let top = (b0 &* (previous[i] >> 4)) >> 16, bottom = (b1 &* (across[i] >> 4)) >> 16
                        target[i] = UInt8(truncatingIfNeeded: (top &+ bottom &+ 2) >> 2)
                    }
                }
            }
        }
        return out
    }

    /// The first `channels` of `pixels` (`width` x `height`, `pixelSize` bytes each) made smaller with INTER_AREA,
    /// interleaved: each output pixel the average of the input pixels it covers, parts of pixels weighted by how much
    /// of them it covers (in floats, as OpenCV adds them up), or, when both sides shrink by whole factors, of whole
    /// pixels (in integers; halved, rounded as its vectorized code does).
    static func area(_ pixels: [UInt8], width: Int, height: Int, pixelSize: Int, channels: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        let scaleX = 1 / (Double(toWidth) / Double(width)), scaleY = 1 / (Double(toHeight) / Double(height))
        let wholeX = Int(scaleX.rounded(.toNearestOrEven)), wholeY = Int(scaleY.rounded(.toNearestOrEven))
        let whole = abs(scaleX - Double(wholeX)) < .ulpOfOne && abs(scaleY - Double(wholeY)) < .ulpOfOne
        let rowSize = width * pixelSize, outRowSize = toWidth * channels
        let columns = whole ? [] : areaTable(width, toWidth, scale: scaleX)
        let rows = whole ? [] : areaTable(height, toHeight, scale: scaleY)
        // Where each output row's entries start in `rows`.
        var rowStarts = [Int](repeating: rows.count, count: toHeight + 1)
        for (k, entry) in rows.enumerated() where k == 0 || entry.output != rows[k - 1].output { rowStarts[entry.output] = k }
        var out = [UInt8](repeating: 0, count: toWidth * toHeight * channels)
        // In bands of output rows, as OpenCV runs it (the same result).
        let bands = min(toHeight, 8)
        out.withUnsafeMutableBufferPointer { out in
            // Each band writes its own rows.
            nonisolated(unsafe) let out = out
            pixels.withUnsafeBufferPointer { pixels in
                nonisolated(unsafe) let pixels = pixels
                DispatchQueue.concurrentPerform(iterations: bands) { [rowStarts] band in
                    let (first, end) = (toHeight * band / bands, toHeight * (band + 1) / bands)
                    if whole {
                        let halved = wholeX == 2 && wholeY == 2
                        let scale = 1 / Float(wholeX * wholeY)
                        var sums = [Int32](repeating: 0, count: outRowSize)
                        for y in first..<end {
                            for i in 0..<outRowSize { sums[i] = 0 }
                            for dy in 0..<wholeY {
                                let source = pixels.baseAddress! + (y * wholeY + dy) * rowSize
                                for x in 0..<toWidth {
                                    for dx in 0..<wholeX {
                                        let pixel = source + (x * wholeX + dx) * pixelSize
                                        for c in 0..<channels { sums[x * channels + c] += Int32(pixel[c]) }
                                    }
                                }
                            }
                            for i in 0..<outRowSize {
                                out[y * outRowSize + i] = halved ? UInt8(truncatingIfNeeded: (sums[i] + 2) >> 2) : rounded(Float(sums[i]) * scale)
                            }
                        }
                        return
                    }
                    let across = UnsafeMutablePointer<Float>.allocate(capacity: outRowSize)
                    let sum = UnsafeMutablePointer<Float>.allocate(capacity: outRowSize)
                    defer { across.deallocate(); sum.deallocate() }
                    sum.initialize(repeating: 0, count: outRowSize)
                    var acrossRow = -1
                    var outputRow = rows[rowStarts[first]].output
                    func write(_ row: Int) {
                        for i in 0..<outRowSize { out[row * outRowSize + i] = rounded(sum[i]) }
                    }
                    columns.withUnsafeBufferPointer { columns in
                        for k in rowStarts[first]..<rowStarts[end] {
                            let entry = rows[k]
                            // An input row across (the same for the two output rows it can fall in).
                            if entry.input != acrossRow {
                                acrossRow = entry.input
                                let source = pixels.baseAddress! + entry.input * rowSize
                                across.initialize(repeating: 0, count: outRowSize)
                                for column in columns {
                                    let (s, d) = (source + column.input * pixelSize, across + column.output * channels)
                                    for c in 0..<channels { d[c] = d[c] + Float(s[c]) * column.alpha }
                                }
                            }
                            if entry.output != outputRow {
                                write(outputRow)
                                for i in 0..<outRowSize { sum[i] = entry.alpha * across[i] }
                                outputRow = entry.output
                            } else {
                                for i in 0..<outRowSize { sum[i] += entry.alpha * across[i] }
                            }
                        }
                    }
                    write(outputRow)
                }
            }
        }
        return out
    }

    /// OpenCV's computeResizeAreaTab: for each output index, the input indices it covers and how much of it each is.
    private static func areaTable(_ inputCount: Int, _ outputCount: Int, scale: Double) -> [(output: Int, input: Int, alpha: Float)] {
        var table: [(output: Int, input: Int, alpha: Float)] = []
        for d in 0..<outputCount {
            let start = Double(d) * scale, end = start + scale
            let cellWidth = min(scale, Double(inputCount) - start)
            var last = Int(end.rounded(.down))
            last = min(last, inputCount - 1)
            let first = min(Int(start.rounded(.up)), last)
            if Double(first) - start > 1e-3 { table.append((d, first - 1, Float((Double(first) - start) / cellWidth))) }
            for s in stride(from: first, to: last, by: 1) { table.append((d, s, Float(1.0 / cellWidth))) }
            if end - Double(last) > 1e-3 { table.append((d, last, Float(min(min(end - Double(last), 1), cellWidth) / cellWidth))) }
        }
        return table
    }

    /// OpenCV's saturate_cast<uchar> of a float: rounded to the nearest (halves to even), within 0...255.
    private static func rounded(_ value: Float) -> UInt8 {
        UInt8(min(max(value.rounded(.toNearestOrEven), 0), 255))
    }
}
