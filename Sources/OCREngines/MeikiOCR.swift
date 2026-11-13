import CoreGraphics
import CoreML
import Foundation

/// Text recognition with meikiocr's models (https://github.com/rtr46/meikiocr), trained on Japanese game text and
/// run with Core ML (converted by scripts/convert-meikiocr.py, see vendor/meikiocr). This follows meikiocr/ocr.py:
/// a detector finds the lines, then a recognizer finds each line's characters (as boxes with a character code).
public final class MeikiOCR: @unchecked Sendable {
    public static let shared = MeikiOCR()

    private struct Models {
        let detection: MLModel
        let horizontal: MLModel
        let vertical: MLModel
    }

    private struct Candidate {
        var character: Character
        var box: CGRect
        var confidence: Float
        /// Along the line, in image pixels.
        var interval: (start: Int, end: Int)
    }

    /// Model input sizes.
    private static let detectionSize = (width: 960, height: 544)
    private static let lineHeight = 32, lineWidth = 960
    private static let columnWidth = 32, columnHeight = 480
    /// Longer columns are read in parts this long (in model pixels), overlapping by this much.
    private static let columnPart = 420, columnOverlap = 64
    private static let detectionThreshold: Float = 0.5
    private static let characterThreshold: Float = 0.1
    /// Characters overlapping a more confident one by more than this (of the shorter one) are dropped.
    private static let overlapThreshold = 0.3
    /// Lines read at once.
    private static let concurrentLines = 4
    /// Pairs the recognizer reads in the wrong order.
    private static let swappedPairs = [
        "儡傀": "傀儡", "談冗": "冗談", "汰淘": "淘汰", "沱滂": "滂沱",
        "攣痙": "痙攣", "酊酩": "酩酊", "麭麺": "麺麭", "哭慟": "慟哭",
    ]

    /// Pictures are read one at a time, off the main thread.
    private let queue = DispatchQueue(label: "MeikiOCR", qos: .userInitiated)
    private var models: Models?
    private let lineCache = LineCache<[Found]>()

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Loads the models, if they aren't yet. Takes a moment, and the first prediction even longer (Core ML
    /// prepares them for the GPU), so they predict once on blank input.
    public func prepare() async throws {
        try await run { _ in }
    }

    /// Lets the models go, to free their memory (the iOS app does when it's in the background); the next picture loads
    /// them again.
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
                continuation.resume(with: Result { try body(self.loadedModels()) })
            }
        }
    }

    private func loadedModels() throws -> Models {
        if let models { return models }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Models") else {
            throw Failure(errorDescription: "The meikiocr models are missing")
        }
        func load(_ name: String, on computeUnits: MLComputeUnits) throws -> MLModel {
            let url = directory.appendingPathComponent("\(name).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure(errorDescription: "The meikiocr model \(name) is missing")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        // The recognizers on the CPU, several lines at once (see recognize): faster than one at a time on the GPU,
        // with the same results.
        let loaded = Models(
            detection: try load("MeikiDetection", on: OCRCompute.units(.all)),
            horizontal: try load("MeikiRecognition", on: .cpuOnly),
            vertical: try load("MeikiVerticalRecognition", on: .cpuOnly)
        )
        for (model, height, width) in [
            (loaded.detection, Self.detectionSize.height, Self.detectionSize.width),
            (loaded.horizontal, Self.lineHeight, Self.lineWidth),
            (loaded.vertical, Self.columnHeight, Self.columnWidth),
        ] {
            let input = try MLMultiArray(shape: [1, 3, height, width] as [NSNumber], dataType: .float32)
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in buffer.initialize(repeating: 0) }
            _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["images": input]))
        }
        models = loaded
        return loaded
    }

    // MARK: Pipeline

    private static func recognize(_ cgImage: CGImage, models: Models, cache: LineCache<[Found]>) throws -> [RecognizedLine] {
        guard let image = RGBImage(cgImage) else { throw Failure(errorDescription: "Couldn't read the image") }
        let (width, height) = (image.width, image.height)
        var boxes = try detectLines(image, model: models.detection)
        // A line cut off by the image's edge (e.g. the top half of one below the area read) reads as garbage.
        let thickness = { (box: CGRect) in min(box.width, box.height) }
        let thickest = boxes.map(thickness).max() ?? 0
        boxes.removeAll { box in
            let atEdge = box.height > box.width
                ? box.minX <= 1 || box.maxX >= CGFloat(width - 1)
                : box.minY <= 1 || box.maxY >= CGFloat(height - 1)
            return atEdge && thickness(box) < thickest * 0.7
        }
        // In reading order: vertical text (mostly taller lines) right to left.
        if boxes.filter({ $0.height > $0.width }).count * 2 > boxes.count {
            boxes.sort { $0.maxX > $1.maxX }
        }
        let normalize = { (rect: CGRect) in
            CGRect(x: rect.minX / CGFloat(width), y: rect.minY / CGFloat(height),
                   width: rect.width / CGFloat(width), height: rect.height / CGFloat(height))
        }
        var lines = [RecognizedLine?](repeating: nil, count: boxes.count)
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: min(concurrentLines, boxes.count)) { worker in
            for index in stride(from: worker, to: boxes.count, by: concurrentLines) {
                let box = boxes[index]
                let vertical = box.height > box.width
                let characters: [Candidate]
                do {
                    characters = vertical
                        ? try recognizeColumn(image, box: box, model: models.vertical, cache: cache)
                        : try recognizeLine(image, box: box, model: models.horizontal, cache: cache)
                } catch {
                    lock.withLock { failure = error }
                    return
                }
                guard !characters.isEmpty else { continue }
                let line = RecognizedLine(
                    text: String(characters.map(\.character)),
                    box: normalize(box),
                    words: characters.map { (String($0.character), normalize($0.box)) }
                )
                lock.withLock { lines[index] = line }
            }
        }
        if let failure { throw failure }
        cache.endReading()
        return lines.compactMap { $0 }
    }

    /// The lines' boxes in image pixels, top to bottom.
    private static func detectLines(_ image: RGBImage, model: MLModel) throws -> [CGRect] {
        let (inputWidth, inputHeight) = detectionSize
        let scale = min(Double(inputWidth) / Double(image.width), Double(inputHeight) / Double(image.height))
        let resizedWidth = Int(Double(image.width) * scale), resizedHeight = Int(Double(image.height) * scale)
        let input = try MLMultiArray(shape: [1, 3, inputHeight, inputWidth] as [NSNumber], dataType: .float32)
        image.write(CGRect(x: 0, y: 0, width: image.width, height: image.height), into: input,
                    width: resizedWidth, height: resizedHeight)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["images": input]))
        guard let boxes = output.featureValue(for: "boxes")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue else {
            throw Failure(errorDescription: "Unexpected detection output")
        }
        var lines: [CGRect] = []
        for index in 0..<scores.shape[1].intValue where scores[[0, index] as [NSNumber]].floatValue > detectionThreshold {
            // In the model's input pixels: back to the image's, clamped to it and truncated (as meikiocr).
            let corner = { (i: Int, limit: Int) in
                Int(min(max(boxes[[0, index, i] as [NSNumber]].doubleValue / scale, 0), Double(limit)))
            }
            let (x1, y1, x2, y2) = (corner(0, image.width), corner(1, image.height), corner(2, image.width), corner(3, image.height))
            guard x2 > x1, y2 > y1 else { continue }
            lines.append(CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
        }
        return lines.sorted { $0.minY < $1.minY }
    }

    private static func recognizeLine(_ image: RGBImage, box: CGRect, model: MLModel, cache: LineCache<[Found]>) throws -> [Candidate] {
        var height = lineHeight
        var width = Int((box.width * CGFloat(lineHeight) / box.height).rounded())
        if width > lineWidth {
            height = Int((Double(lineHeight) * Double(lineWidth) / Double(width)).rounded())
            width = lineWidth
        }
        guard width > 0, height > 0 else { return [] }
        var candidates: [Candidate] = []
        let found = try characters(in: image, part: box, width: width, height: height, input: (lineWidth, lineHeight), model: model, cache: cache)
        for (character, rect, confidence) in found {
            guard rect.minX < CGFloat(width) else { continue }
            let x1 = Int(box.minX) + Int(min(rect.minX, CGFloat(width)) / CGFloat(width) * box.width)
            let x2 = Int(box.minX) + Int(min(rect.maxX, CGFloat(width)) / CGFloat(width) * box.width)
            let y1 = Int(box.minY) + Int(rect.minY / CGFloat(lineHeight) * box.height)
            let y2 = Int(box.minY) + Int(rect.maxY / CGFloat(lineHeight) * box.height)
            candidates.append(Candidate(character: character, box: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1),
                                        confidence: confidence, interval: (x1, x2)))
        }
        return suppressOverlaps(candidates)
    }

    private static func recognizeColumn(_ image: RGBImage, box: CGRect, model: MLModel, cache: LineCache<[Found]>) throws -> [Candidate] {
        let scale = Double(columnWidth) / Double(box.width)
        let (y1, y2) = (Double(box.minY), Double(box.maxY))
        // Columns longer than the model's input are read in overlapping parts.
        var starts: [Double] = []
        let partHeight: Double, maxHeight: Int
        if Double(box.height) * scale > Double(columnHeight) {
            maxHeight = columnPart
            partHeight = Double(columnPart) / scale
            let stride = Double(columnPart - columnOverlap) / scale
            var start = y1
            while start + partHeight < y2 {
                starts.append(start)
                start += stride
            }
            let last = y2 - partHeight
            if starts.isEmpty || last > starts[starts.count - 1] + 1 { starts.append(last) }
        } else {
            maxHeight = columnHeight
            partHeight = y2 - y1
            starts = [y1]
        }
        var candidates: [Candidate] = []
        for start in starts {
            let top = Int(start.rounded()), bottom = min(Int((start + partHeight).rounded()), Int(y2))
            guard bottom > top else { continue }
            let part = CGRect(x: box.minX, y: CGFloat(top), width: box.width, height: CGFloat(bottom - top))
            let height = min(Int((Double(bottom - top) * scale).rounded()), maxHeight)
            guard height > 0 else { continue }
            let found = try characters(in: image, part: part, width: columnWidth, height: height, input: (columnWidth, columnHeight),
                                       model: model, cache: cache)
            for (character, rect, confidence) in found {
                guard rect.minY < CGFloat(height) else { continue }
                let x1 = Int(part.minX) + Int(rect.minX / CGFloat(columnWidth) * part.width)
                let x2 = Int(part.minX) + Int(rect.maxX / CGFloat(columnWidth) * part.width)
                let cy1 = Int(part.minY) + Int(min(rect.minY, CGFloat(height)) / CGFloat(height) * part.height)
                let cy2 = Int(part.minY) + Int(min(rect.maxY, CGFloat(height)) / CGFloat(height) * part.height)
                guard cy2 > cy1 else { continue }
                candidates.append(Candidate(character: character, box: CGRect(x: x1, y: cy1, width: x2 - x1, height: cy2 - cy1),
                                            confidence: confidence, interval: (cy1, cy2)))
            }
        }
        return suppressOverlaps(candidates)
    }

    /// A character the recognizer is confident enough about, its box in model pixels.
    private typealias Found = (character: Character, box: CGRect, confidence: Float)

    /// The characters the recognizer is confident enough about in `part` of the image, resized to `width` x `height`
    /// into the top left of its input (`input` wide and high). The input is made of only those pixels and sizes, so
    /// they're what `cache` (with recent readings' characters) knows it by.
    private static func characters(
        in image: RGBImage, part: CGRect, width: Int, height: Int, input: (width: Int, height: Int), model: MLModel,
        cache: LineCache<[Found]>
    ) throws -> [Found] {
        let pixels = image.cropped(part)
        let key = pixels.pixels.withUnsafeBytes {
            LineCache<[Found]>.Key($0, [pixels.width, pixels.height, width, height, input.width, input.height])
        }
        return try cache.value(key) {
            let array = try MLMultiArray(shape: [1, 3, input.height, input.width] as [NSNumber], dataType: .float32)
            image.write(part, into: array, width: width, height: height)
            return try characters(model: model, input: array)
        }
    }

    private static func characters(model: MLModel, input: MLMultiArray) throws -> [Found] {
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["images": input]))
        guard let codes = output.featureValue(for: "char_codes")?.multiArrayValue,
              let boxes = output.featureValue(for: "boxes")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue else {
            throw Failure(errorDescription: "Unexpected recognition output")
        }
        var found: [Found] = []
        for index in 0..<scores.shape[1].intValue {
            let confidence = scores[[0, index] as [NSNumber]].floatValue
            // U+FFFD is its "unknown character".
            guard confidence >= characterThreshold,
                  let scalar = Unicode.Scalar(UInt32(clamping: codes[[0, index] as [NSNumber]].intValue)),
                  scalar != "\u{FFFD}" else { continue }
            let corner = { (i: Int) in CGFloat(boxes[[0, index, i] as [NSNumber]].doubleValue) }
            found.append((Character(scalar), CGRect(x: corner(0), y: corner(1), width: corner(2) - corner(0), height: corner(3) - corner(1)), confidence))
        }
        return found
    }

    /// Keeps the most confident of characters that overlap along the line, in reading order, and puts the
    /// pairs the recognizer reads in the wrong order right.
    private static func suppressOverlaps(_ candidates: [Candidate]) -> [Candidate] {
        var accepted: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let (start, end) = candidate.interval
            let overlaps = accepted.contains { other in
                let (otherStart, otherEnd) = other.interval
                if start >= otherEnd || otherStart >= end { return false }
                let shared = Double(max(0, min(end, otherEnd) - max(start, otherStart)))
                let shorter = min(Double(end - start), Double(otherEnd - otherStart)) + 1e-6
                return shared / shorter > overlapThreshold
            }
            if !overlaps { accepted.append(candidate) }
        }
        accepted.sort { $0.interval.start < $1.interval.start }
        // Searched by candidate, not in a joined String, where a combining mark read on its own would join the
        // character before it and shift the indices after it.
        let characters = accepted.map(\.character)
        for (wrong, right) in swappedPairs {
            let wrong = Array(wrong), right = Array(right)
            guard let index = characters.indices.dropLast().first(where: { characters[$0] == wrong[0] && characters[$0 + 1] == wrong[1] })
            else { continue }
            accepted[index].character = right[0]
            accepted[index + 1].character = right[1]
        }
        return accepted
    }
}
