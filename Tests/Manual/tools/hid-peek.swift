import Foundation
import IOKit.hid
// Reads (without seizing) a Nintendo controller's input reports for 3 seconds and counts them by report ID.
// Build: swiftc -O -o hid-peek hid-peek.swift
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x057e] as CFDictionary)
var counts: [UInt8: Int] = [:]
var sample: [UInt8: [UInt8]] = [:]
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    print("device:", name)
    IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, { _, _, _, _, id, report, length in
        counts[UInt8(id), default: 0] += 1
        sample[UInt8(id)] = Array(UnsafeBufferPointer(start: report, count: min(length, 14))); if counts[UInt8(id)]! <= 12 { print(String(format: "0x%02x len %d:", id, length), Array(UnsafeBufferPointer(start: report, count: min(length, 14))).map { String(format: "%02x", $0) }.joined(separator: " ")); fflush(stdout) }
    }, nil)
}, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
print("open:", IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    for (id, n) in counts.sorted(by: { $0.key < $1.key }) { print(String(format: "report 0x%02x: %d in 60 s, e.g.", id, n), sample[id]!.map { String(format: "%02x", $0) }.joined(separator: " ")) }
    if counts.isEmpty { print("no reports") }
    exit(0)
}
RunLoop.main.run()
