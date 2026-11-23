// wins [<pid>…]: the on-screen windows (of those processes, or all), front to back, one a line: pid, layer, x, y,
// width, height (global points, top left origin) and title, tab-separated. Reads only; for drivers (tools/build.sh).
import CoreGraphics
let pids = Set(CommandLine.arguments.dropFirst().compactMap { Int32($0) })
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
    guard pids.isEmpty || pids.contains(pid) else { continue }
    let b = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) ?? .null
    print([pid, w[kCGWindowLayer as String] as? Int ?? 0, Int(b.minX), Int(b.minY), Int(b.width), Int(b.height)].map { "\($0)" }
        .joined(separator: "\t") + "\t" + (w[kCGWindowName as String] as? String ?? ""))
}
