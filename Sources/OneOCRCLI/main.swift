import Foundation
import OneOCR

func readDoubles(_ path: String) -> [Double] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: path))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
}

func writeDoubles(_ v: [Double], _ path: String) {
    try! v.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "crt":
    // crt <function> <in: f64 pairs> <out: f64>
    let v = readDoubles(args[3])
    let a = stride(from: 0, to: v.count, by: 2).map { v[$0] }, b = stride(from: 1, to: v.count, by: 2).map { v[$0] }
    guard let r = OneOCRDebug.crt(args[2], a, b) else { fatalError("unknown function \(args[2])") }
    writeDoubles(r, args[4])
case "detect":
    // detect <models dir> <out.json> <image.bgr>...
    let r = try OneOCRDebug.detect(models: args[2], images: Array(args[4...]))
    try JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: args[3]))
case "recnet":
    // recnet <models dir> <char model> <line.bgr>...
    try OneOCRDebug.recnet(models: args[2], name: args[3], images: Array(args[4...]))
case "scores":
    // scores <models dir> <conf|rej> <name> <in: f32 rows of 21> <out: f32>
    try OneOCRDebug.scores(models: args[2], kind: args[3], name: args[4], input: args[5], output: args[6])
case "ocr":
    // ocr <models dir> <out.json> <image.bgr>...
    let r = try OneOCRDebug.ocr(models: args[2], images: Array(args[4...]))
    try JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: args[3]))
default:
    print("""
    usage: oneocr-cli crt <function> <in> <out>
           oneocr-cli detect <models> <out.json> <image.bgr>...
           oneocr-cli recnet <models> <char model> <line.bgr>...
           oneocr-cli scores <models> <conf|rej> <name> <in> <out>
           oneocr-cli ocr <models> <out.json> <image.bgr>...
    """)
    exit(2)
}
