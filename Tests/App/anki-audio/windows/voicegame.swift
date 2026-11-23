// voicegame <dir> <volume> <line times s...>: a 960x240 window "AudioTest" like a visual novel's, playing quiet music
// all along and, at each time, the next line: its text (<dir>/voice<i>.txt, the four over and over) shown in the
// window, sent to mock.py's WebSocket server (POST to 127.0.0.1:59881, MOCK_WEBSOCKET, as a text hook would) and its
// voice (<dir>/voice<i>.aiff, made by voices.sh) played. A line stops the voice before it, as a game does when the player
// goes on. Quits 12 s after the last line. Shown without taking focus at the right of the main screen, 60 points of it
// off the edge. Prints each step as "<ms since 1970> <step> (uptime <s>)": "line <i> shown <text>", "voice <i> started
// <length> s", "voice <i> ended", "voice <i> stopped".
import AppKit
import AVFoundation

let args = CommandLine.arguments
let dir = args[1], volume = Float(args[2])!, times = args[3...].map { Double($0)! }
func log(_ message: String) {
    print("\(Int(Date().timeIntervalSince1970 * 1000)) \(message) (uptime \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)))")
    fflush(stdout)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "AudioTest"
window.contentView!.wantsLayer = true
window.contentView!.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
let label = NSTextField(wrappingLabelWithString: "")
label.frame = NSRect(x: 40, y: 40, width: 820, height: 160)
label.font = NSFont(name: "HiraginoSans-W3", size: 30)
label.textColor = .white
window.contentView!.addSubview(label)
window.orderFrontRegardless()
window.setFrameOrigin(NSPoint(x: screen.maxX - 900, y: screen.maxY - 80 - window.frame.height))

let engine = AVAudioEngine()
let music = AVAudioPlayerNode(), voice = AVAudioPlayerNode()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
engine.attach(music)
engine.attach(voice)
engine.connect(music, to: engine.mainMixerNode, format: format)
engine.connect(voice, to: engine.mainMixerNode, format: nil)
// Music: a slow arpeggio of soft tones over a held chord, 8 s, looped.
let length = AVAudioFrameCount(48000 * 8)
let loop = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length)!
loop.frameLength = length
let chord = [220.0, 277.18, 329.63], notes = [440.0, 554.37, 659.25, 880.0, 659.25, 554.37]
for frame in 0..<Int(length) {
    let t = Double(frame) / 48000
    var sample = chord.reduce(0) { $0 + sin(2 * .pi * $1 * t) } * 0.05
    let note = Int(t * 2) % notes.count, phase = t * 2 - floor(t * 2)
    sample += sin(2 * .pi * notes[note] * t) * 0.12 * exp(-3 * phase)
    loop.floatChannelData![0][frame] = Float(sample)
    loop.floatChannelData![1][frame] = Float(sample)
}
music.volume = volume
voice.volume = volume
try! engine.start()
music.scheduleBuffer(loop, at: nil, options: .loops)
music.play()

var current = -1
func show(_ index: Int) {
    if voice.isPlaying {
        voice.stop()
        log("voice \(current) stopped")
    }
    current = index
    let file = index % 4
    let text = (try? String(contentsOfFile: "\(dir)/voice\(file).txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var request = URLRequest(url: URL(string: "http://127.0.0.1:59881/")!)
    request.httpMethod = "POST"
    request.httpBody = text.data(using: .utf8)
    URLSession.shared.dataTask(with: request).resume()
    label.stringValue = text
    log("line \(index) shown \(text)")
    let audio = try! AVAudioFile(forReading: URL(fileURLWithPath: "\(dir)/voice\(file).aiff"))
    voice.scheduleFile(audio, at: nil) {
        DispatchQueue.main.async { if current == index, voice.isPlaying { log("voice \(index) ended") } }
    }
    voice.play()
    log("voice \(index) started \(String(format: "%.2f", Double(audio.length) / audio.processingFormat.sampleRate)) s")
}
for (index, time) in times.enumerated() {
    DispatchQueue.main.asyncAfter(deadline: .now() + time) { show(index) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + (times.last ?? 0) + 12) { exit(0) }
log("start")
app.run()
