import AppKit
import AVFoundation
import OCREngines
import SoundAnalysis
import Transcription

/// Adds a game's voice line to the sentence audio of cards added from a popup (Settings → Anki Audio). A shortcut takes
/// the voice of the newest card's line from the last few minutes of the game's audio. With Visual novel backlog
/// capture, it can instead switch to the game, press the keys that open its backlog to replay the line, record until
/// the voice ends, and close the backlog again. The recording goes to the cards added from the same line.
///
/// The game's audio is the audio of the captured window's app and its helper processes, or of every
/// app but MacPopup when there's no captured window (see AudioTap).
///
/// The voice is found with Apple's sound classifier (SoundAnalysis), which tells speech from music,
/// so background music doesn't count. Without voice detection, the shortcut starts and stops the
/// recording.
///
/// The last few minutes of the game's audio are kept (AudioHistory), along with when each line was shown (noteLine).
/// Each card added from a popup knows the line it was scanned in (cardAdded). When that line is among the kept ones
/// and its whole voice was kept, the voice is taken from there.
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
    private var state = State.idle {
        didSet {
            // Cards added from a popup while busy get their voice once the current one is done.
            guard case .idle = state, !queued.isEmpty else { return }
            let next = queued.removeFirst()
            Task { self.shortcutPressed(note: next) }
        }
    }
    /// Cards added from a popup while a recording was in progress, waiting for their turn.
    private var queued: [Int64] = []
    private var player: AVAudioPlayer?
    /// The last recording, deleted when the next one starts.
    private var lastFile: URL?
    /// The card this recording is for, when it was added or overwritten from a popup with Option (see popup.js). Its
    /// sentence audio is replaced. Nil means the newest cards.
    private var note: Int64?
    /// The cards the recording goes to.
    private var cards: Cards?
    /// MACPOPUP_TEST_AUDIO_FILE: a sound file played in place of the game's audio (for test runs).
    private let testFile = DevelopmentEnvironment["MACPOPUP_TEST_AUDIO_FILE"]
    private let history = AudioHistory()
    /// The lines shown in the last few minutes, oldest first (see ShownLines for their ids).
    private var lines: [LineTimes] = []
    /// The cards added from a popup, oldest first.
    private var addedCards: [AddedCard] = []

    /// When a shown line appeared.
    private struct LineTimes {
        let id: Int
        var shown: Double
        /// The earliest its voice may have started: shortly before it was shown, or before OCR saw the text change.
        var start: Double
        /// Transcribed from the audio ("Read text from audio"): its times are where its voice and the next line's start,
        /// so the next line can't have cut its voice off.
        var transcribed: Bool
    }

    init(overlay: OverlayController) {
        self.overlay = overlay
        hotkey.onPress = { [weak self] _ in self?.shortcutPressed() }
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        applySettings()
        // Checks again now and then, since the captured window's app may start, quit or open the window later.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHistory() }
        }
    }

    // MARK: Settings

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private func number(_ key: String, _ fallback: Double) -> Double {
        (settings[key] as? NSNumber)?.doubleValue ?? fallback
    }

    private func string(_ key: String, _ fallback: String = "") -> String {
        (settings[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? fallback
    }

    /// Whether Anki Audio is on. It needs Anki integration too: without it, there are no cards to add audio to.
    nonisolated static func isEnabled(_ settings: [String: Any]) -> Bool {
        settings["sentenceAudioEnabled"] as? Bool == true && settings["ankiEnabled"] as? Bool ?? true
    }

    private func applySettings() {
        let shortcut = Self.isEnabled(settings) ? KeyCombination(setting: settings["sentenceAudioShortcut"]) : nil
        hotkey.set(shortcut) { [weak self] taken in
            self?.showToast("The sentence audio shortcut \(taken.displayName) is already in use by another app or shortcut")
        }
        updateHistory()
    }

    // MARK: Audio history

    private var historyMinutes: Double {
        Self.isEnabled(settings) && testFile == nil ? number("sentenceAudioHistory", 5) : 0
    }

    /// Keeps the audio of the captured window's app, or of every app except MacPopup when no window is captured.
    private func updateHistory() {
        let minutes = historyMinutes
        guard minutes > 0 else {
            history.record(nil, minutes: 0)
            lines.removeAll()
            return
        }
        let processes: AudioTap.Processes
        if let saved = settings["ocrWindow"] as? [String: Any], saved["ownerName"] is String {
            // Nothing is kept until the window is open.
            guard let pid = capturedWindowPID() else {
                history.record(nil, minutes: 0)
                return
            }
            processes = .app(pid)
        } else {
            processes = .allBut(ProcessInfo.processInfo.processIdentifier)
        }
        history.record(processes, minutes: minutes)
    }

    /// The line with `id` (see ShownLines) was shown in the text box or read by OCR, `age` seconds ago: a new line
    /// (`isNew`), or the last one again. `transcribed`: from "Read text from audio".
    func noteLine(id: Int, isNew: Bool, text: String, age: Double, transcribed: Bool) {
        let minutes = historyMinutes
        guard minutes > 0 else { return }
        let now = GameClock.now
        let shown = now - max(0, age)
        // OCR may notice a change up to one check late and reads it after that, while a WebSocket line arrives as the
        // game shows it.
        let start = shown - (age > 0 ? 0.75 : 0.25)
        if !isNew {
            guard let index = lines.lastIndex(where: { $0.id == id }) else { return }
            lines[index].shown = min(lines[index].shown, shown)
            lines[index].start = min(lines[index].start, start)
            lines[index].transcribed = lines[index].transcribed || transcribed
        } else {
            sentenceAudioLog(String(format: "line shown %.2f s ago (line %d): %@", now - shown, id, text))
            lines.append(LineTimes(id: id, shown: shown, start: start, transcribed: transcribed))
            lines.removeAll { $0.shown < now - minutes * 60 - 60 }
        }
    }

    /// A card was added or overwritten from a popup (see popup.js). `line` is the id of the line it was scanned in
    /// (see ShownLines), if that's known. A card from a popup inside a popup (`nested`) gets no sentence audio. With
    /// `withAudio` (Option-click), the line's voice goes to this card.
    func cardAdded(note: Int64, line: Int?, nested: Bool, withAudio: Bool) {
        addedCards.removeAll { $0.note == note }
        addedCards.append(AddedCard(note: note, line: line, nested: nested))
        if addedCards.count > 100 { addedCards.removeFirst(addedCards.count - 100) }
        let enabled = Self.isEnabled(settings)
        let voice = !withAudio ? "no voice asked for" : nested ? "no voice, from a popup inside a popup"
            : !enabled ? "no voice, Anki Audio is off" : "its line's voice asked for"
        sentenceAudioLog("card \(note) added, line \(line.map(String.init) ?? "unknown")\(nested ? " (in a popup inside a popup)" : ""): \(voice)")
        if withAudio, !nested, enabled { shortcutPressed(note: note) }
    }

    /// Takes the voice of the cards' line from the audio history and adds it to them. Returns nil on success, or the
    /// reason the line or its whole voice wasn't there, so the caller can replay it or say why.
    private func takeFromHistory(_ cards: Cards) async -> String? {
        guard historyMinutes > 0 else { return "Game audio isn’t being recorded. Turn on “Record game audio for the last” in Settings → Anki Audio." }
        guard history.isRecording else { return "Game audio isn’t being saved because the game window isn’t open" }
        guard let id = cards.line else { return "Couldn’t find which line this card was made from" }
        sentenceAudioLog("history: line \(id), for card\(cards.ids.count == 1 ? "" : "s") \(cards.ids.map(String.init).joined(separator: ", "))")
        let pause = number("sentenceAudioPause", 3000) / 1000
        let maxLength = number("sentenceAudioMaxLength", 60)
        var waiting = false
        /// Whether the voice was still going at the last check.
        var speaking = false
        while true {
            // While the game is paused (see GamePause), its voice can't go on nor its silence last: the wait goes on
            // once the game does (the popup closed), rather than the game being let run with the popup open.
            if waiting, GameClock.isFrozen {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            guard let index = lines.firstIndex(where: { $0.id == id }) else { return "This card’s line is no longer in the saved game audio" }
            let now = GameClock.now
            let start = max(lines[index].start, index > 0 ? lines[index - 1].shown : 0)
            let shownAt = lines[index].shown - start, transcribed = lines[index].transcribed
            let next = index + 1 < lines.count ? lines[index + 1].shown : nil
            let end = min(next ?? now, start + maxLength)
            // Another line followed it, or it has reached the longest a recording can be.
            let ended = next != nil || end < now
            // While the voice goes on, only its last moments are checked, rather than the whole line again.
            if speaking, !ended, let tail = await history.voice(from: max(start, end - pause - 1), to: end),
               let voice = tail.voice?.fine, tail.clip.duration - voice.1 < pause {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            guard let (clip, voice) = await history.voice(from: start, to: end) else {
                return "This card’s line is no longer in the saved game audio"
            }
            let span = String(format: "%.2f s from %.2f s before it was shown", clip.duration, shownAt)
            // The clip is cut from the coarse placing, which keeps the whole voice; whether the voice ended, and was cut
            // off, is told from the fine one, which ends nearer where the voice does.
            if let voice, ended || clip.duration - voice.fine.1 >= pause {
                sentenceAudioLog(String(format: "history: voice %.2f–%.2f s, finely %.2f–%.2f s, of \(span)", voice.coarse.0,
                                        voice.coarse.1, voice.fine.0, voice.fine.1))
                if next != nil, !transcribed, voice.fine.1 > clip.duration - 0.35 {
                    return "The line’s voice was cut off by the next line"
                }
                // A voice that starts with the line is kept from the line's start (the clip's), since a soft start is
                // detected a little late.
                let clip = clip.trimmed(
                    voiceFrom: voice.coarse.0, to: voice.coarse.1, padding: number("sentenceAudioPadding", 500) / 1000,
                    startingBy: voice.coarse.0 < shownAt + 1 ? 0 : .infinity
                )
                await addClip(clip, cards: cards)
                return nil
            }
            if voice == nil, ended || now - start >= number("sentenceAudioVoiceWait", 10) {
                sentenceAudioLog("history: no voice in \(span)")
                return "No speech detected for this card’s line"
            }
            speaking = voice != nil
            if !waiting {
                waiting = true
                sentenceAudioLog(String(format: "history: waiting for the voice to end%@ (%@)", GameClock.isFrozen ? ", once the game resumes" : "", span))
                showToast(GameClock.isFrozen ? "The audio will be added when the game resumes" : "Waiting for speech to finish…")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Recording

    /// Starts a recording, or stops the one in progress and keeps what was recorded. With `note`, the recording
    /// replaces that card's sentence audio instead of filling in the newest cards'.
    /// While busy, a card from a popup waits its turn rather than being dropped (or stopping the recording).
    func shortcutPressed(note: Int64? = nil) {
        switch state {
        case .idle:
            if note == nil { sentenceAudioLog("shortcut pressed") }
            self.note = note
            state = .starting
            Task { await start() }
        case let .recording(recording):
            sentenceAudioLog(note.map { "card \($0) waits for the recording in progress" } ?? "shortcut pressed: the recording stops")
            if let note { queued.append(note) } else { recording.stop(reason: .shortcut) }
        case .starting, .finishing:
            sentenceAudioLog(note.map { "card \($0) waits its turn" } ?? "shortcut pressed while busy: nothing to do")
            if let note { queued.append(note) }
        }
    }

    private func start() async {
        if let lastFile {
            try? FileManager.default.removeItem(at: lastFile)
            self.lastFile = nil
        }
        let cards: Cards
        do {
            cards = try await cardsForAudio()
        } catch {
            showToast(error.localizedDescription)
            state = .idle
            return
        }
        self.cards = cards
        guard let reason = await takeFromHistory(cards) else {
            state = .idle
            return
        }
        sentenceAudioLog("history: \(reason)")
        guard settings["sentenceAudioBacklog"] as? Bool ?? true else {
            showToast(reason)
            state = .idle
            return
        }
        // First the popups close and the game gets its controller back, since the game is what replays the voice.
        overlay.evaluate("window.__macpopupReleaseForGame?.()")
        GamepadController.shared.setHold(false)
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
        showToast(detectsVoice ? "Listening for speech…" : "Recording… Press the shortcut again to stop")
    }

    private func finish(_ result: AudioRecording.Result) {
        guard case .recording = state else { return }
        state = .finishing
        Task {
            await pressKeys(settings["sentenceAudioCloseKeys"])
            defer { state = .idle }
            guard let clip = result.clip else {
                sentenceAudioLog("\(result.reason)\(result.silent ? ", silent" : ""), nothing saved")
                if result.silent {
                    showToast("No audio was saved. If the game played sound, allow MacPopup in System Settings → Privacy & Security → Screen & System Audio Recording.")
                } else {
                    showToast(result.reason == .noVoice ? "No speech detected" : "Nothing was saved")
                }
                return
            }
            sentenceAudioLog("\(result.reason)")
            guard let cards else { return }
            await addClip(clip, cards: cards)
        }
    }

    /// Saves the clip and adds it to `cards`.
    private func addClip(_ clip: AudioClip, cards: Cards) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macpopup-sentence-\(Self.timestamp()).m4a")
        do {
            try clip.write(to: url)
        } catch {
            showToast("Couldn’t save the recording: \(error.localizedDescription)")
            return
        }
        lastFile = url
        sentenceAudioLog("\(String(format: "%.2f", clip.duration))s, \(url.lastPathComponent)")
        do {
            let count = try await addToCards(url, cards: cards)
            // No message for a card from a popup: you just added it there.
            if note == nil { showToast("Added sentence audio to \(count) card\(count == 1 ? "" : "s")") }
            if settings["sentenceAudioPlay"] as? Bool ?? true {
                player = try? AVAudioPlayer(contentsOf: url)
                player?.play()
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// The process of the captured window (Settings → General, whatever the overlay type), whose audio is recorded, or
    /// nil when there isn't one or it isn't open.
    private func capturedWindowPID() -> pid_t? {
        OCRController.savedWindow()?.ownerPID
    }

    // MARK: Keys

    /// Switches to the game, then presses `keys` ([{key, modifiers}]) in turn.
    private func pressKeys(_ value: Any?) async {
        let keys = (value as? [Any] ?? []).compactMap { KeyCombination(setting: $0) }
        let switched = activateApp()
        guard !keys.isEmpty else { return }
        if switched || string("sentenceAudioApp", "captured") == "none" {
            try? await Task.sleep(for: .milliseconds(Int(number("sentenceAudioKeyDelay", 1000))))
        }
        guard Permission.askForAccessibility() else {
            showToast("Allow MacPopup in System Settings → Privacy & Security → Accessibility to press the backlog keys")
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

    /// Brings the game to the front: the captured window (Settings → General, whatever the overlay type),
    /// or the app named. Returns whether it was found.
    private func activateApp() -> Bool {
        switch string("sentenceAudioApp", "captured") {
        case "captured":
            guard let saved = settings["ocrWindow"] as? [String: Any], let owner = saved["ownerName"] as? String else {
                showToast("No captured window selected — choose one in Settings → General")
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
        guard let window = OCRController.savedWindow(ownerName: ownerName, title: title),
              NSRunningApplication(processIdentifier: window.ownerPID) != nil else {
            showToast("\(ownerName) isn’t running")
            return false
        }
        OCRController.raise(window)
        return true
    }

    // MARK: Anki

    /// A card added from a popup (see cardAdded).
    private struct AddedCard {
        let note: Int64
        let line: Int?
        let nested: Bool
    }

    /// The cards a recording goes to, and the id of their line (see ShownLines), if it's known.
    private struct Cards {
        let line: Int?
        let ids: [Int64]
    }

    /// The popup's card (see `note`), whose sentence audio gets replaced, or else the cards added from the newest
    /// card's line that have no sentence audio yet.
    private func cardsForAudio() async throws -> Cards {
        let settings = settings
        guard settings["ankiEnabled"] as? Bool ?? true else { throw AppError("Anki integration is turned off (Settings → Anki)") }
        let audioField = string("sentenceAudioField", "SentenceAudio")
        guard !audioField.isEmpty else { throw AppError("Select a Sentence audio field in Settings → Anki Audio") }
        let card: AddedCard
        if let note {
            card = addedCards.last { $0.note == note } ?? AddedCard(note: note, line: nil, nested: false)
        } else {
            // Cards from a popup inside a popup don't get it.
            guard let newest = addedCards.last(where: { !$0.nested }) else { throw AppError("No card has been added from a popup yet") }
            card = newest
        }
        let ids = note != nil || card.line == nil ? [card.note] : addedCards.filter { $0.line == card.line }.map(\.note)
        let notes = try await AnkiConnect.invoke("notesInfo", ["notes": ids], settings: settings) as? [[String: Any]] ?? []
        // (A deleted card's info is empty.)
        let withField = notes.filter { ($0["fields"] as? [String: Any])?[audioField] != nil }
        guard !withField.isEmpty else { throw AppError("The card doesn’t have a “\(audioField)” field, or it has been deleted") }
        let targets = note != nil ? withField : withField.filter {
            let value = (($0["fields"] as? [String: Any])?[audioField] as? [String: Any])?["value"] as? String ?? ""
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !targets.isEmpty else { throw AppError("The most recent card already has sentence audio") }
        return Cards(line: card.line, ids: targets.compactMap { ($0["noteId"] as? NSNumber)?.int64Value })
    }

    /// Adds the recording to `cards`. Returns how many cards got it.
    private func addToCards(_ url: URL, cards: Cards) async throws -> Int {
        let settings = settings
        let audioField = string("sentenceAudioField", "SentenceAudio")
        let data = try Data(contentsOf: url)
        let stored = try await AnkiConnect.invoke(
            "storeMediaFile", ["filename": url.lastPathComponent, "data": data.base64EncodedString()], settings: settings
        ) as? String ?? url.lastPathComponent
        // A note selected in Anki's card browser is open in its editor, and AnkiConnect doesn't change a note open in an
        // editor (older versions did, and the editor then saved its old fields over the change). So while they change,
        // the browser shows no note, and then the changed ones; a closed browser isn't opened. Other editors (Edit
        // Current, AnkiConnect's Edit dialog) can't be closed from here.
        let targetIds = cards.ids
        let selected = ((try? await AnkiConnect.invoke("guiSelectedNotes", settings: settings)) as? [NSNumber]) ?? []
        let inBrowser = selected.contains { targetIds.contains($0.int64Value) }
        func browse(_ query: String) async {
            if inBrowser { _ = try? await AnkiConnect.invoke("guiBrowse", ["query": query], settings: settings) }
        }
        let changed = "nid:" + targetIds.map(String.init).joined(separator: ",")
        await browse("nid:1")
        do {
            for id in targetIds {
                _ = try await AnkiConnect.invoke(
                    "updateNoteFields", ["note": ["id": id, "fields": [audioField: "[sound:\(stored)]"]]], settings: settings
                )
            }
        } catch {
            await browse(changed)
            throw error
        }
        await browse(changed)
        return targetIds.count
    }

    private func showToast(_ message: String) {
        // (Not to the debug log: the page logs the messages it shows.)
        FileHandle.standardError.write("[sentence audio] message: \(message)\n".data(using: .utf8)!)
        overlay.showToast(message)
    }
}

/// Logged to stderr, like the page's log messages, and to the debug log when it's on (see DebugLog).
func sentenceAudioLog(_ message: String) {
    FileHandle.standardError.write("[sentence audio] \(message)\n".data(using: .utf8)!)
    Task { @MainActor in DebugLog.note("anki audio: \(message)") }
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
                let voice = (voiceStart, voiceEnd ?? all.duration)
                sentenceAudioLog(String(format: "voice %.2f–%.2fs of %.2fs", voice.0, voice.1, all.duration))
                clip = all.trimmed(voiceFrom: voice.0, to: voice.1, padding: padding)
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
