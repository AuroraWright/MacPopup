// slanted <title>: a borderless 900x450 window with dialogue set at an angle, as Danganronpa's: 「鋭利な刃物に」 turned 8°,
// 「よるものですぅ…」 under it turned 15° and starting further right, and 「はい、そうです」 turned −25° lower left. Shown
// without taking focus at the right of the main screen, 100 points of it off the edge (as shotview). Prints its steps
// as "<ms since 1970> <step>": "shown <width>x<height>", then "glyph <character> <x> <y>" for each character's middle
// (window points from its top left); quits after 90 s.
import AppKit

struct Row {
    let text: String
    let size: CGFloat
    /// Where its first character's top left is, in window points from the window's top left.
    let start: CGPoint
    let degrees: CGFloat
}

let rows = [
    Row(text: "鋭利な刃物に", size: 44, start: CGPoint(x: 60, y: 90), degrees: 8),
    Row(text: "よるものですぅ…", size: 44, start: CGPoint(x: 230, y: 175), degrees: 15),
    Row(text: "はい、そうです", size: 44, start: CGPoint(x: 20, y: 400), degrees: -25),
]

/// Each character's middle in the window: drawn one full-width cell after another along the row.
func glyphs(_ row: Row) -> [(text: String, middle: CGPoint)] {
    let angle = row.degrees * .pi / 180
    return row.text.map(String.init).enumerated().map { index, text in
        let (x, y) = ((CGFloat(index) + 0.5) * row.size, row.size / 2)
        return (text, CGPoint(x: row.start.x + x * cos(angle) - y * sin(angle), y: row.start.y + x * sin(angle) + y * cos(angle)))
    }
}

final class Slanted: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for row in rows {
            let font = NSFont(name: "HiraginoSans-W6", size: row.size) ?? .systemFont(ofSize: row.size)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: row.start.x, yBy: row.start.y)
            transform.rotate(byDegrees: row.degrees)
            transform.concat()
            for (index, character) in row.text.map(String.init).enumerated() {
                let string = NSAttributedString(string: character, attributes: attributes)
                // Centered in its cell, as the middles printed are.
                let size = string.size()
                string.draw(at: CGPoint(x: (CGFloat(index) + 0.5) * row.size - size.width / 2, y: row.size / 2 - size.height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
window.title = CommandLine.arguments[1]
window.contentView = Slanted(frame: NSRect(x: 0, y: 0, width: 900, height: 450))
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 800, y: screen.maxY - 60 - window.frame.height))
let now = { Int(Date().timeIntervalSince1970 * 1000) }
print("\(now()) shown \(Int(window.frame.width))x\(Int(window.frame.height))")
for row in rows {
    for glyph in glyphs(row) { print("\(now()) glyph \(glyph.text) \(Int(glyph.middle.x)) \(Int(glyph.middle.y))") }
}
fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { exit(0) }
app.run()
