// audiowin <sound file> <volume> <seconds open> [cold]: a small window "AudioTest" (owner audiowin) that plays the sound
// file once it gets SIGUSR1 (a test's driver sends it), for recording one app's audio. Unless "cold", it opens its audio
// output at launch (silently, as a game playing music would have); cold, only when it plays. Quits after the seconds
// open. Shown without taking focus at the right of the main screen, part of it off the edge. Prints each step as
// "<ms since 1970> <step>".
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
let player = try! AVAudioPlayer(contentsOf: URL(fileURLWithPath: args[1]))
player.volume = Float(args[2])!
let warmup = try! AVAudioPlayer(contentsOf: URL(fileURLWithPath: args[1]))
warmup.volume = 0
if args.count < 5 {
    warmup.play()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { warmup.stop() }
}
signal(SIGUSR1, SIG_IGN)
let play = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
play.setEventHandler {
    // (Logged before too: a cold first start once didn't return for seconds, see record-driver.py.)
    log("told to play")
    player.play()
    log("playing \(String(format: "%.2f", player.duration)) s")
}
play.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + Double(args[3])!) { exit(0) }
log("start")
app.run()
