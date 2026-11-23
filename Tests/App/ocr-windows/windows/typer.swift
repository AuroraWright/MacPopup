// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/typer.swift")" TyperTest
// typer <title>: a 1200x700 window that, 10 s after it opens (once OCR found it), sends a line to mock.py's WebSocket
// server (MOCK_WEBSOCKET, as a text hook would) and types it out a character every 250 ms, as games draw text; quits at
// 45 s. Shown without taking focus at the right of the main screen, with 220 points of it off the edge (its text on
// screen, to be hovered; with part of it off screen, other windows can't count as covering it). Prints each step as
// "<ms since 1970> <step>".
import AppKit
let line = "扉の向こうに、まだ誰も知らない世界が広がっているんだよ。"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
window.backgroundColor = NSColor(white: 0.15, alpha: 1)
let label = NSTextField(labelWithString: "")
label.textColor = .white
label.font = NSFont(name: "Hiragino Sans", size: 30)
label.frame = NSRect(x: 60, y: 120, width: 1100, height: 50)
window.contentView!.addSubview(label)
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 980, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:59881/")!)
    request.httpMethod = "POST"
    request.httpBody = line.data(using: .utf8)
    URLSession.shared.dataTask(with: request).resume()
    log("line sent")
    var shown = 0
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
        shown += 1
        label.stringValue = String(line.prefix(shown))
        if shown == line.count {
            timer.invalidate()
            log("line complete")
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 45) { exit(0) }
app.run()
