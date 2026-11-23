// prompt [title]: a small window at the top of the main screen telling the person at the Mac what to do in a manual
// test: each line read from stdin replaces its text, and it closes at the end of stdin or when its parent is gone. It's a
// non-activating panel, so it never takes the keyboard or the front from the app being tested.
import AppKit

let app = NSApplication.shared
// Prohibited, not accessory: an accessory app is still made the active app when it starts, and the app being tested
// takes that as a switch to another app (the controller is let go, see Gamepads.swift).
app.setActivationPolicy(.prohibited)

let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let size = NSSize(width: 640, height: 110)
let panel = NSPanel(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12,
                                        width: size.width, height: size.height),
                    styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
panel.title = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MacPopup manual test"
panel.level = .floating
panel.hidesOnDeactivate = false
panel.becomesKeyOnlyIfNeeded = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

let label = NSTextField(wrappingLabelWithString: "")
label.font = .systemFont(ofSize: 17, weight: .medium)
label.frame = panel.contentView!.bounds.insetBy(dx: 16, dy: 12)
label.autoresizingMask = [.width, .height]
panel.contentView!.addSubview(label)
panel.orderFrontRegardless()

DispatchQueue.global().async {
    while let line = readLine() {
        DispatchQueue.main.async {
            label.stringValue = line
            panel.orderFrontRegardless()
        }
    }
    DispatchQueue.main.async { exit(0) }
}
let parent = getppid()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    if getppid() != parent { exit(0) }
}
app.run()
