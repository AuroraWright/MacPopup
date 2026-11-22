import Foundation

/// What StretchTranscriber needs from where it runs: its clock (when work's results come) and the text box.
@MainActor
public protocol StretchTranscriberHost: AnyObject {
    /// Runs `work`, and `done` with its result once it's done: in the app, as soon as it is (live passes off the main
    /// actor); in transcribe-cli replay, as long after on its clock as the work took.
    func run<T: Sendable>(_ kind: StretchTranscriber.Work, _ work: @escaping @Sendable () async -> T,
                          done: @escaping @MainActor (T) -> Void)
    /// Adds a line to the box, or replaces its last line with it when it `grows` and is still the last one. `endsLive`:
    /// the stretch whose live line it takes the place of.
    func show(_ line: StretchLines.Shown, endsLive: Int?)
    /// The stretch's live line: `text`, or nil once it's gone.
    func showLive(_ text: String?, stretch: Int)
    /// All live lines are gone.
    func clearLive()
    func log(_ message: String)
    /// A stretch was transcribed (`error` nil) or couldn't be.
    func transcribed(error: Error?)
    /// SaT failed: the lines end at punctuation only.
    func sentenceEndsFailed(_ error: Error)
    /// The audio the stretch's lines were transcribed from, and its text (see StretchLines.lines).
    func heard(_ samples: [Float], text: String, speech: SpeechStretches.Speech, listener: Int)
    /// A live pass: the audio given, the words so far and how long it took.
    func heardLive(_ samples: [Float], text: String?, ms: Double, stretch: Int, listener: Int)
}

public extension StretchTranscriberHost {
    func heard(_ samples: [Float], text: String, speech: SpeechStretches.Speech, listener: Int) {}
    func heardLive(_ samples: [Float], text: String?, ms: Double, stretch: Int, listener: Int) {}
}

/// "Read text from audio" from the stretches of speech found (SpeechStretches, placed): each transcribed into the
/// box's lines (StretchLines), one at a time and in order, with the ones waiting meanwhile kept (PendingStretches), and
/// with "Show words as they're heard" the stretch being heard given to the model's live words (LiveFeed) and shown as
/// its live line until its lines take its place. The app's AudioTranscriber and transcribe-cli replay both run it,
/// each with its own clock and box (StretchTranscriberHost).
@MainActor
public final class StretchTranscriber {
    public enum Work: String, Sendable {
        case lines, live
    }

    private unowned let host: any StretchTranscriberHost
    /// The model transcribing the stretches (nil: none, stretches aren't kept), and its settings.
    public private(set) var recognizer: SpeechRecognizer?
    public var language = "ja"
    /// "Detect sentence ends".
    public var growing = false
    /// The model's words as they're heard; nil: not wanted (or not had from the model).
    public var live: (any LiveTranscription)? {
        didSet {
            guard live !== oldValue else { return }
            // The next piece starts a stretch for it.
            liveFeed.restart()
        }
    }

    private let lines: StretchLines
    private var pending = PendingStretches()
    private var transcribing = false
    /// The open line can't go on past the stretches transcribed so far: speech was dropped, or the audio's source or
    /// model changed. It's ended before the next stretch, not while one is being transcribed (which goes on from it).
    private var linesBroken = false
    private var liveFeed = LiveFeed()
    /// Counts the listeners, so that a stopped one's stretches aren't heard, and the times the live lines were all
    /// removed, so that words worked out before then aren't shown.
    public private(set) var listener = 0
    private var liveGeneration = 0
    /// Stretches dropped because transcription couldn't keep up.
    public private(set) var dropped = 0

    /// `lines`: GrowingLines' settings (for trying others).
    public init(host: any StretchTranscriberHost, lines: GrowingLines = GrowingLines()) {
        self.host = host
        self.lines = StretchLines(lines: lines)
    }

    /// Another model (or none) transcribes the stretches: the ones waiting and the live lines go.
    public func use(_ recognizer: SpeechRecognizer?) {
        guard recognizer !== self.recognizer else { return }
        self.recognizer = recognizer
        live = nil
        restart()
    }

    /// A new listener hears the audio (its source changed): its stretches count from 0 again, and those of the one
    /// before it waiting and their live lines go. Returns the listener, for `heard`.
    @discardableResult
    public func startListener() -> Int {
        restart()
        listener += 1
        return listener
    }

    private func restart() {
        pending.removeAll()
        // The open line can't go on with another source's or model's speech.
        linesBroken = true
        endLiveLines()
    }

    /// A stretch placed by the `listener`'s SpeechStretches (see Cut.place).
    public func heard(_ placed: SpeechStretches.Cut.Placed, listener: Int) {
        // Not from a listener stopped meanwhile (stretches are placed after it's stopped).
        guard listener == self.listener else { return }
        switch placed {
        case let .speech(speech): heard(speech)
        case let .dropped(stretch): endLiveLine(stretch)
        }
    }

    private func heard(_ speech: SpeechStretches.Speech) {
        guard recognizer != nil else { return }
        if let dropped = pending.add(speech) {
            endLiveLine(dropped.id)
            self.dropped += 1
            // The line can't go on past the missing speech.
            linesBroken = true
            host.log("transcription is behind: dropped a stretch of speech")
        }
        transcribeNext()
    }

    private func transcribeNext() {
        guard !transcribing, let recognizer, let speech = pending.next() else { return }
        if linesBroken {
            lines.end()
            linesBroken = false
        }
        guard !speech.samples.isEmpty else {
            // The voice stopped after a stretch too quiet to transcribe.
            lines.end()
            endLiveLine(speech.id)
            transcribeNext()
            return
        }
        let listener = listener
        transcribing = true
        host.run(.lines, { [self] in
            await transcribe(speech, recognizer: recognizer, listener: listener)
        }) { [self] shown in
            // Its live line goes with its last line (see show), or else once it's done; not once another listener
            // started meanwhile, whose stretches count from 0 again (its live lines were all removed then).
            let endsLive = self.listener == listener ? speech.id : nil
            let shown = shown ?? []
            var liveReplaced = false
            for (index, line) in shown.enumerated() {
                let last = index == shown.count - 1
                liveReplaced = show(line, endsLive: last ? endsLive : nil) && last
            }
            if !liveReplaced, let endsLive { endLiveLine(endsLive) }
            transcribing = false
            transcribeNext()
        }
    }

    /// The stretch's lines, or nil when it couldn't be transcribed or the model changed meanwhile.
    private func transcribe(_ speech: SpeechStretches.Speech, recognizer: SpeechRecognizer,
                            listener: Int) async -> [StretchLines.Shown]? {
        do {
            guard let shown = try await lines.lines(
                for: speech, recognizer: recognizer, language: language, growing: growing, log: host.log,
                heard: { host.heard($0, text: $1, speech: speech, listener: listener) },
                sentenceEndsFailed: host.sentenceEndsFailed, wanted: { self.recognizer === recognizer }
            ) else { return nil }
            host.transcribed(error: nil)
            return shown
        } catch {
            // Not for a model no longer used.
            if self.recognizer === recognizer { host.transcribed(error: error) }
            return nil
        }
    }

    /// Returns whether there was text to show.
    private func show(_ line: StretchLines.Shown, endsLive: Int?) -> Bool {
        guard !line.text.isEmpty else { return false }
        if let endsLive { liveFeed.end(endsLive) }
        host.show(line, endsLive: endsLive)
        return true
    }

    /// The stretch being heard by the `listener`'s SpeechStretches, as it's heard: its audio goes to the model, its
    /// words to its live line.
    public func heardLive(_ event: SpeechStretches.Live, listener: Int) {
        guard listener == self.listener else { return }
        switch event {
        case let .audio(stretch, samples):
            guard let live else { return }
            liveFeed.heard(samples, stretch: stretch)
            hearLive(live)
        case let .dropped(stretch):
            // Also once `live` is let go: its line may still be shown.
            endLiveLine(stretch)
        }
    }

    /// Gives `live` the audio waiting, unless it's working out words: then once it's done.
    private func hearLive(_ live: any LiveTranscription) {
        guard let piece = liveFeed.next() else { return }
        let generation = liveGeneration, listener = listener
        host.run(.live, { () -> (String?, Double) in
            if piece.starts { live.start() }
            let started = ProcessInfo.processInfo.systemUptime
            let text = try? await live.accept(piece.samples)
            return (text, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }) { [self] text, ms in
            host.heardLive(piece.samples, text: text, ms: ms, stretch: piece.stretch, listener: listener)
            liveFeed.done()
            if let text, generation == liveGeneration, self.live != nil,
               let text = liveFeed.show(text, stretch: piece.stretch) {
                host.showLive(text, stretch: piece.stretch)
            }
            // Not if it was let go meanwhile.
            if let current = self.live, current === live { hearLive(live) }
        }
    }

    /// Removes the stretch's live line, if it has one.
    private func endLiveLine(_ stretch: Int) {
        guard liveFeed.end(stretch) else { return }
        host.showLive(nil, stretch: stretch)
    }

    /// Removes all live lines.
    private func endLiveLines() {
        liveGeneration += 1
        liveFeed.clear()
        host.clearLive()
    }
}
