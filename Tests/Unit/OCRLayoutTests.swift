// OCR mode's character boxes (OCRLayout.layOut): an engine's line, with boxes that are off, snapped to the cells of
// evenly spaced full-width text in the picture, or kept when the engine's boxes are exact. The pictures are drawn here:
// a row of characters in 40 px cells.
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OCREngines

private let cell: CGFloat = 40, margin: CGFloat = 20

/// `text` drawn black on white, one character per cell from x = margin, with the cells' x ranges.
private func picture(_ text: String) throws -> (image: GrayImage, size: CGSize, cells: [ClosedRange<CGFloat>]) {
    let characters = text.map(String.init)
    let size = CGSize(width: margin * 2 + cell * CGFloat(characters.count), height: cell + margin * 2)
    let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(origin: .zero, size: size))
    let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, cell * 0.85, nil)
    for (index, character) in characters.enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        // Centered in its cell, the baseline a little above the cell's bottom (CG's y goes up).
        context.textPosition = CGPoint(x: margin + cell * CGFloat(index) + (cell - width) / 2, y: margin + cell * 0.18)
        CTLineDraw(line, context)
    }
    let drawn = try #require(context.makeImage())
    let image = try #require(GrayImage(drawn))
    let cells = characters.indices.map { margin + cell * CGFloat($0)...margin + cell * CGFloat($0 + 1) }
    return (image, size, cells)
}

/// The line laid out, its characters' boxes in the picture's pixels.
private func laidOut(_ line: RecognizedLine, in picture: (image: GrayImage, size: CGSize, cells: [ClosedRange<CGFloat>]),
                     exactBoxes: Bool = false) -> [OCRLayout.Char] {
    let size = picture.size
    return OCRLayout.layOut(line, image: picture.image, size: size, exactBoxes: exactBoxes) {
        CGRect(x: $0.minX * size.width, y: $0.minY * size.height, width: $0.width * size.width, height: $0.height * size.height)
    }.chars
}

/// Each character is centered in its cell, within 4 px. The first and last are only checked to be in theirs: the ink is
/// measured inside the engine's line box, so a glyph sticking out of it is centered on the part inside.
private func expectInCells(_ chars: [OCRLayout.Char], _ cells: [ClosedRange<CGFloat>], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(chars.count == cells.count, sourceLocation: sourceLocation)
    for (index, (char, cell)) in zip(chars, cells).enumerated() {
        let offset = abs(char.box.midX - (cell.lowerBound + cell.upperBound) / 2)
        let limit = index == 0 || index == cells.count - 1 ? (cell.upperBound - cell.lowerBound) / 4 : 4
        #expect(offset <= limit, "\(char.text) at \(char.box.midX), its cell \(cell)", sourceLocation: sourceLocation)
    }
}

/// A box in pixels, normalized to the picture.
private func normalized(_ box: CGRect, _ size: CGSize) -> CGRect {
    CGRect(x: box.minX / size.width, y: box.minY / size.height, width: box.width / size.width, height: box.height / size.height)
}

@Test func aLineBoxThatsOffIsSnappedToTheCells() throws {
    let text = "こんにちは世界です"
    let picture = try picture(text)
    // One box for the line, a third of a cell to the right and a little short (as Live Text's often are).
    let box = CGRect(x: margin + cell / 3, y: margin, width: cell * CGFloat(text.count) - cell / 4, height: cell)
    let chars = laidOut(RecognizedLine(text: text, box: normalized(box, picture.size), words: [(text, normalized(box, picture.size))]), in: picture)
    #expect(chars.map(\.text).joined() == text)
    expectInCells(chars, picture.cells)
}

@Test func aHalfWidthReadingOfAFullWidthDigitTakesItsWholeCell() throws {
    // The picture has a full-width ２ (as in "２挺"); the engine reads it as "2" and gives the line a box that's off.
    let picture = try picture("分解して２挺の自動火器")
    let text = "分解して2挺の自動火器"
    let box = CGRect(x: margin - cell / 4, y: margin, width: cell * 11 - cell / 3, height: cell)
    let chars = laidOut(RecognizedLine(text: text, box: normalized(box, picture.size), words: [(text, normalized(box, picture.size))]), in: picture)
    #expect(chars.map(\.text).joined() == text)
    expectInCells(chars, picture.cells)
    let two = try #require(chars.first { $0.text == "2" })
    #expect(two.box.width >= cell * 0.8, "2 is \(two.box.width) wide")
}

@Test func exactBoxesAreKept() throws {
    let text = "今日は晴れ"
    let picture = try picture(text)
    // An engine with exact character boxes (Screen AI's, meikiocr's, …): each a little inside its cell.
    let words = picture.cells.enumerated().map { index, x in
        (String(Array(text)[index]), normalized(CGRect(x: x.lowerBound + 3, y: margin + 2, width: cell - 6, height: cell - 4), picture.size))
    }
    let line = RecognizedLine(text: text, box: normalized(CGRect(x: margin, y: margin, width: cell * 5, height: cell), picture.size), words: words)
    let chars = laidOut(line, in: picture, exactBoxes: true)
    for (char, word) in zip(chars, words) {
        let expected = CGRect(x: word.1.minX * picture.size.width, y: word.1.minY * picture.size.height,
                              width: word.1.width * picture.size.width, height: word.1.height * picture.size.height)
        #expect(abs(char.box.midX - expected.midX) <= 1, "\(char.text) at \(char.box.midX), the engine's at \(expected.midX)")
    }
}
