// The marks a reading's rows end with (OCRController.endMarks, endsVary, coreKey): an icon after the text that OCR reads
// as a bracket one time, another the next, or not at all, varies; the line's last characters drawn, added to, don't.
import Testing
@testable import MacPopup

@Test func endMarks() {
    #expect(OCRController.endMarks(["………………殺される･……………』"]) == "』")
    #expect(OCRController.endMarks(["「はい。」 ", "そう……"]) == "」\n")
    #expect(OCRController.coreKey(["………………殺される･……………』"]) == OCRController.coreKey(["……………･殺される……………"]))
    #expect(OCRController.coreKey(["「はい。」"]) == "「はい。")
    #expect(OCRController.coreKey(["「え？」"]) != OCRController.coreKey(["「え！」"]))
}

@Test func endsVary() {
    #expect(OCRController.endsVary(["』", "」"]))
    #expect(OCRController.endsVary(["』", "", "』"]))
    #expect(OCRController.endsVary(["』", "』", ""]))
    #expect(!OCRController.endsVary(["", "。", "。」"]))
    #expect(!OCRController.endsVary(["！", "！"]))
    #expect(!OCRController.endsVary([]))
}

// A letter or two more at the end of one row (OCRController.tail): Screen AI reading the blinking icon after
// 「……殺される……」 as 上 (test-corpus/phantom/next-icon-screenai-*).
@Test func tail() {
    let rows = OCRController.rowCores(["………………殺される………………"])
    let more = OCRController.rowCores(["………………殺される………………上"])
    #expect(OCRController.tail(of: more, over: rows)?.row == 0)
    #expect(OCRController.tail(of: more, over: rows)?.text == "上")
    #expect(OCRController.tail(of: rows, over: more) == nil)
    #expect(OCRController.tail(of: OCRController.rowCores(["……殺される……」"]), over: rows) == nil)
    // Only the last characters of one row, at most two, after text that's there.
    #expect(OCRController.tail(of: ["あいう", "えお"], over: ["あいう", "え"])?.text == "お")
    #expect(OCRController.tail(of: ["あいうえお"], over: ["あい"]) == nil)
    #expect(OCRController.tail(of: ["あいう", "えお"], over: ["あい", "え"]) == nil)
    #expect(OCRController.tail(of: ["上"], over: [""]) == nil)
    #expect(OCRController.tail(of: ["あいう"], over: ["あいう", ""]) == nil)
    #expect(OCRController.tail(of: ["待て。"], over: ["待て"]) == nil)
    // A letter after a mark (Umineko's icon read as い after the 」, the 」 an end mark when it ends the row).
    #expect(OCRController.tail(of: OCRController.rowCores(["ならば相子というものだろう」い、"]),
                               over: OCRController.rowCores(["ならば相子というものだろう」、"]))?.text == "」い")
}
