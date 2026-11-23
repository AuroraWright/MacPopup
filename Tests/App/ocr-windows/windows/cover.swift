// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/cover.swift")"
// cover: a game-like window ("CoverTest", 900x300, all but 8 points of it off the right edge of the main screen, still
// captured; shown without taking focus) that shows a line and sends it to mock.py's WebSocket server (MOCK_WEBSOCKET),
// and a window of its own in front of it at times:
//   6 s line A; 12 s covered entirely; 16 s line B; 22 s uncovered; 28 s left half covered; 32 s line C;
//   38 s uncovered; 42 s covered but for a 2% strip; 46 s line D; 52 s uncovered; quits at 60 s.
// MacPopup should read A, C at once, and B and D only once they're uncovered. Prints each step as
// "<ms since 1970> <step>".
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let frame = CGRect(x: screen.maxX - 8, y: screen.maxY - 200 - 300, width: 900, height: 300)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "CoverTest"
window.backgroundColor = NSColor(white: 0.12, alpha: 1)
let line = NSTextField(labelWithString: "")
line.textColor = .white
line.font = NSFont(name: "Hiragino Sans", size: 30)
line.frame = CGRect(x: 40, y: 120, width: 840, height: 50)
window.contentView!.addSubview(line)
window.orderFrontRegardless()
window.setFrameOrigin(frame.origin)
let cover = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
cover.backgroundColor = NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.55, alpha: 1)
func log(_ s: String) { print("\(Int(Date().timeIntervalSince1970 * 1000)) \(s)"); fflush(stdout) }
func show(_ text: String) {
    line.stringValue = text
    log("line \(text)")
    var request = URLRequest(url: URL(string: "http://127.0.0.1:59881/")!)
    request.httpMethod = "POST"
    request.httpBody = text.data(using: .utf8)
    URLSession.shared.dataTask(with: request).resume()
}
func coverWith(_ part: CGRect?, _ name: String) {
    if let part {
        cover.setFrame(CGRect(x: frame.minX + part.minX * frame.width, y: frame.minY + (1 - part.maxY) * frame.height,
                              width: part.width * frame.width, height: part.height * frame.height), display: true)
        cover.orderFrontRegardless()
        cover.setFrameOrigin(CGPoint(x: frame.minX + part.minX * frame.width, y: frame.minY + (1 - part.maxY) * frame.height))
    } else {
        cover.orderOut(nil)
    }
    log("cover \(name)")
}
let events: [(Double, () -> Void)] = [
    (6, { show("扉の向こうに、まだ誰も知らない世界が広がっている。") }),
    (12, { coverWith(CGRect(x: 0, y: 0, width: 1, height: 1), "all") }),
    (16, { show("風が止んだ瞬間、街の灯りが一斉に消えた。") }),
    (22, { coverWith(nil, "none") }),
    (28, { coverWith(CGRect(x: 0, y: 0, width: 0.5, height: 1), "left half") }),
    (32, { show("彼女は黙って古い地図を広げ、指で川をなぞった。") }),
    (38, { coverWith(nil, "none") }),
    (42, { coverWith(CGRect(x: 0, y: 0, width: 1, height: 0.98), "all but 2%") }),
    (46, { show("約束の時間を過ぎても、駅には誰も来なかった。") }),
    (52, { coverWith(nil, "none") }),
    (60, { exit(0) }),
]
log("start")
for (time, action) in events { DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: action) }
app.run()
