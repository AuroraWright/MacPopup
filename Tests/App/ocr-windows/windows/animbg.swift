// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/animbg.swift")" AnimTest
// animbg <title>: a 1600x1000 window like a dialogue box over an animated background: diagonal stripes moving all the
// time over most of it, and a line typed out at 4 s (2 s), then left as it is; quits at 40 s. Shown without taking
// focus, all but 8 points of it off the right edge of the main screen (still captured, and other windows can't cover
// it). Prints each step as "<ms since 1970> <step>".
import AppKit
final class Stripes: NSView {
    var phase: CGFloat = 0
    override func draw(_ rect: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill(); bounds.fill()
        NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.4, alpha: 1).setFill()
        let path = NSBezierPath()
        var x = -1000 + phase.truncatingRemainder(dividingBy: 80)
        while x < 1600 {
            path.move(to: NSPoint(x: x, y: 0)); path.line(to: NSPoint(x: x + 40, y: 0))
            path.line(to: NSPoint(x: x + 1040, y: 1000)); path.line(to: NSPoint(x: x + 1000, y: 1000)); path.close()
            x += 80
        }
        path.fill()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
let stripes = Stripes(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
window.contentView = stripes
let label = NSTextField(labelWithString: "")
label.textColor = .white
label.font = NSFont(name: "Hiragino Sans W6", size: 34)
label.frame = NSRect(x: 120, y: 200, width: 1400, height: 60)
stripes.addSubview(label)
Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in stripes.phase += 6; stripes.needsDisplay = true }
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
let line = Array("扉の向こうに、まだ誰も知らない世界が広がっているんだよ。")
for i in 1...line.count {
    DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i) * 2 / Double(line.count)) {
        label.stringValue = String(line[0..<i])
        if i == 1 { log("typing") }
        if i == line.count { log("shown") }
    }
}
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 8, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { exit(0) }
app.run()
