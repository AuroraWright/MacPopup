// wkaudio <sound file> <seconds open>: a small window "WKAudioTest" with a WKWebView whose page (wkaudio.html, written
// next to the sound file) plays the sound from WebKit's own processes (its GPU process): silently once at load (as a
// game with music would have its audio going), then at volume 0.15 when the app gets SIGUSR1 (a test's driver sends it).
// For checking that recording an app's audio takes in its web views'. Run as the executable of WKAudioTest.app
// (record-driver.py makes the bundle in the run folder and opens it), so that it's an app of its own. Shown without
// taking focus at the right of the main screen, part of it off the edge. Quits after the seconds open. Prints
// "<ms since 1970> <step>".
import AppKit
import WebKit

let args = CommandLine.arguments
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message)")
    fflush(stdout)
}
let sound = URL(fileURLWithPath: args[1])
let page = sound.deletingLastPathComponent().appendingPathComponent("wkaudio.html")
try! """
<!doctype html><audio id="a" src="\(sound.lastPathComponent)"></audio>
<script>
const a = document.querySelector('#a');
a.volume = 0; a.play().then(() => setTimeout(() => { a.pause(); a.currentTime = 0; }, 300));
</script>
""".write(to: page, atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "WKAudioTest"
let config = WKWebViewConfiguration()
config.mediaTypesRequiringUserActionForPlayback = []
let view = WKWebView(frame: window.contentView!.bounds, configuration: config)
window.contentView!.addSubview(view)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 120, y: screen.maxY - 400))
view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
signal(SIGUSR1, SIG_IGN)
let play = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
play.setEventHandler {
    view.evaluateJavaScript("(() => { const e = document.querySelector('#a'); e.currentTime = 0; e.volume = 0.15; e.play(); return 'ok'; })()") { result, error in
        log("playing: \(error.map { "\($0)" } ?? "\(result ?? "")")")
    }
}
play.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + Double(args[2])!) { exit(0) }
log("start")
app.run()
