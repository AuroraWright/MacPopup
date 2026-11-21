import AVFoundation
import OCREngines
import Transcription

/// Settings → Floating Window → "Read text from audio": the speech of the captured window's app (or of every app but
/// MacPopup without one) transcribed, a sentence per line in the text box.
///
/// The stretches of speech (SpeechStretches, ending at the pause set in transcriptionPause) are transcribed with the
/// model chosen in Settings → Transcription, a stretch at a time and in order, into the box's lines (StretchLines: its
/// sentences, or with "End lines at sentence ends" a line that grows with the next stretch while its sentence goes on).
/// With "Show words as they're heard", the model's words for the stretch being heard are shown as they come
/// (LiveTranscription, LiveFeed), as a live line that its text then replaces.
///
/// transcribe-cli replay simulates it on a recording, with the same parts: what it does here with them it does too.
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
    /// Stretches of speech waiting to be transcribed.
    private var pending = PendingStretches()
    private var transcribing = false
    /// The last error shown, so that it's shown once rather than for each stretch.
    private var shownError: String?
    /// SaT's error was shown: lines end at punctuation only until "End lines at sentence ends" is turned on again.
    private var sentenceEndsFailed = false
    /// MACPOPUP_TEST_TRANSCRIPTION_FILE: a sound file played in place of the app's audio (for test runs).
    private let testFile = DevelopmentEnvironment["MACPOPUP_TEST_TRANSCRIPTION_FILE"]

    /// The box's lines from the stretches, on the clock of system uptime.
    private let lines = StretchLines()
    /// The open line can't go on past the stretches transcribed so far: speech was dropped, or the audio's source or
    /// model changed. It's ended before the next stretch, not while one is being transcribed (which goes on from it).
    private var linesBroken = false
    /// The model's words as they're heard (for "Show words as they're heard"), for the language it was asked for (nil
    /// when not wanted, or nil from models that don't give them).
    private var live: (any LiveTranscription)?
    private var liveLanguage: String?
    /// Why `live` couldn't be had last time, logged once.
    private var liveError: String?
    /// The audio on its way to `live`, and its live lines.
    private var liveFeed = LiveFeed()
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
                    self.liveFeed.restart()
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
        let onLive: ((SpeechStretches.Live) -> Void)? = source.live ? { [weak self] event in
            Task { @MainActor in self?.heardLive(event, generation: generation) }
        } : nil
        let listener = SpeechListener(pause: source.pause, onSpeech: { [weak self] speech in
            // Not from a listener stopped meanwhile (stretches are placed after it's stopped).
            guard let self, self.listenerGeneration == generation else { return }
            self.heard(speech)
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

    private func heard(_ speech: SpeechStretches.Speech) {
        guard model != nil else { return }
        if let dropped = pending.add(speech) {
            endLiveLine(dropped.id)
            // The line can't go on past the missing speech.
            linesBroken = true
            transcriptionLog("transcription is behind: dropped a stretch of speech")
        }
        transcribeNext()
    }

    private func transcribeNext() {
        guard !transcribing, let model, let speech = pending.next() else { return }
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
        let language = settings["language"] as? String ?? "ja"
        let recognizer = SpeechRecognizer.shared(model)
        let growing = findsSentenceEnds
        let listener = listenerGeneration
        transcribing = true
        Task {
            // Its live line goes with its last line (see show), or else once it's done.
            var liveReplaced = false
            defer {
                if !liveReplaced { endLiveLine(speech.id) }
                transcribing = false
                transcribeNext()
            }
            let shown: [StretchLines.Shown]
            do {
                guard let lines = try await lines.lines(
                    for: speech, recognizer: recognizer, language: language, growing: growing, log: transcriptionLog,
                    heard: { SpeechDebug.shared?.line(listener: listener, stretch: speech.id, samples: $0, text: $1) },
                    sentenceEndsFailed: { self.reportSentenceEnds($0) }, wanted: { self.model == model }
                ) else { return }
                shown = lines
            } catch {
                if self.model == model { unavailable = true }
                report(error)
                return
            }
            shownError = nil
            unavailable = false
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
        if let endsLive { liveFeed.end(endsLive) }
        overlay.evaluate("window.__macpopupTranscript?.(\(json), \(age), \(grows), \(endsLive.map(String.init) ?? "null"))")
        return true
    }

    /// A string as JavaScript.
    private static func json(_ text: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { "\($0)[0]" }
    }

    /// The stretch being heard, as it's heard: its audio goes to the model, its words to its live line.
    private func heardLive(_ event: SpeechStretches.Live, generation: Int) {
        guard generation == listenerGeneration, let live else { return }
        switch event {
        case let .audio(stretch, samples):
            liveFeed.heard(samples, stretch: stretch)
            hearLive(live)
        case let .dropped(stretch):
            endLiveLine(stretch)
        }
    }

    /// Gives `live` the audio waiting, unless it's working out words: then once it's done.
    private func hearLive(_ live: any LiveTranscription) {
        guard let piece = liveFeed.next() else { return }
        let generation = liveGeneration, listener = listenerGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            if piece.starts { live.start() }
            let started = ProcessInfo.processInfo.systemUptime
            let text = try? await live.accept(piece.samples)
            SpeechDebug.shared?.live(listener: listener, stretch: piece.stretch, samples: piece.samples, text: text,
                                     ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            await self?.heardLive(text, from: live, stretch: piece.stretch, generation: generation)
        }
    }

    private func heardLive(_ text: String?, from live: any LiveTranscription, stretch: Int, generation: Int) {
        liveFeed.done()
        if let text { showLive(text, stretch: stretch, generation: generation) }
        // Not if it was let go meanwhile.
        if let current = self.live, current === live { hearLive(live) }
    }

    private func showLive(_ text: String, stretch: Int, generation: Int) {
        guard generation == liveGeneration, live != nil, let text = liveFeed.show(text, stretch: stretch),
              let json = Self.json(text) else { return }
        overlay.evaluate("window.__macpopupLive?.(\(stretch), \(json))")
    }

    /// Removes the stretch's live line, if it has one.
    private func endLiveLine(_ stretch: Int) {
        guard liveFeed.end(stretch) else { return }
        overlay.evaluate("window.__macpopupLive?.(\(stretch), null)")
    }

    /// Removes all live lines: the audio's source or model changed.
    private func endLiveLines() {
        liveGeneration += 1
        liveFeed.clear()
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
}

func transcriptionLog(_ message: String) {
    FileHandle.standardError.write("[transcription] \(message)\n".data(using: .utf8)!)
    Task { @MainActor in DebugLog.note("transcription: \(message)") }
}

/// Records an app's audio (or plays a sound file in its place, for tests) and gives each stretch of speech in it
/// (SpeechStretches), mixed to mono at 16 kHz. Everything but `start` and `stop` runs on its own queue, and stretches
/// are placed on another one (`placing`), which takes a while for a long one (1.4 s for 21 s), while the next one is
/// heard.
final class SpeechListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aury.macpopup.transcription", qos: .userInitiated)
    /// Where stretches are placed, one at a time.
    private let placing = DispatchQueue(label: "com.aury.macpopup.transcription.placing", qos: .userInitiated)
    private let stretches: SpeechStretches
    private var tap: AudioTap?
    private var testTimer: DispatchSourceTimer?

    /// `pause`: seconds, 0: lines don't end at pauses. `onLive` gets the stretch being heard as it's heard, on the
    /// listener's queue; nil: only whole stretches are given.
    init(pause: Double, onSpeech: @escaping @MainActor (SpeechStretches.Speech) -> Void,
         onLive: ((SpeechStretches.Live) -> Void)? = nil) {
        let queue = queue, placing = placing
        stretches = SpeechStretches(pause: pause, live: onLive != nil, clock: { ProcessInfo.processInfo.systemUptime },
                                    deliver: { queue.async(execute: $0) }, log: transcriptionLog)
        stretches.onLive = onLive
        stretches.onCut = { cut in
            // After the stretches before it.
            placing.async {
                for placed in cut.place(log: transcriptionLog) {
                    switch placed {
                    case let .speech(speech): Task { @MainActor in onSpeech(speech) }
                    case let .dropped(stretch): onLive?(.dropped(stretch: stretch))
                    }
                }
            }
        }
    }

    func start(_ processes: AudioTap.Processes) throws {
        let tap = AudioTap(processes: processes, queue: queue) { [weak self] buffer in self?.stretches.append(buffer) }
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
            stretches.append(buffer)
        }
        testTimer = timer
        timer.resume()
    }

    func stop() {
        queue.async { [self] in
            tap?.stop()
            tap = nil
            testTimer?.cancel()
            testTimer = nil
            stretches.stop()
        }
    }
}
