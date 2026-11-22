import Foundation

/// Lines of speech transcribed a stretch at a time that grow while their sentence goes on, as the Floating Window shows
/// them with "Detect sentence ends" (StretchLines; transcribe-cli replay tries them on recordings). A line
/// ends at sentence-ending punctuation, where SaT (SentenceEnds) finds an end with some text after it, or when the voice
/// stops. For models that tell when each character was heard, the open line's speech is transcribed again with the next
/// stretch after a short pause, and the text replaces the line: with more of the sentence, the model hears it better
/// than a stretch at a time (on talk videos, 10.6% of Kitsune's characters were wrong instead of 14.8%, and sentence
/// ends were found better: F1 0.73 instead of 0.61).
///
/// For each stretch: `earlier(before:)` is the speech to transcribe before it, `join` gives the text to find sentence
/// ends in, and `add` the lines to show.
public struct GrowingLines: Sendable {
    /// SaT's probability from which a sentence ends between stretches, after a short pause and after a long one
    /// (`longPause`: always, as game voice lines a second apart are separate lines), and inside a stretch, where a
    /// lower threshold cuts words and phrases in two. Tuned with transcribe-cli lines on two talk videos (at pauses of
    /// 0, 150 and 200 ms) and game voice lines, against sentence ends marked by hand: the sentence ends found (F1) were
    /// about the same from 0.5 to 0.7 inside a stretch (0.73; 0.70 at 0.4, with more lines cut in two), and from 0.05 to
    /// 0.2 at a short pause.
    public var endAtPause: Float = 0.1
    public var endAtLongPause: Float = 0
    public var endWithoutPause: Float = 0.6
    /// The characters needed after an end SaT finds: with none, it takes the end of any text for a sentence end. Not
    /// after a long pause, where the next stretch's text, however short ("はい"), is what follows.
    public var charactersAfterEnd = 6
    /// The least of the open line's characters (punctuation aside) that hearing it again must give for its text to
    /// replace the line's (see `heardWorse`). Kitsune (and its PyTorch original) sometimes skips seconds of speech in
    /// longer audio, mostly before speech that sounds like it ("大きく分けるとnsaそしてsaというものがあるみたいです" heard
    /// again with "ほんでこのnsaというのは" gave "大きく分けるとんでこのnsaというのは"), which turned lines already shown into
    /// nonsense. In 5 talk videos' replays, about 1 in 9 hearings again lost a fifth of the line or more.
    public var keptWhenHeardAgain = 0.8
    /// The longest a line grows, in seconds of speech (the models read 30 s).
    public static let maxDuration = 30.0
    /// After a pause this long, the next stretch is heard on its own: heard together, game voice lines a second apart
    /// were merged and lost words.
    public static let longPause = 0.5
    public static let sampleRate = 16000.0

    /// A line to show: added, or replacing the last one when it `grows`. `start`: when its speech started, on the
    /// stretches' clock.
    public struct Line: Sendable {
        public let text: String
        public let start: Double
        public let grows: Bool
    }

    /// A stretch's text joined to the open line's (see `join`), to find sentence ends in.
    public struct Joined: Sendable {
        public let transcript: Transcript
        public var text: String { transcript.text }
        /// The open line's speech, when the transcript is of it and the stretch.
        let earlier: JoinedSpeech?
        /// The open line's text.
        let previous: String
        /// Where the stretch's text starts, in characters: where the speaker paused.
        let join: Int
        /// Lines end from here on (not inside text shown before, when it isn't heard again).
        let from: Int
        /// SaT's threshold at `join`.
        let endAtJoin: Float
        /// The speaker paused for `longPause` or more at `join`.
        let afterLongPause: Bool
    }

    /// The last line while it may still grow.
    private struct Open {
        let text: String
        /// When its speech started.
        let start: Double
        /// Seconds of speech.
        let duration: Double
        /// Its speech, to hear again with the next stretch (for models that tell when each character was heard).
        let speech: JoinedSpeech?
        /// The quiet after it.
        let pause: Double
        /// Seconds into `speech` up to which its text was heard.
        var heard = 0.0
        /// `speech` is only what its text doesn't have (see `unheard`): the next transcript is joined to the text.
        var keepsText = false
    }

    private var open: Open?

    public init() {}

    /// Ends the open line: the voice stopped, or speech was missed.
    public mutating func end() {
        open = nil
    }

    /// The open line's speech, to transcribe again before `stretch`, while both fit.
    public func earlier(before stretch: [Float]) -> [Float]? {
        guard let speech = open?.speech, speech.duration + Double(stretch.count) / Self.sampleRate <= Self.maxDuration else { return nil }
        return speech.samples
    }

    /// Whether the transcript of `earlier` (the open line's speech) and a stretch has much less of the line than it
    /// shows (`keptWhenHeardAgain`): then the line keeps its text, and what follows it is transcribed again from
    /// `unheard` (the times around a skip are off, so the transcript can't be cut where the stretch starts).
    public func heardWorse(_ transcript: Transcript) -> Bool {
        guard let open, let speech = open.speech else { return false }
        let join = transcript.times?.firstIndex { $0 >= speech.duration } ?? transcript.text.count
        let spoken = { (text: Substring) in text.count { !$0.isPunctuation && !$0.isWhitespace } }
        return Double(spoken(transcript.text.prefix(join))) < Double(spoken(Substring(open.text))) * keptWhenHeardAgain
    }

    /// The open line's speech after what its text has (the model often leaves out a stretch's last words), to
    /// transcribe with the stretch in place of `earlier`; the transcript is joined to the line's text.
    public mutating func unheard() -> [Float] {
        guard let line = open, let speech = line.speech else { return [] }
        let rest = speech.suffix(from: line.heard)
        open = Open(text: line.text, start: line.start, duration: line.duration, speech: rest, pause: line.pause, keepsText: true)
        return rest.samples
    }

    /// The stretch's transcript (of `earlier` and the stretch) joined to the open line.
    public mutating func join(_ transcript: Transcript, earlier: [Float]?, stretchDuration: Double) -> Joined {
        if earlier == nil, let open, open.speech != nil || open.duration + stretchDuration > Self.maxDuration {
            // Too long to hear again or to grow.
            self.open = nil
        }
        let previous = open?.text ?? ""
        let afterLongPause = open.map { $0.pause >= Self.longPause } ?? false
        let endAtJoin = afterLongPause ? endAtLongPause : endAtPause
        if earlier != nil, open?.keepsText != true {
            let join = transcript.times?.firstIndex { $0 >= open?.speech?.duration ?? 0 } ?? transcript.text.count
            return Joined(transcript: transcript, earlier: open?.speech, previous: previous, join: join, from: 0, endAtJoin: endAtJoin,
                          afterLongPause: afterLongPause)
        }
        guard !previous.isEmpty else {
            return Joined(transcript: transcript, earlier: nil, previous: "", join: 0, from: 0, endAtJoin: endAtJoin,
                          afterLongPause: afterLongPause)
        }
        // The open line's text, heard before the stretch (at time 0 of its speech: the stretch's, or `unheard`'s),
        // then the stretch's.
        var joined = Transcript(text: previous, times: transcript.times.map { _ in Array(repeating: 0, count: previous.count) })
        joined.append(" ", at: 0)
        joined.append(transcript)
        joined = SpeechRecognizer.tidied(joined)
        // Tidying may drop the space between them.
        let from = joined.text.hasPrefix(previous) ? previous.count : 0
        return Joined(transcript: joined, earlier: earlier == nil ? nil : open?.speech, previous: previous, join: from, from: from,
                      endAtJoin: endAtJoin, afterLongPause: afterLongPause)
    }

    /// The lines to show for a stretch heard at `start` (`stretch`: its speech, `pause`: the seconds of quiet after it,
    /// infinity when the voice stopped), with SaT's `probabilities` for the joined text (nil: punctuation only).
    public mutating func add(_ joined: Joined, probabilities: [Float]?, stretch: [Float], start: Double, pause: Double,
                             language: String) -> [Line] {
        defer { if pause.isInfinite { open = nil } }
        let text = joined.text
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        var ends = Set<Int>()
        // Sentence-ending punctuation.
        for range in Sentences.ranges(in: text, language: language).dropLast() {
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            if end >= joined.from { ends.insert(end) }
        }
        for (index, probability) in (probabilities ?? []).enumerated() {
            let end = index + 1
            let after = end == joined.join && joined.afterLongPause ? 1 : charactersAfterEnd
            guard end >= joined.from, characters.count - end >= after else { continue }
            if probability >= (end == joined.join ? joined.endAtJoin : endWithoutPause) { ends.insert(end) }
        }
        var segments: [(text: String, start: Int)] = []
        var segmentStart = 0
        for end in ends.sorted() + [characters.count] where end > segmentStart {
            let segment = String(characters[segmentStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { segments.append((segment, segmentStart)) }
            segmentStart = end
        }
        guard let last = segments.last else { return [] }
        // The speech the transcript is of, to place its characters' times.
        var speech = joined.earlier ?? JoinedSpeech()
        speech.append(stretch, heardAt: start)
        /// Seconds into `speech` where the line from `index` starts: at the quietest moment between when its first
        /// character and the one before were heard (punctuation aside, which the model may write later). The times are
        /// the tokens', and a fixed point between them was often in the middle of a sound, so that a line started with
        /// the end of the word before ("gもプラスして" for "5gもプラスして") or lost its first one.
        func cut(_ index: Int) -> Double? {
            guard let times = joined.transcript.times else { return nil }
            guard index > 0, index < times.count else { return 0 }
            let before = characters[..<index].lastIndex { !$0.isPunctuation && !$0.isWhitespace }.map { times[$0] } ?? 0
            return speech.quietest(from: before, to: times[index])
        }
        let openStart = open?.start ?? start
        var lines: [Line] = []
        for (index, segment) in segments.enumerated() {
            let grows = index == 0 && open != nil
            let lineStart = index == 0 ? openStart : cut(segment.start).map(speech.time) ?? start
            if !grows || segment.text != joined.previous { lines.append(Line(text: segment.text, start: lineStart, grows: grows)) }
        }
        let lastStart = segments.count > 1 ? cut(last.start).map(speech.time) ?? start : openStart
        // Heard again with the next stretch while its speech is all in `speech`: the line stays open even after
        // punctuation (the model often ends a stretch with some, where the audio was cut rather than where the
        // sentence ends).
        if pause < Self.longPause, last.start >= joined.from, let offset = cut(last.start) {
            let rest = speech.suffix(from: offset)
            // Just after its last character (not punctuation, which the model may write later).
            let lastHeard = characters.lastIndex { !$0.isPunctuation && !$0.isWhitespace }
                .flatMap { index in joined.transcript.times.map { $0[index] - offset } } ?? 0
            open = Open(text: last.text, start: lastStart, duration: rest.duration, speech: rest, pause: pause,
                        heard: rest.quietest(from: max(lastHeard, 0), to: min(lastHeard + 0.5, rest.duration)))
        } else if last.text.last?.unicodeScalars.first?.properties.isSentenceTerminal == true {
            open = nil
        } else {
            let duration = (segments.count > 1 ? 0 : open?.duration ?? 0) + Double(stretch.count) / Self.sampleRate
            open = Open(text: last.text, start: lastStart, duration: duration, speech: nil, pause: pause)
        }
        return lines
    }
}

/// Speech joined from stretches heard at different times (without the pauses between them), and when each was heard,
/// to place a moment of the joined speech on the stretches' clock.
public struct JoinedSpeech: Sendable {
    public private(set) var samples: [Float] = []
    /// Each stretch's first sample in `samples`, and when it was heard.
    private var pieces: [(sample: Int, start: Double)] = []

    public init() {}

    public var duration: Double { Double(samples.count) / GrowingLines.sampleRate }

    public mutating func append(_ stretch: [Float], heardAt start: Double) {
        pieces.append((samples.count, start))
        samples += stretch
    }

    /// When the speech `seconds` into the joined speech was heard.
    public func time(at seconds: Double) -> Double {
        let sample = Int(seconds * GrowingLines.sampleRate)
        guard let piece = pieces.last(where: { $0.sample <= sample }) ?? pieces.first else { return seconds }
        return piece.start + Double(sample - piece.sample) / GrowingLines.sampleRate
    }

    /// The middle of the quietest 20 ms between `from` and `to` seconds into the speech.
    public func quietest(from: Double, to: Double) -> Double {
        let start = max(Int(from * GrowingLines.sampleRate), 0), end = min(Int(to * GrowingLines.sampleRate), samples.count)
        return start < end ? Double(Transcription.quietest(samples, in: start..<end, span: 1)) / GrowingLines.sampleRate : to
    }

    /// The speech from `seconds` into it on.
    public func suffix(from seconds: Double) -> JoinedSpeech {
        let cut = min(max(Int(seconds * GrowingLines.sampleRate), 0), samples.count)
        var rest = JoinedSpeech()
        rest.samples = Array(samples[cut...])
        for (index, piece) in pieces.enumerated() {
            let end = index + 1 < pieces.count ? pieces[index + 1].sample : samples.count
            guard end > cut else { continue }
            let from = max(piece.sample, cut)
            rest.pieces.append((from - cut, piece.start + Double(from - piece.sample) / GrowingLines.sampleRate))
        }
        return rest
    }
}
