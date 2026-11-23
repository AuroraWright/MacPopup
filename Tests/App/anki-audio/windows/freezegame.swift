// freezegame <silence file> <seconds open> [sound every s]: a small window "AudioTest" (owner freezegame) whose app plays
// the (silent) file over and over, as a game's music, and starts a quiet afplay of Tink (volume 0.05) as its child
// every few seconds (3), so the game's set of audio processes keeps changing (for tap-freeze.test.js). Normal use, never
// a stress test: a flood of sound processes once crashed coreaudiod. Quits after the seconds open. Shown without taking
// focus at the right of the main screen, part of it off the edge. Prints "<ms since 1970> sound <n>" for each sound.
import AppKit
import AVFoundation

let args = CommandLine.arguments
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "AudioTest"
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 120, y: screen.maxY - 400))
let music = try! AVAudioPlayer(contentsOf: URL(fileURLWithPath: args[1]))
music.numberOfLoops = -1
music.play()
// Never more often than every 2 s.
let every = max(2, args.count > 3 ? Double(args[3])! : 3)
var count = 0
Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
    let sound = Process()
    sound.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    sound.arguments = ["-v", "0.05", "/System/Library/Sounds/Tink.aiff"]
    try? sound.run()
    count += 1
    log("sound \(count)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + Double(args[2])!) { exit(0) }
log("start")
app.run()
