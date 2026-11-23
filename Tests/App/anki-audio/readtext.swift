// readtext <image>: the Japanese text Vision reads in the picture (accurate, ja then en), a line per text line, top to
// bottom. For checking what a card's screenshot shows. Built with tools/build.sh.
import AppKit
import Vision

guard CommandLine.arguments.count == 2, let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: readtext <image> (a picture AppKit reads)")
    exit(2)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["ja-JP", "en-US"]
request.usesLanguageCorrection = true
do {
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
} catch {
    print("readtext: \(error.localizedDescription)")
    exit(1)
}
for observation in request.results ?? [] {
    if let text = observation.topCandidates(1).first?.string { print(text) }
}
