// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/fader.swift")" FaderTest 1.5 3
// fader <title> <fade seconds> <cell points>: a 1600x1000 window, dark gray with a darker band, that shows a line at 12 s, dissolves it
// over the given time from 20 s (cells of the given size cleared in random order every 50 ms, as games' transitions do), shows
// another line in the same place at 25 s, and exits at 40 s. Shown without taking focus, all but 8 points of it off the
// right edge of the main screen (still captured, and other windows can't cover it). Prints each step as
// "<ms since 1970> <step>".
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
let fade = Double(CommandLine.arguments[2])!
window.backgroundColor = NSColor(white: 0.2, alpha: 1)
let band = NSView(frame: NSRect(x: 0, y: 120, width: 1600, height: 260))
band.wantsLayer = true
band.layer!.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
window.contentView!.addSubview(band)
final class Line: NSView {
    var text = "" { didSet { cleared = 0; needsDisplay = true } }
    var cleared = 0 { didSet { needsDisplay = true } }
    let cell: CGFloat = CGFloat(Double(CommandLine.arguments[3])!)
    lazy var cells: [Int] = Array(0..<(Int(bounds.width / cell) * Int(bounds.height / cell))).shuffled()
    override func draw(_ dirty: NSRect) {
        (text as NSString).draw(at: NSPoint(x: 0, y: 4), withAttributes: [.font: NSFont(name: "Hiragino Sans", size: 40)!, .foregroundColor: NSColor.white])
        NSColor(white: 0.08, alpha: 1).setFill()
        let columns = Int(bounds.width / cell)
        for index in cells.prefix(cleared) {
            NSRect(x: CGFloat(index % columns) * cell, y: CGFloat(index / columns) * cell, width: cell, height: cell).fill()
        }
    }
}
let label = Line(frame: NSRect(x: 100, y: 250, width: 1400, height: 66))
window.contentView!.addSubview(label)
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 8, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
    label.text = "というわけで、こんな街は即刻滅ぶべきだね。"
    log("first line")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    log("fading")
    let steps = max(Int(fade / 0.05), 1)
    var step = 0
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
        step += 1
        label.cleared = label.cells.count * step / steps
        if step == steps {
            timer.invalidate()
            label.text = ""
            log("faded")
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
    label.text = "でもこの部屋の住み心地はまあまあ我慢できる。"
    log("second line")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { exit(0) }
app.run()
