// screenai-cli <models dir> <out dir> <image>...: writes each image's stage layouts (goodoc.PageLayoutProto) to
// <out dir>/<n>/<stage>.pb, n counting the images from 0, for comparison with the C++ port's SCREENAI_STAGE_DUMP.
// screenai-cli --lines <models dir> <image>...: prints each image's lines as the app gets them (one JSON array per
// image: its path, then the array of its line texts).
import Foundation
import ImageIO
import ScreenAI

let args = CommandLine.arguments
func image(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
if args.count >= 3 && args[1] == "--lines" {
    do {
        let engine = try ScreenAIEngine(modelsDirectory: URL(fileURLWithPath: args[2]))
        for path in args[3...] {
            guard let image = image(path) else {
                print("cannot read \(path)")
                continue
            }
            let texts = try engine.recognize(image).map(\.text)
            print(String(decoding: try JSONSerialization.data(withJSONObject: [path, texts]), as: UTF8.self))
        }
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: screenai-cli <models dir> <out dir> <image>...\n".data(using: .utf8)!)
    exit(2)
}
do {
    let engine = try ScreenAIEngine(modelsDirectory: URL(fileURLWithPath: args[1]))
    let out = URL(fileURLWithPath: args[2])
    for (n, path) in args[3...].enumerated() {
        guard let image = image(path) else {
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
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
