import Foundation

/// Entry points for checking the port's pieces against the Python reimplementation (oneocr-cli).
public enum OneOCRDebug {
    /// Runs one CRT math routine over (a, b) pairs; float routines get their arguments rounded to float.
    public static func crt(_ name: String, _ a: [Double], _ b: [Double]) -> [Double]? {
        let fn: (Double, Double) -> Double
        switch name {
        case "powf": fn = { Double(CRT.powf(Float($0), Float($1))) }
        case "expf": fn = { a, _ in Double(CRT.expf(Float(a))) }
        case "logf": fn = { a, _ in Double(CRT.logf(Float(a))) }
        case "atan2f": fn = { Double(CRT.atan2f(Float($0), Float($1))) }
        case "sinf": fn = { a, _ in Double(CRT.sinf(Float(a))) }
        case "cosf": fn = { a, _ in Double(CRT.cosf(Float(a))) }
        case "atan2": fn = { CRT.atan2($0, $1) }
        case "sin": fn = { a, _ in CRT.sin(a) }
        case "cos": fn = { a, _ in CRT.cos(a) }
        case "pow": fn = { CRT.pow($0, $1) }
        default: return nil
        }
        return zip(a, b).map(fn)
    }
}

extension OneOCRDebug {
    /// A raw image: width and height (little-endian Int32), then BGR rows.
    public static func readBGR(_ path: String) throws -> (Int, Int, [UInt8]) {
        let d = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let w = d[0..<4].reversed().reduce(0) { $0 << 8 | Int($1) }, h = d[4..<8].reversed().reduce(0) { $0 << 8 | Int($1) }
        return (w, h, Array(d[8...]))
    }

    /// Detected lines of a raw BGR image as JSON.
    public static func detect(models: String, images: [String]) throws -> [Any] {
        let files = ModelFiles(root: URL(fileURLWithPath: models))
        let cfg = try files.json("config.json")
        let det = try TextDetector(model: files.model("Detector", units: .cpuAndGPU),
                                   quantization: files.json("detector.json"),
                                   config: (cfg["det_model"] as? [[String: Any]])?.first)
        return try images.map { path in
            let (w, h, data) = try readBGR(path)
            let t0 = Date()
            let lines = try det.detect(ImageU8(width: w, height: h, channels: 3, data: data))
            let dt = Date().timeIntervalSince(t0)
            return ["time": dt, "lines": lines.map { l in
                ["polygon": l.polygon.map { [Double($0.x), Double($0.y)] }, "score": Double(l.score),
                 "hori": l.isHorizontal, "amb": l.isAmbiguous, "multi": l.isPolygon] as [String: Any]
            }] as [String: Any]
        }
    }
}

extension OneOCRDebug {
    /// Log probabilities of the recognizer for 60-pixel-high raw BGR line images (width a multiple of 4), as raw
    /// float32 files next to them (<image>.<name>.logp).
    public static func recnet(models: String, name: String, images: [String]) throws {
        let net = try CharNet(files: ModelFiles(root: URL(fileURLWithPath: models)), name: name)
        for path in images {
            let (w, h, data) = try readBGR(path)
            let t0 = Date()
            let (logp, T) = try net.run(ImageU8(width: w, height: h, channels: 3, data: data))
            print(path, T, String(format: "%.1f ms", Date().timeIntervalSince(t0) * 1000))
            try logp.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: path + ".\(name).logp"))
        }
    }
}

extension OneOCRDebug {
    /// prob1 of a score model (scores/<kind>/<name>.json) for rows of 21 float32 features.
    public static func scores(models: String, kind: String, name: String, input: String, output: String) throws {
        let m = try ScoreModel(ModelFiles(root: URL(fileURLWithPath: models)).json("scores/\(kind)/\(name).json"))
        let d = try Data(contentsOf: URL(fileURLWithPath: input))
        let x = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let y = stride(from: 0, to: x.count, by: 21).map { m.prob1(Array(x[$0..<($0 + 21)])) }
        try y.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: output))
    }
}

extension OneOCRDebug {
    /// OCR results of raw BGR images as JSON, in the format of oneocr's recognize_cv2 (plus the time in seconds).
    public static func ocr(models: String, images: [String]) throws -> [Any] {
        let engine = try OneOCREngine(modelsDirectory: URL(fileURLWithPath: models))
        func rect(_ q: [CGPoint]) -> [String: Double] {
            var r: [String: Double] = [:]
            for (i, p) in q.enumerated() {
                r["x\(i + 1)"] = Double(p.x)
                r["y\(i + 1)"] = Double(p.y)
            }
            return r
        }
        return try images.map { path in
            let (w, h, data) = try readBGR(path)
            let t0 = Date()
            let res = try engine.recognizeIfSupported(ImageU8(width: w, height: h, channels: 3, data: data))
            let dt = Date().timeIntervalSince(t0)
            guard let res else {
                var r: [String: Any] = ["time": dt, "text": "", "text_angle": NSNull(), "lines": [Any]()]
                if !OneOCREngine.supportsSize(w, h) { r["error"] = "Unsupported image size" }
                return r
            }
            let lines = res.lines.map { l in
                ["text": l.text, "bounding_rect": rect(l.quad), "words": l.words.map { w in
                    ["text": w.text, "bounding_rect": rect(w.quad), "confidence": Double(w.confidence)] as [String: Any]
                }] as [String: Any]
            }
            return ["time": dt, "text": res.lines.map(\.text).joined(separator: "\n"),
                    "text_angle": res.angle, "lines": lines] as [String: Any]
        }
    }
}
