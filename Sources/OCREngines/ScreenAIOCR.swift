import CoreGraphics
import Foundation
import ScreenAI

/// Text recognition with Screen AI, Chrome's OCR (see Sources/ScreenAI), run with Core ML. Its models are Google's and
/// aren't shipped with the app: scripts/convert-screenai.py converts the ones Chrome downloads into a zip, which
/// Settings → OCR Mode loads (installModels) into Application Support.
public final class ScreenAIOCR: Sendable {
    public static let shared = ScreenAIOCR()

    let models = ConvertedModels(.screenAI) { try ScreenAIEngine(modelsDirectory: $0, cpuOnly: OCRCompute.cpuOnly) } warmUp: { engine, blank in
        _ = try engine.recognize(blank)
    }

    /// Loads the models, if they aren't yet.
    public func prepare() async throws {
        try await models.run { _ in }
    }

    /// Lets the models go, to free their memory; the next picture loads them again.
    public func unload() async {
        await models.unload()
    }

    public func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try await models.run { engine in Self.lines(try engine.recognize(image), width: image.width, height: image.height) }
    }

    /// Lines with a box per character where the recognizer gives them (its symbols), normalized to the image.
    private static func lines(_ lines: [ScreenAIEngine.Line], width: Int, height: Int) -> [RecognizedLine] {
        let w = CGFloat(width), h = CGFloat(height)
        func normalized(_ box: ScreenAIEngine.Box) -> CGRect {
            let b = box.bounds
            return CGRect(x: b.minX / w, y: b.minY / h, width: b.width / w, height: b.height / h)
        }
        return lines.map { line in
            let words = line.words.flatMap { word -> [(text: String, box: CGRect)] in
                word.symbols.isEmpty
                    ? [(word.text, normalized(word.box))]
                    : word.symbols.map { ($0.text, normalized($0.box)) }
            }
            return RecognizedLine(text: line.text, box: normalized(line.box), words: words)
        }
    }
}
