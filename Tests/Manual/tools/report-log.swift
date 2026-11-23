// report-log.swift: logs a controller's raw HID input reports (opened shared, next to MacPopup or a game) for SECONDS
// (default 45): each report's time, ID, length and bytes, with the bytes that changed since the last report with
// that ID marked. CONTROLLER=<part of its name> picks the controller. Phases are announced on stderr.
// Build: swiftc -O -o report-log report-log.swift
import Foundation
import IOKit.hid

let filter = ProcessInfo.processInfo.environment["CONTROLLER"] ?? ""
let seconds = Double(ProcessInfo.processInfo.environment["SECONDS"] ?? "45") ?? 45
let start = Date()
var last: [UInt8: [UInt8]] = [:]
var counts: [UInt8: Int] = [:]

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(manager, [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
} as CFArray)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
let chosen = devices.filter { filter.isEmpty || (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String ?? "").localizedCaseInsensitiveContains(filter) }
for device in chosen {
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
    let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
    let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 64
    print(String(format: "device %@ %04x:%04x max report %d", name, vendor, product, size))
    let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print(String(format: "open 0x%08x", UInt32(bitPattern: status)))
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 64))
    IOHIDDeviceRegisterInputReportCallback(device, buffer, max(size, 64), { _, _, _, _, reportID, report, length in
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        let full = reportID == 0 ? [0] + bytes : bytes
        let id = full.first ?? 0
        counts[id, default: 0] += 1
        let previous = last[id]
        last[id] = full
        let marked = full.enumerated().map { index, byte in
            let changed = previous.map { index >= $0.count || $0[index] != byte } ?? false
            return String(format: changed ? "[%02x]" : " %02x ", byte)
        }.joined()
        print(String(format: "%7.3f id %d len %d %@", Date().timeIntervalSince(start), id, full.count, marked))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
}
if chosen.isEmpty { print("no controller matching \"\(filter)\" among \(devices.count)"); exit(1) }
setvbuf(stdout, nil, _IOLBF, 0)
FileHandle.standardError.write("logging \(seconds) s\n".data(using: .utf8)!)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
print("counts by report ID: \(counts.sorted { $0.key < $1.key })")
