// winnum <pid>: the window numbers of the process's on-screen windows (for screencapture -l) with their size, largest first, one
// a line: number, width, height (points). Reads only; for drivers (tools/build.sh).
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { w -> (Int, CGRect) in
    (w[kCGWindowNumber as String] as! Int, CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) ?? .null)
}
for (number, bounds) in mine.sorted(by: { $0.1.width * $0.1.height > $1.1.width * $1.1.height }) {
    print(number, Int(bounds.width), Int(bounds.height))
}
