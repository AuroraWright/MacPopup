// OCR mode's reading order (OCRLayout.inParagraphs): lines joined into paragraphs, each paragraph's lines together and
// in order, the paragraphs in order. The lines are made up here, in window points, as the engines may list them.
import CoreGraphics
import Testing
@testable import OCREngines

/// A line of `text` in `box`, its characters dividing it evenly.
private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, vertical: Bool = false) -> OCRLayout.Line {
    let box = CGRect(x: x, y: y, width: width, height: height)
    let count = CGFloat(text.count)
    let chars = text.enumerated().map { index, char in
        OCRLayout.Char(text: String(char), box: vertical
            ? CGRect(x: x, y: y + height * CGFloat(index) / count, width: width, height: height / count)
            : CGRect(x: x + width * CGFloat(index) / count, y: y, width: width / count, height: height))
    }
    return OCRLayout.Line(text: text, box: box, vertical: vertical, chars: chars)
}

@Test func twoSpeechBubblesOneAboveTheOtherStayApart() {
    // Two bubbles of three 20 px columns at the same x, listed from the left as OneOCR does. Sorting every column from
    // the right read them alternately.
    let top = [line("上の一", 160, 0, 20, 100, vertical: true), line("上の二", 132, 0, 20, 100, vertical: true),
               line("上の三", 104, 0, 20, 100, vertical: true)]
    let bottom = [line("下の一", 162, 200, 20, 100, vertical: true), line("下の二", 134, 200, 20, 100, vertical: true),
                  line("下の三", 106, 200, 20, 100, vertical: true)]
    let paragraphs = OCRLayout.inParagraphs((top + bottom).reversed()) { $0 }
    #expect(paragraphs.map { $0.map(\.text) } == [["上の一", "上の二", "上の三"], ["下の一", "下の二", "下の三"]])
}

@Test func aLineSplitAlongItsRowStaysInItsParagraph() {
    // The engine split the first row ("…分厚い、" and "絆創") and lists the second part last.
    let lines = [line("指に巻かれた分厚い、", 0, 0, 360, 36), line("膏を剥がした。", 0, 48, 252, 36), line("絆創", 372, 0, 72, 36)]
    #expect(OCRLayout.inReadingOrder(lines).map(\.text) == ["指に巻かれた分厚い、", "絆創", "膏を剥がした。"])
}

@Test func aTallLabelBesideTheDialogueDoesntReorderItsRows() {
    // A big label left of three rows of dialogue, as tall as two of them: the rows stay top to bottom.
    let lines = [line("一行目のせりふ", 200, 100, 280, 40), line("二行目のせりふ", 200, 150, 280, 40),
                 line("三行目", 200, 200, 120, 40), line("名札", 20, 110, 120, 90)]
    let order = OCRLayout.inReadingOrder(lines).map(\.text)
    #expect(order.filter { $0 != "名札" } == ["一行目のせりふ", "二行目のせりふ", "三行目"])
}

@Test func columnsAndRowsGoTheirOwnWays() {
    // A horizontal caption above two vertical columns: the caption, then the columns from the right.
    let lines = [line("左の列", 100, 100, 24, 120, vertical: true), line("見出しです", 60, 20, 200, 30),
                 line("右の列", 132, 100, 24, 120, vertical: true)]
    #expect(OCRLayout.inParagraphs(lines) { $0 }.map { $0.map(\.text) } == [["見出しです"], ["右の列", "左の列"]])
}

@Test func digitsSetSidewaysInAColumnStayInIt() {
    // Live Text's 「合計35万人を」: "35" set sideways (縦中横) read as a horizontal line of its own between the column's
    // two parts, beside the next column 「超える見込みだ」. It used to be a paragraph of its own, read last.
    let lines = [line("合計", 118, 116, 62, 76, vertical: true), line("35", 138, 194, 42, 32),
                 line("万人を", 144, 236, 28, 98, vertical: true), line("超える見込みだ", 84, 118, 38, 256, vertical: true)]
    #expect(OCRLayout.inReadingOrder(lines).map(\.text) == ["合計", "35", "万人を", "超える見込みだ"])
}

/// A line of `text` turned by `degrees` (clockwise) about its center, with its corners.
private func turned(_ text: String, centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat, degrees: CGFloat) -> OCRLayout.Line {
    let angle = degrees * .pi / 180
    let (c, s) = (cos(angle), sin(angle))
    let (w, h) = (width / 2, height / 2)
    let offsets: [(x: CGFloat, y: CGFloat)] = [(-w, -h), (w, -h), (w, h), (-w, h)]
    let corners = offsets.map { (offset: (x: CGFloat, y: CGFloat)) -> CGPoint in
        CGPoint(x: centerX + offset.x * c - offset.y * s, y: centerY + offset.x * s + offset.y * c)
    }
    let xs = corners.map { $0.x }, ys = corners.map { $0.y }
    let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    var line = line(text, box.minX, box.minY, box.width, box.height)
    line.corners = corners
    return line
}

@Test func slantedRowsStayTogetherAndAnotherAngleIsItsOwn() {
    // As a game's dialogue set at an angle (Danganronpa): two rows turned 8° and 15°, the second starting further
    // right, and a word turned the other way (−32°) lower left, whose upright box shared a row with the second.
    let first = turned("鋭利な刃物に", centerX: 800, centerY: 370, width: 470, height: 75, degrees: 8)
    let second = turned("よるものですぅ…", centerX: 1230, centerY: 610, width: 525, height: 70, degrees: 15)
    let other = turned("はい、", centerX: 445, centerY: 660, width: 310, height: 110, degrees: -32)
    let paragraphs = OCRLayout.inParagraphs([first, other, second]) { $0 }
    #expect(paragraphs.map { $0.map(\.text) } == [["鋭利な刃物に", "よるものですぅ…"], ["はい、"]])
}

@Test func linesWithoutCornersOrSlightlyOffAreUpright() {
    // Corners a degree off, as engines give them for straight text, change nothing.
    let rows = [turned("一行目です", centerX: 200, centerY: 50, width: 300, height: 40, degrees: 1),
                turned("二行目です", centerX: 200, centerY: 100, width: 300, height: 40, degrees: -1)]
    var plain = rows
    for i in plain.indices { plain[i].corners = nil }
    #expect(OCRLayout.inParagraphs(rows) { $0 }.map { $0.map(\.text) } == OCRLayout.inParagraphs(plain) { $0 }.map { $0.map(\.text) })
    #expect(OCRLayout.inParagraphs(rows) { $0 }.count == 1)
}

@Test func aTurnedLineIsDrawnAlongItsText() {
    let row = turned("鋭利な刃物に", centerX: 800, centerY: 370, width: 470, height: 75, degrees: 8)
    let turn = row.turn(paragraphTilt: 0)
    #expect(abs((turn?.angle ?? 0) - 8 * .pi / 180) < 0.001)
    // Its own size, about its middle.
    #expect(abs((turn?.box.width ?? 0) - 470) < 0.5 && abs((turn?.box.height ?? 0) - 75) < 0.5)
    #expect(abs((turn?.box.midX ?? 0) - 800) < 0.5 && abs((turn?.box.midY ?? 0) - 370) < 0.5)
    // A short piece takes its paragraph's tilt; one barely turned, or without corners, is drawn upright.
    let piece = turned("はい", centerX: 300, centerY: 300, width: 80, height: 60, degrees: 30)
    #expect(abs((piece.turn(paragraphTilt: 0.2)?.angle ?? 0) - 0.2) < 0.001)
    #expect(turned("一行目です", centerX: 200, centerY: 50, width: 300, height: 40, degrees: 1).turn(paragraphTilt: 0.2) == nil)
    var plain = row
    plain.corners = nil
    #expect(plain.turn(paragraphTilt: 0.2) == nil)
}

@Test func aLineWithoutCornersIsUprightNotUnknown() {
    // Screen AI gives no corners for an upright line: it doesn't share a tilt with a sign turned 15°, while a short
    // piece (any angle) does.
    let upright = line("これは普通の台詞です", 100, 100, 400, 40)
    let sign = turned("右に曲がる看板です", centerX: 300, centerY: 170, width: 300, height: 40, degrees: 15)
    let piece = turned("は", centerX: 520, centerY: 120, width: 40, height: 40, degrees: 30)
    #expect(upright.tilt == 0)
    #expect(OCRLayout.sharedTilt(upright, sign) == nil)
    #expect(piece.tilt == nil && OCRLayout.sharedTilt(piece, sign) != nil)
}
