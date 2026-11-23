// gc-watch: GameController's changes on every controller, seen from the background as a game in front would see them,
// printed as "<ms since 1970> <control>" (and "<ms> connected <name>"), until stdin ends or its parent is gone. While
// MacPopup holds a controller (it opens it seized), there should be none. Its activation is prohibited, so it never
// becomes the active app: the app being tested would take that as a switch to another app and let the controller go.
import AppKit
import GameController

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
GCController.shouldMonitorBackgroundEvents = true

func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}

func watch(_ controller: GCController) {
    log("connected \(controller.vendorName ?? "?")")
    controller.physicalInputProfile.valueDidChangeHandler = { _, element in log(element.localizedName ?? "?") }
}
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
    (note.object as? GCController).map(watch)
}
GCController.controllers().forEach(watch)

DispatchQueue.global().async {
    while readLine() != nil {}
    DispatchQueue.main.async { exit(0) }
}
let parent = getppid()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    if getppid() != parent { exit(0) }
}
app.run()
