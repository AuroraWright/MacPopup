// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/ocr-windows/windows/endmark.swift")" EndMarkTest
// endmark <title> [seconds] [letter]: a 1200x700 window with a short line ("………殺される………", 34 pt) from 3 s on, and right after it
// a "next" icon (48 pt, bold) that OCR reads as a bracket, as a game's was (Screen AI read it as 』 or 」, or not at all): drawn as 』,
// then 」, then nothing, each for 0.45 s, over and over. (Live Text reads only the 」, as a row of its own.) 21 s after the
// line, it's another one ("………生きている………"), the icon going on. With "letter", the icon is read as a letter
// instead, as Screen AI read it on another day (上): drawn as 上, then nothing, each for 0.45 s. Quits after `seconds` (32 by default). Shown without taking focus, all but 8 points of it off the right edge
// of the main screen (still captured, and other windows can't cover it). Prints each step as "<ms since 1970> <step>".
import AppKit
let arguments = CommandLine.arguments
let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 32 : 32
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.title = arguments[1]
window.backgroundColor = NSColor(white: 0.1, alpha: 1)
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
func label(_ text: String, size: CGFloat = 34) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.textColor = .white
    field.font = NSFont(name: "Hiragino Sans W6", size: size) ?? NSFont(name: "Hiragino Sans", size: size)
    field.sizeToFit()
    return field
}
let line = label("………殺される………")
let marks = arguments.count > 3 && arguments[3] == "letter" ? ["上", ""] : ["』", "」", ""]
let mark = label(marks[0], size: 48)
line.isHidden = true
mark.isHidden = true
window.contentView!.addSubview(line)
window.contentView!.addSubview(mark)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 8, y: screen.maxY - 60 - window.frame.height))
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    line.setFrameOrigin(NSPoint(x: 120, y: 330))
    mark.setFrameOrigin(NSPoint(x: line.frame.maxX + 4, y: 322))
    line.isHidden = false
    mark.isHidden = false
    log("line shown")
    var step = 0
    Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
        step += 1
        mark.stringValue = marks[step % marks.count]
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 21) {
        line.stringValue = "………生きている………"
        line.sizeToFit()
        mark.setFrameOrigin(NSPoint(x: line.frame.maxX + 4, y: 322))
        log("line changed")
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
