// ax <pid> <command> …: reads and presses a test instance's controls through Accessibility, without moving the pointer,
// typing or bringing a window forward. Drivers build it with tools/build.sh.
//   windows                          the windows' titles, one a line
//   list [window title]              the controls, one a line, tab-separated: role, help, title, description,
//                                    placeholder, value, enabled (1 or 0), window title
//   press <role> <text> <n>          presses the nth control of that role whose help, title, description, placeholder or
//                                    value is <text> (n from 1)
//   set <role> <text> <n> <value>    focuses that text field, sets its value and confirms it (as Return does)
//   type <role> <text> <n> <value>   the same without confirming: the field stays focused, still being edited
//   focus <role> <text> <n>          focuses it (which ends the editing of another field)
//   frame <role> <text> <n>          its frame (x y w h, global points from the top left), then its parent's (e.g. a
//                                    text area's scroll view) on a second line
//   frames [window title]            the windows and texts (AXStaticText), one a line, tab-separated: role, title or
//                                    value, frame (x y w h)
//   focused                          the title of the app's focused window (its key window)
//   selected <description>           the texts of the selected rows of the table with that description (e.g. the Fonts
//                                    panel's "typeface list"), one a line
//   scroll <text> <0-1>              scrolls the scroll area holding the first control showing <text> (0 top, 1 bottom)
//   close <window title>             presses that window's close button
// <text> "*" matches any control of that role.
// Prints "ok" or what went wrong, and exits with 1 on a failure. Needs the Accessibility permission of the app it's run
// from (e.g. the terminal).
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    print("usage: ax <pid> windows|list|press|set|type|focus …")
    exit(2)
}
guard AXIsProcessTrusted() else {
    print("ax: no Accessibility permission")
    exit(1)
}
let command = args[2]
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String { (attribute(element, name) as? String) ?? "" }

func texts(_ element: AXUIElement) -> [String] {
    [kAXHelpAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXValueAttribute].map { string(element, $0) }
}

/// Every element of the app's windows, in order, with its window's title.
var all: [(element: AXUIElement, window: String)] = []
func walk(_ element: AXUIElement, window: String, depth: Int) {
    guard depth < 60 else { return }
    all.append((element, window))
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        walk(child, window: window, depth: depth + 1)
    }
}
let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
for window in windows {
    walk(window, window: string(window, kAXTitleAttribute), depth: 0)
}

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

func find(_ role: String, _ text: String, _ n: Int) -> AXUIElement {
    let matches = all.filter { string($0.element, kAXRoleAttribute) == role && (text == "*" || texts($0.element).contains(text)) }
    guard n >= 1, n <= matches.count else { fail("only \(matches.count) \(role) \"\(text)\"") }
    return matches[n - 1].element
}

func focus(_ element: AXUIElement) {
    let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard result == .success else { fail("focus failed (\(result.rawValue))") }
}

func setValue(_ element: AXUIElement, _ value: String) {
    let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    guard result == .success else { fail("setting the value failed (\(result.rawValue))") }
}

func oneLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
}

/// An element's frame: "x y w h" in global points from the top left, or "none".
func frame(_ element: AXUIElement) -> String {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute),
          AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size)
    else { return "none" }
    return "\(origin.x) \(origin.y) \(size.width) \(size.height)"
}

switch command {
case "windows":
    for window in windows { print(string(window, kAXTitleAttribute)) }
case "list":
    let roles: Set = [
        "AXButton", "AXCheckBox", "AXPopUpButton", "AXTextField", "AXIncrementor", "AXMenuItem", "AXStaticText", "AXRadioButton",
        "AXTextArea", "AXSwitch",
    ]
    for (element, window) in all where args.count < 4 || window == args[3] {
        let role = string(element, kAXRoleAttribute)
        guard roles.contains(role) else { continue }
        var fields = texts(element).dropLast().map(oneLine)
        fields.append(attribute(element, kAXValueAttribute).map { oneLine("\($0)") } ?? "")
        let enabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true
        print(([role] + fields + [enabled ? "1" : "0", window]).joined(separator: "\t"))
    }
case "frames":
    for (element, window) in all where args.count < 4 || window == args[3] {
        let role = string(element, kAXRoleAttribute)
        guard role == "AXStaticText" || role == "AXWindow" else { continue }
        print([role, oneLine(role == "AXWindow" ? string(element, kAXTitleAttribute) : string(element, kAXValueAttribute)), frame(element)]
            .joined(separator: "\t"))
    }
case "press":
    guard args.count >= 6, let n = Int(args[5]) else { fail("usage: press <role> <text> <n>") }
    let result = AXUIElementPerformAction(find(args[3], args[4], n), kAXPressAction as CFString)
    guard result == .success else { fail("press failed (\(result.rawValue))") }
    print("ok")
case "set", "type":
    guard args.count >= 7, let n = Int(args[5]) else { fail("usage: \(command) <role> <text> <n> <value>") }
    let element = find(args[3], args[4], n)
    focus(element)
    setValue(element, args[6])
    if command == "set" {
        let result = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
        guard result == .success else { fail("confirm failed (\(result.rawValue))") }
    }
    print("ok")
case "focus":
    guard args.count >= 6, let n = Int(args[5]) else { fail("usage: focus <role> <text> <n>") }
    focus(find(args[3], args[4], n))
    print("ok")
case "frame":
    guard args.count >= 6, let n = Int(args[5]) else { fail("usage: frame <role> <text> <n>") }
    let element = find(args[3], args[4], n)
    print(frame(element))
    print(attribute(element, kAXParentAttribute).map { frame($0 as! AXUIElement) } ?? "none")
case "focused":
    guard let window = attribute(app, kAXFocusedWindowAttribute) else { fail("no focused window") }
    print(string(window as! AXUIElement, kAXTitleAttribute))
case "selected":
    guard args.count >= 4 else { fail("usage: selected <description>") }
    guard let table = all.first(where: { string($0.element, kAXDescriptionAttribute) == args[3] })?.element else {
        fail("no table \"\(args[3])\"")
    }
    for row in attribute(table, kAXSelectedRowsAttribute) as? [AXUIElement] ?? [] {
        let cells = attribute(row, kAXChildrenAttribute) as? [AXUIElement] ?? []
        print(cells.map { oneLine(string($0, kAXValueAttribute)) }.joined(separator: "\t"))
    }
case "scroll":
    guard args.count >= 5, let position = Double(args[4]) else { fail("usage: scroll <text> <0-1>") }
    guard var element = all.first(where: { texts($0.element).contains(args[3]) })?.element else { fail("no \"\(args[3])\"") }
    while string(element, kAXRoleAttribute) != "AXScrollArea", let parent = attribute(element, kAXParentAttribute) {
        element = parent as! AXUIElement
    }
    guard let bar = attribute(element, kAXVerticalScrollBarAttribute) else { fail("no scroll bar") }
    let result = AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, NSNumber(value: position))
    guard result == .success else { fail("scrolling failed (\(result.rawValue))") }
    print("ok")
case "close":
    guard args.count >= 4 else { fail("usage: close <window title>") }
    guard let window = windows.first(where: { string($0, kAXTitleAttribute) == args[3] }),
          let button = attribute(window, kAXCloseButtonAttribute) else { fail("no window \"\(args[3])\"") }
    let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    guard result == .success else { fail("close failed (\(result.rawValue))") }
    print("ok")
default:
    fail("unknown command \(command)")
}
