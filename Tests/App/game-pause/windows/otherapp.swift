// otherapp <seconds open>: another app coming to the front, as when you switch away from the game: a small window
// "OtherApp" that makes itself the active app (taking the focus from whatever app has it), then quits after the seconds
// open (the focus then goes back). Shown at the right of the main screen, most of it off the edge. Prints
// "<ms since 1970> active" once it's the frontmost app.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "OtherApp"
window.makeKeyAndOrderFront(nil)
window.setFrameOrigin(NSPoint(x: screen.maxX - 60, y: screen.maxY - 300))
app.activate(ignoringOtherApps: true)
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
        print("\(Int(Date().timeIntervalSince1970 * 1000)) active")
        fflush(stdout)
        timer.invalidate()
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + Double(CommandLine.arguments[1])!) { exit(0) }
app.run()
