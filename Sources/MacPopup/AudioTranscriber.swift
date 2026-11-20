import AVFoundation
import OCREngines
import Transcription

/// Settings → Floating Window → "Read text from audio": the speech of the captured window's app (or of every app but
/// MacPopup without one) transcribed, a sentence per line in the text box.
///
/// Apple's sound classifier finds the speech (VoiceDetector, as for Anki Audio), which it tells from music and sound
/// effects. A stretch of speech ends after a pause (transcriptionPause, measured from the loudness, since the classifier
/// can't hear a short breath), or at the quietest moment once it's long: 28 seconds (the models read 30 at most), or 10
/// without pauses (transcriptionPause 0).
/// It's transcribed with the model chosen in Settings → Transcription, a stretch at a time and in order, and the text is
/// split into sentences. With "End lines at sentence ends", as with OCR's lines (ShownLines), a line grows with the
/// next stretch while its sentence goes on (GrowingLines).
@MainActor
final class AudioTranscriber {
    private struct Source: Equatable {
        var processes: AudioTap.Processes?
        var pause: Double
    }

    private let overlay: OverlayController
    private var listener: SpeechListener?
    private var source: Source?
    private var model: SpeechModel?
    /// Stretches of speech waiting to be transcribed, oldest first.
    private var pending: [SpeechListener.Speech] = []
    private var transcribing = false
    /// The last error shown, so that it's shown once rather than for each stretch.
    private var shownError: String?
    /// SaT's error was shown: lines end at punctuation only until "End lines at sentence ends" is turned on again.
    private var sentenceEndsFailed = false
    /// MACPOPUP_TEST_TRANSCRIPTION_FILE: a sound file played in place of the app's audio (for test runs).
    private let testFile = ProcessInfo.processInfo.environment["MACPOPUP_TEST_TRANSCRIPTION_FILE"]

    /// Stretches kept waiting while one is transcribed; older ones are dropped when transcription can't keep up.
    private static let maxPending = 4
    /// The lines while "End lines at sentence ends" is on, on the clock of system uptime.
    private var lines = GrowingLines()
    /// The open line can't go on past the stretches transcribed so far: speech was dropped, or the audio's source or
    /// model changed. It's ended before the next stretch, not while one is being transcribed (which goes on from it).
    private var linesBroken = false

    init(overlay: OverlayController) {
        self.overlay = overlay
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        NotificationCenter.default.addObserver(forName: ModelsLoading.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showLoading() }
        }
        applySettings()
        // Checks again now and then, since the captured window's app may start, quit or open the window later.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    /// Shows on the box's audio button whether a model is loading.
    private func showLoading() {
        overlay.evaluate("window.__macpopupAudioLoading?.(\(ModelsLoading.count > 0))")
    }

    /// The box's page (re)loaded.
    func pageReady() {
        showLoading()
    }

    private func applySettings() {
        let enabled = settings["floatingWindowAudio"] as? Bool ?? false
        let model = enabled ? SpeechModel(rawValue: settings["transcriptionModel"] as? String ?? "") ?? .kitsune : nil
        if model != self.model {
            if let old = self.model {
                let recognizer = SpeechRecognizer.shared(old)
                Task { await recognizer.unload() }
            }
            self.model = model
            shownError = nil
            pending.removeAll()
            linesBroken = true
            if let model {
                // Now, so the first line isn't late (the first time, Core ML takes long to prepare a model).
                let recognizer = SpeechRecognizer.shared(model)
                let language = settings["language"] as? String ?? "ja"
                Task {
                    do {
                        let started = Date()
                        try await recognizer.load(language: language)
                        transcriptionLog(String(format: "%@ loaded in %.1f s", model.kind.name, Date().timeIntervalSince(started)))
                    } catch {
                        self.report(error)
                    }
                }
            }
        }
        let wantsSentenceEnds = enabled && findsSentenceEnds
        if wantsSentenceEnds != self.wantsSentenceEnds {
            self.wantsSentenceEnds = wantsSentenceEnds
            sentenceEndsFailed = false
            if !wantsSentenceEnds { Task { await SentenceEnds.shared.unload() } }
        }
        if wantsSentenceEnds, !satLoading {
            satLoading = true
            Task {
                do {
                    try await SentenceEnds.shared.load()
                } catch {
                    self.reportSentenceEnds(error)
                }
                satLoading = false
            }
        }
        let source = enabled ? Source(processes: processes(), pause: Double(settings["transcriptionPause"] as? NSNumber ?? 1000) / 1000) : nil
        guard source != self.source else { return }
        self.source = source
        // The stretches waiting are of the old source's audio, and the open line can't go on with the new one's.
        pending.removeAll()
        linesBroken = true
        listener?.stop()
        listener = nil
        guard let source, source.processes != nil || testFile != nil else { return }
        let listener = SpeechListener(pause: source.pause) { [weak self] speech in
            self?.heard(speech)
        }
        do {
            if let testFile {
                transcriptionLog("playing \(testFile) in place of app audio")
                try listener.start(testFile: URL(fileURLWithPath: testFile))
            } else if let processes = source.processes {
                transcriptionLog("listening to \(processes)")
                try listener.start(processes)
            }
            self.listener = listener
        } catch {
            transcriptionLog("couldn't record: \(error.localizedDescription)")
            report(error)
        }
    }

    /// The captured window's app, or every app but MacPopup when no window is captured; nil while the captured window
    /// isn't open.
    private func processes() -> AudioTap.Processes? {
        if let saved = settings["ocrWindow"] as? [String: Any], saved["ownerName"] is String {
            return OCRController.savedWindow().map { .app($0.ownerPID) }
        }
        return .allBut(ProcessInfo.processInfo.processIdentifier)
    }

    /// Settings → Transcription → "End lines at sentence ends".
    private var findsSentenceEnds: Bool { settings["transcriptionSentenceEnds"] as? Bool ?? false }
    /// Whether SaT is wanted (audio and "End lines at sentence ends" on), so it's unloaded when it no longer is.
    private var wantsSentenceEnds = false
    private var satLoading = false

    private func heard(_ speech: SpeechListener.Speech) {
        guard model != nil else { return }
        pending.append(speech)
        if pending.count > Self.maxPending {
            pending.removeFirst()
            // The line can't go on past the missing speech.
            linesBroken = true
            transcriptionLog("transcription is behind: dropped a stretch of speech")
        }
        transcribeNext()
    }

    private func transcribeNext() {
        guard !transcribing, let model, !pending.isEmpty else { return }
        if linesBroken {
            lines.end()
            linesBroken = false
        }
        let speech = pending.removeFirst()
        guard !speech.samples.isEmpty else {
            // The voice stopped after a stretch too quiet to transcribe.
            lines.end()
            transcribeNext()
            return
        }
        let language = settings["language"] as? String ?? "ja"
        let recognizer = SpeechRecognizer.shared(model)
        let growing = findsSentenceEnds
        // The open line's speech, heard again with the stretch (see GrowingLines).
        var earlier = growing ? lines.earlier(before: speech.samples) : nil
        transcribing = true
        Task {
            defer {
                transcribing = false
                transcribeNext()
            }
            let started = Date()
            var transcript: Transcript
            do {
                transcript = try await recognizer.transcribe((earlier ?? []) + speech.samples, language: language)
                let again = earlier.map { String(format: " (and %.1f s again)", Double($0.count) / SpeechListener.sampleRate) } ?? ""
                transcriptionLog(String(format: "%.1f s of speech%@ in %.0f ms with %@: %@", speech.duration, again,
                                        Date().timeIntervalSince(started) * 1000, model.kind.name, transcript.text))
                if earlier != nil, lines.heardWorse(transcript) {
                    // Hearing the line again lost some of it: what follows its text, joined to it.
                    let unheard = lines.unheard()
                    earlier = unheard
                    transcript = try await recognizer.transcribe(unheard + speech.samples, language: language)
                    transcriptionLog(String(format: "heard worse again; %.1f s after the line's text: %@",
                                            Double(unheard.count) / SpeechListener.sampleRate, transcript.text))
                }
            } catch {
                report(error)
                return
            }
            // Turned off or switched to another model meanwhile.
            guard self.model == model else { return }
            shownError = nil
            guard growing else {
                lines.end()
                for sentence in Self.sentences(transcript.text, language: language) {
                    show(sentence, start: speech.start, grows: false)
                }
                return
            }
            let joined = lines.join(transcript, earlier: earlier, stretchDuration: speech.duration)
            var probabilities: [Float]?
            if !joined.text.isEmpty {
                do {
                    probabilities = try await SentenceEnds.shared.probabilities(joined.text)
                } catch {
                    reportSentenceEnds(error)
                }
            }
            guard self.model == model else { return }
            for line in lines.add(joined, probabilities: probabilities, stretch: speech.samples, start: speech.start,
                                  pause: speech.pause, language: language) {
                show(line.text, start: line.start, grows: line.grows)
            }
        }
    }

    /// Adds a line to the text box, or replaces its last line with the text when it `grows`.
    private func show(_ text: String, start: Double, grows: Bool) {
        guard !text.isEmpty, let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return }
        let age = ProcessInfo.processInfo.systemUptime - start
        overlay.evaluate("window.__macpopupTranscript?.(\(json)[0], \(age), \(grows))")
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        guard message != shownError, model != nil else { return }
        shownError = message
        overlay.showToast(message)
    }

    /// SaT's error, shown once (a transcription clears `shownError`): lines then end at punctuation only.
    private func reportSentenceEnds(_ error: Error) {
        guard !sentenceEndsFailed else { return }
        sentenceEndsFailed = true
        report(error)
    }

    /// The text's sentences in `language` (see Sentences), trimmed, without empty ones.
    nonisolated static func sentences(_ text: String, language: String) -> [String] {
        Sentences.ranges(in: text, language: language)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

func transcriptionLog(_ message: String) {
    FileHandle.standardError.write("[transcription] \(message)\n".data(using: .utf8)!)
    Task { @MainActor in DebugLog.note("transcription: \(message)") }
}

/// Records an app's audio (or plays a sound file in its place, for tests) and gives each stretch of speech in it,
/// mixed to mono at 16 kHz. Everything but `start` and `stop` runs on its own queue.
final class SpeechListener: @unchecked Sendable {
    struct Speech {
        /// Empty when the stretch was too quiet to transcribe but ended the voice.
        let samples: [Float]
        /// When the samples start (`padding` before the voice, or less), in seconds of system uptime.
        let start: Double
        /// Seconds of quiet after it: 0 when it was cut for its length, the pause setting when cut at a pause, infinity
        /// when the voice stopped (the classifier heard no speech).
        let pause: Double
        var endsVoice: Bool { pause.isInfinite }
        var duration: Double { Double(samples.count) / SpeechListener.sampleRate }
    }

    static let sampleRate = 16000.0
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
    private static let padding = 0.2

    /// Seconds; 0: lines don't end at pauses.
    private let pause: Double
    private let onSpeech: @MainActor (Speech) -> Void
    private let queue = DispatchQueue(label: "com.aury.macpopup.transcription", qos: .userInitiated)
    private var tap: AudioTap?
    private var testTimer: DispatchSourceTimer?
    private var format: AVAudioFormat?
    private var detector: VoiceDetector?
    /// The audio kept, from `keptFrom` (frames into the recording).
    private var buffers: [AVAudioPCMBuffer] = []
    private var keptFrom: AVAudioFramePosition = 0
    private var frames: AVAudioFramePosition = 0
    /// The system uptime at the recording's first frame.
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

    init(pause: Double, onSpeech: @escaping @MainActor (Speech) -> Void) {
        self.pause = pause
        self.onSpeech = onSpeech
    }

    func start(_ processes: AudioTap.Processes) throws {
        let tap = AudioTap(processes: processes, queue: queue) { [weak self] buffer in self?.append(buffer) }
        try tap.start()
        self.tap = tap
    }

    /// Plays a sound file in place of the app's audio, in real time.
    func start(testFile url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
            if (try? file.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0 {
                // Silence after the end, so the last voice ends too.
                buffer.frameLength = chunk
                for channel in 0..<Int(buffer.format.channelCount) {
                    buffer.floatChannelData?[channel].update(repeating: 0, count: Int(chunk))
                }
            }
            append(buffer)
        }
        testTimer = timer
        timer.resume()
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            tap?.stop()
            tap = nil
            testTimer?.cancel()
            testTimer = nil
            detector?.finish()
            detector = nil
            buffers = []
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard !stopped else { return }
        if format == nil {
            format = buffer.format
            clockStart = ProcessInfo.processInfo.systemUptime
            detector = try? VoiceDetector(format: buffer.format) { [weak self] range, isSpeech in
                self?.queue.async { self?.classified(range, isSpeech: isSpeech) }
            }
            if detector == nil { transcriptionLog("voice detection unavailable") }
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

    /// Gives the speech between `start` and `end` (seconds into the recording), placed more finely, and lets the audio
    /// before `end` go. `pause`: as Speech's.
    private func give(from start: Double, to end: Double, pause: Double) {
        let after = pause.isInfinite ? ", voice ended" : pause > 0 ? String(format: ", %.2f s pause", pause) : ""
        voiceStart = nil
        guard let format else { return }
        // No speech to give, but the voice's end still ends the line.
        func endVoice(at end: Double) {
            guard pause.isInfinite else { return }
            let speech = Speech(samples: [], start: clockStart + end, pause: pause)
            Task { @MainActor in onSpeech(speech) }
        }
        // The classifier's end (a second late, a quarter of a second at a time) is often before a pause's cut.
        guard end > start else { return endVoice(at: start) }
        let previous = given
        given = end
        let offset = Double(keptFrom) / format.sampleRate
        let first = max(0, Int(start / Self.block) - levelsFrom), last = min(voiced.count, Int(end / Self.block) - levelsFrom)
        let sound = first < last ? voiced[first..<last].count(where: { $0 }) : 0
        guard Double(sound) * Self.block >= Self.minVoiced else {
            transcriptionLog(String(format: "speech %.2f–%.2f s, too quiet%@", start, end, after))
            dropAudio(before: end)
            return endVoice(at: end)
        }
        // Only the audio after the last stretch and up to this one's end, so that the padding takes no words from
        // either side of a pause.
        let base = max(0, previous - offset)
        let all = AudioClip(format: format, buffers: buffers).slice(from: base, to: end - offset)
        let from = max(0, start - offset - base), to = min(all.duration, end - offset - base)
        // Within the stretch (one cut at the longest length goes on in the next), and the coarse one when the fine one
        // is empty.
        let range = VoiceDetector.refine(all, start: from, end: to)
            .map { (max($0.0, from), min($0.1, to)) }
            .flatMap { $0.1 - $0.0 >= 0.1 ? $0 : nil } ?? (from, to)
        let kept = all.voiceRange(from: range.0, to: range.1, padding: Self.padding)
        let clip = all.slice(from: kept.lowerBound, to: kept.upperBound)
        transcriptionLog(String(format: "speech %.2f–%.2f s, finely %.2f–%.2f s%@", start, end, offset + base + range.0,
                                offset + base + range.1, after))
        dropAudio(before: end)
        guard let samples = clip.monoSamples(sampleRate: Self.sampleRate), !samples.isEmpty else { return endVoice(at: end) }
        let speech = Speech(samples: samples, start: clockStart + offset + base + kept.lowerBound, pause: pause)
        Task { @MainActor in onSpeech(speech) }
    }
}

/// A second-order low-pass filter (RBJ's, Q 0.707).
private struct LowPass {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(cutoff: Double, sampleRate: Double) {
        let w = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate, alpha = sin(w) / (2 * 0.7071), a0 = 1 + alpha
        b1 = Float((1 - cos(w)) / a0)
        b0 = b1 / 2
        b2 = b1 / 2
        a1 = Float(-2 * cos(w) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func callAsFunction(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}

extension AudioClip {
    /// The clip mixed to mono and converted to `sampleRate`.
    func monoSamples(sampleRate: Double) -> [Float]? {
        let frames = AVAudioFrameCount(frameCount)
        guard frames > 0, let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let target = mono.floatChannelData?[0],
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: monoFormat, to: outputFormat) else { return nil }
        var position = 0
        for buffer in buffers {
            guard let source = buffer.floatChannelData else { continue }
            let length = Int(buffer.frameLength), channels = Int(format.channelCount)
            for frame in 0..<length {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[channel][frame] }
                target[position + frame] = sum / Float(channels)
            }
            position += length
        }
        mono.frameLength = frames
        let capacity = AVAudioFrameCount(Double(frames) * sampleRate / format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let samples = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}
