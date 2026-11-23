import Foundation
import OneOCR

/// ocr-cli oneocr crt|detect|recnet|scores|ocr ...: the port's pieces, for checking them against the Python
/// reimplementation (see OneOCRDebug).
func oneOCRChecks(_ arguments: [String]) throws {
    func readDoubles(_ path: String) throws -> [Double] {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        return d.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    }
    func writeDoubles(_ v: [Double], _ path: String) throws {
        try v.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: path))
    }
    switch (arguments.first, arguments.count) {
    case ("crt", 4):
        // crt <function> <in: f64 pairs> <out: f64>
        let v = try readDoubles(arguments[2])
        let a = stride(from: 0, to: v.count, by: 2).map { v[$0] }, b = stride(from: 1, to: v.count, by: 2).map { v[$0] }
        guard let r = OneOCRDebug.crt(arguments[1], a, b) else { fatalError("unknown function \(arguments[1])") }
        try writeDoubles(r, arguments[3])
    case ("detect", 4...):
        // detect <models dir> <out.json> <image.bgr>...
        let r = try OneOCRDebug.detect(models: arguments[1], images: Array(arguments[3...]))
        try JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: arguments[2]))
    case ("recnet", 4...):
        // recnet <models dir> <char model> <line.bgr>...
        try OneOCRDebug.recnet(models: arguments[1], name: arguments[2], images: Array(arguments[3...]))
    case ("scores", 6):
        // scores <models dir> <conf|rej> <name> <in: f32 rows of 21> <out: f32>
        try OneOCRDebug.scores(models: arguments[1], kind: arguments[2], name: arguments[3], input: arguments[4], output: arguments[5])
    case ("ocr", 4...):
        // ocr <models dir> <out.json> <image.bgr>...
        let r = try OneOCRDebug.ocr(models: arguments[1], images: Array(arguments[3...]))
        try JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: arguments[2]))
    default:
        usage()
    }
}
