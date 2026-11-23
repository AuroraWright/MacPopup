// shotview <title>: a 600x300 window with one line of Japanese, for screenshots and popups (after
// scratch-tools/harness/shotviewer). Shown without taking focus at the right of the main screen, 100 points of it off
// the edge (its text on screen, to be hovered; other windows can't count as covering it). Prints its steps as
// "<ms since 1970> <step>": "shown <width>x<height> scale <backing scale>" (its frame in points, title bar included);
// quits after 60 s.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
let label = NSTextField(labelWithString: "上から見ると手の中に生き物が出た。")
label.font = NSFont(name: "Hiragino Sans", size: 32)
label.frame = NSRect(x: 30, y: 120, width: 560, height: 60)
window.contentView!.addSubview(label)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 500, y: screen.maxY - 60 - window.frame.height))
let size = window.frame.size
print("\(Int(Date().timeIntervalSince1970 * 1000)) shown \(Int(size.width))x\(Int(size.height)) scale \(window.backingScaleFactor)")
fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
app.run()
