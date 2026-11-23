// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/vanish.swift")" VanishTest
// vanish <title>: a 1200x700 window with text that never settles. At 6 s a line is typed at 70 ms a character and
// cleared 0.15 s after it's complete; at 12 s a line scrolls through a 600-point box (it's wider, so it's never all
// in it) for 6 s, then it's gone; quits at 22 s. Shown without taking focus at the right of the main screen, with 280
// points of it off the edge (its box on screen, to be hovered; with part of it off screen, other windows can't count
// as covering it). Prints each step as "<ms since 1970> <step>".
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
func makeLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.textColor = .white
    label.font = NSFont(name: "Hiragino Sans", size: 30)
    return label
}
let typed = makeLabel()
typed.frame = NSRect(x: 60, y: 520, width: 1100, height: 50)
window.contentView!.addSubview(typed)
let box = NSView(frame: NSRect(x: 300, y: 200, width: 600, height: 60))
box.wantsLayer = true
box.layer!.masksToBounds = true
window.contentView!.addSubview(box)
let ticker = makeLabel()
ticker.stringValue = "遠くで鐘が鳴っている。誰かが呼んでいるような気がした。"
ticker.sizeToFit()
ticker.setFrameOrigin(NSPoint(x: 600, y: 8))
box.addSubview(ticker)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 920, y: screen.maxY - 60 - window.frame.height))
log("start")
let line = Array("扉の向こうに、まだ誰も知らない世界が広がっている。")
DispatchQueue.main.asyncAfter(deadline: .now() + 6) { log("typed start") }
for i in 1...line.count {
    DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(i) * 0.07) { typed.stringValue = String(line[0..<i]) }
}
let typedEnd = 6 + Double(line.count) * 0.07
DispatchQueue.main.asyncAfter(deadline: .now() + typedEnd + 0.15) {
    typed.stringValue = ""
    log("typed cleared")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
    log("ticker start")
    let start = Date(), distance = 600 + ticker.frame.width
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
        let t = Date().timeIntervalSince(start)
        guard t < 6 else {
            timer.invalidate()
            ticker.isHidden = true
            log("ticker gone")
            return
        }
        ticker.setFrameOrigin(NSPoint(x: 600 - distance * t / 6, y: 8))
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 22) { exit(0) }
app.run()
