// gc-list: prints every controller GameController knows (vendor, category, profiles) and its buttons, axes and
// D-pads. Build: swiftc -O -o gc-list gc-list.swift
import Foundation
import GameController
GCController.shouldMonitorBackgroundEvents = true
func show() {
    for c in GCController.controllers() {
        let p = c.physicalInputProfile
        print("vendorName=\(c.vendorName ?? "nil") productCategory=\(c.productCategory) extended=\(c.extendedGamepad != nil) micro=\(c.microGamepad != nil)")
        print("  buttons:", p.buttons.keys.sorted().joined(separator: ", "))
        print("  dpads:", p.dpads.keys.sorted().joined(separator: ", "))
    }
}
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in print("connected:", (n.object as? GCController)?.vendorName ?? "?") }
DispatchQueue.main.asyncAfter(deadline: .now() + 3) { show(); exit(0) }
RunLoop.main.run()
