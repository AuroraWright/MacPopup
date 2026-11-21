import AVFoundation
import Transcription

/// "Read text from audio" simulated on a recording (transcribe-cli replay), as fast as the models go: the app's
/// StretchTranscriber, given the stretches as the app's SpeechListener gives them, with the recording played in place
/// of the app's audio as a test run's MACPOPUP_TEST_TRANSCRIPTION_FILE is, a tenth of a second at a time, on a
/// simulated clock: seconds into the recording.
///
/// What takes time in the app takes as long on the clock (`timed`): placing a stretch, transcribing it into lines, a
/// live pass. Each is done when it starts, but what follows from it waits until the clock gets to its end. Placing,
/// lines and live passes each go one at a time, apart from one another, as on the app's queues. What's left out: the
/// model loading (it's loaded before the clock starts, so the first stretches and live words aren't late), the time
/// the app takes to find the stretches, the text box (its lines are kept here as the app sends them, a grown line
/// replacing the last one, before the box's own text settings: replacements, removeAllWhitespace, filters, duplicates),
/// and the time models working at once take from one another.
@MainActor
final class Replay: StretchTranscriberHost {
    struct Settings {
        var label: String
        /// Seconds; 0: lines don't end at pauses.
        var pause: Double
        /// "Detect sentence ends", and its settings.
        var growing: Bool
        var lines = GrowingLines()
        /// "Show words as they're heard".
        var live: Bool
        var language: String
        /// Seconds of audio given at a time.
        var chunk: Double
        /// Whether what takes time in the app takes time on the clock (else nothing does: as on a machine infinitely fast).
        var timed: Bool

        /// The app's settings' names, as in run.sh's (transcriptionPause in ms, transcriptionSentenceEnds,
        /// transcriptionLive, language), GrowingLines' (endAtPause, endAtLongPause, endWithoutPause, keptWhenHeardAgain),
        /// and label, chunk and timed.
        init(_ json: [String: Any]) {
            label = json["label"] as? String ?? (try? String(decoding: JSONSerialization.data(withJSONObject: json, options: .sortedKeys), as: UTF8.self)) ?? ""
            pause = (json["transcriptionPause"] as? Double ?? 1000) / 1000
            growing = json["transcriptionSentenceEnds"] as? Bool ?? false
            live = json["transcriptionLive"] as? Bool ?? false
            language = json["language"] as? String ?? "ja"
            chunk = json["chunk"] as? Double ?? 0.1
            timed = json["timed"] as? Bool ?? true
            if let value = json["endAtPause"] as? Double { lines.endAtPause = Float(value) }
            if let value = json["endAtLongPause"] as? Double { lines.endAtLongPause = Float(value) }
            if let value = json["endWithoutPause"] as? Double { lines.endWithoutPause = Float(value) }
            if let value = json["keptWhenHeardAgain"] as? Double { lines.keptWhenHeardAgain = value }
        }
    }

    private let settings: Settings
    private let stretches: SpeechStretches
    private var transcriber: StretchTranscriber!
    private var listener = 0

    /// The clock, and what's to happen on it, in order (`order` among things at the same time).
    private var now = 0.0
    private var events: [(time: Double, order: Int, run: () async -> Void)] = []
    private var order = 0
    /// Classifier results to run after the buffer being analyzed.
    private var delivered: [() -> Void] = []

    // As in SpeechListener.
    private var cuts: [SpeechStretches.Cut] = []
    private var placing = false

    // What's shown: the box's lines (and which one grows), each stretch's live words, and the log.
    private var box: [[String: Any]] = []
    private var transcriptLine: Int?
    private var stretchRows: [Int: [String: Any]] = [:]
    private var log: [String] = []
    /// Seconds each kind of work took, and live passes.
    private var spent = ["place": 0.0, "lines": 0.0, "live": 0.0]
    private var livePasses = 0

    init(_ settings: Settings, recognizer: SpeechRecognizer, live: (any LiveTranscription)?) {
        self.settings = settings
        var deliver: (@escaping () -> Void) -> Void = { _ in }
        var noted: (String) -> Void = { _ in }
        stretches = SpeechStretches(pause: settings.pause, live: settings.live && live != nil, clock: { 0 },
                                    deliver: { deliver($0) }, log: { noted($0) })
        deliver = { [unowned self] in self.delivered.append($0) }
        noted = { [unowned self] in self.note($0) }
        transcriber = StretchTranscriber(host: self, lines: settings.lines)
        transcriber.use(recognizer)
        transcriber.language = settings.language
        transcriber.growing = settings.growing
        listener = transcriber.startListener()
        transcriber.live = settings.live ? live : nil
        stretches.onCut = { [unowned self] in
            self.cuts.append($0)
            self.placeNext()
        }
        // As the app's listener queue gives them to the main actor.
        stretches.onLive = { [unowned self] event in
            self.at(self.now) { self.transcriber.heardLive(event, listener: self.listener) }
        }
    }

    private func note(_ message: String) {
        log.append(String(format: "%.2f %@", now, message))
    }

    /// Runs `run` at `time` on the clock.
    private func at(_ time: Double, _ run: @escaping () async -> Void) {
        order += 1
        events.append((time, order, run))
    }

    /// Plays the recording, then silence until the last voice has ended, and runs what follows until nothing's left.
    func run(_ url: URL) async throws -> [String: Any] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount((format.sampleRate * settings.chunk).rounded())
        let duration = Double(file.length) / format.sampleRate
        // Enough for the classifier to hear the voice stop and the pause after it.
        let buffers = Int(((duration + 5 + settings.pause) / settings.chunk).rounded(.up))
        let started = Date()
        var given = 0
        while true {
            let next = events.indices.min { (events[$0].time, events[$0].order) < (events[$1].time, events[$1].order) }
            let audioTime = Double(given) * settings.chunk
            if given < buffers, next.map({ audioTime <= events[$0].time }) ?? true {
                now = audioTime
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                if (try? file.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0 {
                    buffer.frameLength = chunk
                    for channel in 0..<Int(format.channelCount) {
                        buffer.floatChannelData?[channel].update(repeating: 0, count: Int(chunk))
                    }
                }
                stretches.append(buffer)
                while !delivered.isEmpty { delivered.removeFirst()() }
                given += 1
            } else if let next {
                let event = events.remove(at: next)
                now = event.time
                await event.run()
            } else {
                break
            }
        }
        stretches.stop()
        let ms = spent.mapValues { ($0 * 10000).rounded() / 10 }
        return [
            "setting": settings.label, "lines": box, "dropped": transcriber.dropped, "log": log,
            "stretches": stretchRows.keys.sorted().compactMap { stretchRows[$0] },
            "audio": duration, "wall": (Date().timeIntervalSince(started) * 100).rounded() / 100, "ms": ms,
            "livePasses": livePasses,
        ]
    }

    // MARK: SpeechListener

    private func placeNext() {
        guard !placing, !cuts.isEmpty else { return }
        let cut = cuts.removeFirst()
        placing = true
        let started = Date()
        let placed = cut.place(log: note)
        let seconds = Date().timeIntervalSince(started)
        spent["place", default: 0] += seconds
        at(now + (settings.timed ? seconds : 0)) {
            for item in placed { self.transcriber.heard(item, listener: self.listener) }
            self.placing = false
            self.placeNext()
        }
    }

    // MARK: StretchTranscriberHost

    /// The work now, and `done` as long after on the clock as it took (see `timed`).
    func run<T: Sendable>(_ kind: StretchTranscriber.Work, _ work: @escaping @Sendable () async -> T,
                          done: @escaping @MainActor (T) -> Void) {
        at(now) {
            let started = Date()
            let result = await work()
            let seconds = Date().timeIntervalSince(started)
            self.spent[kind.rawValue, default: 0] += seconds
            if kind == .live { self.livePasses += 1 }
            self.at(self.now + (self.settings.timed ? seconds : 0)) { done(result) }
        }
    }

    /// The box: a line that grows replaces the last line when it's still the last one.
    func show(_ line: StretchLines.Shown, endsLive: Int?) {
        let row: [String: Any] = ["text": line.text, "start": line.start, "shown": now]
        if line.grows, let index = transcriptLine, index == box.count - 1 {
            box[index] = row
        } else {
            box.append(row)
        }
        transcriptLine = box.count - 1
    }

    func showLive(_ text: String?, stretch: Int) {
        guard let text else { return }
        self[row: stretch, nil]["partials"] = (self[row: stretch, nil]["partials"] as? [[Any]] ?? [])
            + [[(now * 1000).rounded() / 1000, text]]
    }

    func clearLive() {}

    func log(_ message: String) {
        note(message)
    }

    func transcribed(error: Error?) {
        if let error { note("couldn't transcribe: \(error.localizedDescription)") }
    }

    func sentenceEndsFailed(_ error: Error) {
        note("SaT: \(error.localizedDescription)")
    }

    func heard(_ samples: [Float], text: String, speech: SpeechStretches.Speech, listener: Int) {
        self[row: speech.id, speech]["final"] = text
    }

    /// The stretch's row: its live words as they were shown ([seconds, text]) and the text it was transcribed to, as
    /// transcribe-cli live's rows were (for live-stats.py).
    private subscript(row id: Int, speech: SpeechStretches.Speech?) -> [String: Any] {
        get {
            var row = stretchRows[id] ?? ["id": id, "partials": [[Any]]()]
            if let speech {
                row["start"] = speech.start
                row["end"] = speech.start + speech.duration
            }
            return row
        }
        set { stretchRows[id] = newValue }
    }
}
