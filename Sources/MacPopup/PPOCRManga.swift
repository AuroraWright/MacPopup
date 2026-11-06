import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Text recognition with PP-OCRv6_manga's models (https://huggingface.co/Kellenok/PP-OCRv6_manga), trained on manga and
/// anime (Japanese and Chinese) and run with Core ML (converted by scripts/convert-ppocr-manga.py, see
/// vendor/ppocr-manga). This follows the repository's examples/onnx_openvino.py, but with the widening its README
/// recommends (`unclipRatio`: 1.5, where the example still has 1.4): a detector gives each pixel's probability of
/// being text, whose regions are the lines; a recognizer reads each line (columns turned to read across), with a
/// character or none for each of its output's steps (CTC).
final class PPOCRManga: @unchecked Sendable {
    static let shared = PPOCRManga()

    private struct Models {
        let detection: MLModel
        let recognition: MLModel
        /// The recognizer's characters: index 0 is no character, the last a space.
        let characters: [String]
    }

    /// The detector's input: the longer side this long (in multiples of 32), at most this long on either side.
    private static let detectionSide = 960.0, detectionMaxSide = 2048
    private static let lineHeight = 48
    /// How many lines are read at once.
    private static let concurrentLines = 4
    /// Lines are read at their natural width (at `lineHeight`), up to the most the recognizer takes.
    private static let maxLineWidth = 4800
    /// Pixels with a higher probability are text; regions whose average is lower are left out.
    private static let pixelThreshold: Float = 0.15, regionThreshold: Float = 0.25
    /// How far a region is widened on each side (its area times this, divided by its perimeter): the detector finds
    /// a line's core.
    private static let unclipRatio = 1.5
    /// ImageNet's, in the detector input's channel order (blue, green, red).
    private static let detectionMean: [Float] = [0.485, 0.456, 0.406], detectionDeviation: [Float] = [0.229, 0.224, 0.225]

    /// Predictions run one at a time, off the main thread.
    private let queue = DispatchQueue(label: "PPOCRManga", qos: .userInitiated)
    private var models: Models?

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Loads the models, if they aren't yet. Takes a moment, and the first prediction even longer (Core ML
    /// prepares them for the GPU), so they predict once on blank input.
    func prepare() async throws {
        try await run { _ in }
    }

    func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try await run { models in try Self.recognize(image, models: models) }
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
            throw Failure(errorDescription: "The PP-OCRv6_manga models are missing")
        }
        // Not the Neural Engine: with inputs of any size, it's several times slower than the GPU. The recognizer runs
        // on the CPU, where several lines are read at once (on the GPU, they'd mostly wait for each other).
        func load(_ name: String, on computeUnits: MLComputeUnits) throws -> MLModel {
            let url = directory.appendingPathComponent("\(name).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure(errorDescription: "The PP-OCRv6_manga model \(name) is missing")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        guard let list = try? String(contentsOf: directory.appendingPathComponent("PPOCRMangaCharacters.txt"), encoding: .utf8) else {
            throw Failure(errorDescription: "The PP-OCRv6_manga character list is missing")
        }
        var characters = list.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        if characters.last == "" { characters.removeLast() }
        let loaded = Models(
            detection: try load("PPOCRMangaDetection", on: .cpuAndGPU),
            recognition: try load("PPOCRMangaRecognition", on: .cpuOnly),
            characters: [""] + characters + [" "]
        )
        for (model, name, height, width) in [
            (loaded.detection, "image", 544, 960), (loaded.recognition, "line", Self.lineHeight, 320),
        ] {
            let input = try MLMultiArray(shape: [1, 3, height, width] as [NSNumber], dataType: .float32)
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in buffer.initialize(repeating: 0) }
            _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: input]))
        }
        models = loaded
        return loaded
    }

    // MARK: Pipeline

    private static func recognize(_ cgImage: CGImage, models: Models) throws -> [RecognizedLine] {
        guard let image = RGBImage(cgImage) else { throw Failure(errorDescription: "Couldn't read the image") }
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        let normalize = { (rect: CGRect) in
            CGRect(x: rect.minX / width, y: rect.minY / height, width: rect.width / width, height: rect.height / height)
        }
        let boxes = try detectLines(image, model: models.detection)
        var lines = [RecognizedLine?](repeating: nil, count: boxes.count)
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: min(concurrentLines, boxes.count)) { worker in
            for index in stride(from: worker, to: boxes.count, by: concurrentLines) {
                let box = boxes[index]
                // Columns (taller than wide) are turned to read across.
                let vertical = box.height > box.width
                let characters: [(text: String, steps: Range<Int>)], steps: Int
                do {
                    (characters, steps) = try read(image.cropped(box, rotated: vertical), models: models)
                } catch {
                    lock.withLock { failure = error }
                    return
                }
                guard !characters.isEmpty else { continue }
                // Each character where its steps are along the line, a quarter of a step earlier: a step's character
                // is recognized toward the end of what the step sees (closest to Google Lens' boxes on games and
                // manga).
                let length = vertical ? box.height : box.width
                let words = characters.map { character -> (text: String, box: CGRect) in
                    let start = length * max(0, CGFloat(character.steps.lowerBound) - 0.25) / CGFloat(steps)
                    let end = length * (CGFloat(character.steps.upperBound) - 0.25) / CGFloat(steps)
                    let rect = vertical
                        ? CGRect(x: box.minX, y: box.minY + start, width: box.width, height: end - start)
                        : CGRect(x: box.minX + start, y: box.minY, width: end - start, height: box.height)
                    return (character.text, normalize(rect))
                }
                let line = RecognizedLine(text: characters.map(\.text).joined(), box: normalize(box), words: words)
                lock.withLock { lines[index] = line }
            }
        }
        if let failure { throw failure }
        return lines.compactMap { $0 }
    }

    /// The lines' boxes in image pixels.
    private static func detectLines(_ image: RGBImage, model: MLModel) throws -> [CGRect] {
        let (width, height) = (Double(image.width), Double(image.height))
        // Long strips (e.g. webtoons) get the pixels of a 3:4 page with the longer side `detectionSide` long.
        let ratio = max(width, height) / min(width, height) > 2
            ? min(1, (0.75 * detectionSide * detectionSide / (width * height)).squareRoot())
            : detectionSide / max(width, height)
        let side = { (length: Double) in min(max(Int((length * ratio / 32).rounded(.toNearestOrEven)) * 32, 32), detectionMaxSide) }
        let (inputWidth, inputHeight) = (side(width), side(height))
        let input = try MLMultiArray(shape: [1, 3, inputHeight, inputWidth] as [NSNumber], dataType: .float32)
        image.write(CGRect(x: 0, y: 0, width: image.width, height: image.height), into: input, width: inputWidth,
                    height: inputHeight, mean: detectionMean, deviation: detectionDeviation, rounded: true)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let probabilities = output.featureValue(for: "probabilities")?.multiArrayValue else {
            throw Failure(errorDescription: "Unexpected detection output")
        }
        let map = MLShapedArray<Float>(converting: probabilities)
        var lines: [CGRect] = []
        map.withUnsafeShapedBufferPointer { values, _, strides in
            let rowStride = strides[2], columnStride = strides[3]
            let probability = { (x: Int, y: Int) in values[y * rowStride + x * columnStride] }
            for region in textRegions(width: inputWidth, height: inputHeight, probability: probability) {
                guard let bounds = widenedBounds(region.hull, outline: region.outline) else { continue }
                // Back to the image's pixels (rounded, within the image).
                let x = { (value: CGFloat) in min(max((Double(value) / Double(inputWidth) * width).rounded(.toNearestOrEven), 0), width) }
                let y = { (value: CGFloat) in min(max((Double(value) / Double(inputHeight) * height).rounded(.toNearestOrEven), 0), height) }
                let x1 = x(bounds.minX), y1 = y(bounds.minY), x2 = x(bounds.maxX), y2 = y(bounds.maxY)
                guard x2 > x1, y2 > y1 else { continue }
                lines.append(CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
            }
        }
        return lines
    }

    /// Each region of text pixels (8-connected, as OpenCV's contours) with an average probability over
    /// `regionThreshold`: its outline and its convex hull (pixel centers).
    private static func textRegions(width: Int, height: Int, probability: (Int, Int) -> Float) -> [(outline: [CGPoint], hull: [CGPoint])] {
        var label = [Int32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where probability(x, y) > pixelThreshold { label[y * width + x] = -1 }
        }
        var regions: [(outline: [CGPoint], hull: [CGPoint])] = []
        var stack: [Int] = []
        var next: Int32 = 0
        for start in 0..<label.count where label[start] == -1 {
            next += 1
            label[start] = next
            stack.append(start)
            var total: Float = 0, count = 0
            // Each row's leftmost and rightmost pixel: the hull's points are among them.
            var rows: [Int: (Int, Int)] = [:]
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                total += probability(x, y)
                count += 1
                rows[y] = rows[y].map { (min($0.0, x), max($0.1, x)) } ?? (x, x)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < width, label[ny * width + nx] == -1 else { continue }
                        label[ny * width + nx] = next
                        stack.append(ny * width + nx)
                    }
                }
            }
            guard total / Float(count) >= regionThreshold else { continue }
            let outline = border(from: start, region: next, label: label, width: width, height: height)
            // OpenCV's contours with under 4 corners (e.g. a line of pixels) are left out.
            guard corners(of: outline) >= 4 else { continue }
            let points = rows.flatMap { y, ends in [CGPoint(x: ends.0, y: y), CGPoint(x: ends.1, y: y)] }
            regions.append((outline, convexHull(points)))
        }
        return regions
    }

    /// The neighbors of a pixel, counterclockwise on screen from the right.
    private static let neighbors = [(1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1), (0, 1), (1, 1)]

    /// The outer border of the region labeled `region`, from its first pixel in raster order (`start`), as OpenCV's
    /// findContours follows it (Suzuki and Abe's border following): the region's pixels on it, in order.
    private static func border(from start: Int, region: Int32, label: [Int32], width: Int, height: Int) -> [CGPoint] {
        let inRegion = { (x: Int, y: Int) in x >= 0 && x < width && y >= 0 && y < height && label[y * width + x] == region }
        let first = (x: start % width, y: start / width)
        // Around the first pixel, clockwise from its left neighbor (not in the region: it's the first in its row).
        guard let toSecond = (0..<8).map({ (4 - $0 + 8) % 8 }).first(where: {
            inRegion(first.x + neighbors[$0].0, first.y + neighbors[$0].1)
        }) else { return [CGPoint(x: first.x, y: first.y)] }
        let second = (x: first.x + neighbors[toSecond].0, y: first.y + neighbors[toSecond].1)
        var points: [CGPoint] = []
        var current = first
        // The direction from the current pixel to the one before it on the border.
        var back = toSecond
        while true {
            // Around the current pixel, counterclockwise from the one after the previous.
            var direction = back
            for step in 1...8 {
                let candidate = (back + step) % 8
                if inRegion(current.x + neighbors[candidate].0, current.y + neighbors[candidate].1) {
                    direction = candidate
                    break
                }
            }
            points.append(CGPoint(x: current.x, y: current.y))
            let next = (x: current.x + neighbors[direction].0, y: current.y + neighbors[direction].1)
            if next == first && current == second { break }
            back = (direction + 4) % 8
            current = next
        }
        return points
    }

    /// How many points OpenCV keeps of `outline` (CHAIN_APPROX_SIMPLE: where the direction changes).
    private static func corners(of outline: [CGPoint]) -> Int {
        guard outline.count > 2 else { return outline.count }
        let direction = { (a: CGPoint, b: CGPoint) in [b.x - a.x, b.y - a.y] }
        return outline.indices.filter { index in
            let previous = outline[(index + outline.count - 1) % outline.count], next = outline[(index + 1) % outline.count]
            return direction(previous, outline[index]) != direction(outline[index], next)
        }.count
    }

    /// Andrew's monotone chain.
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = Set(points.map { [$0.x, $0.y] }).map { CGPoint(x: $0[0], y: $0[1]) }
            .sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count > 2 else { return sorted }
        let cross = { (o: CGPoint, a: CGPoint, b: CGPoint) in (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The bounds of the region widened on every side by its area times `unclipRatio` over its perimeter (of its
    /// `outline`), as the reference widens it (with rounded corners): its convex `hull`'s bounds, that much bigger on
    /// each side. Nil if it has no area or the smallest rectangle (any angle) around the widened region is under 3
    /// pixels thick: that's the hull's smallest rectangle, at the same angle, wider on each side by the distance.
    private static func widenedBounds(_ hull: [CGPoint], outline: [CGPoint]) -> CGRect? {
        var area = 0.0, perimeter = 0.0
        for (index, point) in outline.enumerated() {
            let next = outline[(index + 1) % outline.count]
            area += Double(point.x * next.y - next.x * point.y)
            perimeter += Double(hypot(next.x - point.x, next.y - point.y))
        }
        area = abs(area) / 2
        guard area > 0, perimeter > 0 else { return nil }
        let distance = area * unclipRatio / perimeter
        var best: (area: Double, thickness: Double)?
        for (index, point) in hull.enumerated() {
            let next = hull[(index + 1) % hull.count]
            let length = Double(hypot(next.x - point.x, next.y - point.y))
            guard length > 0 else { continue }
            // Along this edge (u) and across it (v).
            let ux = Double(next.x - point.x) / length, uy = Double(next.y - point.y) / length
            let along = hull.map { Double($0.x) * ux + Double($0.y) * uy }
            let across = hull.map { -Double($0.x) * uy + Double($0.y) * ux }
            let u0 = along.min()! - distance, u1 = along.max()! + distance
            let v0 = across.min()! - distance, v1 = across.max()! + distance
            let rectArea = (u1 - u0) * (v1 - v0)
            guard best.map({ rectArea < $0.area }) ?? true else { continue }
            best = (rectArea, min(u1 - u0, v1 - v0))
        }
        guard let best, best.thickness >= 3 else { return nil }
        let xs = hull.map(\.x), ys = hull.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -distance, dy: -distance)
    }

    /// The characters the recognizer reads in `line` (turned to read across), each with its output steps, and the
    /// number of steps.
    private static func read(_ line: RGBImage, models: Models) throws -> (characters: [(text: String, steps: Range<Int>)], steps: Int) {
        let natural = Int((Double(lineHeight) * Double(line.width) / Double(max(1, line.height))).rounded(.toNearestOrEven))
        let width = max(16, min(maxLineWidth, natural))
        let input = try MLMultiArray(shape: [1, 3, lineHeight, width] as [NSNumber], dataType: .float32)
        line.write(CGRect(x: 0, y: 0, width: line.width, height: line.height), into: input, width: width,
                   height: lineHeight, mean: [0.5, 0.5, 0.5], deviation: [0.5, 0.5, 0.5], rounded: true)
        let output = try models.recognition.prediction(from: MLDictionaryFeatureProvider(dictionary: ["line": input]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw Failure(errorDescription: "Unexpected recognition output")
        }
        let scores = MLShapedArray<Float>(converting: logits)
        var characters: [(text: String, steps: Range<Int>)] = []
        var steps = 0
        scores.withUnsafeShapedBufferPointer { values, shape, strides in
            steps = shape[1]
            let classes = shape[2]
            var previous = 0
            for step in 0..<steps {
                // The most likely class: 0 is no character, a repeat continues the character before.
                var best: Float = 0
                var index: vDSP_Length = 0
                vDSP_maxvi(values.baseAddress! + step * strides[1], vDSP_Stride(strides[2]), &best, &index, vDSP_Length(classes))
                let found = Int(index) / strides[2]
                if found != 0 && found < models.characters.count {
                    if found == previous, let last = characters.indices.last {
                        characters[last].steps = characters[last].steps.lowerBound..<(step + 1)
                    } else {
                        characters.append((models.characters[found], step..<(step + 1)))
                    }
                }
                previous = found
            }
        }
        return (characters, steps)
    }
}
