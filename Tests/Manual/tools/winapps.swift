// winapps: the windows on screen of Windows apps in Parallels' Coherence mode (apps whose bundle ID starts with
// "com.parallels.winapp."), the largest first, one a line: "<pid>\t<owner name>\t<title>\t<width>x<height>".
import AppKit

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var found: [(pid: Int32, owner: String, title: String, width: Int, height: Int)] = []
for window in list {
    guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.hasPrefix("com.parallels.winapp.") == true,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    found.append((pid, window[kCGWindowOwnerName as String] as? String ?? "", window[kCGWindowName as String] as? String ?? "",
                  Int(bounds["Width"] ?? 0), Int(bounds["Height"] ?? 0)))
}
for window in found.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
    print("\(window.pid)\t\(window.owner)\t\(window.title)\t\(window.width)x\(window.height)")
}
