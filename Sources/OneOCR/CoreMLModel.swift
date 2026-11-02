import CoreML
import Foundation

public struct OneOCRError: LocalizedError {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A compiled Core ML model made by scripts/convert-oneocr.py.
final class CoreMLModel: @unchecked Sendable {
    let model: MLModel

    init(_ url: URL, units: MLComputeUnits) throws {
        let config = MLModelConfiguration()
        config.computeUnits = units
        do {
            model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            throw OneOCRError("Can't load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Outputs by name. Safe to call from several threads.
    func predict(_ inputs: [String: MLMultiArray]) throws -> [String: MLMultiArray] {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        let out = try autoreleasepool { try model.prediction(from: provider) }
        var result: [String: MLMultiArray] = [:]
        for name in out.featureNames {
            if let a = out.featureValue(for: name)?.multiArrayValue { result[name] = a }
        }
        return result
    }
}

/// A float32 [1, 3, h, w] input array filled by body (given the planes' storage, row-major).
func makeInput(_ h: Int, _ w: Int, _ body: (UnsafeMutablePointer<Float>) -> Void) throws -> MLMultiArray {
    let a = try MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
    a.withUnsafeMutableBytes { raw, strides in
        precondition(strides[3] == 1 && strides[2] == w && strides[1] == h * w)
        body(raw.bindMemory(to: Float.self).baseAddress!)
    }
    return a
}

/// The array's values as row-major floats, with its shape.
func floats(_ a: MLMultiArray) -> (shape: [Int], data: [Float]) {
    let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
    let count = shape.reduce(1, *)
    var out = [Float](repeating: 0, count: count)
    if count == 0 { return (shape, out) }
    a.withUnsafeBytes { raw in
        out.withUnsafeMutableBufferPointer { dst in
            let rank = shape.count
            var contiguous = true
            var expected = 1
            for d in stride(from: rank - 1, through: 0, by: -1) {
                if shape[d] != 1 && strides[d] != expected { contiguous = false }
                expected *= shape[d]
            }
            func copy<T>(_ src: UnsafePointer<T>, _ convert: (T) -> Float) {
                if contiguous {
                    for i in 0..<count { dst[i] = convert(src[i]) }
                    return
                }
                var idx = [Int](repeating: 0, count: rank)
                for i in 0..<count {
                    var off = 0
                    for d in 0..<rank { off += idx[d] * strides[d] }
                    dst[i] = convert(src[off])
                    var d = rank - 1
                    while d >= 0 {
                        idx[d] += 1
                        if idx[d] < shape[d] { break }
                        idx[d] = 0
                        d -= 1
                    }
                }
            }
            switch a.dataType {
            case .float16: copy(raw.bindMemory(to: UInt16.self).baseAddress!) { Float(Float16(bitPattern: $0)) }
            case .double: copy(raw.bindMemory(to: Double.self).baseAddress!) { Float($0) }
            default: copy(raw.bindMemory(to: Float.self).baseAddress!) { $0 }
            }
        }
    }
    return (shape, out)
}

/// The files of an unpacked models archive (made by scripts/convert-oneocr.py): config.json and the original's
/// other non-network files under their original paths, Core ML models under "coreml/", the recognizers' LSTM
/// weights under "tail/", the confidence and rejection models under "scores/".
struct ModelFiles {
    let root: URL

    func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    func json(_ relativePath: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url(relativePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OneOCRError("Can't read \(relativePath)") }
        return obj
    }

    /// coreml/<name>.mlmodelc, compiled from coreml/<name>.mlpackage first if needed.
    func model(_ name: String, units: MLComputeUnits) throws -> CoreMLModel {
        let compiled = url("coreml/\(name).mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let tmp = try MLModel.compileModel(at: url("coreml/\(name).mlpackage"))
            try FileManager.default.moveItem(at: tmp, to: compiled)
        }
        return try CoreMLModel(compiled, units: units)
    }
}

/// body(0..<n) on all cores, in order; rethrows the first error by index.
func concurrentMap<T>(_ n: Int, _ body: (Int) throws -> T) throws -> [T] {
    var results = [Result<T, Error>?](repeating: nil, count: n)
    results.withUnsafeMutableBufferPointer { r in
        let p = r.baseAddress!
        DispatchQueue.concurrentPerform(iterations: n) { i in p[i] = Result { try body(i) } }
    }
    return try results.map { try $0!.get() }
}
