import Foundation

// The page layout passed between the OCR stages (detection, then recognition). Field meanings follow the original
// engine's goodoc.PageLayoutEntity; only the fields the pipeline uses are kept. `goodocProto()` serializes it like
// the C++ port's WriteGoodocProto, so the two can be compared byte for byte.

/// Curved line geometry: a polyline along the middle of the text, plus its thickness.
struct Curve {
    var points: [(x: Double, y: Double)] = []
    var thickness: Double = 0
    /// Set on goodoc polygons, unset in the detector's copy.
    var topToBottom: Bool?
}

/// Rotated rectangle: (left, top) is the top-left corner before the rotation about it; the angle is in degrees,
/// clockwise. With a curve, the box is the curve's enclosing box.
struct RotatedBox {
    var left = 0, top = 0, width = 0, height = 0
    var angle: Float = 0
    var curve: Curve?
}

enum EntityType: Int {
    case word = 0, line = 2, paragraph = 3, block = 4, symbol = 5
}

/// google_ocr.PhotoOcrTextDetectionInfo of the lines the detector finds.
struct DetectionInfo {
    var detectionBox = RotatedBox()
    var detectionImageScale = 1000
    var averageRawDetectionsHeight: Float = 0
    var varianceRawDetectionsHeight: Float = 0
    var detectionNmsScore: Float = 0
    var numRawBoxes = 0
    var sumRawBoxesScores: Float = 0
    var leftPadding: Float = 0, rightPadding: Float = 0
    var garbageProb: Float?
    var fallbackUpscaling = false
}

struct Colors {
    var foregroundGray = 0, backgroundGray = 0
    var foregroundRgb: Int?, backgroundRgb: Int?
    var foregroundGrayThreshold: Int?
    var foregroundSamples: [(Int, Int)] = [], backgroundSamples: [(Int, Int)] = []
}

struct WordBreak {
    /// goodoc.Break.BreakType: 1 none, 2 space.
    var type = 0
    var box: RotatedBox?
}

/// aksara.TextLineResult of a line.
struct AksaraResult {
    var text: String?, language: String?, predictedScript: String?
    var confidence: Float?
    var rightToLeft: Bool?
}

struct Entity {
    var type = EntityType.line
    /// Index into `PageLayout.entities`, or -1.
    var parent = -1
    var box: RotatedBox?
    /// goodoc ContentType (0 text, 1 handwritten).
    var contentType: Int?
    var orientation: Int?, writingDirection: Int?, textlineOrder: Int?
    var confidence: Float?, detectionConfidence: Float?, typeConfidence: Float?, directionConfidence: Float?
    var predictedDirection: Int?
    /// BCP 47 tags.
    var languages: [String] = []
    var text: String?
    var recognizerScriptId: String?
    var wordBreak: WordBreak?
    var colors: Colors?
    var detection: DetectionInfo?
    var aksara: AksaraResult?
}

struct PageLayout {
    var width = 0, height = 0
    var entities: [Entity] = []
}

// MARK: - goodoc.PageLayoutProto

extension PageLayout {
    private static let photoOcrTextDetectionInfoExt = 12365408
    private static let aksaraInternalEntityExt = 108072910

    private static func curveFields(_ c: Curve) -> ProtoWriter {
        var w = ProtoWriter()
        var curve = ProtoWriter()
        for p in c.points {
            var pw = ProtoWriter()
            pw.double(1, p.x)
            pw.double(2, p.y)
            curve.message(1, pw)
        }
        w.message(1, curve)
        w.double(2, c.thickness)
        if let t = c.topToBottom { w.bool(3, t) }
        return w
    }

    private static func box(_ b: RotatedBox) -> ProtoWriter {
        var w = ProtoWriter()
        w.int(1, b.left)
        w.int(2, b.top)
        w.int(3, b.width)
        w.int(4, b.height)
        w.float(5, b.angle)
        return w
    }

    private static func polygon(_ b: RotatedBox) -> ProtoWriter {
        var poly = ProtoWriter()
        if let c = b.curve {
            var curved = curveFields(c)
            curved.message(4, box(b))
            poly.message(3, curved)
        } else {
            poly.message(2, box(b))
        }
        return poly
    }

    private static func entity(_ e: Entity) -> ProtoWriter {
        var w = ProtoWriter()
        if e.parent >= 0 { w.int(1, e.parent) }
        if let b = e.box { w.message(2, polygon(b)) }
        w.int(4, e.type.rawValue)
        if let v = e.contentType { w.int(5, v) }
        if e.orientation != nil || e.writingDirection != nil || e.textlineOrder != nil {
            var o = ProtoWriter()
            if let v = e.orientation { o.int(1, v) }
            if let v = e.writingDirection { o.int(2, v) }
            if let v = e.textlineOrder { o.int(3, v) }
            w.message(6, o)
        }
        if let v = e.confidence { w.float(7, v) }
        if !e.languages.isEmpty {
            var mix = ProtoWriter()
            for l in e.languages {
                var lang = ProtoWriter()
                lang.string(1, l)
                mix.message(1, lang)
            }
            w.message(13, mix)
        }
        if let v = e.detectionConfidence { w.float(14, v) }
        if let v = e.text { w.string(15, v) }
        if let wb = e.wordBreak {
            var b = ProtoWriter()
            b.int(1, wb.type)
            if let bb = wb.box { b.message(2, box(bb)) }
            w.message(16, b)
        }
        if let c = e.colors {
            var cw = ProtoWriter()
            cw.int(1, c.foregroundGray)
            cw.int(2, c.backgroundGray)
            if let v = c.foregroundRgb { cw.int(3, v) }
            if let v = c.backgroundRgb { cw.int(4, v) }
            if let v = c.foregroundGrayThreshold { cw.int(5, v) }
            for (field, samples) in [(6, c.foregroundSamples), (7, c.backgroundSamples)] {
                for (x, y) in samples {
                    var p = ProtoWriter()
                    p.int(1, x)
                    p.int(2, y)
                    cw.message(field, p)
                }
            }
            w.message(17, cw)
        }
        if let v = e.typeConfidence { w.float(22, v) }
        if let v = e.recognizerScriptId { w.string(23, v) }
        if let v = e.directionConfidence { w.float(27, v) }
        if let v = e.predictedDirection { w.int(32, v) }
        if let d = e.detection {
            var dw = ProtoWriter()
            var detBox = box(d.detectionBox)
            if let c = d.detectionBox.curve { detBox.message(6, curveFields(c)) }
            dw.message(1, detBox)
            dw.int(4, d.detectionImageScale)
            dw.float(9, d.averageRawDetectionsHeight)
            dw.float(10, d.varianceRawDetectionsHeight)
            dw.float(11, d.detectionNmsScore)
            dw.int(12, d.numRawBoxes)
            dw.float(13, d.sumRawBoxesScores)
            dw.float(14, d.leftPadding)
            dw.float(15, d.rightPadding)
            if let v = d.garbageProb { dw.float(16, v) }
            dw.bool(17, d.fallbackUpscaling)
            w.message(photoOcrTextDetectionInfoExt, dw)
        }
        if let a = e.aksara {
            var result = ProtoWriter()
            if let v = a.text { result.string(1, v) }
            if let v = a.rightToLeft { result.bool(19, v) }
            if let v = a.language { result.string(20, v) }
            if let v = a.confidence { result.float(21, v) }
            if let v = a.predictedScript { result.string(24, v) }
            var ext = ProtoWriter()
            ext.message(3, result)
            w.message(aksaraInternalEntityExt, ext)
        }
        return w
    }

    /// goodoc.PageLayoutProto wire format (the subset the C++ port writes).
    func goodocProto() -> [UInt8] {
        var w = ProtoWriter()
        w.int(1, width)
        w.int(2, height)
        var image = ProtoWriter()
        image.int(2, width)
        image.int(3, height)
        image.int(4, 1)
        w.message(3, image)
        for e in entities { w.message(7, Self.entity(e)) }
        return w.bytes
    }
}
