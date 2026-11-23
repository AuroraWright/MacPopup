// winid <pid> <title>: the window number of the process's window with this title (for screencapture -l), one a line.
import CoreGraphics
let args = CommandLine.arguments
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == Int32(args[1]) && (window[kCGWindowName as String] as? String) == args[2] {
    print(window[kCGWindowNumber as String]!)
}
