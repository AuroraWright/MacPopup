// mouse <command> …: the real pointer, for interactive tests' drivers (tests with "// interactive"). Moves and clicks go
// only where a window of the test instance (<pid>) is the frontmost one at that point (no other app's visible window
// above it there); a refused one prints why and exits with 1. Clicks are left clicks without modifiers (a Control left
// over would make a right click, which opens a menu). Drivers build it with tools/build.sh.
//   pos                                    where the pointer is: "x y" (global points, top left origin)
//   put <x> <y>                            puts it there in one move, unchecked (to put it back afterwards)
//   window <pid> [<title> | <w> <h>]       the process's on-screen window with that title or size (or its largest):
//                                          "x y w h id"
//   move <pid> <x0> <y0> <x1> <y1> [ms]    moves it from one point to the other over ms (300) as HID moves, ~8 ms apart
//   click <pid> <x> <y>                    moves there and clicks
//   drag <pid> <x0> <y0> <x1> <y1>         presses at the first point, drags to the second (40 steps), lets go
// Points are global; the start of a move or drag and the end of a move need the instance's window in front there.
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}

func bounds(_ w: [String: Any]) -> CGRect {
    CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) ?? .null
}

/// Whether the frontmost visible window at the point (front to back, as the list is) is one of the process's. The
/// window server's own (menu bar, cursor) and fully transparent windows don't count; any other app's window does.
func inFront(_ pid: Int32, _ p: CGPoint) -> Bool {
    for w in windows() where bounds(w).contains(p) {
        if (w[kCGWindowOwnerPID as String] as? Int32) == pid { return true }
        if (w[kCGWindowOwnerName as String] as? String) == "Window Server" { continue }
        if (w[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
        return false
    }
    return false
}

func post(_ type: CGEventType, _ p: CGPoint) {
    let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                        mouseCursorPosition: p, mouseButton: .left)
    event?.flags = []
    event?.post(tap: .cghidEventTap)
}

func number(_ i: Int) -> Double {
    guard i < args.count, let value = Double(args[i]) else { fail("mouse: argument \(i + 1) isn't a number") }
    return value
}

func pid() -> Int32 {
    guard args.count > 1, let value = Int32(args[1]) else { fail("mouse: no pid") }
    return value
}

func checked(_ pid: Int32, _ p: CGPoint) {
    guard inFront(pid, p) else { fail("refused: the test instance's window isn't in front at \(Int(p.x)),\(Int(p.y))") }
}

switch args.first {
case "pos":
    let at = CGEvent(source: nil)?.location ?? .zero
    print(Int(at.x.rounded()), Int(at.y.rounded()))
case "put":
    post(.mouseMoved, CGPoint(x: number(1), y: number(2)))
case "window":
    let pid = pid()
    let ours = windows().filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    let match: [String: Any]?
    if args.count > 3 {
        let size = CGSize(width: number(2), height: number(3))
        match = ours.first { abs(bounds($0).width - size.width) < 1 && abs(bounds($0).height - size.height) < 1 }
    } else if args.count == 3 {
        match = ours.first { ($0[kCGWindowName as String] as? String) == args[2] }
    } else {
        match = ours.max { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }
    }
    guard let w = match else { fail("no window") }
    let r = bounds(w)
    print(Int(r.minX), Int(r.minY), Int(r.width), Int(r.height), w[kCGWindowNumber as String] as? Int ?? 0)
case "move":
    let pid = pid()
    let a = CGPoint(x: number(2), y: number(3)), b = CGPoint(x: number(4), y: number(5))
    let ms = args.count > 6 ? number(6) : 300
    checked(pid, a)
    checked(pid, b)
    let steps = max(1, Int(ms / 8))
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        post(.mouseMoved, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(8000)
    }
case "click":
    let pid = pid()
    let p = CGPoint(x: number(2), y: number(3))
    checked(pid, p)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        post(type, p)
        usleep(60_000)
    }
case "drag":
    let pid = pid()
    let a = CGPoint(x: number(2), y: number(3)), b = CGPoint(x: number(4), y: number(5))
    checked(pid, a)
    post(.mouseMoved, a)
    usleep(150_000)
    post(.leftMouseDown, a)
    for i in 1...40 {
        let t = Double(i) / 40
        post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(8000)
    }
    post(.leftMouseUp, b)
    usleep(400_000)
default:
    fail("usage: mouse pos | put x y | window pid [title | w h] | move pid x0 y0 x1 y1 [ms] | click pid x y | drag pid x0 y0 x1 y1")
}
