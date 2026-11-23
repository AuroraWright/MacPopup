import AVFoundation
import SoundAnalysis

/// Finds the stretches of speech in a recording, given a buffer at a time, mixed to mono at 16 kHz: in the app
/// (SpeechListener, with the app's audio) and in transcribe-cli replay's simulation of it.
///
/// Apple's sound classifier finds the speech (VoiceDetector, as for Anki Audio), which it tells from music and sound
/// effects. A stretch of speech ends after a pause (`pause`, measured from the loudness, since the classifier can't hear
/// a short breath), or at the quietest moment once it's long: 28 seconds (the models read 30 at most), or 10 without
/// pauses (`pause` 0).
///
/// Not thread-safe: its owner gives it buffers and runs what `deliver` is given one at a time, in order. The classifier's
/// results come while a buffer is analyzed, and are run by `deliver` after it (the app: on the listener's queue).
public final class SpeechStretches: @unchecked Sendable {
    public struct Speech: Sendable {
        /// The stretch's, as in its Live events.
        public let id: Int
        /// Empty when the stretch was too quiet to transcribe but ended the voice.
        public let samples: [Float]
        /// When the samples start (`padding` before the voice, or less), on the owner's clock (see `clock`).
        public let start: Double
        /// Seconds of quiet after it: 0 when it was cut for its length, the pause setting when cut at a pause, infinity
        /// when the voice stopped (the classifier heard no speech).
        public let pause: Double
        public var endsVoice: Bool { pause.isInfinite }
        public var duration: Double { Double(samples.count) / SpeechStretches.sampleRate }
    }

    /// The stretch being heard, as it's heard ("Show words as they're heard").
    public enum Live: Sendable {
        /// The stretch's next audio, 16 kHz mono: from `padding` before its voice, a tenth of a second or more at a time.
        case audio(stretch: Int, samples: [Float])
        /// The stretch ended without being given to be transcribed (too quiet, or too short).
        case dropped(stretch: Int)
    }

    /// A stretch cut from the recording, given once it's placed (`place`): its audio taken from the recording, which the
    /// app converts to 16 kHz mono apart while the next stretch is heard.
    ///
    /// The stretch is taken as the classifier placed it, with `padding`: placing it more finely (VoiceDetector.refine)
    /// cut the first syllables of many lines, more so over music (Bocchi the Rock! episode 2, anime-whisper: 22% of its
    /// subtitles' text missing, 13% without; evals/diarization/bocchi).
    public struct Cut: @unchecked Sendable {
        public enum Placed: Sendable {
            case speech(Speech)
            /// Its live words (if it had any) are gone.
            case dropped(stretch: Int)
        }

        fileprivate enum Content {
            /// No speech to give: only its live words are dropped.
            case nothing
            /// No speech to give, but the voice's end (at this time on the clock) still ends the line.
            case voiceEnd(at: Double)
            /// `all`, the audio after the last stretch and up to this one's end, which starts at `time` on the clock
            /// and `recording` seconds into the recording; its speech between `from` and `to`, in seconds into it. For the
            /// log: the stretch, in seconds into the recording, and what ended it.
            case audio(all: AudioClip, from: Double, to: Double, time: Double, recording: Double, cut: (Double, Double),
                       after: String)
        }

        public let id: Int
        fileprivate let heardLive: Bool
        fileprivate let pause: Double
        fileprivate let content: Content

        /// What the stretch gives, in order.
        public func place(log: (String) -> Void) -> [Placed] {
            func endVoice(at end: Double) -> [Placed] {
                (heardLive ? [.dropped(stretch: id)] : [])
                    + (pause.isInfinite ? [.speech(Speech(id: id, samples: [], start: end, pause: pause))] : [])
            }
            switch content {
            case .nothing:
                return heardLive ? [.dropped(stretch: id)] : []
            case let .voiceEnd(at):
                return endVoice(at: at)
            case let .audio(all, from, to, time, recording, (start, end), after):
                // `all` ends at the stretch's end, so the padding takes no words from the next one either.
                let kept = all.voiceRange(from: from, to: to, padding: SpeechStretches.padding)
                log(String(format: "speech %.2f–%.2f s%@", start, end, after))
                guard let samples = all.slice(from: kept.lowerBound, to: kept.upperBound)
                    .monoSamples(sampleRate: SpeechStretches.sampleRate), !samples.isEmpty else {
                    return endVoice(at: time - recording + end)
                }
                return [.speech(Speech(id: id, samples: samples, start: time + kept.lowerBound, pause: pause))]
            }
        }
    }

    public static let sampleRate = 16000.0
    /// The longest stretch: the models read 30 seconds at most.
    private static let maxLength = 28.0
    /// The longest stretch without pauses (`pause` 0), so that someone talking on still gives lines now and then.
    private static let maxLengthWithoutPauses = 10.0
    /// The shortest stretch ended at a pause, so that a short stop inside a word doesn't make a line of its own.
    private static let minLength = 0.5
    /// The loudness is measured per 20 ms.
    private static let block = 0.02
    /// A pause: this much quieter than the speech of the last 3 seconds (the 75th percentile of its loudness).
    private static let pauseDrop: Float = 15
    /// The least sound louder than a pause that a stretch needs to be transcribed: the end of the classifier's last
    /// stretch with speech is often after the voice, and the models make up words from the near-silence after a pause.
    private static let minVoiced = 0.2
    /// Seconds kept before the voice while waiting for it (the classifier's results come about a second late).
    private static let history = 3.0
    /// Seconds kept around the voice.
    static let padding = 0.2

    /// Seconds; 0: lines don't end at pauses.
    private let pause: Double
    /// Whether the stretch being heard is given as it's heard (`onLive`).
    private let live: Bool
    /// The time on the owner's clock (the app: system uptime), read at the recording's first frame.
    private let clock: () -> Double
    /// Runs a classifier result after the buffer being analyzed.
    private let deliver: (@escaping () -> Void) -> Void
    private let log: (String) -> Void
    /// Each stretch cut, to be placed.
    public var onCut: ((Cut) -> Void)?
    /// The stretch being heard, as it's heard (with `live`).
    public var onLive: ((Live) -> Void)?

    private var format: AVAudioFormat?
    private var detector: VoiceDetector?
    /// The audio kept, from `keptFrom` (frames into the recording).
    private var buffers: [AVAudioPCMBuffer] = []
    private var keptFrom: AVAudioFramePosition = 0
    private var frames: AVAudioFramePosition = 0
    /// The clock's time at the recording's first frame.
    private var clockStart = 0.0
    /// The speech being heard, in seconds into the recording.
    private var voiceStart: Double?
    private var voiceEnd = 0.0
    /// How far the classifier got, in seconds: its results come some time after the audio, so pauses are measured
    /// against them rather than against the audio given to it.
    private var classifiedEnd = 0.0
    /// Seconds into the recording up to which speech was given (classified stretches overlap, so later ones may start
    /// before it).
    private var given = 0.0
    /// The loudness of each 20 ms of the last 30 seconds, in dB, from block `levelsFrom` of the recording, and whether
    /// it was louder than a pause.
    private var levels: [Float] = []
    private var voiced: [Bool] = []
    private var levelsFrom = 0
    /// Each channel's filter, which leaves the voice's frequencies: hiss above it would fill its pauses.
    private var filters: [LowPass] = []
    /// The block being measured: its sum of squares and frames so far.
    private var blockSum: Float = 0
    private var blockFrames = 0
    /// Quiet blocks in a row, up to the last one.
    private var quietBlocks = 0
    private var stopped = false
    /// The id of the stretch being heard.
    private var stretch = 0
    /// For onLive: seconds into the recording up to which the stretch's audio was given, and its converter.
    private var liveGiven: Double?
    private var resampler: StreamResampler?

    public init(pause: Double, live: Bool, clock: @escaping () -> Double, deliver: @escaping (@escaping () -> Void) -> Void,
                log: @escaping (String) -> Void) {
        self.pause = pause
        self.live = live
        self.clock = clock
        self.deliver = deliver
        self.log = log
    }

    /// No more audio.
    public func stop() {
        stopped = true
        detector?.finish()
        detector = nil
        buffers = []
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard !stopped else { return }
        if format == nil {
            format = buffer.format
            clockStart = clock()
            detector = try? VoiceDetector(format: buffer.format) { [weak self] range, isSpeech in
                self?.deliver { self?.classified(range, isSpeech: isSpeech) }
            }
            if detector == nil { log("voice detection unavailable") }
        }
        // Keeps to the first format, in case it changes.
        guard let format, buffer.format == format else { return }
        buffers.append(buffer)
        detector?.analyze(buffer, at: frames)
        frames += AVAudioFramePosition(buffer.frameLength)
        measure(buffer, format: format)
        let seconds = Double(frames) / format.sampleRate
        if let start = voiceStart {
            let longest = pause > 0 ? Self.maxLength : Self.maxLengthWithoutPauses
            if seconds - start >= longest {
                // At the quietest moment of the second half, likely between words.
                let cut = quietest(from: start + longest / 2, to: seconds)
                give(from: start, to: cut, pause: 0)
                voiceStart = cut
            }
        } else {
            // Only the last few seconds while there's no voice.
            let keep = AVAudioFramePosition((seconds - Self.history) * format.sampleRate)
            while let first = buffers.first, keptFrom + AVAudioFramePosition(first.frameLength) < keep {
                keptFrom += AVAudioFramePosition(first.frameLength)
                buffers.removeFirst()
            }
        }
        if let start = voiceStart { giveLive(from: start, to: seconds) }
    }

    /// Gives onLive the stretch's audio up to `end` (seconds into the recording), from `padding` before its voice
    /// (`start`) at first.
    private func giveLive(from start: Double, to end: Double) {
        guard live, let format else { return }
        let offset = Double(keptFrom) / format.sampleRate
        if liveGiven == nil {
            liveGiven = max(given, start - Self.padding, offset)
            resampler = StreamResampler(from: format, to: Self.sampleRate)
        }
        guard let from = liveGiven, end - from >= 0.1, let resampler else { return }
        liveGiven = end
        let samples = resampler.convert(AudioClip(format: format, buffers: buffers).slice(from: from - offset, to: end - offset))
        if !samples.isEmpty { onLive?(.audio(stretch: stretch, samples: samples)) }
    }

    /// Adds the loudness of the buffer's blocks of 20 ms, and ends the speech at a pause.
    private func measure(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let channels = buffer.floatChannelData else { return }
        let size = Int(format.sampleRate * Self.block), count = Int(format.channelCount)
        if filters.isEmpty {
            filters = Array(repeating: LowPass(cutoff: 4000, sampleRate: format.sampleRate), count: count)
        }
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<count {
                let sample = filters[channel](channels[channel][frame])
                blockSum += sample * sample
            }
            blockFrames += 1
            guard blockFrames == size else { continue }
            added(10 * log10(blockSum / Float(size * count) + 1e-10))
            blockSum = 0
            blockFrames = 0
        }
    }

    private func added(_ level: Float) {
        levels.append(level)
        if levels.count > Int(30 / Self.block) {
            levels.removeFirst()
            voiced.removeFirst()
            levelsFrom += 1
        }
        let recent = levels.suffix(Int(3 / Self.block)).sorted()
        let quiet = level < recent[recent.count * 3 / 4] - Self.pauseDrop
        voiced.append(!quiet)
        quietBlocks = quiet ? quietBlocks + 1 : 0
        guard pause > 0, let start = voiceStart, quietBlocks == max(1, Int((pause / Self.block).rounded())) else { return }
        // In the middle of the pause so far: the voice may go on right after.
        let cut = Double(levelsFrom + levels.count) * Self.block - Double(quietBlocks) * Self.block / 2
        guard cut - start >= Self.minLength else { return }
        give(from: start, to: cut, pause: pause)
        voiceStart = cut
    }

    /// The middle of the quietest 0.2 seconds between `start` and `end` (seconds into the recording), or `end`.
    private func quietest(from start: Double, to end: Double) -> Double {
        let span = 10
        let first = max(0, Int(start / Self.block) - levelsFrom), last = min(levels.count, Int(end / Self.block) - levelsFrom)
        guard last - first >= span else { return end }
        var best = first, bestSum = Float.infinity
        for index in first...(last - span) {
            let sum = levels[index..<index + span].reduce(0, +)
            if sum < bestSum { (best, bestSum) = (index, sum) }
        }
        return Double(levelsFrom + best + span / 2) * Self.block
    }

    /// Lets the audio before `end` (seconds into the recording) go.
    private func dropAudio(before end: Double) {
        guard let format else { return }
        let keep = AVAudioFramePosition(end * format.sampleRate)
        while let first = buffers.first, keptFrom + AVAudioFramePosition(first.frameLength) <= keep {
            keptFrom += AVAudioFramePosition(first.frameLength)
            buffers.removeFirst()
        }
    }

    /// A stretch of the recording was classified (they overlap, in order).
    private func classified(_ range: CMTimeRange, isSpeech: Bool) {
        guard !stopped else { return }
        classifiedEnd = max(classifiedEnd, range.end.seconds)
        if isSpeech {
            if voiceStart == nil { voiceStart = max(range.start.seconds, given) }
            voiceEnd = max(voiceEnd, range.end.seconds)
        } else if let start = voiceStart, classifiedEnd - voiceEnd >= pause {
            give(from: start, to: voiceEnd, pause: .infinity)
        }
    }

    /// Cuts the speech between `start` and `end` (seconds into the recording), to be placed, and lets the audio before
    /// `end` go. `pause`: as Speech's.
    private func give(from start: Double, to end: Double, pause: Double) {
        let after = pause.isInfinite ? ", voice ended" : pause > 0 ? String(format: ", %.2f s pause", pause) : ""
        voiceStart = nil
        // The next stretch is heard from here.
        let id = stretch, heardLive = liveGiven != nil
        stretch += 1
        liveGiven = nil
        resampler = nil
        func cut(_ content: Cut.Content) { onCut?(Cut(id: id, heardLive: heardLive, pause: pause, content: content)) }
        guard let format else { return cut(.nothing) }
        // The classifier's end (a second late, a quarter of a second at a time) is often before a pause's cut.
        guard end > start else { return cut(.voiceEnd(at: clockStart + start)) }
        let previous = given
        given = end
        let offset = Double(keptFrom) / format.sampleRate
        let first = max(0, Int(start / Self.block) - levelsFrom), last = min(voiced.count, Int(end / Self.block) - levelsFrom)
        let sound = first < last ? voiced[first..<last].count(where: { $0 }) : 0
        guard Double(sound) * Self.block >= Self.minVoiced else {
            log(String(format: "speech %.2f–%.2f s, too quiet%@", start, end, after))
            dropAudio(before: end)
            return cut(.voiceEnd(at: clockStart + end))
        }
        // Only the audio after the last stretch and up to this one's end, so that the padding takes no words from
        // either side of a pause.
        let base = max(0, previous - offset)
        let all = AudioClip(format: format, buffers: buffers).slice(from: base, to: end - offset)
        dropAudio(before: end)
        let from = max(0, start - offset - base), to = min(all.duration, end - offset - base)
        cut(.audio(all: all, from: from, to: to, time: clockStart + offset + base, recording: offset + base, cut: (start, end),
                   after: after))
    }
}
