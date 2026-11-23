// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/blinker.swift")" BlinkTest 40 0.5 blink
// blinker <title> <gap> [interval] [kind]: a 1200x700 window with a line from 3 s on and a "next" icon `gap` points
// after it: "blink" (▼ shown and hidden every `interval` seconds, 0.5 by default), "spin" (a circle's arc turning once
// a second), "fade" (a square fading out and in every 1.2 s) or "noise" (random gray cells, drawn anew 60 times a
// second: more looks than can be remembered). At 12 s the icon goes and the line gets longer, over where it was. 20 s
// in all. Shown without taking focus, all but 8 points of it off the right edge of the main screen (still captured,
// and other windows can't cover it). Prints each step as "<ms since 1970> <step>".
// BLINKER_REPLACE=1: at 12 s the icon goes and one character is drawn where it was instead (the line stays), so only the
// icon's spot changes.
import AppKit
let arguments = CommandLine.arguments
let gap = CGFloat(Double(arguments[2]) ?? 40)
let interval = arguments.count > 3 ? Double(arguments[3]) ?? 0.5 : 0.5
let kind = arguments.count > 4 ? arguments[4] : "blink"
final class Icon: NSView {
    var phase = 0.0
    override func draw(_ rect: NSRect) {
        NSColor.white.setStroke()
        NSColor.white.setFill()
        switch kind {
        case "spin":
            let path = NSBezierPath()
            let start = CGFloat(phase * 360)
            path.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: 11, startAngle: start, endAngle: start + 270)
            path.lineWidth = 4
            path.stroke()
        case "fade":
            NSColor(white: 1, alpha: 0.5 + 0.5 * cos(phase / 1.2 * 2 * .pi)).setFill()
            NSRect(x: 4, y: 4, width: 22, height: 22).fill()
        case "noise":
            for row in 0..<6 {
                for column in 0..<5 {
                    NSColor(white: .random(in: 0...1), alpha: 1).setFill()
                    NSRect(x: CGFloat(column) * 6, y: CGFloat(row) * 5 + 2, width: 6, height: 5).fill()
                }
            }
        default:
            let label = "▼" as NSString
            label.draw(at: NSPoint(x: 0, y: 0), withAttributes: [.font: NSFont(name: "Hiragino Sans", size: 26)!, .foregroundColor: NSColor.white])
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.title = arguments[1]
window.backgroundColor = NSColor(white: 0.15, alpha: 1)
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
let line = NSTextField(labelWithString: "")
line.textColor = .white
line.font = NSFont(name: "Hiragino Sans", size: 30)
let icon = Icon(frame: NSRect(x: 0, y: 0, width: 30, height: 34))
icon.isHidden = true
window.contentView!.addSubview(line)
window.contentView!.addSubview(icon)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 8, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    line.stringValue = "扉の向こうに、まだ誰も知らない世界が広がっている。"
    line.sizeToFit()
    line.setFrameOrigin(NSPoint(x: 60, y: 300))
    icon.setFrameOrigin(NSPoint(x: line.frame.maxX + gap, y: 302))
    icon.isHidden = false
    log("line shown, icon \(kind)")
    let start = Date()
    if kind == "blink" {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in icon.isHidden.toggle() }
    } else {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            icon.phase = Date().timeIntervalSince(start)
            icon.needsDisplay = true
        }
    }
}
let env = ProcessInfo.processInfo.environment
DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
    icon.removeFromSuperview()
    if env["BLINKER_REPLACE"] == "1" {
        let word = NSTextField(labelWithString: "終")
        word.textColor = .white
        word.font = NSFont(name: "Hiragino Sans", size: 30)
        word.sizeToFit()
        word.setFrameOrigin(NSPoint(x: icon.frame.minX, y: 300))
        window.contentView!.addSubview(word)
        log("character where the icon was")
        return
    }
    line.stringValue = "扉の向こうに、まだ誰も知らない世界が広がっている。それでも"
    line.sizeToFit()
    log("line longer")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
app.run()
