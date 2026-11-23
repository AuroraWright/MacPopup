import Foundation
import ImageIO
import ScreenAI

/// ocr-cli screenai-stages <models dir> <out dir> <image>...: writes each image's stage layouts (goodoc.PageLayoutProto)
/// to <out dir>/<n>/<stage>.pb, n counting the images from 0, for comparison with the C++ port's SCREENAI_STAGE_DUMP.
func screenAIStages(_ arguments: [String]) throws {
    guard arguments.count >= 3 else { usage() }
    let engine = try ScreenAIEngine(modelsDirectory: URL(fileURLWithPath: arguments[0]))
    let out = URL(fileURLWithPath: arguments[1])
    for (n, path) in arguments[2...].enumerated() {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("cannot read \(path)")
            continue
        }
        let start = Date()
        let dumps = try engine.stageDumps(image)
        let dir = out.appendingPathComponent(String(n))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, bytes) in dumps { try Data(bytes).write(to: dir.appendingPathComponent(name + ".pb")) }
        print(String(format: "%@ %.1f ms", path, Date().timeIntervalSince(start) * 1000))
    }
}
