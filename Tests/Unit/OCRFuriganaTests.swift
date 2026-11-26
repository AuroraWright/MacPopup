// Furigana left out of OCR readings (Settings → OCR → Ignore furigana; OCRLayout.furigana and removingFurigana): small
// lines without kanji right above kanji (right of them in vertical text), and not a speaker's name, a caption or a line
// of kana. The pages are drawn here, laid out as test-corpus/furigana's synthetic ones (a game's text box with ruby,
// vertical text, and their negatives): each engine line is one or more runs of characters in square cells.
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OCREngines

/// Characters in cells of `size` px from (x, y) (the top left, y down), across or down; the engine's boxes for them
/// `padding` px bigger across.
private struct Run {
    let text: String
    let x: CGFloat, y: CGFloat, size: CGFloat
    var vertical = false
    var padding: CGFloat = 0

    var cells: [CGRect] {
        (0..<text.count).map { index in
            let offset = size * CGFloat(index)
            return CGRect(x: vertical ? x : x + offset, y: vertical ? y + offset : y, width: size, height: size)
        }
    }

    var boxes: [CGRect] {
        cells.map { $0.insetBy(dx: vertical ? -padding : 0, dy: vertical ? 0 : -padding) }
    }
}

/// A page: what the engine read (each line one or more runs) drawn on a plain background.
private struct Page {
    let width: CGFloat, height: CGFloat
    var dark = false
    let lines: [[Run]]

    /// The picture, in Hiragino Sans: white on dark gray (a game's text box) or near black on white.
    func picture() throws -> GrayImage {
        let context = try #require(CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: dark ? 0.15 : 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for run in lines.joined() {
            let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, run.size, nil)
            for (character, cell) in zip(run.text, run.cells) {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: dark ? 1 : 0.07, alpha: 1),
                ]))
                let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
                // Centered across the cell, on a baseline at its descent (CG's y goes up).
                context.textPosition = CGPoint(x: cell.minX + (cell.width - advance) / 2, y: height - cell.maxY + 0.12 * run.size)
                CTLineDraw(line, context)
            }
        }
        let drawn = try #require(context.makeImage())
        return try #require(GrayImage(drawn))
    }

    /// The lines laid out as OCR mode does (window points = the picture's pixels), measuring their ink in the picture
    /// unless `withPicture` is false (as for an engine without one).
    func laidOut(withPicture: Bool = true) throws -> [OCRLayout.Line] {
        let image = withPicture ? try picture() : nil
        let size = CGSize(width: width, height: height)
        let normalized = { (box: CGRect) in
            CGRect(x: box.minX / width, y: box.minY / height, width: box.width / width, height: box.height / height)
        }
        return lines.map { runs in
            let cells = runs.flatMap(\.boxes)
            let words = zip(runs.map(\.text).joined(), cells).map { (text: String($0), box: normalized($1)) }
            let box = cells.dropFirst().reduce(cells[0]) { $0.union($1) }
            let line = RecognizedLine(text: runs.map(\.text).joined(), box: normalized(box), words: words)
            return OCRLayout.layOut(line, image: image, size: size, exactBoxes: true) {
                CGRect(x: $0.minX * width, y: $0.minY * height, width: $0.width * width, height: $0.height * height)
            }
        }
    }
}

/// h_game: a text box's two rows of 44 px text with 19 px ruby above their kanji; the second row's readings (over 準備
/// and 整) read as one line, as engines often do.
private let gamePage = Page(width: 560, height: 200, dark: true, lines: [
    [Run(text: "魔王の城へ向かう前に、", x: 40, y: 54, size: 44)],
    [Run(text: "準備を整えておこう。", x: 40, y: 146, size: 44)],
    [Run(text: "まおう", x: 55.5, y: 35, size: 19)],
    [Run(text: "しろ", x: 175, y: 35, size: 19)],
    [Run(text: "む", x: 272.5, y: 35, size: 19)],
    [Run(text: "まえ", x: 395, y: 35, size: 19)],
    [Run(text: "じゅんび", x: 46, y: 127, size: 19), Run(text: "ととの", x: 165.5, y: 127, size: 19)],
])

@Test func rubyAboveKanjiIsTheirRows() throws {
    let lines = try gamePage.laidOut()
    #expect(lines.allSatisfy { $0.ink?.runs != nil })
    // The second row's readings are below the first row too: they're the second row's.
    #expect(OCRLayout.furigana(in: lines) == [2: 0, 3: 0, 4: 0, 5: 0, 6: 1])
    #expect(OCRLayout.removingFurigana(lines).map(\.text) == ["魔王の城へ向かう前に、", "準備を整えておこう。"])
}

@Test func withoutThePictureTheBoxesTell() throws {
    let lines = try gamePage.laidOut(withPicture: false)
    #expect(lines.allSatisfy { $0.ink == nil })
    #expect(OCRLayout.furigana(in: lines) == [2: 0, 3: 0, 4: 0, 5: 0, 6: 1])
}

@Test func paddedBoxesOfRubyAreMeasuredOnTheirInk() throws {
    // The readings' boxes 8 px bigger above and below (as Screen AI's for small kana): too big for furigana on the boxes,
    // reaching into the row below them, but their strokes are as small as before. Not む's: a box that tall for one kana
    // is taken for vertical text, measured on its box.
    let padded = gamePage.lines.map { runs in
        runs.map { $0.size < 44 && $0.text != "む" ? Run(text: $0.text, x: $0.x, y: $0.y, size: $0.size, padding: 8) : $0 }
    }
    let page = Page(width: gamePage.width, height: gamePage.height, dark: true, lines: padded)
    #expect(OCRLayout.furigana(in: try page.laidOut()) == [2: 0, 3: 0, 4: 0, 5: 0, 6: 1])
    // Without the picture, only む's.
    #expect(OCRLayout.furigana(in: try page.laidOut(withPicture: false)) == [4: 0])
}

@Test func rubyRightOfVerticalKanjiIsTheirColumns() throws {
    // v_game: two 36 px columns from the right, readings 16 px right of their kanji; 待's one-kana reading is a square
    // box, which the layout takes for horizontal text.
    let page = Page(width: 600, height: 300, dark: true, lines: [
        [Run(text: "明日の朝", x: 513, y: 30, size: 36, vertical: true)],
        [Run(text: "港で待っている", x: 434, y: 30, size: 36, vertical: true)],
        [Run(text: "あした", x: 549, y: 42, size: 16, vertical: true)],
        [Run(text: "あさ", x: 549, y: 140, size: 16, vertical: true)],
        [Run(text: "みなと", x: 470, y: 24, size: 16, vertical: true)],
        [Run(text: "ま", x: 470, y: 112, size: 16)],
    ])
    let lines = try page.laidOut()
    #expect(lines.map(\.vertical) == [true, true, true, true, true, false])
    #expect(OCRLayout.furigana(in: lines) == [2: 0, 3: 0, 4: 1, 5: 1])
}

@Test func aSpeakersNameAboveTheTextIsKept() throws {
    // neg_name: a 24 px name 17 px above 36 px text.
    let page = Page(width: 520, height: 130, dark: true, lines: [
        [Run(text: "さくら", x: 40, y: 31, size: 24)],
        [Run(text: "今日は雨が降りそうだね。", x: 40, y: 72, size: 36)],
    ])
    #expect(OCRLayout.furigana(in: try page.laidOut()).isEmpty)
    #expect(OCRLayout.furigana(in: try page.laidOut(withPicture: false)).isEmpty)
}

@Test func aSmallCaptionFarAboveIsKept() throws {
    // neg_caption: an 18 px button label 53 px above 34 px text.
    let page = Page(width: 500, height: 150, lines: [
        [Run(text: "つづきから", x: 24, y: 28, size: 18)],
        [Run(text: "冒険の書を選択してください", x: 24, y: 99, size: 34)],
    ])
    #expect(OCRLayout.furigana(in: try page.laidOut()).isEmpty)
}

@Test func aLineOfKanaAboveIsKept() throws {
    // neg_kana: two rows of 30 px text, the first without kanji.
    let page = Page(width: 420, height: 130, lines: [
        [Run(text: "ねえ、ちょっといいかな。", x: 24, y: 31, size: 30)],
        [Run(text: "明日の予定を教えて。", x: 24, y: 76, size: 30)],
    ])
    #expect(OCRLayout.furigana(in: try page.laidOut()).isEmpty)
}

@Test func smallKanaOverKanaOnlyAreKept() throws {
    // Small kana over おこう, past 整's reading's reach: not a reading of kanji (a sound, emphasis).
    var lines = gamePage.lines
    lines.append([Run(text: "ふふふ", x: 341.5, y: 127, size: 19)])
    let page = Page(width: gamePage.width, height: gamePage.height, dark: true, lines: lines)
    let bases = OCRLayout.furigana(in: try page.laidOut())
    #expect(bases[7] == nil)
    #expect(bases[6] == 1)
}

@Test func rubyBelowItsLineIsntTheirs() throws {
    // The first row alone with its readings moved below it, where furigana don't go in horizontal text.
    let page = Page(width: 560, height: 140, lines: [
        [Run(text: "魔王の城へ向かう前に、", x: 40, y: 30, size: 44)],
        [Run(text: "まおう", x: 55.5, y: 74, size: 19)],
        [Run(text: "しろ", x: 175, y: 74, size: 19)],
    ])
    #expect(OCRLayout.furigana(in: try page.laidOut()).isEmpty)
}

@Test func lowResolutionRubyIsTheirRows() throws {
    // A PSP game's text box: 18 px rows with readings in 10 px kana right above them, whose ink is 0.55–0.58 of the
    // row's (small kana stay legible at that size). Vertical kana that small beside kanji are text as often as
    // readings (manga lettering), so there the limit stays lower.
    let page = Page(width: 400, height: 80, dark: true, lines: [
        [Run(text: "貫祿たっぷりな刑事像だ。", x: 16, y: 30, size: 18)],
        [Run(text: "かんろく", x: 16, y: 19, size: 10)],
    ])
    let lines = try page.laidOut()
    #expect(OCRLayout.furigana(in: lines) == [1: 0])
}
