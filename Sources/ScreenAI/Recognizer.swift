import Accelerate
import CoreML
import Foundation

// Line recognition: GocrLineRecognizer (line images, chunked model runs, CTC decoding) for every LINE the detector
// found, run by the MultiPassLineRecognitionMutator: the "und" recognizer first, then, for lines whose language
// selects another recognizer, that one. Each line gets its text, language, words and symbols.

private let modelRoot = "gocr/gocr_models/"
private let modelDir = "gocr/gocr_models/line_recognition_mobile_convnext320_omni/"
private let multiPassConfig = "gocr/gocr_models/gocr_line_recognition_omni_mobile_chrome_multiscript_2024_q4.binarypb"

// Fixed line geometry of every shipped GocrLineRecognizerConfig (scaled_image_height, chunk_width,
// chunk_left/right_padding, frame_width, num_chunk_per_batch).
private let lineHeight = 32, chunkWidth = 136, pad = 16, frameWidth = 4, batchSize = 8
private let chunkInput = pad + chunkWidth + pad  // 168

/// google_ocr.GocrLineRecognizerConfig (the fields that differ between the shipped recognizers).
private struct RecognizerConfig {
    var recognizerName = "", modelPath = "", labelMapPath = "", scriptId = ""
    var baseDirRtl = false
    /// The config has a ctc_decoder_config with an LM: CtcBeamDecoder decodes instead of greedy decoding.
    var hasCtcDecoder = false
    var scriptNames: [String] = [], supportedScripts: [String] = [], contentTypeNames: [String] = []
    /// Output indices of the optional heads (0 = not used: the line gets default symbol boxes, no script/content
    /// type/direction prediction).
    var symbolBoxIndex = 0, scriptIndex = 0, contentTypeIndex = 0, directionIndex = 0
    /// How many batches run at once.
    var poolSize = 1

    init?(_ lineRecognizerConfig: [UInt8]) {
        // LineRecognizerConfig{name=1, sub_config=2 (Any{type_url=1, value=2})}
        var sub: ArraySlice<UInt8> = []
        var r = ProtoReader(lineRecognizerConfig)
        while r.next() {
            guard r.field == 2 else { continue }
            var any = ProtoReader(r.bytes)
            while any.next() {
                if any.field == 2 { sub = any.bytes }
            }
        }
        if sub.isEmpty { return nil }
        var g = ProtoReader(sub)
        while g.next() {
            switch g.field {
            case 1: recognizerName = g.string
            case 12: baseDirRtl = g.varint != 0
            case 14: labelMapPath = g.string
            case 17: scriptId = g.string
            case 13:  // TensorFlowModelRunnerConfig.tflite_model_pooled_runner_config (3)
                var t = ProtoReader(g.bytes)
                while t.next() {
                    guard t.field == 3 else { continue }
                    var p = ProtoReader(t.bytes)
                    while p.next() {
                        if p.field == 1 { modelPath = p.string }
                        if p.field == 2 { poolSize = max(1, p.int) }
                    }
                }
            case 102:  // GocrCTCDecoderRecognizerConfig
                var d = ProtoReader(g.bytes)
                while d.next() {
                    switch d.field {
                    case 1:
                        var cd = ProtoReader(d.bytes)
                        while cd.next() {
                            if cd.field == 1 { hasCtcDecoder = true }  // lm_spec
                        }
                    case 10: scriptNames.append(d.string)
                    case 11: supportedScripts.append(d.string)
                    case 12: contentTypeNames.append(d.string)
                    case 19: symbolBoxIndex = d.int
                    case 20: scriptIndex = d.int
                    case 21: contentTypeIndex = d.int
                    case 22: directionIndex = d.int
                    default: break
                    }
                }
            default:
                break
            }
        }
        if !g.ok || modelPath.isEmpty { return nil }
    }
}

// MARK: - Line images (GocrLineRecognizer::CreateLineImage): deskewed crop of the line box at page resolution

@inline(__always) private func roundHalfAway(_ v: Float) -> Int { Int(v.rounded(.toNearestOrAwayFromZero)) }

private func alignedBox(_ b: RotatedBox) -> (l: Int, t: Int, w: Int, h: Int) {
    let a = b.angle
    if a == 0 { return (b.left, b.top, b.width, b.height) }
    let r = a * 0.0174532924
    let sc = sinCos(Double(r))
    let s = Float(sc.sin), c = Float(sc.cos)
    let fw = Float(b.width - 1), fh = Float(b.height - 1)
    let fl = Float(b.left), ft = Float(b.top)
    let x1 = c * fw + fl, y1 = s * fw + ft
    let x2 = x1 + -(s * fh), y2 = y1 + c * fh
    let x3 = -(s * fh) + fl, y3 = c * fh + ft
    let mnx = min(fl, x1, x2, x3), mxx = max(fl, x1, x2, x3)
    let mny = min(ft, y1, y2, y3), mxy = max(ft, y1, y2, y3)
    let L = roundHalfAway(mnx), T = roundHalfAway(mny)
    let R = roundHalfAway(mnx + (mxx - mnx)), B = roundHalfAway(mny + (mxy - mny))
    return (L, T, R - L + 1, B - T + 1)
}

private func clip(_ r: inout (l: Int, t: Int, w: Int, h: Int), _ W: Int, _ H: Int) {
    if r.l < 0 {
        r.w = r.l + r.w
        r.l = 0
    }
    if r.t < 0 {
        r.h = r.t + r.h
        r.t = 0
    }
    if r.l + r.w > W { r.w = W - r.l }
    if r.t + r.h > H { r.h = H - r.t }
}

/// Inverse-affine bilinear warp with 10-bit fixed-point coordinates and 5-bit interpolation weights.
/// OpenCV's bilinear tables for warpAffine (INTER_BITS 5): per fractional position (fy * 32 + fx), the weights of the
/// four neighbours as floats and in 15-bit fixed point.
private let bilinearTable: (float: [Float], fixed: [Int]) = {
    var float = [Float](repeating: 0, count: 4 * 1024), fixed = [Int](repeating: 0, count: 4 * 1024)
    for idx in 0..<1024 {
        let fx = Double(idx & 31) / 32.0, fy = Double(idx >> 5) / 32.0
        let w = [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]
        for k in 0..<4 {
            float[4 * idx + k] = Float(w[k])
            fixed[4 * idx + k] = Int((w[k] * 32768).rounded(.toNearestOrEven))
        }
    }
    return (float, fixed)
}()

private func warp(_ page: GrayImage, _ cl: Int, _ ct: Int, _ sw: Int, _ sh: Int, _ M: [Float], _ dw: Int, _ dh: Int)
    -> GrayImage
{
    var out = GrayImage(width: dw, height: dh)
    let fp = M.map { Int(($0 * 1024).rounded(.toNearestOrEven)) }
    let pw = page.width
    page.data.withUnsafeBufferPointer { pd in
        out.data.withUnsafeMutableBufferPointer { od in
            bilinearTable.float.withUnsafeBufferPointer { tf in
                bilinearTable.fixed.withUnsafeBufferPointer { tq in
                    let base = pd.baseAddress! + ct * pw + cl
                    func src(_ x: Int, _ y: Int) -> Int { Int(base[y * pw + x]) }
                    for v in 0..<dh {
                        for u in 0..<dw {
                            let xf = Int32(truncatingIfNeeded: fp[4] + 16 + u * fp[0] + v * fp[1])
                            let yf = Int32(truncatingIfNeeded: fp[5] + 16 + u * fp[2] + v * fp[3])
                            let x = Int(Int16(truncatingIfNeeded: xf >> 10)), y = Int(Int16(truncatingIfNeeded: yf >> 10))
                            let t = 4 * Int((yf & 0x3E0) | ((xf >> 5) & 0x1F))
                            var value: Int
                            if (x & 0xFFFF) < sw - 1 && (y & 0xFFFF) < sh - 1 {
                                let a = tf[t] * Float(src(x, y)) + tf[t + 1] * Float(src(x + 1, y))
                                let val = (a + tf[t + 2] * Float(src(x, y + 1))) + tf[t + 3] * Float(src(x + 1, y + 1))
                                value = min(255, max(0, Int(val.rounded(.toNearestOrEven))))
                            } else {
                                let x0 = x < 0 ? 0 : min(x, sw - 1), x1 = x < -1 ? 0 : min(x + 1, sw - 1)
                                let y0 = y < 0 ? 0 : min(y, sh - 1), y1 = y < -1 ? 0 : min(y + 1, sh - 1)
                                let sum = tq[t] * src(x0, y0) + tq[t + 1] * src(x1, y0) + tq[t + 2] * src(x0, y1)
                                    + tq[t + 3] * src(x1, y1)
                                value = (sum + 0x4000) >> 15
                            }
                            od[v * dw + u] = UInt8(truncatingIfNeeded: value)
                        }
                    }
                }
            }
        }
    }
    return out
}

private func lineImage(_ page: GrayImage, _ b: RotatedBox) -> GrayImage {
    if let curve = b.curve { return curvedLineImage(page, curve) }  // ImageCrop of a curved_box polygon
    if b.angle == 0 {
        var r = (l: b.left, t: b.top, w: b.width, h: b.height)
        clip(&r, page.width, page.height)
        if r.w <= 0 || r.h <= 0 { return GrayImage() }
        var out = GrayImage(width: r.w, height: r.h)
        GrayImage.copyRows(page.data, r.t * page.width + r.l, page.width, &out.data, 0, r.w, count: r.w, rows: r.h)
        return out
    }
    var r = alignedBox(b)
    clip(&r, page.width, page.height)
    if r.w <= 0 || r.h <= 0 || b.width <= 0 || b.height <= 0 { return GrayImage() }
    let rad = Float(Double(b.angle) * 3.141592653589793 / 180.0)
    let sc = sinCos(Double(rad))
    let s = Float(sc.sin), c = Float(sc.cos)
    let M = [c, -s, s, c, Float(b.left - r.l), Float(b.top - r.t)]
    return warp(page, r.l, r.t, r.w, r.h, M, b.width, b.height)
}

private func scaleToHeight(_ img: GrayImage) -> GrayImage {
    if img.height == lineHeight { return img }
    let sc = Float(lineHeight) / Float(img.height)
    let w = max(1, Int((sc * Float(img.width)).rounded(.toNearestOrEven)))
    let h = max(1, Int((sc * Float(img.height)).rounded(.toNearestOrEven)))
    return img.scaled(to: w, h, .box)
}

/// Chunks of 136 columns with 16 columns of context on each side (zero outside the line).
private func chunks(_ img: GrayImage) -> [[UInt8]] {
    var out: [[UInt8]] = []
    let W = img.width, H = img.height
    var s = 0
    while true {
        let left = min(s, pad)
        var n = W - s
        if s + chunkWidth + pad <= W { n = chunkWidth + pad }
        var c = [UInt8](repeating: 0, count: H * chunkInput)
        GrayImage.copyRows(img.data, s - left, W, &c, pad - left, chunkInput, count: left + n, rows: H)
        out.append(c)
        s += chunkWidth
        if s >= W { break }
    }
    return out
}

private func rotate180(_ img: GrayImage) -> GrayImage {
    var out = img
    out.data.reverse()
    return out
}

// MARK: - Script recognizer

/// Per-line model outputs after GocrLineRecognizer::DecodeLines (chunks merged, gated heads reduced).
private struct LineTensors {
    var frames = 0
    /// [frames][k = 5][2] {class, value}
    var logits: [Float] = []
    var left: [Float] = [], right: [Float] = [], top: [Float] = [], height: [Float] = []
    /// Softmax over the gated activations (empty if absent).
    var script: [Float] = [], content: [Float] = [], direction: [Float] = []

    /// Adds the next chunk's frames.
    mutating func append(_ chunk: LineTensors) {
        frames += chunk.frames
        logits += chunk.logits
        left += chunk.left
        right += chunk.right
        top += chunk.top
        height += chunk.height
        script += chunk.script
        content += chunk.content
        direction += chunk.direction
    }
}

/// The uint8 quantization of a model output (the original's TFLite tensors are quantized; the Core ML model's
/// float outputs are quantized back the same way).
struct OutputQuantization {
    var scale: Float
    var zeroPoint: Int
}

/// TfliteModelPooledRunner dense dequantization (vectorized blocks of 8 use FMLA with a double-rounded bias).
private func dequantizeDense(_ q: [UInt8], _ scale: Float, _ zp: Int) -> [Float] {
    let n = q.count
    var out = [Float](repeating: 0, count: n)
    let bias = Float(Double(scale) * Double(-zp))
    var i = 0
    while i + 8 <= n {
        for j in i..<(i + 8) { out[j] = fma(Float(q[j]), scale, bias) }
        i += 8
    }
    while i < n {
        out[i] = Float(Double(scale) * Double(Int(q[i]) - zp))
        i += 1
    }
    return out
}

/// tensor_utils::ReduceActivationsGatesAndSoftMax for one line.
private func reduceGatedSoftmax(_ act: [Float], _ gate: [Float], _ frames: Int, _ classes: Int) -> [Float] {
    var acc = [Float](repeating: 0, count: classes)
    var gsum: Float = 0
    for t in 0..<frames {
        for c in 0..<classes { acc[c] += gate[t] * act[t * classes + c] }
        gsum += gate[t]
    }
    var mx = -Float.greatestFiniteMagnitude
    for c in 0..<classes {
        acc[c] = acc[c] / (gsum + 1)
        if acc[c] > mx { mx = acc[c] }
    }
    var sum: Float = 0
    for c in 0..<classes {
        acc[c] = expf(acc[c] - mx)
        sum += acc[c]
    }
    for c in 0..<classes { acc[c] = acc[c] / sum }
    return acc
}

private final class ScriptRecognizer {
    let config: RecognizerConfig
    let decoder: CTCBeamDecoder?
    private let model: CoreMLModel
    private let quantization: [String: OutputQuantization]
    private let labels: [Int: String]
    /// The chunks of recent readings' lines, with their share of the lines' tensors (see LineCache).
    private let chunkCache = LineCache<LineTensors>()

    init(resources: Resources, configFile: String, quantization: [String: [String: OutputQuantization]]) throws {
        guard let bytes = resources.read(modelRoot + configFile), let cfg = RecognizerConfig(bytes) else {
            throw ScreenAIError("Can't read the recognizer config \(configFile)")
        }
        config = cfg
        let base = String(cfg.modelPath.split(separator: "/").last ?? "")
        let name = base.hasSuffix(".tflite") ? String(base.dropLast(7)) : base
        guard let q = quantization[name] else { throw ScreenAIError("No output quantization for \(name)") }
        self.quantization = q
        model = try CoreMLModel(resources.url("coreml/\(name).mlmodelc"), cpuOnly: resources.cpuOnly)
        guard let lm = resources.read(modelDir + cfg.labelMapPath) else {
            throw ScreenAIError("Can't read \(cfg.labelMapPath)")
        }
        var labels: [Int: String] = [:]
        var lr = ProtoReader(lm)
        while lr.next() {
            guard lr.field == 1 else { continue }
            var name = ""
            var id = 0
            var e = ProtoReader(lr.bytes)
            while e.next() {
                if e.field == 1 { name = e.string }
                if e.field == 2 { id = e.int }
            }
            if labels[id] == nil { labels[id] = name }
        }
        // Every shipped model has labels 0..C-2 plus the CTC blank (C = decode_logits classes, checked when it's
        // run). A label map that doesn't (truncated or corrupt file) fails the OCR call like the original does,
        // instead of decoding to labels that don't exist.
        guard lr.ok, !labels.isEmpty, labels.keys.min() == 0, labels.keys.max() == labels.count - 1 else {
            throw ScreenAIError("Label map \(cfg.labelMapPath) doesn't match the model")
        }
        self.labels = labels
        if cfg.hasCtcDecoder {
            let file = configFile.firstIndex(of: "/").map { String(configFile[configFile.index(after: $0)...]) }
            decoder = try CTCBeamDecoder(resources: resources, dir: modelDir, configFile: file ?? configFile)
        } else {
            decoder = nil
        }
    }

    /// A reading is done (see LineCache).
    func endReading() { chunkCache.endReading() }

    func label(_ id: Int) -> String? { labels[id] }
    var numLabels: Int { labels.count }

    /// Runs the model over all lines (batches of 8 chunks) and returns the merged per-line tensors.
    func run(_ lines: [GrayImage]) throws -> [LineTensors] {
        // Core ML's autoreleased objects (its output buffers among them) are freed after each call.
        try autoreleasepool { try runBatches(lines) }
    }

    private func runBatches(_ lines: [GrayImage]) throws -> [LineTensors] {
        var allChunks: [[UInt8]] = []
        var refs: [(line: Int, offset: Int, width: Int)] = []
        for (li, line) in lines.enumerated() where line.width > 0 {
            for (c, chunk) in chunks(line).enumerated() {
                let off = c * chunkWidth
                refs.append((li, off, min(chunkWidth, line.width - off)))
                allChunks.append(chunk)
            }
        }
        let framesPerChunk = chunkInput / frameWidth  // 42
        let firstFrame = pad / frameWidth  // 4
        var out = [LineTensors](repeating: LineTensors(), count: lines.count)
        if allChunks.isEmpty { return out }
        // Each chunk's share of its line's tensors: from recent readings, or else from the model, which only gets the
        // others (chunks are independent within a batch).
        let keys = allChunks.indices.map { c in allChunks[c].withUnsafeBytes { LineCache<LineTensors>.Key($0, refs[c].width) } }
        var shares = keys.map { chunkCache[$0] }
        let missing = shares.indices.filter { shares[$0] == nil }
        let chunkData = missing.map { allChunks[$0] }
        let numBatches = (chunkData.count + batchSize - 1) / batchSize
        let chunkBytes = lineHeight * chunkInput

        // The batches run concurrently; each output is quantized back to uint8.
        var outputs = [[String: [UInt8]]](repeating: [:], count: numBatches)
        var shapes: [String: [Int]] = [:]
        var failure: Error?
        let lock = NSLock()
        func runBatch(_ b: Int) throws {
            let input = try MLMultiArray(
                shape: [NSNumber(value: batchSize), NSNumber(value: lineHeight), NSNumber(value: chunkInput), 1],
                dataType: .float32)
            let d = input.dataPointer.assumingMemoryBound(to: Float.self)
            d.initialize(repeating: 0, count: batchSize * chunkBytes)
            for j in 0..<batchSize where b * batchSize + j < chunkData.count {
                chunkData[b * batchSize + j].withUnsafeBufferPointer { c in
                    vDSP_vfltu8(c.baseAddress!, 1, d + j * chunkBytes, 1, vDSP_Length(c.count))
                }
            }
            let result = try model.predict(["image_tensor": input])
            var batchOut: [String: [UInt8]] = [:]
            var batchShapes: [String: [Int]] = [:]
            for (name, q) in quantization {
                guard let a = result[name] else { continue }
                batchOut[name] = requantize(a, scale: q.scale, zeroPoint: Float(q.zeroPoint))
                batchShapes[name] = a.shape.map(\.intValue)
            }
            lock.withLock {
                outputs[b] = batchOut
                shapes.merge(batchShapes) { a, _ in a }
            }
        }
        // Up to poolSize workers (the original's interpreter pool), each taking the next batch.
        var nextBatch = 0
        DispatchQueue.concurrentPerform(iterations: min(config.poolSize, numBatches)) { _ in
            while true {
                let b: Int = lock.withLock {
                    defer { nextBatch += 1 }
                    return failure == nil ? nextBatch : numBatches
                }
                if b >= numBatches { return }
                do {
                    try autoreleasepool { try runBatch(b) }
                } catch {
                    lock.withLock { failure = error }
                }
            }
        }
        if let failure { throw failure }
        func assembled() -> [LineTensors] {
            for (c, share) in shares.enumerated() { out[refs[c].line].append(share!) }
            return finished(out)
        }
        if chunkData.isEmpty { return assembled() }

        let denseNames = ["symbol_left_offset", "symbol_right_offset", "symbol_top", "symbol_height",
                          "script_activations", "script_gates", "content_type_activations", "content_type_gates",
                          "direction_activations", "direction_gates"]
        guard let logitsQ = quantization["decode_logits"], let C = shapes["decode_logits"]?.last else {
            throw ScreenAIError("The recognizer has no decode_logits output")
        }
        guard labels.count == C - 1 else { throw ScreenAIError("Label map \(config.labelMapPath) doesn't match the model") }
        var b0 = 0
        while b0 < chunkData.count {
            defer { b0 += batchSize }
            let batchOut = outputs[b0 / batchSize]
            var d: [(v: [Float], inner: Int)] = []
            for name in denseNames {
                guard let data = batchOut[name], let q = quantization[name] else {
                    d.append(([], 0))
                    continue
                }
                d.append((dequantizeDense(data, q.scale, q.zeroPoint), data.count / (batchSize * framesPerChunk)))
            }
            guard let lt = batchOut["decode_logits"] else { throw ScreenAIError("Missing decode_logits") }
            for j in 0..<batchSize where b0 + j < chunkData.count {
                let c = missing[b0 + j]
                let nf = (refs[c].width + frameWidth - 1) / frameWidth
                var share = LineTensors()
                lt.withUnsafeBufferPointer { logits in
                    for f in 0..<nf {
                        let src = j * framesPerChunk + firstFrame + f
                        let sp = sparseDequantizeFrame(logits.baseAddress! + src * C, C, logitsQ.zeroPoint,
                                                       logitsQ.scale, 5)
                        for e in sp {
                            share.logits.append(e.id)
                            share.logits.append(e.value)
                        }
                        if !d[0].v.isEmpty { share.left.append(d[0].v[src]) }
                        if !d[1].v.isEmpty { share.right.append(d[1].v[src]) }
                        if !d[2].v.isEmpty { share.top.append(d[2].v[src]) }
                        if !d[3].v.isEmpty { share.height.append(d[3].v[src]) }
                        share.frames += 1
                    }
                }
                // The gated heads keep their raw per-frame activations until all the chunks of the line are merged.
                for h in 0..<3 {
                    let act = d[4 + 2 * h], gate = d[5 + 2 * h]
                    if act.v.isEmpty { continue }
                    var dst: [Float] = []
                    for f in 0..<nf {
                        let src = j * framesPerChunk + firstFrame + f
                        dst += act.v[(src * act.inner)..<((src + 1) * act.inner)]
                        dst.append(gate.v[src])
                    }
                    switch h {
                    case 0: share.script += dst
                    case 1: share.content += dst
                    default: share.direction += dst
                    }
                }
                shares[c] = share
                chunkCache[keys[c]] = share
            }
        }
        return assembled()
    }

    /// The lines' tensors, with all their chunks: the heads the model doesn't have left out, and the gated ones reduced.
    private func finished(_ lines: [LineTensors]) -> [LineTensors] {
        var out = lines
        // Reduces a gated head, stored per frame as [act x C, gate].
        func reduce(_ v: [Float], _ frames: Int) -> [Float] {
            if v.isEmpty || frames == 0 { return v }
            let stride = v.count / frames
            let C = stride - 1
            var act = [Float](repeating: 0, count: frames * C), gate = [Float](repeating: 0, count: frames)
            for t in 0..<frames {
                for c in 0..<C { act[t * C + c] = v[t * stride + c] }
                gate[t] = v[t * stride + C]
            }
            return reduceGatedSoftmax(act, gate, frames, C)
        }
        for i in out.indices {
            if config.symbolBoxIndex <= 0 {
                out[i].left = []
                out[i].right = []
                out[i].top = []
                out[i].height = []
            }
            if config.scriptIndex <= 0 { out[i].script = [] }
            if config.contentTypeIndex <= 0 { out[i].content = [] }
            if config.directionIndex <= 0 { out[i].direction = [] }
            out[i].script = reduce(out[i].script, out[i].frames)
            out[i].content = reduce(out[i].content, out[i].frames)
            out[i].direction = reduce(out[i].direction, out[i].frames)
        }
        return out
    }
}

// MARK: - Decoding

private struct DecodedLabel {
    var id: Int, frame: Int
    var prob: Float
}

/// recognition::GreedyCTCLineDecoding over the sparse top-k logits.
private func greedyDecode(_ L: LineTensors, _ r: ScriptRecognizer) -> [DecodedLabel] {
    let blank = r.numLabels
    var out: [DecodedLabel] = []
    var prev = blank
    for t in 0..<L.frames {
        let e = t * 10
        var best = 0
        for i in 1..<5 where L.logits[e + 2 * i + 1] > L.logits[e + 2 * best + 1] { best = i }
        let mx = L.logits[e + 2 * best + 1]
        var sum: Float = 0
        for i in 0..<5 { sum += expf(L.logits[e + 2 * i + 1] - mx) }
        let prob = 1 / sum
        var id = Int(rintf(L.logits[e + 2 * best]))
        if r.label(id) == nil { id = blank }
        if id != blank {
            if id != prev {
                out.append(DecodedLabel(id: id, frame: t, prob: prob))
            } else {
                out[out.count - 1].prob = prob
            }
        }
        prev = id
    }
    return out
}

/// CTCDecoder + CTCDecoderConfidenceScorer (CTCDecoderConfidenceFeatureExtractor logits_top_k with all costs
/// disabled, AvgLogitsConfidenceScorer): label confidence = 1 / sum_j exp(topk_j - logit(label)).
private func beamDecode(_ L: LineTensors, _ dec: CTCBeamDecoder) -> [DecodedLabel] {
    let k = 5
    var values = [Float](repeating: 0, count: L.frames * k), ids = values
    for i in values.indices {
        ids[i] = L.logits[2 * i]
        values[i] = L.logits[2 * i + 1]
    }
    var labels: [DecodedLabel] = []
    for l in dec.decode(frames: L.frames, k: k, ids: ids, values: values) {
        let row = Array(values[(l.frame * k)..<((l.frame + 1) * k)])
        let rid = ids[(l.frame * k)..<((l.frame + 1) * k)]
        let v = row.sorted(by: >)
        var j = 0
        while j < k && Int(rintf(rid[rid.startIndex + j])) != l.label { j += 1 }
        if j == k { j = 0 }  // an error status in the original
        let logit = row[j]
        let conf = 1 / eigenSumExp(v.map { $0 - logit })
        labels.append(DecodedLabel(id: l.label, frame: l.frame, prob: conf))
    }
    return labels
}

private func argmax(_ v: [Float], _ n: Int) -> Int {
    var best = 0
    for i in 1..<max(n, 1) where v[i] > v[best] { best = i }
    return best
}

/// RotateOrientationClockwise<Box<float>> + BoundingBoxToBoundingPolygon (rounded). A curved box keeps its curve,
/// with points and thickness rounded to float by the Box<float> round trip: each quadrant clears top_to_bottom if
/// set, else reverses the mid-line points and sets it.
private func rotateClockwise(_ b: RotatedBox, _ quadrants: Int) -> RotatedBox {
    let q = quadrants & 3
    if q == 0 { return b }
    let x = Float(b.left), y = Float(b.top), w = Float(b.width), h = Float(b.height)
    let sc = sinCos(b.angle * 0.0174532924)
    let s = sc.sin, c = sc.cos
    var nx: Float, ny: Float
    if q == 1 {
        nx = x + w * c
        ny = y + w * s
    } else if q == 2 {
        nx = (x + w * c) - h * s
        ny = h * c + (y + w * s)
    } else {
        nx = x - h * s
        ny = y + h * c
    }
    var a = b.angle + Float(90 * q)
    while a <= -180 { a = a + 360 }
    while a > 180 { a = a + -360 }
    var out = RotatedBox()
    out.left = roundHalfAway(nx)
    out.top = roundHalfAway(ny)
    out.width = q & 1 != 0 ? b.height : b.width
    out.height = q & 1 != 0 ? b.width : b.height
    out.angle = a
    if var curve = b.curve {
        curve.points = curve.points.map { (Double(Float($0.0)), Double(Float($0.1))) }
        curve.thickness = Double(Float(curve.thickness))
        if curve.points.count >= 2 {
            var ttb = curve.topToBottom ?? false
            for _ in 0..<q {
                if !ttb { curve.points.reverse() }
                ttb = !ttb
            }
            curve.topToBottom = ttb
        }
        out.curve = curve
    }
    return out
}

private func orientationFromAngle(_ a: Float) -> Int {
    if a >= -45 && a < 45 { return 0 }
    if a >= 45 && a < 135 { return 1 }
    if a < 135 && a >= -135 { return 3 }
    return 2
}

private struct LineDecode {
    /// Their boxes are relative to the line.
    var symbols: [RecSymbol] = []
    var text = ""
    var confidence: Float = 0
}

@inline(__always) private func llround(_ v: Float) -> Int { Int(v.rounded(.toNearestOrAwayFromZero)) }
@inline(__always) private func llround(_ v: Double) -> Int { Int(v.rounded(.toNearestOrAwayFromZero)) }

private func decodeLine(_ L: LineTensors, _ r: ScriptRecognizer, _ line: GrayImage, reversed: Bool) -> LineDecode {
    var d = LineDecode()
    var LL = L
    if reversed {  // logits of the 180-degree rotated line
        for t in 0..<L.frames {
            let s = (L.frames - 1 - t) * 10
            LL.logits.replaceSubrange((t * 10)..<(t * 10 + 10), with: L.logits[s..<(s + 10)])
        }
    }
    let labels = r.decoder.map { beamDecode(LL, $0) } ?? greedyDecode(LL, r)
    let W = Float(line.width), H = Float(line.height)
    let scale = Double(W / Float(L.frames))
    var left = L.left, right = L.right, top = L.top, height = L.height
    if reversed && !left.isEmpty {
        // GetSymbolBoxPredictions(reverse): predictions of the 180-degree rotated line
        let n = L.frames
        var l2 = [Float](repeating: 0, count: n), r2 = l2, t2 = l2, h2 = l2
        for t in 0..<n {
            let s = n - 1 - t
            l2[t] = right[s]
            r2[t] = left[s]
            h2[t] = height[s]
            t2[t] = (1 - top[s]) - height[s]
        }
        left = l2
        right = r2
        top = t2
        height = h2
    }
    let have = !left.isEmpty && !right.isEmpty && !top.isEmpty && !height.isEmpty
    // The vertical extent of the first label that isn't a space, which space symbols get.
    var nsTop = 0, nsH = Int(H)
    for l in labels {
        guard let s = r.label(l.id), s != " " else { continue }
        if have {
            nsTop = max(0, min(llround(top[l.frame] * H), Int(H - 1)))
            nsH = max(1, llround(H * height[l.frame]))
            nsH = min(nsH, Int(H - Float(nsTop)))
        }
        break
    }
    var sum = 0.0
    for l in labels {
        var s = RecSymbol(text: r.label(l.id) ?? "")
        s.confidence = l.prob
        let f = l.frame
        if !have || s.text == " " {
            s.box.left = min(llround(scale * Double(f)), Int(W - 1))
            s.box.width = max(1, llround(scale))
            if !have {
                s.box.top = 0
                s.box.height = Int(H)
            } else {
                s.box.top = nsTop
                s.box.height = nsH
            }
        } else {
            // The center goes to float before the subtraction: 279.49999 - 6e-6 rounds to 280.
            let center = Float((Double(f) + 0.5) * scale)
            let lo = left[f] * H
            s.box.left = max(0, min(llround(center - lo), Int(W - 1)))
            s.box.width = max(1, llround(lo + H * right[f]))
            s.box.width = min(s.box.width, Int(W - Float(s.box.left)))
            s.box.top = max(0, min(llround(H * top[f]), Int(H - 1)))
            s.box.height = max(1, llround(H * height[f]))
            s.box.height = min(s.box.height, Int(H - Float(s.box.top)))
        }
        d.text += s.text
        sum += Double(s.confidence)
        d.symbols.append(s)
    }
    d.confidence = d.symbols.isEmpty ? 0 : Float(sum / Double(d.symbols.count))
    return d
}

// MARK: - Pyramid crops

/// Lines of large text (detection_image_scale < 1000) come with the image GroupRpnDetectorV2's CropDetections cut
/// from the detector pyramid level of that scale. Their page box went through box_util::ScaleBoundingBox by s and
/// back by 1/s (integer truncation, see Detector.swift cropDetection); the crop box is recovered by inverting the
/// way back, which is injective since 1/s > 1.
private func unscaleTruncated(_ v: Int, _ s: Float) -> Int {
    let r = 1 / s
    let x = Int(floorf(Float(v) * s))
    for d in [0, 1, -1, 2, -2, 3, -3] where Int(r * Float(x + d)) == v { return x + d }
    return x
}

private func unscaleDouble(_ v: Double, _ s: Float) -> Double {
    let r = Double(1 / s)
    var c = v / r
    var i = 0
    while i < 4 && c * r != v {
        c = c * r < v ? c.nextUp : c.nextDown
        i += 1
    }
    return c
}

private func pyramidCropBox(_ page: RotatedBox, _ s: Float) -> RotatedBox {
    var b = page
    b.left = unscaleTruncated(page.left, s)
    b.top = unscaleTruncated(page.top, s)
    b.width = unscaleTruncated(page.left + page.width, s) - b.left
    b.height = unscaleTruncated(page.top + page.height, s) - b.top
    if var curve = b.curve {
        curve.thickness = unscaleDouble(curve.thickness, s)
        curve.points = curve.points.map { (unscaleDouble($0.x, s), unscaleDouble($0.y, s)) }
        b.curve = curve
    }
    return b
}

/// GenerateLineWordsMaybeSetColors: symbol and word-break boxes (floor/ceil of the edges) and color sampling points
/// (truncated) of a pyramid line image are scaled to page pixels before they are mapped onto the page.
private func scaleLineBoxes(_ f: Float, _ symbols: inout [RecSymbol], _ words: inout [RecWord]) {
    func box(_ b: inout RotatedBox) {
        let l = Int(floorf(Float(b.left) * f)), t = Int(floorf(Float(b.top) * f))
        b.width = Int(ceilf(Float(b.width + b.left) * f)) - l
        b.height = Int(ceilf(Float(b.height + b.top) * f)) - t
        b.left = l
        b.top = t
    }
    func pt(_ p: (Int, Int)) -> (Int, Int) { (Int(Float(p.0) * f), Int(Float(p.1) * f)) }
    for i in symbols.indices { box(&symbols[i].box) }
    for i in words.indices {
        if words[i].brk?.box != nil { box(&words[i].brk!.box!) }
        if words[i].colors != nil {
            words[i].colors!.foregroundSamples = words[i].colors!.foregroundSamples.map(pt)
            words[i].colors!.backgroundSamples = words[i].colors!.backgroundSamples.map(pt)
        }
    }
}

// MARK: - Multi-pass line recognition

final class LineRecognizer {
    private let resources: Resources
    /// The config file of each recognizer key (MultiPassLineRecognitionMutatorConfig).
    private var configFiles: [String: String] = [:]
    private var defaultKey = ""
    private var maximumIterations = 0
    /// Optional, as in the original: without a loadable model, lines get no language from it.
    private let langid: LanguageIdentifier?
    private var recognizers: [String: ScriptRecognizer] = [:]
    private let quantization: [String: [String: OutputQuantization]]

    init(resources: Resources) throws {
        self.resources = resources
        guard let bytes = resources.read(multiPassConfig) else { throw ScreenAIError("Missing the recognizer config") }
        // google.protobuf.Any{value=2: MultiPassLineRecognitionMutatorConfig}
        var cfg: ArraySlice<UInt8> = []
        var any = ProtoReader(bytes)
        while any.next() {
            if any.field == 2 { cfg = any.bytes }
        }
        var m = ProtoReader(cfg)
        while m.next() {
            if m.field == 1 {  // map<string, LineRecognizerConfig{config_file=2}>
                var key = "", file = ""
                var e = ProtoReader(m.bytes)
                while e.next() {
                    if e.field == 1 { key = e.string }
                    if e.field == 2 {
                        var v = ProtoReader(e.bytes)
                        while v.next() {
                            if v.field == 2 { file = v.string }
                        }
                    }
                }
                configFiles[key] = file
            } else if m.field == 2 {  // LineRecognizerConfigSelectorConfig{default_key=3}
                var s = ProtoReader(m.bytes)
                while s.next() {
                    if s.field == 3 { defaultKey = s.string }
                }
            } else if m.field == 5 {
                maximumIterations = m.int
            }
        }
        guard configFiles[defaultKey] != nil else { throw ScreenAIError("Unexpected recognizer config") }
        quantization = try Self.readQuantization(resources)
        langid = try? LanguageIdentifier(resources: resources)
        _ = try recognizer(defaultKey)
    }

    /// coreml/recognizers.json: {model name: {output name: {"scale", "zero_point"}}}
    private static func readQuantization(_ resources: Resources) throws -> [String: [String: OutputQuantization]] {
        guard let data = resources.read("coreml/recognizers.json"),
              let json = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: [String: [String: Any]]]
        else { throw ScreenAIError("Missing coreml/recognizers.json") }
        return json.mapValues { outputs in
            outputs.compactMapValues { o in
                guard let s = o["scale"] as? NSNumber, let z = o["zero_point"] as? NSNumber else { return nil }
                return OutputQuantization(scale: s.floatValue, zeroPoint: z.intValue)
            }
        }
    }

    /// How many script recognizers stay loaded besides the default one. On iOS each holds memory of its own once it
    /// has run (on the GPU, unless the models run on the CPU), and pictures with lines in several scripts kept loading
    /// more (1.1 GB for screenshots of Japanese games on an iPhone 15 Pro Max), so the least recently used one is let
    /// go and loaded again when it's needed.
    #if os(iOS)
    private static let keptRecognizers = 2
    #else
    private static let keptRecognizers = Int.max
    #endif
    /// The loaded recognizers other than the default one, the most recently used last.
    private var recentKeys: [String] = []

    private func recognizer(_ key: String) throws -> ScriptRecognizer {
        if key != defaultKey {
            recentKeys.removeAll { $0 == key }
            recentKeys.append(key)
        }
        if let r = recognizers[key] { return r }
        guard let file = configFiles[key] else { throw ScreenAIError("No recognizer \(key)") }
        let r = try ScriptRecognizer(resources: resources, configFile: file, quantization: quantization)
        recognizers[key] = r
        while recentKeys.count > Self.keptRecognizers {
            recognizers[recentKeys.removeFirst()] = nil
        }
        return r
    }

    /// LanguageBasedLineRecognizerConfigSelector::Select: the recognizer key for a line after the first pass.
    /// recognizer_script_id is taken as is for CUSTOM (101) content. Otherwise, for each language (one per line here),
    /// with key suffixes "-t-i0-handwrit:vert", ":vert", "-t-i0-handwrit" (HANDWRITTEN_TEXT / top-to-bottom lines
    /// only) and "": the tag itself, its language subtag (not und/mul), its most likely script, and Hani for
    /// Hans/Hant. Nil: the original's error status ("-t-i0-handwrit needs to come at the very end").
    private func selectKey(_ e: Entity) -> String? {
        if let id = e.recognizerScriptId, !id.isEmpty, e.contentType == 101, configFiles[id] != nil { return id }
        let handwrit = "-t-i0-handwrit"
        for tag in e.languages {
            var lang = tag
            var handwritten = e.contentType == 1
            if let h = lang.range(of: handwrit, options: [.literal, .backwards]) {
                if h.upperBound != lang.endIndex { return nil }
                lang = String(lang[..<h.lowerBound])
                handwritten = true
            }
            var suffixes = [""]
            if handwritten { suffixes.append(handwrit) }
            if e.writingDirection == 2 {
                suffixes.append(":vert")
                if handwritten { suffixes.append(handwrit + ":vert") }
            }
            suffixes.reverse()
            let language = String(lang.prefix { $0 != "-" && $0 != "_" }).lowercased()
            let script = mostLikelyScript(lang)
            for s in suffixes {
                if configFiles[lang + s] != nil { return lang + s }
                if language != "und" && language != "mul" && configFiles[language + s] != nil { return language + s }
                if configFiles[script + s] != nil { return script + s }
                if (script == "Hans" || script == "Hant") && configFiles["Hani" + s] != nil { return "Hani" + s }
            }
        }
        return defaultKey
    }

    private struct LineState {
        var decode = LineDecode()
        var words: [RecWord] = []
        /// The recognizer used.
        var key = ""
        /// The line image of the first pass (every pass starts from it).
        var baseImage = GrayImage()
        /// Line-image pixels to page pixels (1000 / detection_image_scale).
        var boxScale: Float = 1
        /// The box was turned by 180 degrees (by the direction head) since the first pass.
        var flipped = false
    }

    /// Recognizes the layout's lines; returns the layout with each line followed by its words and their symbols.
    func recognize(_ gray: GrayImage, _ input: PageLayout, pyramid: [PyramidLevel]) throws -> PageLayout {
        defer { recognizers.values.forEach { $0.endReading() } }
        var layout = input
        let lineIdx = layout.entities.indices.filter { layout.entities[$0].type == .line }
        var state = [LineState](repeating: LineState(), count: lineIdx.count)

        // Recognizes `which` lines with recognizer `key`; the first pass also handles the direction head.
        func runPass(_ key: String, _ which: [Int]) throws {
            let r = try recognizer(key)
            let cfg = r.config
            var images: [GrayImage] = [], scaled: [GrayImage] = []
            for w in which {
                // Later passes cut the line from its pass-1 box and turn the image when the direction head flipped
                // the box (not the same pixels as cutting the flipped box: that is off by one pixel in x and y).
                let e = layout.entities[lineIdx[w]]
                if state[w].key.isEmpty, let box = e.box {
                    let dis = e.detection?.detectionImageScale ?? 1000
                    var level: PyramidLevel?
                    if dis > 0 && dis < 1000 {
                        for l in pyramid where l.image != nil && Int(l.scale * 1000) == dis { level = l }
                    }
                    if let level, let image = level.image {
                        // The detection box keeps the curve in double precision (the polygon's points are floats).
                        var b = box
                        if b.curve != nil, let dc = e.detection?.detectionBox.curve {
                            b.curve!.points = dc.points
                            b.curve!.thickness = dc.thickness
                        }
                        let crop = pyramidCropBox(b, level.scale)
                        state[w].baseImage = crop.curve.map { curvedLineImage(image, $0, floatThickness: false) }
                            ?? lineImage(image, crop)
                        state[w].boxScale = 1000 / Float(dis)
                    } else {
                        state[w].baseImage = lineImage(gray, box)
                    }
                }
                images.append(state[w].flipped ? rotate180(state[w].baseImage) : state[w].baseImage)
                scaled.append(images.last!.width > 0 ? scaleToHeight(images.last!) : GrayImage())
            }
            let tensors = try r.run(scaled)
            for (k, w) in which.enumerated() {
                let ei = lineIdx[w]
                let L = tensors[k]
                state[w].key = key
                if L.frames == 0 { continue }
                var reversed = false
                if !L.direction.isEmpty {
                    let d = argmax(L.direction, 4)
                    let rotated = rotateClockwise(layout.entities[ei].box!, d)
                    if d == 1 || d == 2 {
                        layout.entities[ei].box = rotateClockwise(layout.entities[ei].box!, 2)
                        state[w].flipped.toggle()
                        reversed = true
                    }
                    layout.entities[ei].orientation = orientationFromAngle(rotated.angle)
                    layout.entities[ei].writingDirection = (d & ~2) == 1 ? 2 : 0
                    layout.entities[ei].textlineOrder = (d & ~2) == 1 ? 1 : 2
                    layout.entities[ei].predictedDirection = d
                    layout.entities[ei].directionConfidence = L.direction[d]
                    layout.entities[ei].detection?.garbageProb = L.direction[4]
                }
                var decode = decodeLine(L, r, images[k], reversed: reversed)
                // StandardTextReorderer::JoinAtomsToSymbols (Indic symbol manipulators)
                let before = decode.symbols.count
                joinSymbolsLogical(&decode.symbols)
                if decode.symbols.count != before {
                    let sum = decode.symbols.reduce(0.0) { $0 + Double($1.confidence) }
                    decode.confidence = decode.symbols.isEmpty ? 0 : Float(sum / Double(decode.symbols.count))
                }
                // StandardTextReorderer::SymbolsToResult: recognition (visual) order -> logical order.
                let (text, offsets) = symbolsVisualToLogical(decode.symbols.map(\.text), baseDirRtl: cfg.baseDirRtl)
                decode.text = text
                if !offsets.contains(-1) {
                    var perm = Array(offsets.indices)
                    perm.stableSort { offsets[$0] < offsets[$1] }
                    decode.symbols = perm.map { decode.symbols[$0] }
                }
                let rtl = cfg.baseDirRtl && hasAnyRtl(decode.text)
                var e = layout.entities[ei]
                if rtl { e.writingDirection = 1 }
                if !L.content.isEmpty || e.contentType == nil { e.contentType = 0 }  // later passes keep und's
                if !L.content.isEmpty {
                    let c = argmax(L.content, L.content.count)
                    e.contentType = c < cfg.contentTypeNames.count && cfg.contentTypeNames[c] == "HANDWRITTEN_TEXT" ? 1 : 0
                    e.typeConfidence = L.content[c]
                }
                var language: String
                var predictedScript: String?
                if !L.script.isEmpty {
                    let s = argmax(L.script, L.script.count)
                    let name = s < cfg.scriptNames.count ? cfg.scriptNames[s] : ""
                    predictedScript = name
                    language = cfg.supportedScripts.contains(name) ? langid?.identify(decode.text) ?? "" : name
                } else {
                    language = langid?.identify(decode.text) ?? ""
                }
                e.confidence = decode.confidence
                e.languages = [language]
                e.recognizerScriptId = cfg.scriptId.isEmpty ? key : cfg.scriptId
                var a = AksaraResult()
                if !decode.symbols.isEmpty {  // a line decoded to nothing has neither
                    a.text = decode.text
                    a.confidence = decode.confidence
                }
                a.language = language
                a.predictedScript = predictedScript
                if cfg.baseDirRtl { a.rightToLeft = rtl }  // set by RTL recognizers: paragraph direction of the text
                e.aksara = a
                layout.entities[ei] = e
                var words = buildWords(decode.symbols, decode.text)
                if !rtl {
                    recomputeSpaceWordBreakBoxes(decode.symbols, vertical: e.writingDirection == 2, &words)
                    estimateWordColors(images[k], decode.symbols, &words)
                }
                if state[w].boxScale != 1 { scaleLineBoxes(state[w].boxScale, &decode.symbols, &words) }
                state[w].decode = decode
                state[w].words = words
            }
        }

        // Lines in hierarchy order (grouped under their parents, parents in entity order), as goodoc::PageLayout
        // traverses them.
        var order = Array(lineIdx.indices)
        func parentRank(_ k: Int) -> Int {
            let p = layout.entities[lineIdx[k]].parent
            return p >= 0 && p < layout.entities.count ? p : lineIdx[k]
        }
        order.stableSort { parentRank($0) < parentRank($1) }
        try runPass(defaultKey, order)
        if maximumIterations > 1 {
            // Second pass: lines whose language selects another recognizer are re-recognized by it; the multi-pass
            // mutator moves them behind the others, grouped by recognizer key (in key order).
            var second: [String: [Int]] = [:]
            var kept: [Int] = []
            for i in order {
                guard let key = selectKey(layout.entities[lineIdx[i]]) else {
                    throw ScreenAIError("Can't select a recognizer")
                }
                if key != state[i].key {
                    second[key, default: []].append(i)
                } else {
                    kept.append(i)
                }
            }
            order = kept
            for key in second.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                try runPass(key, second[key]!)
                order += second[key]!
            }
        }

        // Assemble: non-line entities first, then each line with its words and symbols.
        var out = layout
        out.entities = []
        var remap = [Int](repeating: -1, count: layout.entities.count)
        for (i, e) in layout.entities.enumerated() where e.type != .line {
            remap[i] = out.entities.count
            out.entities.append(e)
        }
        var next = out.entities.count
        for k in order {
            remap[lineIdx[k]] = next
            next += 1
            for w in state[k].words { next += 1 + w.symbols.count }
        }
        for i in out.entities.indices where out.entities[i].parent >= 0 {
            out.entities[i].parent = remap[out.entities[i].parent]
        }
        for k in order {
            var line = layout.entities[lineIdx[k]]
            if line.parent >= 0 { line.parent = remap[line.parent] }
            let lineId = out.entities.count
            // Vertical (top-to-bottom) lines: the recognizer worked on the line rotated to horizontal; the page boxes
            // of the line and its descendants are turned upright again (RotateOrientationClockwise by 3 quadrants).
            let vertical = line.writingDirection == 2
            func upright(_ b: RotatedBox) -> RotatedBox { vertical ? rotateClockwise(b, 3) : b }
            // Vertical lines re-recognized in a later pass map their boxes from the upright line box of the first
            // pass turned back by one quadrant: the angle round trip moves the page angle of every symbol by an ulp,
            // which shows in the averaged word angles. Lines kept from the first pass map from their box as
            // recognized. For curved lines the round trip rounds the curve to float.
            var lb = line.box ?? RotatedBox()
            if vertical && state[k].key != defaultKey { lb = rotateClockwise(rotateClockwise(lb, 3), 1) }
            // Curved lines: line-image boxes follow the mid-line curve back onto the page.
            let mapper = lb.curve.map { CurveMapper($0) }
            func page(_ rel: RotatedBox) -> RotatedBox { mapper.map { curveToPage($0, rel) } ?? toPage(lb, rel) }
            if let b = line.box { line.box = upright(b) }
            out.entities.append(line)
            let st = state[k]
            for w in st.words {
                var we = Entity()
                we.type = .word
                we.parent = lineId
                we.contentType = line.contentType
                we.orientation = line.orientation
                we.writingDirection = w.writingDirection != nil && !vertical ? w.writingDirection : line.writingDirection
                we.textlineOrder = line.textlineOrder
                we.confidence = w.confidence
                we.languages = line.languages
                we.text = w.text
                let childBoxes = w.symbols.map { page(st.decode.symbols[$0].box) }
                we.box = upright(containingBoxWithAverageAngle(childBoxes))
                if let brk = w.brk {
                    var b = WordBreak()
                    b.type = brk.type
                    if let bb = brk.box { b.box = upright(page(bb)) }
                    we.wordBreak = b
                }
                if var c = w.colors {
                    func pt(_ p: (Int, Int)) -> (Int, Int) {
                        let q = page(RotatedBox(left: p.0, top: p.1, width: 1, height: 1))
                        return (q.left, q.top)
                    }
                    c.foregroundSamples = c.foregroundSamples.map(pt)
                    c.backgroundSamples = c.backgroundSamples.map(pt)
                    we.colors = c
                }
                let wordId = out.entities.count
                out.entities.append(we)
                for (j, si) in w.symbols.enumerated() {
                    let s = st.decode.symbols[si]
                    var se = Entity()
                    se.type = .symbol
                    se.parent = wordId
                    se.contentType = line.contentType
                    se.confidence = s.confidence
                    se.text = s.text
                    if s.mirrored { se.writingDirection = 1 }
                    se.box = upright(childBoxes[j])
                    out.entities.append(se)
                }
            }
        }
        return out
    }
}
