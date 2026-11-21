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
/// next stretch while its sentence goes on (GrowingLines). With "Show words as they're heard", the model's words for the
/// stretch being heard are shown as they come (LiveTranscription), as a live line that its text then replaces.
@MainActor
final class AudioTranscriber {
    private struct Source: Equatable {
        var processes: AudioTap.Processes?
        var pause: Double
        /// "Show words as they're heard".
        var live: Bool
    }

    private let overlay: OverlayController
    private var listener: SpeechListener?
    private var source: Source?
    private var model: SpeechModel?
    /// Settings → General → language, as the model was last loaded for.
    private var language: String?
    /// Stretches of speech waiting to be transcribed, oldest first.
    private var pending: [SpeechListener.Speech] = []
    private var transcribing = false
    /// The last error shown, so that it's shown once rather than for each stretch.
    private var shownError: String?
    /// SaT's error was shown: lines end at punctuation only until "End lines at sentence ends" is turned on again.
    private var sentenceEndsFailed = false
    /// MACPOPUP_TEST_TRANSCRIPTION_FILE: a sound file played in place of the app's audio (for test runs).
    private let testFile = DevelopmentEnvironment["MACPOPUP_TEST_TRANSCRIPTION_FILE"]

    /// Stretches kept waiting while one is transcribed; older ones are dropped when transcription can't keep up.
    private static let maxPending = 4
    /// The lines while "End lines at sentence ends" is on, on the clock of system uptime.
    private var lines = GrowingLines()
    /// The open line can't go on past the stretches transcribed so far: speech was dropped, or the audio's source or
    /// model changed. It's ended before the next stretch, not while one is being transcribed (which goes on from it).
    private var linesBroken = false
    /// The model's words as they're heard (for "Show words as they're heard"), for the language it was asked for (nil
    /// when not wanted, or nil from models that don't give them).
    private var live: (any LiveTranscription)?
    private var liveLanguage: String?
    /// Why `live` couldn't be had last time, logged once.
    private var liveError: String?
    /// Whether `live` is working out words, and the audio heard meanwhile, given to it next in one piece: a model
    /// that takes longer than the audio does falls behind by a piece at most.
    private var liveBusy = false
    private var liveWaiting: (stretch: Int, samples: [Float], starts: Bool)?
    /// The stretch `live` hears, the text shown for each stretch's live line, and the stretches whose live lines are
    /// gone (their late words aren't shown).
    private var liveStretch: Int?
    private var liveShown: [Int: String] = [:]
    private var liveEnded = Set<Int>()
    /// Counts the listeners, so that a stopped one's audio isn't heard, and the times the live lines were all removed,
    /// so that words worked out before then aren't shown.
    private var listenerGeneration = 0, liveGeneration = 0

    init(overlay: OverlayController) {
        self.overlay = overlay
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        NotificationCenter.default.addObserver(forName: ModelsLoading.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showLoading() }
        }
        // The live words come from the new models (or none).
        NotificationCenter.default.addObserver(forName: SpeechRecognizer.modelsChanged, object: nil, queue: .main) { [weak self] note in
            let model = note.object as? SpeechModel
            MainActor.assumeIsolated {
                guard let self, model == self.model else { return }
                // Loaded again (see applySettings), with its live words.
                self.language = nil
                self.live = nil
                self.liveLanguage = nil
                self.applySettings()
            }
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

    /// The model chosen couldn't be loaded (its last load or transcription failed), shown on the box's audio button.
    private var unavailable = false {
        didSet { if unavailable != oldValue { showUnavailable() } }
    }

    private func showUnavailable() {
        overlay.evaluate("window.__macpopupAudioUnavailable?.(\(unavailable))")
    }

    /// The box's page (re)loaded.
    func pageReady() {
        showLoading()
        showUnavailable()
    }

    private func applySettings() {
        let enabled = settings["floatingWindowAudio"] as? Bool ?? false
        let model = enabled ? SpeechModel(rawValue: settings["transcriptionModel"] as? String ?? "") ?? .kitsune : nil
        let language = settings["language"] as? String ?? "ja"
        let modelChanged = model != self.model
        if modelChanged {
            if let old = self.model {
                let recognizer = SpeechRecognizer.shared(old)
                Task { await recognizer.unload() }
            }
            self.model = model
            shownError = nil
            unavailable = false
            pending.removeAll()
            linesBroken = true
            live = nil
            liveLanguage = nil
            endLiveLines()
        }
        // Now, so the first line isn't late (the first time, Core ML takes long to prepare a model), and again for
        // another language (Live Caption has a pack per language).
        if let model, modelChanged || language != self.language {
            let recognizer = SpeechRecognizer.shared(model)
            Task {
                do {
                    let started = Date()
                    try await recognizer.load(language: language)
                    transcriptionLog(String(format: "%@ loaded in %.1f s", model.kind.name, Date().timeIntervalSince(started)))
                    if self.model == model { self.unavailable = false }
                } catch {
                    if self.model == model { self.unavailable = true }
                    self.report(error)
                }
            }
        }
        self.language = model == nil ? nil : language
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
        let wantsLive = enabled && settings["transcriptionLive"] as? Bool == true
        if let model, wantsLive, language != liveLanguage {
            liveLanguage = language
            live = nil
            let recognizer = SpeechRecognizer.shared(model)
            Task {
                do {
                    let live = try await recognizer.live(language: language)
                    // Still wanted for this model and language.
                    guard self.model == model, self.liveLanguage == language else { return }
                    self.live = live
                    self.liveStretch = nil
                    self.liveError = nil
                    // The model loaded for it.
                    self.unavailable = false
                    if live != nil { transcriptionLog("\(model.kind.name) gives words as they're heard") }
                } catch {
                    // Tried again with the settings (at least every 5 seconds), e.g. once the models are loaded. The
                    // stretches' transcription shows the error.
                    if self.liveLanguage == language { self.liveLanguage = nil }
                    if error.localizedDescription != self.liveError {
                        transcriptionLog("no words as they're heard yet: \(error.localizedDescription)")
                    }
                    self.liveError = error.localizedDescription
                }
            }
        } else if !wantsLive {
            live = nil
            liveLanguage = nil
        }
        let source = enabled ? Source(processes: processes(), pause: Double(settings["transcriptionPause"] as? NSNumber ?? 1000) / 1000,
                                      live: wantsLive) : nil
        guard source != self.source else { return }
        self.source = source
        // The stretches waiting are of the old source's audio, and the open line can't go on with the new one's.
        pending.removeAll()
        linesBroken = true
        endLiveLines()
        listener?.stop()
        listener = nil
        guard let source, source.processes != nil || testFile != nil else { return }
        listenerGeneration += 1
        let generation = listenerGeneration
        let onLive: ((SpeechListener.Live) -> Void)? = source.live ? { [weak self] event in
            Task { @MainActor in self?.heardLive(event, generation: generation) }
        } : nil
        let listener = SpeechListener(pause: source.pause, onSpeech: { [weak self] speech in
            self?.heard(speech)
        }, onLive: onLive)
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
            endLiveLine(pending.removeFirst().id)
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
            endLiveLine(speech.id)
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
            // Its live line goes with its last line (see show), or else once it's done.
            var liveReplaced = false
            defer {
                if !liveReplaced { endLiveLine(speech.id) }
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
                if self.model == model { unavailable = true }
                report(error)
                return
            }
            // Turned off or switched to another model meanwhile.
            guard self.model == model else { return }
            shownError = nil
            unavailable = false
            guard growing else {
                lines.end()
                let sentences = Self.sentences(transcript.text, language: language)
                for (index, sentence) in sentences.enumerated() {
                    let last = index == sentences.count - 1
                    liveReplaced = show(sentence, start: speech.start, grows: false, endsLive: last ? speech.id : nil) && last
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
            let shown = lines.add(joined, probabilities: probabilities, stretch: speech.samples, start: speech.start,
                                  pause: speech.pause, language: language)
            for (index, line) in shown.enumerated() {
                let last = index == shown.count - 1
                liveReplaced = show(line.text, start: line.start, grows: line.grows, endsLive: last ? speech.id : nil) && last
            }
        }
    }

    /// Adds a line to the text box, or replaces its last line with the text when it `grows`; `endsLive`: the stretch
    /// whose live line it takes the place of. Returns whether there was text to show.
    @discardableResult
    private func show(_ text: String, start: Double, grows: Bool, endsLive: Int? = nil) -> Bool {
        guard !text.isEmpty, let json = Self.json(text) else { return false }
        let age = ProcessInfo.processInfo.systemUptime - start
        if let endsLive { liveEnded(endsLive) }
        overlay.evaluate("window.__macpopupTranscript?.(\(json), \(age), \(grows), \(endsLive.map(String.init) ?? "null"))")
        return true
    }

    /// A string as JavaScript.
    private static func json(_ text: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { "\($0)[0]" }
    }

    /// The stretch being heard, as it's heard: its audio goes to the model, its words to its live line.
    private func heardLive(_ event: SpeechListener.Live, generation: Int) {
        guard generation == listenerGeneration, let live else { return }
        switch event {
        case let .audio(stretch, samples):
            guard !liveEnded.contains(stretch) else { return }
            let starts = stretch != liveStretch
            liveStretch = stretch
            if let waiting = liveWaiting, waiting.stretch == stretch {
                liveWaiting = (stretch, waiting.samples + samples, waiting.starts || starts)
            } else {
                liveWaiting = (stretch, samples, starts)
            }
            hearLive(live)
        case let .dropped(stretch):
            endLiveLine(stretch)
        }
    }

    /// Gives `live` the audio waiting, unless it's working out words: then once it's done.
    private func hearLive(_ live: any LiveTranscription) {
        guard !liveBusy, let (stretch, samples, starts) = liveWaiting else { return }
        liveWaiting = nil
        liveBusy = true
        let generation = liveGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            if starts { live.start() }
            let text = try? await live.accept(samples)
            await self?.heardLive(text, from: live, stretch: stretch, generation: generation)
        }
    }

    private func heardLive(_ text: String?, from live: any LiveTranscription, stretch: Int, generation: Int) {
        liveBusy = false
        if let text { showLive(text, stretch: stretch, generation: generation) }
        // Not if it was let go meanwhile.
        if let current = self.live, current === live { hearLive(live) }
    }

    private func showLive(_ text: String, stretch: Int, generation: Int) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard generation == liveGeneration, live != nil, !liveEnded.contains(stretch), !text.isEmpty,
              liveShown[stretch] != text, let json = Self.json(text) else { return }
        liveShown[stretch] = text
        overlay.evaluate("window.__macpopupLive?.(\(stretch), \(json))")
    }

    /// The stretch's live line is gone (or going, with its last line): its late words aren't shown.
    private func liveEnded(_ stretch: Int) {
        liveEnded.insert(stretch)
        liveShown[stretch] = nil
    }

    /// Removes the stretch's live line, if it has one.
    private func endLiveLine(_ stretch: Int) {
        guard !liveEnded.contains(stretch) else { return }
        liveEnded(stretch)
        overlay.evaluate("window.__macpopupLive?.(\(stretch), null)")
    }

    /// Removes all live lines: the audio's source or model changed.
    private func endLiveLines() {
        liveGeneration += 1
        liveWaiting = nil
        liveShown.removeAll()
        liveEnded.removeAll()
        liveStretch = nil
        overlay.evaluate("window.__macpopupLiveClear?.()")
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
        /// The stretch's, as in its Live events.
        let id: Int
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

    /// The stretch being heard, as it's heard ("Show words as they're heard").
    enum Live {
        /// The stretch's next audio, 16 kHz mono: from `padding` before its voice, a tenth of a second or more at a time.
        case audio(stretch: Int, samples: [Float])
        /// The stretch ended without being given to be transcribed (too quiet, or too short).
        case dropped(stretch: Int)
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
    /// Gets the stretch being heard as it's heard, on the listener's queue; nil: only whole stretches are given.
    private let onLive: ((Live) -> Void)?
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
    /// The id of the stretch being heard.
    private var stretch = 0
    /// For onLive: seconds into the recording up to which the stretch's audio was given, and its converter.
    private var liveGiven: Double?
    private var resampler: StreamResampler?

    init(pause: Double, onSpeech: @escaping @MainActor (Speech) -> Void, onLive: ((Live) -> Void)? = nil) {
        self.pause = pause
        self.onSpeech = onSpeech
        self.onLive = onLive
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
        if let start = voiceStart { giveLive(from: start, to: seconds) }
    }

    /// Gives onLive the stretch's audio up to `end` (seconds into the recording), from `padding` before its voice
    /// (`start`) at first.
    private func giveLive(from start: Double, to end: Double) {
        guard let onLive, let format else { return }
        let offset = Double(keptFrom) / format.sampleRate
        if liveGiven == nil {
            liveGiven = max(given, start - Self.padding, offset)
            resampler = StreamResampler(from: format, to: Self.sampleRate)
        }
        guard let from = liveGiven, end - from >= 0.1, let resampler else { return }
        liveGiven = end
        let samples = resampler.convert(AudioClip(format: format, buffers: buffers).slice(from: from - offset, to: end - offset))
        if !samples.isEmpty { onLive(.audio(stretch: stretch, samples: samples)) }
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
        // The next stretch is heard from here.
        let id = stretch, heardLive = liveGiven != nil
        stretch += 1
        liveGiven = nil
        resampler = nil
        var transcribed = false
        defer { if heardLive && !transcribed { onLive?(.dropped(stretch: id)) } }
        guard let format else { return }
        // No speech to give, but the voice's end still ends the line.
        func endVoice(at end: Double) {
            guard pause.isInfinite else { return }
            let speech = Speech(id: id, samples: [], start: clockStart + end, pause: pause)
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
        let speech = Speech(id: id, samples: samples, start: clockStart + offset + base + kept.lowerBound, pause: pause)
        transcribed = true
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

/// Converts the pieces of a recording, one after another, to mono at another sample rate, carrying the converter's
/// state from piece to piece so that they join as if converted together.
private final class StreamResampler {
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from format: AVAudioFormat, to sampleRate: Double) {
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono, to: output) else { return nil }
        self.converter = converter
        ratio = sampleRate / format.sampleRate
    }

    func convert(_ clip: AudioClip) -> [Float] {
        guard let mono = clip.monoBuffer(),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(mono.frameLength) * ratio) + 1024)
        else { return [] }
        var given = false
        var error: NSError?
        // No more for now (rather than the end of the stream): the converter keeps what it needs of this piece.
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let samples = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}

extension AudioClip {
    /// The clip mixed to mono and converted to `sampleRate`.
    func monoSamples(sampleRate: Double) -> [Float]? {
        guard let mono = monoBuffer(),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono.format, to: outputFormat) else { return nil }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * sampleRate / format.sampleRate) + 1024
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

    /// The clip mixed to mono, at its sample rate.
    func monoBuffer() -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(frameCount)
        guard frames > 0, let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let target = mono.floatChannelData?[0] else { return nil }
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
        return mono
    }
}
