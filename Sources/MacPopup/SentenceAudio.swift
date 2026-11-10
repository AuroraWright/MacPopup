import AppKit
import AVFoundation
import SoundAnalysis

/// Records a game's voice line for the sentence audio of the cards just added (Settings → Sentence
/// Audio): a shortcut switches to the game, presses the keys that open its backlog (where the line is
/// replayed), records the game's audio until the voice ends, closes the backlog again, and adds the
/// recording to the newest Anki cards with the same sentence.
///
/// The game's audio is the audio of the captured window's app and its helper processes, or of every
/// app but MacPopup when there's no captured window (see AudioTap).
///
/// The voice is found with Apple's sound classifier (SoundAnalysis), which tells speech from music,
/// so background music doesn't count. Without voice detection, the shortcut starts and stops the
/// recording.
@MainActor
final class SentenceAudioController {
    private enum State {
        case idle
        /// Switching to the game and pressing keys before recording.
        case starting
        case recording(AudioRecording)
        /// Closing the backlog and adding the recording to cards.
        case finishing
    }

    private let overlay: OverlayController
    private let hotkey = HotkeyController(signature: 0x4D50_5341) // "MPSA"
    private var state = State.idle
    private var player: AVAudioPlayer?
    /// The last recording, deleted when the next one starts.
    private var lastFile: URL?
    /// MACPOPUP_TEST_AUDIO_FILE: a sound file played in place of the game's audio (for test runs).
    private let testFile = ProcessInfo.processInfo.environment["MACPOPUP_TEST_AUDIO_FILE"]

    init(overlay: OverlayController) {
        self.overlay = overlay
        hotkey.onPress = { [weak self] _ in self?.shortcutPressed() }
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        applySettings()
    }

    // MARK: Settings

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private func number(_ key: String, _ fallback: Double) -> Double {
        (settings[key] as? NSNumber)?.doubleValue ?? fallback
    }

    private func string(_ key: String, _ fallback: String = "") -> String {
        (settings[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? fallback
    }

    private static func combination(_ value: Any?) -> KeyCombination? {
        guard let item = value as? [String: Any], let key = item["key"] as? String, !key.isEmpty else { return nil }
        return KeyCombination(key: key, modifiers: item["modifiers"] as? [String] ?? [])
    }

    private func applySettings() {
        let shortcut = settings["sentenceAudioEnabled"] as? Bool == true ? Self.combination(settings["sentenceAudioShortcut"]) : nil
        let registered = hotkey.set(shortcut.map { [$0] } ?? [])
        if let shortcut, registered.first == false {
            showToast("The sentence audio shortcut \(shortcut.displayName) is used by another app")
        }
    }

    // MARK: Recording

    /// Starts a recording, or ends the one in progress (keeping what was recorded).
    func shortcutPressed() {
        switch state {
        case .idle:
            state = .starting
            Task { await start() }
        case let .recording(recording):
            recording.stop(reason: .shortcut)
        case .starting, .finishing:
            break
        }
    }

    private func start() async {
        if let lastFile {
            try? FileManager.default.removeItem(at: lastFile)
            self.lastFile = nil
        }
        let detectsVoice = settings["sentenceAudioDetectVoice"] as? Bool ?? true
        // The input is started first, since that takes a moment, and recorded from once the keys are
        // pressed: a voice that plays as soon as the backlog opens is recorded from its start.
        let recording = AudioRecording(
            detectsVoice: detectsVoice,
            voiceWait: number("sentenceAudioVoiceWait", 10),
            pause: number("sentenceAudioPause", 3000) / 1000,
            padding: number("sentenceAudioPadding", 500) / 1000,
            maxLength: number("sentenceAudioMaxLength", 60)
        )
        recording.onEnd = { [weak self] result in
            MainActor.assumeIsolated { self?.finish(result) }
        }
        do {
            if let testFile {
                try recording.start(testFile: URL(fileURLWithPath: testFile))
            } else {
                try recording.start(appPID: capturedWindowPID())
            }
        } catch {
            showToast("Couldn’t record: \(error.localizedDescription)")
            state = .idle
            return
        }
        await pressKeys(settings["sentenceAudioOpenKeys"])
        // Voice detection waits for the voice itself, and leaves out what comes before it.
        if !detectsVoice {
            try? await Task.sleep(for: .milliseconds(Int(number("sentenceAudioRecordDelay", 500))))
        }
        recording.record()
        state = .recording(recording)
        if testFile == nil { NSSound(named: "Tink")?.play() }
        showToast(detectsVoice ? "Listening for the voice…" : "Recording… press the shortcut again to stop")
    }

    private func finish(_ result: AudioRecording.Result) {
        guard case .recording = state else { return }
        state = .finishing
        Task {
            await pressKeys(settings["sentenceAudioCloseKeys"])
            defer { state = .idle }
            guard let clip = result.clip else {
                sentenceAudioLog("\(result.reason)\(result.silent ? ", silent" : ""), nothing kept")
                if result.silent {
                    showToast("No sound was recorded. If the game played some, allow MacPopup in System Settings → Privacy & Security → Screen & System Audio Recording")
                } else {
                    showToast(result.reason == .noVoice ? "No voice heard" : "Nothing was recorded")
                }
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("macpopup-sentence-\(Self.timestamp()).m4a")
            do {
                try clip.write(to: url)
            } catch {
                showToast("Couldn’t save the recording: \(error.localizedDescription)")
                return
            }
            lastFile = url
            sentenceAudioLog("\(String(format: "%.2f", clip.duration))s (\(result.reason)), \(url.lastPathComponent)")
            do {
                let count = try await addToCards(url)
                showToast("Added sentence audio to \(count) card\(count == 1 ? "" : "s")")
                if settings["sentenceAudioPlay"] as? Bool ?? true {
                    player = try? AVAudioPlayer(contentsOf: url)
                    player?.play()
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// The process of the captured window (Settings → General, also outside OCR mode), whose audio is
    /// recorded, or nil when there isn't one or it isn't open.
    private func capturedWindowPID() -> pid_t? {
        guard let saved = settings["ocrWindow"] as? [String: Any], let owner = saved["ownerName"] as? String else { return nil }
        return findWindow(ownerName: owner, title: saved["title"] as? String ?? "")?.ownerPID
    }

    private func findWindow(ownerName: String, title: String) -> OCRController.WindowInfo? {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap(OCRController.windowInfo).filter { $0.ownerName == ownerName && $0.layer == 0 }
        return windows.first(where: { $0.title == title }) ?? windows.first
    }

    // MARK: Keys

    /// Switches to the game, then presses `keys` ([{key, modifiers}]) in turn.
    private func pressKeys(_ value: Any?) async {
        let keys = (value as? [Any] ?? []).compactMap(Self.combination)
        let switched = activateApp()
        guard !keys.isEmpty else { return }
        if switched || string("sentenceAudioApp", "captured") == "none" {
            try? await Task.sleep(for: .milliseconds(Int(number("sentenceAudioKeyDelay", 1000))))
        }
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            showToast("Allow MacPopup in System Settings → Privacy & Security → Accessibility to press keys")
            return
        }
        let hold = Int(number("sentenceAudioKeyHold", 100))
        let interval = Int(number("sentenceAudioKeyInterval", 800))
        for (index, combination) in keys.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(interval)) }
            guard let keyCode = combination.keyCode else { continue }
            let flags: CGEventFlags = combination.modifiers.reduce([]) { flags, name in
                switch name {
                case "ctrl": flags.union(.maskControl)
                case "alt": flags.union(.maskAlternate)
                case "shift": flags.union(.maskShift)
                case "meta": flags.union(.maskCommand)
                default: flags
                }
            }
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
            down?.flags = flags
            down?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(hold))
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
            up?.flags = flags
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Brings the game to the front: the captured window (Settings → General, also outside OCR mode),
    /// or the app named. Returns whether it was found.
    private func activateApp() -> Bool {
        switch string("sentenceAudioApp", "captured") {
        case "captured":
            guard let saved = settings["ocrWindow"] as? [String: Any], let owner = saved["ownerName"] as? String else {
                showToast("No captured window: choose one in Settings → General")
                return false
            }
            return activateWindow(ownerName: owner, title: saved["title"] as? String ?? "")
        case "named":
            let name = string("sentenceAudioAppName")
            guard !name.isEmpty else { return false }
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
                showToast("\(name) isn’t running")
                return false
            }
            app.activate()
            return true
        default:
            return false
        }
    }

    /// Activates the app of a window, found by its app and title like the captured window, and raises
    /// the window above the app's others (with Accessibility permission).
    private func activateWindow(ownerName: String, title: String) -> Bool {
        guard let window = findWindow(ownerName: ownerName, title: title),
              NSRunningApplication(processIdentifier: window.ownerPID) != nil else {
            showToast("\(ownerName) isn’t running")
            return false
        }
        OCRController.raise(window)
        return true
    }

    // MARK: Anki

    /// Adds the recording to the newest cards added today that have the same sentence and no sentence
    /// audio yet. Returns how many. The sentence field of each note type is the one its Yomitan card
    /// format fills with the sentence.
    private func addToCards(_ url: URL) async throws -> Int {
        let settings = settings
        guard settings["ankiEnabled"] as? Bool ?? true else { throw SentenceAudioError("Anki integration is off (Settings → Anki)") }
        let audioField = string("sentenceAudioField", "SentenceAudio")
        guard !audioField.isEmpty else { throw SentenceAudioError("Choose the sentence audio field in Settings → Anki") }
        let sentenceFields = try await AnkiConnect.sentenceFields(settings: settings)
        guard !sentenceFields.isEmpty else { throw SentenceAudioError("No Yomitan card format has a field with {sentence}") }
        let query = "added:1 \(Self.fieldQuery(audioField))"
        let ids = try await AnkiConnect.invoke("findNotes", ["query": query], settings: settings) as? [NSNumber] ?? []
        let notes = (try await AnkiConnect.invoke("notesInfo", ["notes": ids], settings: settings) as? [[String: Any]] ?? []).filter {
            ($0["modelName"] as? String).flatMap { sentenceFields[$0] } != nil
        }
        func field(_ note: [String: Any], _ name: String) -> String {
            ((note["fields"] as? [String: Any])?[name] as? [String: Any])?["value"] as? String ?? ""
        }
        func sentence(_ note: [String: Any]) -> String {
            Self.plainText(field(note, sentenceFields[note["modelName"] as? String ?? ""] ?? ""))
        }
        func noteId(_ note: [String: Any]) -> Int64 { (note["noteId"] as? NSNumber)?.int64Value ?? 0 }
        guard let newest = notes.max(by: { noteId($0) < noteId($1) }) else {
            throw SentenceAudioError("No card added today has the field \(audioField) and a sentence from Yomitan")
        }
        let newestSentence = sentence(newest)
        let targets = notes.filter {
            sentence($0) == newestSentence && field($0, audioField).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !targets.isEmpty else { throw SentenceAudioError("The newest card already has sentence audio") }

        let data = try Data(contentsOf: url)
        let stored = try await AnkiConnect.invoke(
            "storeMediaFile", ["filename": url.lastPathComponent, "data": data.base64EncodedString()], settings: settings
        ) as? String ?? url.lastPathComponent
        for note in targets {
            _ = try await AnkiConnect.invoke(
                "updateNoteFields", ["note": ["id": noteId(note), "fields": [audioField: "[sound:\(stored)]"]]], settings: settings
            )
        }
        return targets.count
    }

    /// A search for notes that have a field (empty or not).
    private static func fieldQuery(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + ":*\""
    }

    /// A field's text without HTML, furigana or whitespace, so formatting (e.g. the mined word in bold)
    /// doesn't tell sentences apart.
    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<rt>.*?</rt>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private func showToast(_ message: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [message]), let json = String(data: data, encoding: .utf8) else { return }
        overlay.evaluate("window.__macpopupToast?.(...\(json))")
    }
}

/// Logged to stderr, like the page's log messages.
func sentenceAudioLog(_ message: String) {
    FileHandle.standardError.write("[sentence audio] \(message)\n".data(using: .utf8)!)
}

struct SentenceAudioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// One recording of an app's audio (or, for tests, a sound file played at its own pace), and the voice
/// found in it. Everything but `start` and `stop` runs on its own queue.
final class AudioRecording: NSObject, @unchecked Sendable {
    enum Reason: String {
        /// The voice ended.
        case voiceEnded
        /// No voice in time.
        case noVoice
        case maxLength
        case shortcut
        case inputEnded
    }

    struct Result {
        var reason: Reason
        var clip: AudioClip?
        /// Every sample was 0, as when MacPopup may not record other apps' audio (or nothing played).
        var silent = false
    }

    var onEnd: ((Result) -> Void)?

    private let detectsVoice: Bool
    private let voiceWait: Double
    /// Seconds without the voice after which it has ended: longer than the pauses within a line.
    private let pause: Double
    /// Seconds kept before and after the voice.
    private let padding: Double
    private let maxLength: Double
    private let queue = DispatchQueue(label: "com.aury.macpopup.sentence-audio")
    private var tap: AudioTap?
    private var testTimer: DispatchSourceTimer?
    private var format: AVAudioFormat?
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFramePosition = 0
    private var detector: VoiceDetector?
    /// Seconds into the recording.
    private var voiceStart: Double?
    private var voiceEnd: Double?
    private var ended = false
    private var heardSound = false
    /// Input is only kept once `record` is called (the input is started before).
    private var isRecording = false

    init(detectsVoice: Bool, voiceWait: Double, pause: Double, padding: Double, maxLength: Double) {
        self.detectsVoice = detectsVoice
        self.voiceWait = voiceWait
        self.pause = pause
        self.padding = padding
        self.maxLength = maxLength
    }

    /// Records the audio of the app with the process `pid` and its helpers, or, when it's nil, of every
    /// app but MacPopup (whose popups play audio too).
    func start(appPID pid: pid_t?) throws {
        if let pid {
            sentenceAudioLog("recording \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)")")
        } else {
            sentenceAudioLog("recording every app")
        }
        let tap = AudioTap(processes: pid.map { .app($0) } ?? .allBut(ProcessInfo.processInfo.processIdentifier), queue: queue) { [weak self] buffer in
            guard let self, !ended, isRecording else { return }
            append(buffer)
        }
        try tap.start()
        self.tap = tap
    }

    /// Plays a sound file in place of the game's audio, in real time.
    func start(testFile url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, !ended, isRecording else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else {
                end(.inputEnded)
                return
            }
            append(buffer)
        }
        testTimer = timer
        timer.resume()
    }

    /// Keeps the input from now on.
    func record() {
        queue.async { self.isRecording = true }
    }

    func stop(reason: Reason) {
        queue.async { self.end(reason) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        if format == nil {
            format = buffer.format
            if detectsVoice {
                detector = try? VoiceDetector(format: buffer.format) { [weak self] range, isSpeech in
                    self?.queue.async { self?.classified(range, isSpeech: isSpeech) }
                }
                if detector == nil { sentenceAudioLog("voice detection unavailable") }
            }
        }
        // Keeps to the first format, in case it changes.
        guard buffer.format == format else { return }
        if !heardSound, let channels = buffer.floatChannelData {
            heardSound = (0..<Int(buffer.format.channelCount)).contains { channel in
                UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)).contains { $0 != 0 }
            }
        }
        buffers.append(buffer)
        detector?.analyze(buffer, at: frames)
        frames += AVAudioFramePosition(buffer.frameLength)
        let seconds = Double(frames) / buffer.format.sampleRate
        if seconds >= maxLength {
            end(.maxLength)
        } else if detector != nil, voiceStart == nil, seconds >= voiceWait {
            end(.noVoice)
        } else if let voiceEnd, seconds - voiceEnd >= max(pause, padding) {
            end(.voiceEnded)
        }
    }

    /// A stretch of the recording was classified (they overlap, in order).
    private func classified(_ range: CMTimeRange, isSpeech: Bool) {
        guard isSpeech else { return }
        if voiceStart == nil { voiceStart = range.start.seconds }
        voiceEnd = range.end.seconds
    }

    private func end(_ reason: Reason) {
        guard !ended else { return }
        ended = true
        tap?.stop()
        testTimer?.cancel()
        detector?.finish()
        var clip: AudioClip?
        if let format, frames > 0, reason != .noVoice {
            let all = AudioClip(format: format, buffers: buffers)
            if detectsVoice, let voiceStart {
                // Without the end of the voice (stopped early), up to the end of the recording.
                let coarse = (voiceStart, voiceEnd ?? all.duration)
                let fine = VoiceDetector.refine(all, start: coarse.0, end: coarse.1)
                sentenceAudioLog(String(format: "voice %.2f–%.2fs, finely %.2f–%.2fs, of %.2fs", coarse.0, coarse.1, fine?.0 ?? -1, fine?.1 ?? -1, all.duration))
                let range = fine ?? coarse
                clip = all.trimmed(voiceFrom: range.0, to: range.1, padding: padding)
            } else if !detectsVoice || detector == nil {
                clip = all
            }
        }
        buffers = []
        let result = Result(
            reason: reason == .inputEnded && voiceStart == nil && detector != nil ? .noVoice : reason,
            clip: clip,
            silent: frames > 0 && !heardSound
        )
        DispatchQueue.main.async { self.onEnd?(result) }
    }
}

/// Finds speech with Apple's sound classifier.
final class VoiceDetector: NSObject, SNResultsObserving {
    /// The classifier's labels that are a voice.
    private static let voiceLabels = ["speech", "shout", "yell", "whispering", "laughter"]
    private static let threshold = 0.5

    private let analyzer: SNAudioStreamAnalyzer
    private let onResult: (CMTimeRange, Bool) -> Void

    /// - Parameters:
    ///   - window: How long each classified stretch is, in seconds (at least 0.5).
    ///   - overlap: How much of each stretch the next one repeats, so results come every
    ///     `window * (1 - overlap)` seconds.
    init(format: AVAudioFormat, window: Double = 1, overlap: Double = 0.75, onResult: @escaping (CMTimeRange, Bool) -> Void) throws {
        analyzer = SNAudioStreamAnalyzer(format: format)
        self.onResult = onResult
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: window, preferredTimescale: 1000)
        request.overlapFactor = overlap
        try analyzer.add(request, withObserver: self)
    }

    /// Where the voice is in `clip` between about `start` and `end` (from a coarse pass), placed more
    /// finely with short stretches: from the middle of the first one with speech to the middle of the
    /// last one.
    static func refine(_ clip: AudioClip, start: Double, end: Double) -> (Double, Double)? {
        let from = max(0, start - 0.5), to = min(clip.duration, end + 0.5)
        var found: (Double, Double)?
        guard let detector = try? VoiceDetector(format: clip.format, window: 0.5, overlap: 0.9, onResult: { range, isSpeech in
            guard isSpeech else { return }
            let middle = from + (range.start.seconds + range.end.seconds) / 2
            found = (min(found?.0 ?? middle, middle), max(found?.1 ?? middle, middle))
        }) else { return nil }
        var position: AVAudioFramePosition = 0
        for buffer in clip.slice(from: from, to: to).buffers {
            detector.analyze(buffer, at: position)
            position += AVAudioFramePosition(buffer.frameLength)
        }
        detector.finish()
        return found
    }

    /// Called on the recording's queue, in order.
    func analyze(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition) {
        analyzer.analyze(buffer, atAudioFramePosition: position)
    }

    func finish() {
        analyzer.completeAnalysis()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = Self.voiceLabels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
        onResult(result.timeRange, confidence >= Self.threshold)
    }
}

/// Recorded audio, kept in memory.
struct AudioClip {
    let format: AVAudioFormat
    let buffers: [AVAudioPCMBuffer]

    var frameCount: Int { buffers.reduce(0) { $0 + Int($1.frameLength) } }
    var duration: Double { Double(frameCount) / format.sampleRate }

    /// The voice, found between `start` and `end`, with `padding` seconds before and after it. Its
    /// ends are first moved in to where it's louder than the quiet around it, when that's clear (a
    /// voice well above the music).
    func trimmed(voiceFrom start: Double, to end: Double, padding: Double) -> AudioClip {
        let padded = { (from: Double, to: Double) in self.slice(from: max(0, from - padding), to: min(self.duration, to + padding)) }
        let step = 0.02
        let levels = rmsLevels(window: Int(format.sampleRate * step))
        let startIndex = max(0, Int(start / step)), endIndex = min(levels.count, Int(ceil(end / step)))
        guard startIndex < endIndex else { return padded(start, end) }
        // The quiet level: the 20th percentile of the whole recording.
        let quiet = levels.sorted()[levels.count / 5]
        let loud = max(quiet * 3.16, 0.003) // 10 dB above, and above about -50 dBFS
        let voiced = (startIndex..<endIndex).filter { levels[$0] > loud }
        guard let first = voiced.first, let last = voiced.last else { return padded(start, end) }
        return padded(Double(first) * step, Double(last + 1) * step)
    }

    /// Root mean square of each `window` frames, over all channels.
    private func rmsLevels(window: Int) -> [Float] {
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        for buffer in buffers {
            guard let channels = buffer.floatChannelData else { continue }
            let channelCount = Int(buffer.format.channelCount)
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channelCount {
                    let sample = channels[channel][frame]
                    sum += sample * sample
                }
                count += 1
                if count == window {
                    levels.append(sqrt(sum / Float(window * channelCount)))
                    sum = 0
                    count = 0
                }
            }
        }
        return levels
    }

    func slice(from start: Double, to end: Double) -> AudioClip {
        let first = AVAudioFramePosition(start * format.sampleRate), last = AVAudioFramePosition(end * format.sampleRate)
        var result: [AVAudioPCMBuffer] = []
        var position: AVAudioFramePosition = 0
        for buffer in buffers {
            let length = AVAudioFramePosition(buffer.frameLength)
            defer { position += length }
            let from = max(first, position), to = min(last, position + length)
            guard from < to, let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(to - from)),
                  let source = buffer.floatChannelData, let target = part.floatChannelData else { continue }
            part.frameLength = AVAudioFrameCount(to - from)
            for channel in 0..<Int(format.channelCount) {
                (target[channel]).update(from: source[channel] + Int(from - position), count: Int(to - from))
            }
            result.append(part)
        }
        return AudioClip(format: format, buffers: result)
    }

    /// Writes AAC in an .m4a file: mono or stereo (the first two channels of an input with more).
    func write(to url: URL) throws {
        let channels = min(format.channelCount, 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64_000 * Int(channels),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let fileFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: channels) else { return }
        for buffer in buffers {
            guard channels != format.channelCount else {
                try file.write(from: buffer)
                continue
            }
            guard let part = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: buffer.frameLength),
                  let source = buffer.floatChannelData, let target = part.floatChannelData else { continue }
            part.frameLength = buffer.frameLength
            for channel in 0..<Int(channels) {
                target[channel].update(from: source[channel], count: Int(buffer.frameLength))
            }
            try file.write(from: part)
        }
    }
}
