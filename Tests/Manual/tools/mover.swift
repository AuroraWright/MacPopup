// mover <title>: a 1200x700 window with a line of Japanese from 2 s on, moved 150 points left at 16 s (the same text,
// somewhere else on screen); quits at 40 s. Shown without taking focus at the right of the main screen, with 300 points
// of it off the edge before the move (still captured; with part of it off screen, other windows can't count as covering
// it). Prints each step as "<ms since 1970> <step>": "start", "line", "moved <x>,<y>" (its new origin).
import AppKit

let line = "今日は朝から雨が降っていて、少し寒い。"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
window.backgroundColor = NSColor(white: 0.15, alpha: 1)
let label = NSTextField(labelWithString: "")
label.textColor = .white
label.font = NSFont(name: "Hiragino Sans", size: 34)
label.frame = NSRect(x: 60, y: 300, width: 1100, height: 60)
window.contentView!.addSubview(label)
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 900, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    label.stringValue = line
    log("line")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
    let origin = NSPoint(x: window.frame.minX - 150, y: window.frame.minY)
    window.setFrameOrigin(origin)
    log("moved \(Int(origin.x)),\(Int(origin.y))")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { exit(0) }
app.run()
