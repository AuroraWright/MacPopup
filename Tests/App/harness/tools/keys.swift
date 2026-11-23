// keys <pid>[,<pid>…] <step>: one key press for interactive tests' drivers (tests with "// interactive"), sent only while
// one of these processes is the frontmost app and none of their menus is open (a menu would take the key: Return would
// pick its item). Steps: return, escape, backspace, end (⌃⇥, which moves the focus on and so ends a text's editing),
// textend (⌘↓, to the text's end), type:<text> (typed as one key press, as a paste puts text in; \r and \n in it are
// line breaks). Prints "ok", or why nothing was sent and exits with 1. One step a run, so the frontmost app is checked
// afresh each time. Drivers build it with tools/build.sh.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: keys <pid>[,<pid>…] return|escape|backspace|end|textend|type:<text>")
    exit(2)
}
let pids = Set(args[1].split(separator: ",").compactMap { Int32($0) })
let step = args[2]

guard let front = NSWorkspace.shared.frontmostApplication, pids.contains(front.processIdentifier) else {
    print("refused: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing") (\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)) is in front")
    exit(1)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
// Menus (the menu bar's and context menus) are on the pop-up menu level.
if windows.contains(where: { pids.contains($0[kCGWindowOwnerPID as String] as? Int32 ?? 0)
    && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)) }) {
    print("refused: a menu is open")
    exit(1)
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], _ text: String? = nil) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.flags = flags
        if let text { event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
        event.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

switch step {
case "return": key(36)
case "escape": key(53)
case "backspace": key(51)
case "end": key(48, .maskControl)
case "textend": key(125, .maskCommand)
default:
    guard step.hasPrefix("type:") else {
        print("unknown step \(step)")
        exit(2)
    }
    let text = step.dropFirst(5).replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\n", with: "\n")
    key(0, [], text)
}
print("ok")
