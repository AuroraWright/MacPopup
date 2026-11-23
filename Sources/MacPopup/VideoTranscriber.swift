import AppKit
import AVFoundation
import CryptoKit
import OCREngines
import Transcription

/// Settings → IINA Integration → "Transcribe videos without subtitles": a video IINA plays without subtitles in the
/// language read is transcribed from its file or stream (not a live one), with the model and settings in Settings →
/// Transcription, ahead of playback, into a subtitle file that MacPopup's IINA plugin shows as a track ("MacPopup
/// transcription"). Its lines then come to the box as subtitles' lines do (with their clean screenshot and audio for
/// cards), on time. Meanwhile "Read text from audio" listens to nothing (AudioTranscriber).
///
/// The plugin tells each second what each player window plays and where (iina-plugin/main.js). A video's transcript
/// (by its address, audio track, model and settings) is kept in a folder of its own in
/// Caches/com.aury.macpopup/Transcripts, with the parts of it done, so watching it again needs no more work. It's
/// transcribed from where it's played to its end, the stretches of speech found as for the app's audio
/// (SpeechStretches) and transcribed into lines as the box's are (StretchTranscriber); after a seek outside what's
/// done, from there.
@MainActor
final class VideoTranscriber {
    struct Settings: Equatable {
        var model: SpeechModel
        var language: String
        /// "Detect sentence ends".
        var growing: Bool
        /// Seconds; 0: lines don't end at pauses.
        var pause: Double
    }

    /// What a player window plays, as its plugin last told.
    struct Status {
        let key: String
        let socket: URL
        /// Its address (for the cache: a stream's own URL may change each time it's opened) and audio track.
        let media: String
        let track: String
        /// The file's name and the video's title, which the window's title is one of.
        let titles: [String]
        let position: Double
        let paused: Bool
        let duration: Double?
        /// Its subtitle tracks' languages (mpv's "lang", e.g. "jpn" or "ja", or ""), other than MacPopup's.
        let subtitles: [String]
        /// Those of the ones from files: added by the user, or by IINA from the video's folder.
        let files: [String]
        /// Where its audio is read from; nil when it can't be (e.g. a live stream).
        let audio: MediaClip.Source?
        let received = Date()

        init?(_ body: [String: Any]) {
            guard let key = body["key"] as? String, let socket = try? MediaClip.Source.localSocket(body["socket"] as? String),
                  let media = body["media"] as? String, let position = (body["position"] as? NSNumber)?.doubleValue,
                  position.isFinite
            else { return nil }
            self.key = key
            self.socket = socket
            self.media = media
            track = body["track"].map { "\($0)" } ?? ""
            titles = (body["titles"] as? [Any] ?? []).compactMap { $0 as? String }
            self.position = max(0, position)
            paused = body["paused"] as? Bool ?? false
            duration = (body["duration"] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            subtitles = (body["subtitles"] as? [Any] ?? []).map { $0 as? String ?? "" }
            files = (body["files"] as? [Any] ?? []).map { $0 as? String ?? "" }
            let audio = (body["audio"] as? [String: Any]).flatMap { try? MediaClip.Source($0, socket: socket.absoluteString) }
            if case .cache = audio {
                self.audio = nil
            } else {
                self.audio = audio
            }
        }
    }

    /// Nil: off.
    private var settings: Settings?
    /// Whether a video is being transcribed (AudioTranscriber then doesn't listen).
    private(set) var isActive = false
    /// The model it's transcribed with.
    var model: SpeechModel? { job == nil ? nil : settings?.model }
    private let onActive: () -> Void
    private let report: (Error) -> Void
    private var players: [String: Status] = [:]
    private var job: Job?
    /// When IINA's video could last be transcribed.
    private var lastWanted = Date.distantPast
    private var lastUnwanted: String?
    /// The video and settings (a job's key) the model couldn't transcribe, not tried again until the models change.
    private var failed: String?
    /// The captured window, as last looked up.
    private var captured: (window: Captured, checked: Date)?

    private enum Captured {
        case absent
        case iina(title: String)
        case other
    }

    init(onActive: @escaping () -> Void, report: @escaping (Error) -> Void) {
        self.onActive = onActive
        self.report = report
        // Players that stopped telling (closed, or IINA quit).
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // E.g. Live Caption's language packs imported.
        NotificationCenter.default.addObserver(forName: SpeechRecognizer.modelsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.failed = nil
                self?.update()
            }
        }
    }

    /// Where the transcripts are kept, a folder each; MACPOPUP_TRANSCRIPTS_DIRECTORY for test runs (ending in
    /// Library/Caches/com.aury.macpopup/Transcripts, as the plugin knows the transcript by its path).
    nonisolated static let folder = DevelopmentEnvironment["MACPOPUP_TRANSCRIPTS_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.aury.macpopup/Transcripts")

    /// Posted when a transcript is saved, or they're cleared.
    static let transcriptsChanged = Notification.Name("VideoTranscriber.transcriptsChanged")

    /// The transcripts kept (for Settings → IINA Integration): how many videos, and the bytes their files take.
    nonisolated static func kept() -> (videos: Int, bytes: Int64) {
        let manager = FileManager.default
        let videos = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var bytes: Int64 = 0
        for video in videos {
            for file in (try? manager.contentsOfDirectory(at: video, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? [] {
                bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return (videos.count, bytes)
    }

    /// Settings → IINA Integration → Clear: the transcripts kept are removed, the one being made too (without saving
    /// it again), which is then started over from where the video is played.
    func clearTranscripts() throws {
        job?.discard()
        job = nil
        defer { NotificationCenter.default.post(name: Self.transcriptsChanged, object: nil) }
        if FileManager.default.fileExists(atPath: Self.folder.path) { try FileManager.default.removeItem(at: Self.folder) }
        update()
    }

    func configure(_ settings: Settings?) {
        guard settings != self.settings else { return }
        self.settings = settings
        update()
    }

    /// A player window's status from the plugin (through the box's page, which is connected to it).
    func playerStatus(_ body: [String: Any]) {
        guard let status = Status(body) else { return }
        players[status.key] = status
        update()
    }

    private func update() {
        players = players.filter { Date().timeIntervalSince($0.value.received) < 3 }
        let status = settings == nil ? nil : player()
        let unwanted = settings == nil ? "off" : status == nil ? "no IINA video"
            : status!.subtitles.contains { Self.isLanguage($0, settings!.language) }
                || status!.files.contains { Self.isLanguage($0, settings!.language, unknown: true) } ? "it has \(settings!.language) subtitles"
            : status!.audio == nil ? "its audio can't be read ahead"
            : Self.key(status!, settings!) == failed ? "the model couldn't transcribe it" : nil
        if unwanted == nil {
            lastWanted = Date()
        } else if job != nil, settings != nil, Date().timeIntervalSince(lastWanted) < 3 {
            // Not for a moment (e.g. while a track is read again).
            if unwanted != lastUnwanted { transcriptionLog("IINA's video can't be transcribed for now: \(unwanted ?? "")") }
            lastUnwanted = unwanted
            return
        }
        lastUnwanted = unwanted
        if let settings, let status, unwanted == nil, let audio = status.audio {
            let key = Self.key(status, settings)
            if job?.key != key {
                job?.stop()
                transcriptionLog("transcribing IINA's video ahead: \(status.media)")
                job = Job(key: key, settings: settings, report: report) { [weak self] in
                    self?.failed = key
                    // Stopped now, not after a moment.
                    self?.lastWanted = .distantPast
                    self?.update()
                }
            }
            job?.source = audio
            job?.player = (status.key, status.socket)
            job?.follow(status.position, duration: status.duration)
        } else if let job {
            transcriptionLog("stopped transcribing IINA's video: \(unwanted ?? "")")
            job.stop()
            self.job = nil
        }
        if (job != nil) != isActive {
            isActive = job != nil
            onActive()
        }
    }

    /// The player window to transcribe: the captured one (Settings → General) if it's IINA's, found by its video's name
    /// as the window's title; or else one playing (the one transcribed while it plays, rather than switching each second
    /// between two that play); or else, unless another app's window is captured (whose audio "Read text from audio"
    /// then listens to), the one transcribed or the one heard from last.
    private func player() -> Status? {
        guard !players.isEmpty else { return nil }
        let recent = players.values.sorted { $0.received > $1.received }
        let window = capturedWindow()
        if case let .iina(title) = window, let status = recent.first(where: { $0.titles.contains(title) }) { return status }
        let current = job?.player?.key
        let playing = recent.filter { !$0.paused }
        if let status = playing.first(where: { $0.key == current }) ?? playing.first { return status }
        if case .other = window { return nil }
        return recent.first { $0.key == current } ?? recent.first
    }

    /// The captured window, looked up again at most every 5 seconds (that lists every window, and statuses come
    /// several times a second): an IINA window's title changes with its video.
    private func capturedWindow() -> Captured {
        if let captured, Date().timeIntervalSince(captured.checked) < 5 { return captured.window }
        let window: Captured = OCRController.savedWindow().map {
            NSRunningApplication(processIdentifier: $0.ownerPID)?.bundleIdentifier == "com.colliderli.iina" ? .iina(title: $0.title) : .other
        } ?? .absent
        captured = (window, Date())
        return window
    }

    /// Whether a subtitle track's language is `language` (Yomitan's code). One without a language known (none, "und",
    /// or a code that isn't ISO 639's) counts as English if it's in the video (most are), or as `language` if `unknown`
    /// (a file of subtitles added to the video, e.g. "Episode 1.srt": most likely those of the language read).
    static func isLanguage(_ track: String, _ language: String, unknown: Bool = false) -> Bool {
        func code(_ text: String) -> String? {
            guard let code = Locale(identifier: text).language.languageCode, code.isISOLanguage, code.identifier != "und"
            else { return nil }
            return code.identifier
        }
        guard let track = code(track) else { return unknown || code(language) ?? language == "en" }
        return track == code(language) ?? language
    }

    private static func key(_ status: Status, _ settings: Settings) -> String {
        let text = [status.media, status.track, settings.model.rawValue, settings.language, "\(settings.growing)", "\(settings.pause)"]
            .joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A video's transcript: its lines, the parts of the video done, and the part being transcribed (Worker). Kept as a
/// subtitle file for IINA and the lines' JSON, written at most every 2 seconds. The subtitle file has no extension
/// (mpv reads SubRip by its content), since mpv names a track it reads again after its file.
@MainActor
private final class Job {
    struct Entry {
        let id: Int
        var start: Double
        /// When the speech it's from ends.
        var end: Double
        var text: String
    }

    /// Seconds a line stays after its speech, and the least it's shown (unless the next one comes sooner).
    private static let hold = 0.5
    private static let shortest = 1.0
    /// IINA reads the whole track again each time it's told the transcript changed, which can make the line on screen
    /// blink (and mpv tells the plugin that line again): it's told only once a changed line starts within this many
    /// seconds of the position played, so lines transcribed far ahead are loaded together as playback nears them.
    private static let lead = 30.0

    let key: String
    let settings: VideoTranscriber.Settings
    var source: MediaClip.Source?
    /// The window showing it, and the plugin's socket.
    var player: (key: String, socket: URL)? {
        didSet { if player?.key != oldValue?.key { loaded = false } }
    }
    /// Whether the window has the transcript as a track, and the earliest start of a line changed since it last read it.
    private var loaded = false
    private var changedFrom: Double?
    /// Where the video is played, as last told.
    private var position = 0.0
    private let report: (Error) -> Void
    private let onFailed: () -> Void
    /// Stopped (another video or other settings): IINA is no longer told about it.
    private var stopped = false
    /// Cleared in Settings: no longer saved.
    private var discarded = false
    private let subtitlesURL: URL
    private let linesURL: URL
    private var entries: [Entry] = []
    private var nextID = 0
    /// The parts done, in seconds into the video: in order, apart.
    private var covered: [ClosedRange<Double>] = []
    private var duration: Double?
    private var worker: Worker?
    /// No new worker before then, after one failed.
    private var retryAfter = Date.distantPast
    private var saveScheduled = false
    private var lastSaved: Date?

    init(key: String, settings: VideoTranscriber.Settings, report: @escaping (Error) -> Void,
         onFailed: @escaping () -> Void) {
        self.key = key
        self.settings = settings
        self.report = report
        self.onFailed = onFailed
        let folder = VideoTranscriber.folder.appendingPathComponent(key)
        subtitlesURL = folder.appendingPathComponent("MacPopup transcription")
        linesURL = folder.appendingPathComponent("lines.json")
        load()
        if !entries.isEmpty { scheduleSave() }
    }

    /// Transcribes on from where the video is played (`position`), unless that's done or being done.
    func follow(_ position: Double, duration: Double?) {
        if let duration { self.duration = duration }
        self.position = position
        if let changedFrom, changedFrom < position + Self.lead { scheduleSave() }
        if let worker, position >= worker.from - 1, position <= worker.reached + 10 { return }
        if let range = covered.first(where: { $0.contains(position) }) {
            if let worker, abs(worker.from - range.upperBound) < 1 { return }
            if let duration, range.upperBound >= duration - 1 {
                stopWorker()
                return
            }
            start(at: range.upperBound)
        } else {
            // A little before, for the line being spoken.
            start(at: max(0, position - 2))
        }
    }

    func stop() {
        stopped = true
        stopWorker()
        save(notify: false)
    }

    /// Stopped, its transcript removed.
    func discard() {
        discarded = true
        stopped = true
        stopWorker()
    }

    private func start(at time: Double) {
        guard let source, Date() >= retryAfter else { return }
        stopWorker()
        let worker = Worker(job: self, from: time, settings: settings)
        self.worker = worker
        worker.start(source)
    }

    private func stopWorker() {
        guard let worker else { return }
        worker.stop()
        self.worker = nil
        if worker.finished > worker.from { add(worker.from...worker.finished) }
        scheduleSave()
    }

    private func add(_ range: ClosedRange<Double>) {
        var merged = range
        covered = covered.filter { other in
            guard other.overlaps(merged) || abs(other.lowerBound - merged.upperBound) < 0.01
                || abs(other.upperBound - merged.lowerBound) < 0.01 else { return true }
            merged = min(other.lowerBound, merged.lowerBound)...max(other.upperBound, merged.upperBound)
            return false
        }
        covered.append(merged)
        covered.sort { $0.lowerBound < $1.lowerBound }
    }

    // MARK: From the worker

    /// A line of the worker's (replacing its last one when it `grows`).
    func shown(_ line: StretchLines.Shown, speechEnd: Double, worker: Worker) {
        guard worker === self.worker else { return }
        let text = line.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if line.grows, let id = worker.lastEntry, let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text = text
            entries[index].end = max(entries[index].end, speechEnd)
            changedFrom = min(changedFrom ?? entries[index].start, entries[index].start)
        } else {
            // Already there from another time (the worker runs into a part done). Its growing doesn't replace the
            // worker's line before it.
            guard !text.isEmpty, !covered.contains(where: { $0.lowerBound <= line.start && line.start < $0.upperBound }) else {
                worker.lastEntry = nil
                return
            }
            entries.append(Entry(id: nextID, start: line.start, end: speechEnd, text: text))
            changedFrom = min(changedFrom ?? line.start, line.start)
            worker.lastEntry = nextID
            nextID += 1
        }
        scheduleSave()
    }

    /// The worker transcribed up to `worker.finished`: once that's into a part done, it goes on after it.
    func progressed(_ worker: Worker) {
        guard worker === self.worker,
              let next = covered.first(where: { $0.lowerBound > worker.from && worker.finished >= $0.lowerBound })
        else { return }
        stopWorker()
        let end = covered.first { $0.contains(next.lowerBound) }?.upperBound ?? next.upperBound
        if let duration, end >= duration - 1 { return }
        start(at: end)
    }

    /// The worker got to the video's end (at `worker.finished`), or failed.
    func ended(_ worker: Worker, error: Error?) {
        guard worker === self.worker else { return }
        if let error {
            transcriptionLog("couldn't transcribe IINA's video: \(error.localizedDescription)")
            report(error)
            retryAfter = Date().addingTimeInterval(30)
        } else if duration == nil {
            // (With the silence after it.)
            duration = worker.finished
        }
        stopWorker()
    }

    /// The model couldn't transcribe a stretch (e.g. its files aren't there, or it doesn't know the language): the
    /// rest would fail too.
    func failed(_ worker: Worker, error: Error) {
        guard worker === self.worker else { return }
        transcriptionLog("the model couldn't transcribe IINA's video: \(error.localizedDescription)")
        report(error)
        onFailed()
    }

    // MARK: Files

    private func load() {
        guard let data = try? Data(contentsOf: linesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for item in json["lines"] as? [[Any]] ?? [] {
            guard item.count == 3, let start = (item[0] as? NSNumber)?.doubleValue, let end = (item[1] as? NSNumber)?.doubleValue,
                  let text = item[2] as? String else { continue }
            entries.append(Entry(id: nextID, start: start, end: end, text: text))
            nextID += 1
        }
        for item in json["covered"] as? [[NSNumber]] ?? [] where item.count == 2 && item[0].doubleValue <= item[1].doubleValue {
            add(item[0].doubleValue...item[1].doubleValue)
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        let wait = lastSaved.map { max(0, 2 - Date().timeIntervalSince($0)) } ?? 0
        Task {
            try? await Task.sleep(for: .seconds(wait))
            saveScheduled = false
            save(notify: !stopped)
        }
    }

    private func save(notify: Bool) {
        guard !discarded else { return }
        lastSaved = Date()
        var done = covered
        if let worker, worker.finished > worker.from {
            done.append(worker.from...worker.finished)
        }
        let json: [String: Any] = [
            "lines": entries.sorted { $0.start < $1.start }.map { [$0.start, $0.end, $0.text] as [Any] },
            "covered": done.map { [$0.lowerBound, $0.upperBound] },
        ]
        do {
            try FileManager.default.createDirectory(at: linesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: linesURL, options: .atomic)
            // Replaced as a whole, so IINA never reads half of it.
            try Data(subtitles().utf8).write(to: subtitlesURL, options: .atomic)
        } catch {
            transcriptionLog("couldn't save the transcript: \(error.localizedDescription)")
            return
        }
        NotificationCenter.default.post(name: VideoTranscriber.transcriptsChanged, object: nil)
        guard notify, !entries.isEmpty, let player, !loaded || (changedFrom ?? .infinity) < position + Self.lead else { return }
        loaded = true
        changedFrom = nil
        let file = subtitlesURL, language = settings.language
        Task { [weak self] in
            do {
                try await Player.subtitles(key: player.key, file: file, language: language, socket: player.socket)
            } catch {
                transcriptionLog("IINA didn't load the transcript: \(error.localizedDescription)")
                // Told again with the next save.
                self?.loaded = false
            }
        }
    }

    /// The lines as SubRip. Each lasts until its speech ends (and `hold` after, or `shortest` in all), up to the next
    /// one; lines from the same stretch of speech (one start) share its time by their lengths.
    private func subtitles() -> String {
        let sorted = entries.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var cues: [(start: Double, end: Double, text: String)] = []
        var index = 0
        while index < sorted.count {
            var after = index + 1
            while after < sorted.count, sorted[after].start == sorted[index].start { after += 1 }
            let group = sorted[index..<after]
            let start = sorted[index].start
            let next = after < sorted.count ? sorted[after].start : .infinity
            let end = min(next, max(group.map(\.end).max()! + Self.hold, start + Self.shortest))
            let total = Double(group.reduce(0) { $0 + max(1, $1.text.count) })
            var time = start
            for entry in group {
                let length = (end - start) * Double(max(1, entry.text.count)) / total
                cues.append((time, time + length, entry.text))
                time += length
            }
            index = after
        }
        func stamp(_ seconds: Double) -> String {
            let ms = Int((seconds * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start)) --> \(stamp($0.element.end))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }
}

/// Transcribes a video from `from` on: its audio decoded (SpeechFeed) and the stretches of speech found in it
/// transcribed into lines (StretchTranscriber), one at a time and in order, with the decoding held back meanwhile.
@MainActor
private final class Worker: StretchTranscriberHost {
    let from: Double
    /// Seconds into the video up to which the stretches were all transcribed (or had no speech).
    private(set) var finished: Double
    /// Its last line (an entry of the job's), which a line that grows replaces.
    var lastEntry: Int?
    private weak var job: Job?
    private let settings: VideoTranscriber.Settings
    private var feed: SpeechFeed?
    private var transcriber: StretchTranscriber!
    private var listener = 0
    /// The stretches placed, waiting to be transcribed.
    private var cuts: [[SpeechStretches.Cut.Placed]] = []
    /// The end of the stretch being transcribed.
    private var transcribing: Double?
    /// The end of the speech last transcribed, for its lines.
    private var speechEnd: Double
    private var feedEnded = false
    private var feedError: Error?
    private var stopped = false

    init(job: Job, from: Double, settings: VideoTranscriber.Settings) {
        self.job = job
        self.from = from
        self.settings = settings
        finished = from
        speechEnd = from
        transcriber = StretchTranscriber(host: self)
        transcriber.use(SpeechRecognizer.shared(settings.model))
        transcriber.language = settings.language
        transcriber.growing = settings.growing
        listener = transcriber.startListener()
    }

    /// Up to where the audio was decoded.
    var reached: Double { feed?.reached ?? from }

    func start(_ source: MediaClip.Source) {
        let feed = SpeechFeed(from: from, pause: settings.pause, onPlaced: { [weak self] placed in
            self?.placed(placed)
        }, onEnd: { [weak self] error in
            self?.feedEnded = true
            self?.feedError = error
            self?.next()
        })
        self.feed = feed
        feed.start(source)
    }

    func stop() {
        stopped = true
        feed?.cancel()
    }

    private func placed(_ items: [SpeechStretches.Cut.Placed]) {
        guard !stopped else { return }
        cuts.append(items)
        next()
    }

    private func next() {
        guard !stopped else { return }
        while transcribing == nil, !cuts.isEmpty {
            var end: Double?
            for item in cuts.removeFirst() {
                if case let .speech(speech) = item {
                    end = speech.start + speech.duration
                    if !speech.samples.isEmpty { transcribing = end }
                }
                transcriber.heard(item, listener: listener)
            }
            if transcribing == nil { done(end) }
        }
        if transcribing == nil, cuts.isEmpty, feedEnded {
            if feedError == nil { finished = max(finished, reached) }
            job?.ended(self, error: feedError)
        }
    }

    /// A stretch is done (transcribed, or without speech to transcribe), up to `end`.
    private func done(_ end: Double?) {
        if let end { finished = max(finished, end) }
        feed?.release()
        job?.progressed(self)
    }

    // MARK: StretchTranscriberHost

    func run<T: Sendable>(_ kind: StretchTranscriber.Work, _ work: @escaping @Sendable () async -> T,
                          done: @escaping @MainActor (T) -> Void) {
        Task {
            done(await work())
            guard kind == .lines, let end = transcribing else { return }
            transcribing = nil
            self.done(end)
            next()
        }
    }

    func show(_ line: StretchLines.Shown, endsLive: Int?) {
        job?.shown(line, speechEnd: speechEnd, worker: self)
    }

    func heard(_ samples: [Float], text: String, speech: SpeechStretches.Speech, listener: Int) {
        speechEnd = speech.start + speech.duration
    }

    func showLive(_ text: String?, stretch: Int) {}
    func clearLive() {}

    func log(_ message: String) {
        transcriptionLog(message)
    }

    func transcribed(error: Error?) {
        if let error { job?.failed(self, error: error) }
    }

    func sentenceEndsFailed(_ error: Error) {
        transcriptionLog("sentence ends: \(error.localizedDescription)")
    }
}

/// A video's audio from `from` on, decoded on a thread of its own (MediaClip.decodeAudio) and given to SpeechStretches
/// on its own queue, as SpeechListener gives an app's; the stretches are placed on another one. The decoding waits
/// while two stretches are waiting to be transcribed (`release` each once it is), and at its end the audio goes on
/// in silence for a while, so that the last voice ends.
private final class SpeechFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aury.macpopup.video-transcription", qos: .utility)
    private let placing = DispatchQueue(label: "com.aury.macpopup.video-transcription.placing", qos: .utility)
    private let from: Double
    private let pause: Double
    private let stretches: SpeechStretches
    private let onEnd: @MainActor (Error?) -> Void
    private let format = AVAudioFormat(standardFormatWithSampleRate: SpeechStretches.sampleRate, channels: 1)!
    private let condition = NSCondition()
    private var waiting = 0
    private var cancelled = false
    private var decoded = 0.0

    init(from: Double, pause: Double, onPlaced: @escaping @MainActor ([SpeechStretches.Cut.Placed]) -> Void,
         onEnd: @escaping @MainActor (Error?) -> Void) {
        self.from = from
        self.pause = pause
        self.onEnd = onEnd
        let queue = queue, placing = placing, condition = condition
        stretches = SpeechStretches(pause: pause, live: false, clock: { from }, deliver: { queue.async(execute: $0) },
                                    log: transcriptionLog)
        stretches.onCut = { [weak self] cut in
            condition.withLock { self?.waiting += 1 }
            placing.async {
                let placed = cut.place(log: transcriptionLog)
                // In order, after the stretches before it (and before onEnd).
                DispatchQueue.main.async { MainActor.assumeIsolated { onPlaced(placed) } }
            }
        }
    }

    /// Up to where the audio was decoded, in seconds into the video.
    var reached: Double { condition.withLock { from + decoded } }

    func start(_ source: MediaClip.Source) {
        Thread.detachNewThread { [self] in
            var failure: Error?
            do {
                if try MediaClip.decodeAudio(source, from: from, handler: give) {
                    let silence = [Float](repeating: 0, count: 1600)
                    for _ in 0..<Int((5 + pause) * 10) {
                        guard give(silence) else { break }
                    }
                }
            } catch {
                failure = error
            }
            queue.sync { stretches.stop() }
            let onEnd = onEnd, isCancelled = condition.withLock { cancelled }
            placing.async {
                DispatchQueue.main.async { MainActor.assumeIsolated { onEnd(isCancelled ? nil : failure) } }
            }
        }
    }

    /// A stretch was transcribed.
    func release() {
        condition.withLock {
            waiting -= 1
            condition.broadcast()
        }
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    private func give(_ samples: [Float]) -> Bool {
        condition.lock()
        while waiting >= 2 && !cancelled { condition.wait() }
        let go = !cancelled
        condition.unlock()
        guard go, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        queue.sync { stretches.append(buffer) }
        condition.withLock { decoded += Double(samples.count) / SpeechStretches.sampleRate }
        return true
    }
}
