import AppKit
import GameController
// Prints GameController's changes for every controller for 5 minutes (as a regular app, so it can be in front).
// Build: swiftc -O -o gc-probe gc-probe.swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
GCController.shouldMonitorBackgroundEvents = true
let start = Date()
var count = 0
func watch(_ c: GCController) {
    print("watching \(c.vendorName ?? "?") micro=\(c.microGamepad != nil) extended=\(c.extendedGamepad != nil)"); fflush(stdout)
    c.physicalInputProfile.valueDidChangeHandler = { profile, element in
        count += 1
        if count <= 40 {
            let pressed = profile.buttons.filter { $0.value.isPressed }.map(\.key).sorted()
            print(String(format: "%.2f", Date().timeIntervalSince(start)), element.localizedName ?? "?", "pressed:", pressed); fflush(stdout)
        }
    }
}
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in (n.object as? GCController).map(watch) }
NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in print("disconnected", (n.object as? GCController)?.vendorName ?? "?") }
for c in GCController.controllers() { watch(c) }
DispatchQueue.main.asyncAfter(deadline: .now() + 300) { print("changes:", count); exit(0) }
app.run()
