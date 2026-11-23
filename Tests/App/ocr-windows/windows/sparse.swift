// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/sparse.swift")" SparseTest
// sparse <title>: a black 1600x1000 window like a visual novel's chapter screen: "第1章" small at the top left from 4 s,
// nothing from 25 s, then from 28 s a short line in the middle (white, 17 pt: the share of the window CHAOS;HEAD NOAH's
// line has); quits at 40 s. Shown without taking focus, all but 8 points of it off the right edge of the main screen
// (still captured, and other windows can't cover it). Prints each step as "<ms since 1970> <step>".
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
window.backgroundColor = .black
let label = NSTextField(labelWithString: "")
label.textColor = .white
label.font = NSFont(name: "Hiragino Sans", size: 17)
window.contentView!.addSubview(label)
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
func show(_ text: String, center: Bool) {
    label.stringValue = text
    label.sizeToFit()
    label.setFrameOrigin(center ? NSPoint(x: (1600 - label.frame.width) / 2, y: 500) : NSPoint(x: 60, y: 900))
    log("shown \"\(text)\"")
}
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 8, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 4) { show("第1章", center: false) }
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { show("", center: false) }
DispatchQueue.main.asyncAfter(deadline: .now() + 28) { show("“視線”は見えない。", center: true) }
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { exit(0) }
app.run()
