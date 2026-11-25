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
