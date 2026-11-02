// screenai-cli <models dir> <out dir> <image>...: writes each image's stage layouts (goodoc.PageLayoutProto) to
// <out dir>/<n>/<stage>.pb, n counting the images from 0, for comparison with the C++ port's SCREENAI_STAGE_DUMP.
import Foundation
import ImageIO
import ScreenAI

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: screenai-cli <models dir> <out dir> <image>...\n".data(using: .utf8)!)
    exit(2)
}
do {
    let engine = try ScreenAIEngine(modelsDirectory: URL(fileURLWithPath: args[1]))
    let out = URL(fileURLWithPath: args[2])
    for (n, path) in args[3...].enumerated() {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
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
