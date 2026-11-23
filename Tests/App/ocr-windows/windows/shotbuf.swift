// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/shotbuf.swift")" ShotTest
// shotbuf <title>: a 1200x700 window for Anki Screenshot's kept screenshots. At 3 s a line is shown on a blue
// background; at 9 s the background turns red and the line moves 4 points right (the same text read again, as when a
// game moves on behind it). A card made after that should still get the blue screenshot. 25 s in all. Shown without
// taking focus at the right of the main screen, with 220 points of it off the edge (its text on screen, to be hovered;
// with part of it off screen, other windows can't count as covering it). Prints each step as "<ms since 1970> <step>".
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
window.backgroundColor = NSColor(white: 0.15, alpha: 1)
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
let line = NSTextField(labelWithString: "")
line.textColor = .white
line.font = NSFont(name: "Hiragino Sans", size: 30)
window.contentView!.addSubview(line)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 980, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    window.backgroundColor = NSColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)
    line.stringValue = "明日も晴れるといいね、まだ誰も知らない世界が広がっている。"
    line.sizeToFit()
    line.setFrameOrigin(NSPoint(x: 60, y: 300))
    log("line shown, blue")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
    window.backgroundColor = NSColor(red: 0.7, green: 0.1, blue: 0.1, alpha: 1)
    line.setFrameOrigin(NSPoint(x: 64, y: 300))
    log("red, line moved")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
app.run()
