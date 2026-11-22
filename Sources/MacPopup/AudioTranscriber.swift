import AVFoundation
import OCREngines
import Transcription

/// Settings → Floating Window → "Read text from audio": the speech of the captured window's app (or of every app but
/// MacPopup without one) transcribed, a sentence per line in the text box.
///
/// The stretches of speech (SpeechStretches, ending at the pause set in transcriptionPause) are transcribed with the
/// model chosen in Settings → Transcription, a stretch at a time and in order, into the box's lines (StretchLines: its
/// sentences, or with "Detect sentence ends" a line that grows with the next stretch while its sentence goes on).
/// With "Show words as they're heard", the model's words for the stretch being heard are shown as they come
/// (LiveTranscription, LiveFeed), as a live line that its text then replaces.
///
/// StretchTranscriber does that, as transcribe-cli replay's simulation does on a recording; this gives it the model, its
/// settings and the stretches heard (SpeechListener), and shows its lines in the box. While an IINA video is
/// transcribed from its file (VideoTranscriber, its own setting), nothing is listened to even with the setting on, as
/// the box's audio button then shows.
@MainActor
final class AudioTranscriber: StretchTranscriberHost {
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
    /// The last error shown, so that it's shown once rather than for each stretch.
    private var shownError: String?
    /// SaT's error was shown: lines end at punctuation only until "Detect sentence ends" is turned on again.
    private var sentenceEndsFailed = false
    /// MACPOPUP_TEST_TRANSCRIPTION_FILE: a sound file played in place of the app's audio (for test runs).
    private let testFile = DevelopmentEnvironment["MACPOPUP_TEST_TRANSCRIPTION_FILE"]

    /// The box's lines from the stretches, on the clock of system uptime.
    private lazy var transcriber = StretchTranscriber(host: self)
    /// The language the model's words as they're heard (transcriber.live, for "Show words as they're heard") were
    /// asked for; nil when not wanted.
    private var liveLanguage: String?
    /// Why the live words couldn't be had last time, logged once.
    private var liveError: String?
    /// Settings → IINA Integration → "Transcribe videos without subtitles".
    private lazy var video = VideoTranscriber(onActive: { [weak self] in
        self?.showVideoActive()
        self?.applySettings()
    }, report: { [weak self] in self?.report($0) })
    /// The models listening or the IINA video's transcription use (SaT: whether it's used), so the others are let go.
    private var modelsUsed: Set<SpeechModel> = []
    private var sentenceEndsUsed = false

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
                self.transcriber.live = nil
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

    /// What an IINA player window plays, from MacPopup's plugin (see VideoTranscriber).
    func playerStatus(_ body: [String: Any]) {
        video.playerStatus(body)
    }

    /// The box's page (re)loaded.
    func pageReady() {
        showLoading()
        showUnavailable()
        showVideoActive()
    }

    private func applySettings() {
        let enabled = settings["floatingWindowAudio"] as? Bool ?? false
        let chosen = SpeechModel(rawValue: settings["transcriptionModel"] as? String ?? "") ?? .soda
        let model = enabled ? chosen : nil
        let language = settings["language"] as? String ?? "ja"
        let modelChanged = model != self.model
        if modelChanged {
            self.model = model
            shownError = nil
            unavailable = false
            transcriber.use(model.map(SpeechRecognizer.shared))
            liveLanguage = nil
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
        transcriber.language = language
        transcriber.growing = findsSentenceEnds
        let wantsSentenceEnds = enabled && findsSentenceEnds
        if wantsSentenceEnds != self.wantsSentenceEnds {
            self.wantsSentenceEnds = wantsSentenceEnds
            sentenceEndsFailed = false
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
        // Not for a model that doesn't give them (the setting is only hidden for it).
        let wantsLive = enabled && settings["transcriptionLive"] as? Bool == true && model?.hearsLive == true
        if let model, wantsLive, language != liveLanguage {
            liveLanguage = language
            transcriber.live = nil
            let recognizer = SpeechRecognizer.shared(model)
            Task {
                do {
                    let live = try await recognizer.live(language: language)
                    // Still wanted for this model and language.
                    guard self.model == model, self.liveLanguage == language else { return }
                    self.transcriber.live = live
                    self.liveError = nil
                    // The model loaded for it.
                    self.unavailable = false
                    if live != nil { transcriptionLog("\(model.kind.name) gives words as they're heard") }
                } catch {
                    // Tried again once the model's files are replaced (SpeechRecognizer.modelsChanged), e.g. when it's
                    // loaded in Settings, or with another model or language: not before, since each try loads it again.
                    // The stretches' transcription shows the error.
                    if error.localizedDescription != self.liveError {
                        transcriptionLog("no words as they're heard: \(error.localizedDescription)")
                    }
                    self.liveError = error.localizedDescription
                }
            }
        } else if !wantsLive {
            transcriber.live = nil
            liveLanguage = nil
        }
        let pause = ((settings["transcriptionPause"] as? NSNumber)?.doubleValue ?? 1000) / 1000
        video.configure(settings["iinaTranscribe"] as? Bool ?? true
            ? VideoTranscriber.Settings(model: chosen, language: language, growing: findsSentenceEnds, pause: pause) : nil)
        releaseUnused(listening: enabled)
        let source = enabled ? Source(processes: video.isActive ? nil : processes(), pause: pause, live: wantsLive) : nil
        guard source != self.source else { return }
        self.source = source
        // The stretches waiting are of the old source's audio, and the open line can't go on with the new one's.
        let generation = transcriber.startListener()
        listener?.stop()
        listener = nil
        guard let source, source.processes != nil || testFile != nil && !video.isActive else {
            if source != nil, video.isActive { transcriptionLog("not listening: IINA's video is transcribed from its file") }
            return
        }
        let onLive: ((SpeechStretches.Live) -> Void)? = source.live ? { [weak self] event in
            Task { @MainActor in self?.transcriber.heardLive(event, listener: generation) }
        } : nil
        let listener = SpeechListener(pause: source.pause, onPlaced: { [weak self] placed in
            self?.transcriber.heard(placed, listener: generation)
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

    /// Lets go of the models (and SaT) that neither listening nor the IINA video's transcription uses any more; they're
    /// loaded when first used.
    private func releaseUnused(listening: Bool) {
        let used = Set([model, video.model].compactMap { $0 })
        for old in modelsUsed.subtracting(used) {
            let recognizer = SpeechRecognizer.shared(old)
            Task { await recognizer.unload() }
        }
        modelsUsed = used
        let sentenceEnds = findsSentenceEnds && (listening || video.isActive)
        if sentenceEndsUsed, !sentenceEnds { Task { await SentenceEnds.shared.unload() } }
        sentenceEndsUsed = sentenceEnds
    }

    /// Shows on the box's audio button whether IINA's video is transcribed (and so nothing listened to).
    private func showVideoActive() {
        overlay.evaluate("window.__macpopupIinaTranscribing?.(\(video.isActive))")
    }

    /// The captured window's app, or every app but MacPopup when no window is captured; nil while the captured window
    /// isn't open.
    private func processes() -> AudioTap.Processes? {
        if let saved = settings["ocrWindow"] as? [String: Any], saved["ownerName"] is String {
            return OCRController.savedWindow().map { .app($0.ownerPID) }
        }
        return .allBut(ProcessInfo.processInfo.processIdentifier)
    }

    /// Settings → Transcription → "Detect sentence ends".
    private var findsSentenceEnds: Bool { settings["transcriptionSentenceEnds"] as? Bool ?? false }
    /// Whether SaT is wanted for listening (audio and "Detect sentence ends" on), loaded ahead.
    private var wantsSentenceEnds = false
    private var satLoading = false

    // MARK: StretchTranscriberHost

    func run<T: Sendable>(_ kind: StretchTranscriber.Work, _ work: @escaping @Sendable () async -> T,
                          done: @escaping @MainActor (T) -> Void) {
        switch kind {
        case .lines:
            Task { done(await work()) }
        case .live:
            // Off the main actor: a live pass is work done right away (SODA's).
            Task.detached(priority: .userInitiated) {
                let result = await work()
                await done(result)
            }
        }
    }

    func show(_ line: StretchLines.Shown, endsLive: Int?) {
        guard let json = Self.json(line.text) else { return }
        let age = ProcessInfo.processInfo.systemUptime - line.start
        overlay.evaluate("window.__macpopupTranscript?.(\(json), \(age), \(line.grows), \(endsLive.map(String.init) ?? "null"))")
    }

    func showLive(_ text: String?, stretch: Int) {
        let json: String? = if let text { Self.json(text) } else { "null" }
        guard let json else { return }
        overlay.evaluate("window.__macpopupLive?.(\(stretch), \(json))")
    }

    func clearLive() {
        overlay.evaluate("window.__macpopupLiveClear?.()")
    }

    func log(_ message: String) {
        transcriptionLog(message)
    }

    func transcribed(error: Error?) {
        guard let error else {
            shownError = nil
            unavailable = false
            return
        }
        unavailable = true
        report(error)
    }

    func sentenceEndsFailed(_ error: Error) {
        reportSentenceEnds(error)
    }

    func heard(_ samples: [Float], text: String, speech: SpeechStretches.Speech, listener: Int) {
        SpeechDebug.shared?.line(listener: listener, stretch: speech.id, samples: samples, text: text)
    }

    func heardLive(_ samples: [Float], text: String?, ms: Double, stretch: Int, listener: Int) {
        SpeechDebug.shared?.live(listener: listener, stretch: stretch, samples: samples, text: text, ms: ms)
    }

    /// A string as JavaScript.
    private static func json(_ text: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { "\($0)[0]" }
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
/// are placed (taken from the recording and converted) on another one (`placing`), while the next one is heard.
final class SpeechListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aury.macpopup.transcription", qos: .userInitiated)
    /// Where stretches are placed, one at a time.
    private let placing = DispatchQueue(label: "com.aury.macpopup.transcription.placing", qos: .userInitiated)
    private let stretches: SpeechStretches
    private var tap: AudioTap?
    private var testTimer: DispatchSourceTimer?

    /// `pause`: seconds, 0: lines don't end at pauses. `onLive` gets the stretch being heard as it's heard, on the
    /// listener's queue; nil: only whole stretches are given. `onPlaced`: each stretch placed (see Cut.place).
    init(pause: Double, onPlaced: @escaping @MainActor (SpeechStretches.Cut.Placed) -> Void,
         onLive: ((SpeechStretches.Live) -> Void)? = nil) {
        let queue = queue, placing = placing
        stretches = SpeechStretches(pause: pause, live: onLive != nil, clock: { ProcessInfo.processInfo.systemUptime },
                                    deliver: { queue.async(execute: $0) }, log: transcriptionLog)
        stretches.onLive = onLive
        stretches.onCut = { cut in
            // After the stretches before it.
            placing.async {
                for placed in cut.place(log: transcriptionLog) {
                    Task { @MainActor in onPlaced(placed) }
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
