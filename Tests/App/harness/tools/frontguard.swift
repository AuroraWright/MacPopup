// frontguard: a window of its own made the frontmost app for a test with Game Pause on (launch.sh starts it before the
// instance). Game Pause freezes the frontmost app when the saved OCR window isn't found (GamePause.gameProcesses), which
// would otherwise be the terminal the tests run from. Prints "frontmost" once it is (launch.sh waits for that line), and
// quits when its parent (launch.sh) is gone or on SIGTERM.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled], backing: .buffered,
                      defer: false)
window.title = "MacPopup test: front guard"
let label = NSTextField(labelWithString: "A MacPopup test with Game Pause is running.")
label.frame = NSRect(x: 20, y: 35, width: 320, height: 20)
window.contentView?.addSubview(label)
window.center()
window.makeKeyAndOrderFront(nil)

let parent = getppid()
let own = ProcessInfo.processInfo.processIdentifier
var told = false
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { exit(0) }
term.resume()

var tries = 0
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    if getppid() != parent { exit(0) }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if front == own {
        if !told { told = true; print("frontmost"); fflush(stdout) }
    } else if !told, tries < 20 {
        tries += 1
        app.activate(ignoringOtherApps: true)
    }
}
app.activate(ignoringOtherApps: true)
app.run()
