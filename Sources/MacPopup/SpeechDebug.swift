import OCREngines
import Foundation

/// With MACPOPUP_DEBUG_SPEECH_DIR set: what the speech models heard, for finding out why a line or its live words
/// came out as they did. In the folder, for each stretch of speech (<listener>-<stretch>: the listener restarts with
/// the audio's source or model): line-….wav, the audio its line was transcribed from; live-….wav, the audio its live
/// words came from until its line came; and speech.jsonl, each live text and line text as it came.
final class SpeechDebug: @unchecked Sendable {
    static let shared: SpeechDebug? = DevelopmentEnvironment["MACPOPUP_DEBUG_SPEECH_DIR"].map {
        SpeechDebug(folder: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
    }

    private let folder: URL
    private let queue = DispatchQueue(label: "com.aury.macpopup.speech-debug", qos: .utility)
    /// Each stretch's live audio so far.
    private var live: [String: [Float]] = [:]

    private init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A live pass: the audio it was given and the text it gave, after `ms`.
    func live(listener: Int, stretch: Int, samples: [Float], text: String?, ms: Double) {
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            let name = "\(listener)-\(stretch)"
            live[name, default: []] += samples
            let heard = Double(live[name]!.count) / 16000
            append(["kind": "live", "stretch": name, "uptime": uptime, "heard": heard, "ms": ms, "text": text ?? NSNull()])
        }
    }

    /// A stretch's line: the audio it was transcribed from, and its text.
    func line(listener: Int, stretch: Int, samples: [Float], text: String) {
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            let name = "\(listener)-\(stretch)"
            // Its live audio up to now (any after it isn't shown).
            if let audio = live.removeValue(forKey: name) { write(audio, to: "live-\(name).wav") }
            append(["kind": "line", "stretch": name, "uptime": uptime, "heard": Double(samples.count) / 16000, "text": text])
            write(samples, to: "line-\(name).wav")
        }
    }

    private func append(_ record: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let url = folder.appendingPathComponent("speech.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// 16 kHz mono samples (-1 to 1) as a 16-bit WAV file.
    private func write(_ samples: [Float], to name: String) {
        var data = Data()
        func add<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); add(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); add(UInt32(16)); add(UInt16(1)); add(UInt16(1))
        add(UInt32(16000)); add(UInt32(32000)); add(UInt16(2)); add(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); add(bytes)
        for sample in samples { add(Int16(max(-1, min(1, sample.isNaN ? 0 : sample)) * 32767)) }
        try? data.write(to: folder.appendingPathComponent(name))
    }
}
