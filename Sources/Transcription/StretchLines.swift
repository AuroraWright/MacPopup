import Foundation

/// The text box's lines from each stretch of speech, one stretch at a time and in order (AudioTranscriber in the app,
/// transcribe-cli replay's simulation of it): the stretch transcribed and split into sentences, or with "End lines at
/// sentence ends", as with OCR's lines (ShownLines), the open line grown with the stretch while its sentence goes on
/// (GrowingLines, with SaT's sentence ends).
@MainActor
public final class StretchLines {
    public struct Shown: Sendable {
        public let text: String
        /// When its speech starts, on the stretches' clock.
        public let start: Double
        /// It replaces the last line shown (the open line, grown).
        public let grows: Bool
    }

    private var lines: GrowingLines

    /// `lines`: its settings (for trying others).
    public init(lines: GrowingLines = GrowingLines()) {
        self.lines = lines
    }

    /// The open line ends: it can't go on past the stretches transcribed so far.
    public func end() {
        lines.end()
    }

    /// The stretch's lines. `growing`: "End lines at sentence ends". `heard`: the audio the model transcribed (the
    /// stretch, after the open line's speech heard again) and its text. `sentenceEndsFailed`: SaT's error, the lines
    /// then end at punctuation only. Nil when no longer `wanted` after a step (checked after each one).
    public func lines(for speech: SpeechStretches.Speech, recognizer: SpeechRecognizer, language: String, growing: Bool,
                      log: (String) -> Void, heard: ([Float], String) -> Void, sentenceEndsFailed: (Error) -> Void,
                      wanted: () -> Bool) async throws -> [Shown]? {
        // The open line's speech, heard again with the stretch (see GrowingLines).
        var earlier = growing ? lines.earlier(before: speech.samples) : nil
        let started = Date()
        var transcript = try await recognizer.transcribe((earlier ?? []) + speech.samples, language: language)
        heard((earlier ?? []) + speech.samples, transcript.text)
        let again = earlier.map { String(format: " (and %.1f s again)", Double($0.count) / SpeechStretches.sampleRate) } ?? ""
        log(String(format: "%.1f s of speech%@ in %.0f ms with %@: %@", speech.duration, again,
                   Date().timeIntervalSince(started) * 1000, recognizer.model.kind.name, transcript.text))
        if earlier != nil, lines.heardWorse(transcript) {
            // Hearing the line again lost some of it: what follows its text, joined to it.
            let unheard = lines.unheard()
            earlier = unheard
            transcript = try await recognizer.transcribe(unheard + speech.samples, language: language)
            log(String(format: "heard worse again; %.1f s after the line's text: %@",
                       Double(unheard.count) / SpeechStretches.sampleRate, transcript.text))
        }
        // Turned off or switched to another model meanwhile.
        guard wanted() else { return nil }
        guard growing else {
            lines.end()
            return Self.sentences(transcript.text, language: language).map { Shown(text: $0, start: speech.start, grows: false) }
        }
        let joined = lines.join(transcript, earlier: earlier, stretchDuration: speech.duration)
        var probabilities: [Float]?
        if !joined.text.isEmpty {
            do {
                probabilities = try await SentenceEnds.shared.probabilities(joined.text)
            } catch {
                sentenceEndsFailed(error)
            }
        }
        guard wanted() else { return nil }
        return lines.add(joined, probabilities: probabilities, stretch: speech.samples, start: speech.start,
                         pause: speech.pause, language: language)
            .map { Shown(text: $0.text, start: $0.start, grows: $0.grows) }
    }

    /// The text's sentences in `language` (see Sentences), trimmed, without empty ones.
    public nonisolated static func sentences(_ text: String, language: String) -> [String] {
        Sentences.ranges(in: text, language: language)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// The stretches of speech waiting to be transcribed while one is, oldest first.
public struct PendingStretches {
    /// Stretches kept waiting; older ones are dropped when transcription can't keep up.
    public static let max = 4

    private var waiting: [SpeechStretches.Speech] = []

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty }

    /// Adds a stretch, and returns the oldest one dropped to make room for it.
    public mutating func add(_ speech: SpeechStretches.Speech) -> SpeechStretches.Speech? {
        waiting.append(speech)
        return waiting.count > Self.max ? waiting.removeFirst() : nil
    }

    public mutating func next() -> SpeechStretches.Speech? {
        waiting.isEmpty ? nil : waiting.removeFirst()
    }

    public mutating func removeAll() {
        waiting.removeAll()
    }
}

/// The audio of the stretches being heard on its way to the model's words as they're heard (LiveTranscription), and
/// the live lines shown, one per stretch ("Show words as they're heard"). The model is given one piece of audio at a
/// time: the audio heard while it works goes to it next in one piece per stretch, in order, so a model that takes
/// longer than the audio does falls behind by a piece at most, and a stretch's last words still come when the next
/// one starts meanwhile.
public struct LiveFeed {
    public struct Piece: Sendable {
        public let stretch: Int
        public fileprivate(set) var samples: [Float]
        /// The model starts a new stretch with it.
        public let starts: Bool
    }

    /// Whether the model is working out words (from `next` until `done`).
    public private(set) var busy = false
    private var waiting: [Piece] = []
    /// The stretch the model hears.
    private var current: Int?
    /// The text shown for each stretch's live line, and the stretches whose live lines are gone (their late words
    /// aren't shown).
    private var shown: [Int: String] = [:]
    private var ended = Set<Int>()

    public init() {}

    /// The stretch's next audio.
    public mutating func heard(_ samples: [Float], stretch: Int) {
        guard !ended.contains(stretch) else { return }
        let starts = stretch != current
        current = stretch
        if let last = waiting.last, last.stretch == stretch {
            waiting[waiting.count - 1].samples += samples
        } else {
            waiting.append(Piece(stretch: stretch, samples: samples, starts: starts))
        }
    }

    /// The audio to give the model next, unless it's working out words; then it's busy until `done`.
    public mutating func next() -> Piece? {
        guard !busy else { return nil }
        // Not for stretches whose lines took the place of their live lines meanwhile.
        waiting.removeAll { ended.contains($0.stretch) }
        guard !waiting.isEmpty else { return nil }
        busy = true
        return waiting.removeFirst()
    }

    public mutating func done() {
        busy = false
    }

    /// The text to show as the stretch's live line, or nil when it's shown already (or its line is gone).
    public mutating func show(_ text: String, stretch: Int) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ended.contains(stretch), !text.isEmpty, shown[stretch] != text else { return nil }
        shown[stretch] = text
        return text
    }

    /// The stretch's live line is gone (or going, with its last line); returns whether it was there.
    @discardableResult
    public mutating func end(_ stretch: Int) -> Bool {
        guard !ended.contains(stretch) else { return false }
        ended.insert(stretch)
        shown[stretch] = nil
        return true
    }

    /// All live lines are gone (the audio's source or model changed).
    public mutating func clear() {
        waiting.removeAll()
        shown.removeAll()
        ended.removeAll()
        current = nil
    }

    /// Another model hears the stretches: the next piece starts a stretch for it.
    public mutating func restart() {
        current = nil
    }
}
