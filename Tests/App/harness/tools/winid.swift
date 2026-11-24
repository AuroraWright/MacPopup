// winid <pid> <title>: the window number of the process's window with this title (for screencapture -l), one a line:
// those on screen first (an app may have hidden windows with the same title).
import CoreGraphics
let args = CommandLine.arguments
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let list = all.filter { $0[kCGWindowIsOnscreen as String] as? Bool == true } + all.filter { $0[kCGWindowIsOnscreen as String] as? Bool != true }
for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == Int32(args[1]) && (window[kCGWindowName as String] as? String) == args[2] {
    print(window[kCGWindowNumber as String]!)
}
