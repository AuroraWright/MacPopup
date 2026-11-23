// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/multiwin.swift")"
// multiwin: like a Windows app in Parallels' Coherence mode, several untitled windows, only one of them on screen (a
// 1200x700 one with a line of text); the others (500x500 and 1200x43) are created after it and ordered out, so
// they're listed first. MacPopup should read the one on screen. Quits after 40 s. Shown without taking focus, all but
// 8 points of it off the right edge of the main screen (still captured, and other windows can't cover it). Prints
// each step as "<ms since 1970> <step>".
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.title = ""
window.backgroundColor = NSColor(white: 0.15, alpha: 1)
let line = NSTextField(labelWithString: "扉の向こうに、まだ誰も知らない世界が広がっている。")
line.textColor = .white
line.font = NSFont(name: "Hiragino Sans", size: 30)
line.sizeToFit()
line.setFrameOrigin(NSPoint(x: 60, y: 300))
window.contentView!.addSubview(line)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 8, y: screen.maxY - 60 - window.frame.height))
var hidden: [NSWindow] = []
for size in [NSSize(width: 500, height: 500), NSSize(width: 1200, height: 43)] {
    let other = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    other.orderFront(nil)
    other.orderOut(nil)
    hidden.append(other)
}
print("\(Int(Date().timeIntervalSince1970 * 1000)) start")
fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { exit(0) }
app.run()
