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
