import AVFoundation
import Transcription

/// "Read text from audio" simulated on a recording (transcribe-cli replay), as fast as the models go: the app's parts
/// (SpeechStretches, StretchLines, PendingStretches, LiveFeed) put together as AudioTranscriber and SpeechListener do,
/// with the recording played in place of the app's audio as a test run's MACPOPUP_TEST_TRANSCRIPTION_FILE is, a tenth
/// of a second at a time, on a simulated clock: seconds into the recording.
///
/// What takes time in the app takes as long on the clock (`timed`): placing a stretch, transcribing it into lines, a
/// live pass. Each is done when it starts, but what follows from it waits until the clock gets to its end. Placing,
/// lines and live passes each go one at a time, apart from one another, as on the app's queues. What's left out: the
/// model loading (it's loaded before the clock starts, so the first stretches and live words aren't late), the time
/// the app takes to find the stretches, the text box (its lines are kept here as the app sends them, a grown line
/// replacing the last one, before the box's own text settings: replacements, removeAllWhitespace, filters, duplicates),
/// and the time models working at once take from one another.
@MainActor
final class Replay {
    struct Settings {
        var label: String
        /// Seconds; 0: lines don't end at pauses.
        var pause: Double
        /// "End lines at sentence ends", and its settings.
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
    private let recognizer: SpeechRecognizer
    private let live: (any LiveTranscription)?
    private let stretches: SpeechStretches
    private let lines: StretchLines

    /// The clock, and what's to happen on it, in order (`order` among things at the same time).
    private var now = 0.0
    private var events: [(time: Double, order: Int, run: () async -> Void)] = []
    private var order = 0
    /// Classifier results to run after the buffer being analyzed.
    private var delivered: [() -> Void] = []

    // As in SpeechListener and AudioTranscriber.
    private var cuts: [SpeechStretches.Cut] = []
    private var placing = false
    private var pending = PendingStretches()
    private var transcribing = false
    private var linesBroken = false
    private var liveFeed = LiveFeed()

    // What's shown: the box's lines (and which one grows), each stretch's live words, and the log.
    private var box: [[String: Any]] = []
    private var transcriptLine: Int?
    private var stretchRows: [Int: [String: Any]] = [:]
    private var log: [String] = []
    private var dropped = 0
    /// Seconds each kind of work took, and live passes.
    private var spent = ["place": 0.0, "lines": 0.0, "live": 0.0]
    private var livePasses = 0

    init(_ settings: Settings, recognizer: SpeechRecognizer, live: (any LiveTranscription)?) {
        self.settings = settings
        self.recognizer = recognizer
        self.live = settings.live ? live : nil
        lines = StretchLines(lines: settings.lines)
        var deliver: (@escaping () -> Void) -> Void = { _ in }
        var noted: (String) -> Void = { _ in }
        stretches = SpeechStretches(pause: settings.pause, live: settings.live && live != nil, clock: { 0 },
                                    deliver: { deliver($0) }, log: { noted($0) })
        deliver = { [unowned self] in self.delivered.append($0) }
        noted = { [unowned self] in self.note($0) }
        stretches.onCut = { [unowned self] in
            self.cuts.append($0)
            self.placeNext()
        }
        // As the app's listener queue gives them to the main actor.
        stretches.onLive = { [unowned self] event in self.at(self.now) { await self.heardLive(event) } }
    }

    private func note(_ message: String) {
        log.append(String(format: "%.2f %@", now, message))
    }

    /// Runs `run` at `time` on the clock.
    private func at(_ time: Double, _ run: @escaping () async -> Void) {
        order += 1
        events.append((time, order, run))
    }

    /// Seconds on the clock the work took (see `timed`), and its result.
    private func timed<T>(_ kind: String, _ work: () async throws -> T) async rethrows -> (Double, T) {
        let started = Date()
        let result = try await work()
        let seconds = Date().timeIntervalSince(started)
        spent[kind, default: 0] += seconds
        return (settings.timed ? seconds : 0, result)
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
            "setting": settings.label, "lines": box, "dropped": dropped, "log": log,
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
            for item in placed {
                switch item {
                case let .speech(speech): await self.heard(speech)
                case let .dropped(stretch): self.endLiveLine(stretch)
                }
            }
            self.placing = false
            self.placeNext()
        }
    }

    // MARK: AudioTranscriber

    private func heard(_ speech: SpeechStretches.Speech) async {
        if let dropped = pending.add(speech) {
            endLiveLine(dropped.id)
            self.dropped += 1
            // The line can't go on past the missing speech.
            linesBroken = true
            note("transcription is behind: dropped a stretch of speech")
        }
        await transcribeNext()
    }

    private func transcribeNext() async {
        guard !transcribing, let speech = pending.next() else { return }
        if linesBroken {
            lines.end()
            linesBroken = false
        }
        guard !speech.samples.isEmpty else {
            // The voice stopped after a stretch too quiet to transcribe.
            lines.end()
            endLiveLine(speech.id)
            await transcribeNext()
            return
        }
        transcribing = true
        let (seconds, shown) = await timed("lines") {
            try? await lines.lines(for: speech, recognizer: recognizer, language: settings.language,
                                   growing: settings.growing, log: note,
                                   heard: { _, text in self[row: speech.id, speech]["final"] = text },
                                   sentenceEndsFailed: { self.note("SaT: \($0.localizedDescription)") }, wanted: { true })
        }
        at(now + seconds) {
            var liveReplaced = false
            for (index, line) in (shown ?? []).enumerated() {
                let last = index == (shown ?? []).count - 1
                liveReplaced = self.show(line, endsLive: last ? speech.id : nil) && last
            }
            if !liveReplaced { self.endLiveLine(speech.id) }
            self.transcribing = false
            await self.transcribeNext()
        }
    }

    /// The box: a line that grows replaces the last line when it's still the last one.
    private func show(_ line: StretchLines.Shown, endsLive: Int?) -> Bool {
        guard !line.text.isEmpty else { return false }
        if let endsLive { liveFeed.end(endsLive) }
        let row: [String: Any] = ["text": line.text, "start": line.start, "shown": now]
        if line.grows, let index = transcriptLine, index == box.count - 1 {
            box[index] = row
        } else {
            box.append(row)
        }
        transcriptLine = box.count - 1
        return true
    }

    private func heardLive(_ event: SpeechStretches.Live) async {
        guard let live else { return }
        switch event {
        case let .audio(stretch, samples):
            liveFeed.heard(samples, stretch: stretch)
            await hearLive(live)
        case let .dropped(stretch):
            endLiveLine(stretch)
        }
    }

    private func hearLive(_ live: any LiveTranscription) async {
        guard let piece = liveFeed.next() else { return }
        if piece.starts { live.start() }
        let (seconds, text) = await timed("live") { try? await live.accept(piece.samples) }
        livePasses += 1
        at(now + seconds) {
            self.liveFeed.done()
            if let text, let shown = self.liveFeed.show(text, stretch: piece.stretch) {
                self[row: piece.stretch, nil]["partials"] = (self[row: piece.stretch, nil]["partials"] as? [[Any]] ?? [])
                    + [[(self.now * 1000).rounded() / 1000, shown]]
            }
            await self.hearLive(live)
        }
    }

    private func endLiveLine(_ stretch: Int) {
        liveFeed.end(stretch)
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
