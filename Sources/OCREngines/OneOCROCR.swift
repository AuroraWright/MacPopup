import CoreGraphics
import Foundation
import OneOCR

/// Text recognition with OneOCR, the OCR of Windows' Snipping Tool (see Sources/OneOCR), run with Core ML. Its models
/// are Microsoft's and aren't shipped with the app: scripts/convert-oneocr.py converts them into a zip, which
/// Settings → OCR Mode loads into Application Support.
public final class OneOCROCR: Sendable {
    public static let shared = OneOCROCR()

    let models = ConvertedModels(.oneOCR) { try OneOCREngine(modelsDirectory: $0) } warmUp: { engine, blank in
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
        try await models.run { engine in
            Self.lines(try engine.recognize(image).lines, width: image.width, height: image.height)
        }
    }

    /// Lines with their words' boxes (CJK characters are words of their own), normalized to the image.
    private static func lines(_ lines: [OneOCREngine.Line], width: Int, height: Int) -> [RecognizedLine] {
        let w = CGFloat(width), h = CGFloat(height)
        func normalized(_ quad: [CGPoint]) -> CGRect {
            let xs = quad.map(\.x), ys = quad.map(\.y)
            let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
            return CGRect(x: x0 / w, y: y0 / h, width: ((xs.max() ?? 0) - x0) / w, height: ((ys.max() ?? 0) - y0) / h)
        }
        return lines.map { line in
            RecognizedLine(text: line.text, box: normalized(line.quad), words: line.words.map { ($0.text, normalized($0.quad)) })
        }
    }
}
