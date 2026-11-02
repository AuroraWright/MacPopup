import CoreML
import Foundation

/// A compiled Core ML model converted from one of the original's TFLite models. They run on the GPU: the models are
/// in 32-bit floats, which the Neural Engine can't run, and Core ML's CPU engine crashes on some detector input
/// sizes (it reads past a buffer).
final class CoreMLModel: @unchecked Sendable {
    let model: MLModel

    init(_ url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        do {
            model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            throw ScreenAIError("Can't load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Outputs by name. Safe to call from several threads.
    func predict(_ inputs: [String: MLMultiArray]) throws -> [String: MLMultiArray] {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        let out = try model.prediction(from: provider)
        var result: [String: MLMultiArray] = [:]
        for name in out.featureNames {
            if let a = out.featureValue(for: name)?.multiArrayValue { result[name] = a }
        }
        return result
    }
}

/// The name a tensor gets in the converted model (scripts/convert-screenai.py): non-alphanumerics become "_".
func coreMLName(_ tensorName: String) -> String {
    String(tensorName.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
}

/// Calls body with each innermost row of the array in row-major order, as floats: (row, its length, the row-major
/// offset of its first value). Rows are passed in place when they're contiguous 32-bit floats, else converted.
func forEachFloatRow(_ a: MLMultiArray, _ body: (UnsafePointer<Float>, Int, Int) -> Void) {
    let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
    let rank = shape.count
    let inner = rank > 0 ? shape[rank - 1] : 1, innerStride = rank > 0 ? strides[rank - 1] : 1
    let rows = rank > 0 ? shape.dropLast().reduce(1, *) : 1
    if inner == 0 || rows == 0 { return }
    func walk<T>(_ src: UnsafePointer<T>, _ convert: (T) -> Float) {
        var scratch = [Float](repeating: 0, count: inner)
        var idx = [Int](repeating: 0, count: max(rank - 1, 0))
        var offset = 0
        scratch.withUnsafeMutableBufferPointer { row in
            for r in 0..<rows {
                if T.self == Float.self && innerStride == 1 {
                    UnsafeRawPointer(src + offset).withMemoryRebound(to: Float.self, capacity: inner) { body($0, inner, r * inner) }
                } else {
                    for k in 0..<inner { row[k] = convert(src[offset + k * innerStride]) }
                    body(row.baseAddress!, inner, r * inner)
                }
                // Next row: increment the outer index like an odometer.
                var d = rank - 2
                while d >= 0 {
                    idx[d] += 1
                    offset += strides[d]
                    if idx[d] < shape[d] { break }
                    offset -= idx[d] * strides[d]
                    idx[d] = 0
                    d -= 1
                }
            }
        }
    }
    a.withUnsafeBytes { raw in
        switch a.dataType {
        case .float16: walk(raw.bindMemory(to: UInt16.self).baseAddress!) { Float(Float16(bitPattern: $0)) }
        case .double: walk(raw.bindMemory(to: Double.self).baseAddress!) { Float($0) }
        default: walk(raw.bindMemory(to: Float.self).baseAddress!) { $0 }
        }
    }
}

/// Calls body with the array's values as contiguous floats in row-major order (copied when the array is strided or
/// not 32-bit).
func withContiguousFloats<R>(_ a: MLMultiArray, _ body: (UnsafePointer<Float>) -> R) -> R {
    let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
    var contiguous = a.dataType == .float32
    var expected = 1
    for d in stride(from: shape.count - 1, through: 0, by: -1) {
        if shape[d] != 1 && strides[d] != expected { contiguous = false }
        expected *= shape[d]
    }
    if contiguous {
        return a.withUnsafeBytes { body($0.bindMemory(to: Float.self).baseAddress!) }
    }
    var out = [Float](repeating: 0, count: shape.reduce(1, *))
    out.withUnsafeMutableBufferPointer { dst in
        forEachFloatRow(a) { row, n, offset in (dst.baseAddress! + offset).update(from: row, count: n) }
    }
    return out.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// TFLite's requantization of a float output: clamp(rint(v / scale) + zero point, 0, 255), in row-major order.
func requantize(_ a: MLMultiArray, scale: Float, zeroPoint: Float) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: a.count)
    data.withUnsafeMutableBufferPointer { dst in
        forEachFloatRow(a) { row, n, offset in
            let d = dst.baseAddress! + offset
            for k in 0..<n {
                let q = min(max((row[k] / scale).rounded(.toNearestOrEven) + zeroPoint, 0), 255)
                // q is a whole number in 0...255, so 2^23 + q holds it in the low mantissa bits: an unchecked
                // conversion, which lets the loop vectorize.
                d[k] = UInt8(truncatingIfNeeded: (q + 8_388_608).bitPattern)
            }
        }
    }
    return data
}
