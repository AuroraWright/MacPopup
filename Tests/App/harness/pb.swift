// pb <pasteboard name> <text>: puts text on a named pasteboard.
import AppKit
let pasteboard = NSPasteboard(name: .init(CommandLine.arguments[1]))
pasteboard.clearContents()
pasteboard.setString(CommandLine.arguments[2], forType: .string)
