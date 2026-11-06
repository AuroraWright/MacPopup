import CoreGraphics
import Foundation
import LiveText
import OCREngines

/// The text recognition engines, by the names MacPopup's settings use (Settings → OCR Mode → Text recognition engine).
enum Engine: String, CaseIterable, Identifiable, Sendable {
    case liveText
    case meikiocr
    case screenAI = "screenai"
    case oneOCR = "oneocr"
    case ppocrManga = "ppocrmanga"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .liveText: "Live Text"
        case .meikiocr: "meikiocr"
        case .screenAI: "Screen AI"
        case .oneOCR: "OneOCR"
        case .ppocrManga: "PP-OCRv6 Manga"
        }
    }

    /// Screen AI and OneOCR need the models the user converts on the Mac (loading them comes in a later version).
    var isAvailable: Bool {
        switch self {
        case .liveText: MPLiveText.isAvailable()
        case .meikiocr, .ppocrManga: true
        case .screenAI: ConvertedModelsKind.screenAI.installed
        case .oneOCR: ConvertedModelsKind.oneOCR.installed
        }
    }

    /// Whether its boxes for words are where they are (see OCRLayout.layOut).
    var hasExactBoxes: Bool { self != .liveText }

    /// Whether it gives the lines in reading order (see OCRController.lines(from:)).
    var ordersLines: Bool { self == .screenAI }

    func recognize(_ image: CGImage, language: String) async throws -> [RecognizedLine] {
        switch self {
        case .liveText:
            try await Self.liveText(image, locales: await Self.liveTextLocales(for: language)).map { line in
                RecognizedLine(text: line.text, box: line.box, words: line.words.map { ($0.text, $0.box) })
            }
        case .meikiocr: try await MeikiOCR.shared.recognize(image)
        case .screenAI: try await ScreenAIOCR.shared.recognize(image)
        case .oneOCR: try await OneOCROCR.shared.recognize(image)
        case .ppocrManga: try await PPOCRManga.shared.recognize(image)
        }
    }

    /// Loads the models, so that the first picture doesn't wait for them.
    func prepare(language: String) async throws {
        switch self {
        case .liveText: _ = try await Self.liveText(Self.blank(), locales: await Self.liveTextLocales(for: language))
        case .meikiocr: try await MeikiOCR.shared.prepare()
        case .screenAI: try await ScreenAIOCR.shared.prepare()
        case .oneOCR: try await OneOCROCR.shared.prepare()
        case .ppocrManga: try await PPOCRManga.shared.prepare()
        }
    }

    /// Frees the models' memory (Live Text's is the system's).
    func unload() async {
        switch self {
        case .liveText: break
        case .meikiocr: await MeikiOCR.shared.unload()
        case .screenAI: await ScreenAIOCR.shared.unload()
        case .oneOCR: await OneOCROCR.shared.unload()
        case .ppocrManga: await PPOCRManga.shared.unload()
        }
    }

    /// Live Text's languages: the language's, or only English when it doesn't read it. English is always read too.
    @MainActor private static func liveTextLocales(for language: String) -> [String] {
        let locales = OCRLanguage.liveTextLocales(for: language)
        return locales.contains { $0.hasPrefix("en") } ? locales : locales + ["en"]
    }

    private static func liveText(_ image: CGImage, locales: [String]) async throws -> [MPLiveTextItem] {
        try await withCheckedThrowingContinuation { continuation in
            MPLiveText.recognizeImage(image, locales: locales) { lines, error in
                if let lines {
                    continuation.resume(returning: lines)
                } else {
                    continuation.resume(throwing: error ?? AppError("Live Text failed."))
                }
            }
        }
    }

    private static func blank() -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return context.makeImage()!
    }
}
