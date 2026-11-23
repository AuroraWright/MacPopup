// plainwin <title> <x> <y>: a plain 500×400 test window (AppKit's coordinates, from the bottom left) in an app of its own
// that comes to the front when it starts. Logs "<ms since 1970> started <title> pid <pid>" and each key it gets
// ("<ms> <title> got key <code>"), for the picker and controller tests (beside.log, see test-lib's windowSteps).
import AppKit

func say(_ text: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(text)")
    fflush(stdout)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let args = CommandLine.arguments
let window = NSWindow(contentRect: NSRect(x: Double(args[2])!, y: Double(args[3])!, width: 500, height: 400), styleMask: [.titled],
                      backing: .buffered, defer: false)
window.title = args[1]
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    say("\(args[1]) got key \(event.keyCode)")
    return event
}
say("started \(args[1]) pid \(getpid())")
app.run()
