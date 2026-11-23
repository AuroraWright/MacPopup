// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/floater.swift")" FloatTest
// floater <title>: a 1200x700 window kept on top (the floating window level, as a player's "float on top" or a
// floating panel), with a line of Japanese from 2 s; quits at 30 s. Shown without taking focus, all but 8 points of it
// off the right edge of the main screen (still captured). Prints each step as "<ms since 1970> <step>": "start <its
// window level>", "line".
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
window.level = .floating
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
window.setFrameOrigin(NSPoint(x: screen.maxX - 8, y: screen.maxY - 60 - window.frame.height))
log("start \(window.level.rawValue)")
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    label.stringValue = "今日は朝から雨が降っていて、少し寒い。"
    log("line")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
app.run()
