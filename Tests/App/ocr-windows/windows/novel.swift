// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/novel.swift")"
// novel: a visual novel's page for "Read text from OCR" ("NovelTest", borderless, 1000x560, all but 8 points of it off
// the right edge of the main screen, still captured; shown without taking focus). Text is typed a character every
// 80 ms; lines marked "ws" are also sent to mock.py's WebSocket server (MOCK_WEBSOCKET, as a text hook), "ws late"
// 2.5 s after they're shown. Prints each step as "<ms since 1970> <step>".
//   1 s  a page at once, wrapped       この街に来てから…  (a wrapped row: how far rows reach); cleared at 3.5 s
//   4 s  paragraph 1, typed            「おはよう。今日は早いね。」
//   8 s  paragraph 2, typed            「うん、ちょっと用事があって……」          (ends without a sentence end)
//  13 s  paragraph 3, typed            そう言って彼女は笑った。
//  18 s  paragraph 4, typed with a 3 s pause after それから、
//  27 s  a new page, at once           風が強い。 / 空が暗い。                  (two paragraphs at once: one line)
//  33 s  a new page, at once, ws       扉の向こうに、まだ誰も知らない世界が広がっている。
//  39 s  a new page, at once           これはフックされない行です。
//  45 s  a new page, at once, ws late  遅れて届く行がここにある。
//  53 s  covered by a window of its own; 55 s a new page, at once: 隠れていても読める行。; 61 s uncovered
//  66 s  quits
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let frame = CGRect(x: screen.maxX - 8, y: screen.maxY - 150 - 560, width: 1000, height: 560)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "NovelTest"
window.backgroundColor = NSColor(white: 0.1, alpha: 1)
let text = NSTextField(wrappingLabelWithString: "")
text.textColor = .white
text.font = NSFont(name: "Hiragino Sans", size: 30)
text.frame = CGRect(x: 40, y: 40, width: 920, height: 480)
let style = NSMutableParagraphStyle()
style.paragraphSpacing = 6
window.contentView!.addSubview(text)
window.orderFrontRegardless()
window.setFrameOrigin(frame.origin)
let cover = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
cover.backgroundColor = .darkGray

func log(_ s: String) { print("\(Int(Date().timeIntervalSince1970 * 1000)) \(s)"); fflush(stdout) }
var page = ""
func show(_ s: String) {
    page = s
    text.attributedStringValue = NSAttributedString(string: s, attributes: [.font: text.font!, .foregroundColor: NSColor.white, .paragraphStyle: style])
}
func send(_ line: String) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:59881/")!)
    request.httpMethod = "POST"
    request.httpBody = line.data(using: .utf8)
    URLSession.shared.dataTask(with: request).resume()
    log("ws \(line)")
}
/// Types `s` after what's on the page, a character every 80 ms, from `at` s; returns when it's done.
@discardableResult func type(_ s: String, at: Double, newParagraph: Bool) -> Double {
    DispatchQueue.main.asyncAfter(deadline: start + at) { log("typing \(s)"); if newParagraph, !page.isEmpty { show(page + "\n") } }
    for (i, c) in s.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: start + at + Double(i + 1) * 0.08) { show(page + String(c)) }
    }
    return at + Double(s.count) * 0.08
}
func at(_ time: Double, _ action: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: start + time, execute: action) }
let start = DispatchTime.now()
log("start")
at(1) { show("この街に来てから、もう三年が経った。毎朝同じ道を歩き、同じ店でパンを買い、同じ時間に家を出る。"); log("page この街に来てから…") }
at(3.5) { show(""); log("cleared") }
type("「おはよう。今日は早いね。」", at: 4, newParagraph: true)
type("「うん、ちょっと用事があって……」", at: 8, newParagraph: true)
type("そう言って彼女は笑った。", at: 13, newParagraph: true)
type("それから、", at: 18, newParagraph: true)
type("駅へ向かった。", at: 18 + 0.4 + 3, newParagraph: false)
at(27) { show("風が強い。\n空が暗い。"); log("page 風が強い。/空が暗い。") }
at(33) { show("扉の向こうに、まだ誰も知らない世界が広がっている。"); send("扉の向こうに、まだ誰も知らない世界が広がっている。") }
at(39) { show("これはフックされない行です。"); log("page これはフックされない行です。") }
at(45) { show("遅れて届く行がここにある。"); log("page 遅れて届く行がここにある。") }
at(47.5) { send("遅れて届く行がここにある。") }
at(53) { cover.setFrame(frame.insetBy(dx: -4, dy: -4), display: true); cover.orderFrontRegardless(); cover.setFrameOrigin(frame.insetBy(dx: -4, dy: -4).origin); log("covered") }
at(55) { show("隠れていても読める行。"); log("page 隠れていても読める行。") }
at(61) { cover.orderOut(nil); log("uncovered") }
at(66) { exit(0) }
app.run()
