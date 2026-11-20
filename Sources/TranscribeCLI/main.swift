// transcribe-cli <whisper|animeWhisper|kitsune|senseVoice|parakeet|soda> <unpacked zip> <samples folder> <results folder> [domain ...]:
// transcribes samples/<domain>/*.wav (16 kHz mono 16-bit, listed in truth.jsonl) with the app's speech recognizers and
// writes <results folder>/<domain>.jsonl ({"file", "text", "ms"}), for checking them against the Python ones
// (scratch-tools/asr). Japanese, except eu-<language>_<region> domains (FLEURS's European languages, e.g. eu-es_419).
// Prints how long loading took.
//
// transcribe-cli install <model|sat> <zip>: loads the zip as Settings' Load button does, into MACPOPUP_MODELS_DIRECTORY
// (set it, or it's Application Support's).
//
// transcribe-cli lines <model> <unpacked zip> <recording, 16 kHz mono> <summary.log> <language> <out.jsonl>
// <setting> ...: the lines "End lines at sentence ends" makes (GrowingLines) from the stretches of speech an
// app run logged (scratch-tools/transcribe/run.sh) of the recording, for each setting of GrowingLines'
// atPause:atLongPause:withoutPause[:keptWhenHeardAgain] (":old" at the end: without hearing lines again): a row per setting, with the lines'
// starts (seconds) and text. LINES_DEBUG=1 prints each transcript with when its characters were heard.
//
// transcribe-cli ends <model> <unpacked zip> <recording> <summary.log> <language> <out.json>: where sentences start in
// the recording, as a model that punctuates well hears it (SenseVoice), with the stretches transcribed together up to
// 28 s: after its 。！？ and where the voice starts again ("starts", seconds); and its text, with when each character
// was heard ("times").
//
// transcribe-cli sat <talk.jsonl> <out.jsonl>: SaT's sentence end probabilities for each row's "bare" text
// (scratch-tools/punct/make-talk.py), as {"p": [per character]}, for checking against wtpsplit.
import Foundation
import Transcription

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "install", arguments[2] == "sat" {
    let started = Date()
    try await SentenceEnds.shared.installModels(from: URL(fileURLWithPath: arguments[3]))
    print(String(format: "installed and loaded in %.1f s", Date().timeIntervalSince(started)))
    exit(0)
}
if arguments.count == 4, arguments[1] == "sat" {
    let rows = try String(contentsOfFile: arguments[2], encoding: .utf8).split(separator: "\n")
    let started = Date()
    try await SentenceEnds.shared.load()
    print(String(format: "loaded in %.1f s", Date().timeIntervalSince(started)))
    var out = "", total = 0.0
    for row in rows {
        let text = (try JSONSerialization.jsonObject(with: Data(row.utf8)) as! [String: Any])["bare"] as! String
        let start = Date()
        let probabilities = try await SentenceEnds.shared.probabilities(text)
        total += Date().timeIntervalSince(start)
        out += String(decoding: try JSONSerialization.data(withJSONObject: ["p": probabilities]), as: UTF8.self) + "\n"
    }
    try out.write(toFile: arguments[3], atomically: true, encoding: .utf8)
    print(String(format: "%.1f ms per text", total / Double(rows.count) * 1000))
    exit(0)
}
if arguments.count >= 9 && arguments[1] == "lines" || arguments.count == 8 && arguments[1] == "ends", let model = SpeechModel(rawValue: arguments[2]) {
    let recognizer = SpeechRecognizer(model, directory: URL(fileURLWithPath: arguments[3]))
    let audio = try read(URL(fileURLWithPath: arguments[4]))
    let stretches = try loggedStretches(arguments[5])
    let language = arguments[6]
    var out = ""
    func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }
    /// LINES_PADDING: seconds of audio kept around the voice, as the app's SpeechListener.padding (within the stretch and
    /// after the one before).
    let padding = Double(ProcessInfo.processInfo.environment["LINES_PADDING"] ?? "") ?? 0
    /// Where a stretch's samples start, as the app's Speech.start.
    func samplesStart(_ stretch: LoggedStretch) -> Double { max(stretch.start - padding, stretch.after) }
    func samples(_ stretch: LoggedStretch) -> [Float] {
        let start = samplesStart(stretch), end = min(stretch.end + padding, stretch.before)
        return Array(audio[min(Int(start * 16000), audio.count)..<min(Int(max(start, end) * 16000), audio.count)])
    }
    if arguments[1] == "ends" {
        // The stretches transcribed together, up to 28 s or where the voice stopped.
        var group: [LoggedStretch] = []
        var starts: [Double] = []
        var text = ""
        /// When each of `text`'s characters was heard.
        var times: [Double] = []
        /// The next group starts a sentence.
        var startsSentence = false
        func transcribeGroup() async throws {
            guard let first = group.first, let last = group.last else { return }
            var speech = JoinedSpeech()
            for stretch in group { speech.append(samples(stretch), heardAt: samplesStart(stretch)) }
            let transcript = try await recognizer.transcribe(speech.samples, language: language)
            text += transcript.text
            times += (transcript.times ?? Array(repeating: 0, count: transcript.text.count)).map(speech.time)
            if startsSentence { starts.append(first.start) }
            let characters = Array(transcript.text), times = transcript.times ?? []
            for index in characters.indices where "。！？!?".contains(characters[index]) && index + 1 < times.count {
                starts.append(speech.time(at: times[index + 1]))
            }
            startsSentence = last.endsVoice || characters.last.map { "。！？!?".contains($0) } == true
            group = []
        }
        for stretch in stretches {
            if let first = group.first, stretch.end - first.start > 28 { try await transcribeGroup() }
            if stretch.end > stretch.start { group.append(stretch) }
            if stretch.endsVoice { try await transcribeGroup() }
        }
        try await transcribeGroup()
        out = try json(["starts": starts, "text": text, "times": times])
    } else {
        for setting in arguments.dropFirst(8) {
            let values = setting.split(separator: ":").compactMap { Float($0) }
            var lines = GrowingLines()
            (lines.endAtPause, lines.endAtLongPause, lines.endWithoutPause) = (values[0], values[1], values[2])
            if values.count > 3 { lines.keptWhenHeardAgain = Double(values[3]) }
            // ":old": the lines without hearing them again (as for a model that doesn't tell when it heard what).
            let old = setting.hasSuffix(":old")
            var shown: [[String: Any]] = []
            /// Times hearing the shown line again gave under 80% of its characters (punctuation aside) for its speech,
            /// and the characters lost.
            var shrunk = 0, lost = 0
            let spoken = { (text: String) in text.count { !$0.isPunctuation && !$0.isWhitespace } }
            for stretch in stretches {
                let speech = samples(stretch)
                guard !speech.isEmpty else {
                    // Too quiet to transcribe.
                    if stretch.endsVoice { lines.end() }
                    continue
                }
                var earlier = lines.earlier(before: speech)
                var transcript = try await recognizer.transcribe((earlier ?? []) + speech, language: language)
                if let folder = ProcessInfo.processInfo.environment["LINES_DUMP"], earlier != nil {
                    // The audio heard again with the stretch, as 16-bit 16 kHz WAV.
                    let samples = ((earlier ?? []) + speech).map { Int16(max(-1, min(1, $0)) * 32767) }
                    var wav = Data("RIFF".utf8)
                    let size = UInt32(samples.count * 2)
                    for value in [36 + size] { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
                    wav.append(contentsOf: Data("WAVEfmt ".utf8))
                    for value: UInt32 in [16, 1 | 1 << 16, 16000, 32000, 2 | 16 << 16] { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
                    wav.append(contentsOf: Data("data".utf8))
                    withUnsafeBytes(of: size.littleEndian) { wav.append(contentsOf: $0) }
                    samples.withUnsafeBytes { wav.append(contentsOf: $0) }
                    try wav.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%.2f+%.2f.wav", stretch.start, Double(earlier!.count) / 16000)))
                }
                if old { transcript = Transcript(text: transcript.text) }
                if ProcessInfo.processInfo.environment["LINES_DEBUG"] != nil {
                    let timed = zip(transcript.text, transcript.times ?? []).map { String(format: "%@%.2f", String($0), $1) }
                    FileHandle.standardError.write(Data(String(format: "%.2f s (+%.2f s again): %@\n", stretch.start,
                        Double(earlier?.count ?? 0) / 16000, timed.joined(separator: " ")).utf8))
                }
                if let earlier, let last = shown.last?["text"] as? String {
                    let seconds = Double(earlier.count) / 16000
                    let join = transcript.times?.firstIndex { $0 >= seconds } ?? transcript.text.count
                    let heard = spoken(String(transcript.text.prefix(join)))
                    if Double(heard) < Double(spoken(last)) * 0.8 { (shrunk, lost) = (shrunk + 1, lost + spoken(last) - heard) }
                }
                if earlier != nil, lines.heardWorse(transcript) {
                    let unheard = lines.unheard()
                    earlier = unheard
                    transcript = try await recognizer.transcribe(unheard + speech, language: language)
                }
                let joined = lines.join(transcript, earlier: earlier, stretchDuration: Double(speech.count) / 16000)
                let probabilities = joined.text.isEmpty ? nil : try await SentenceEnds.shared.probabilities(joined.text)
                for line in lines.add(joined, probabilities: probabilities, stretch: speech, start: samplesStart(stretch),
                                      pause: stretch.pause, language: language) {
                    let row: [String: Any] = ["start": line.start, "text": line.text]
                    if line.grows, !shown.isEmpty { shown[shown.count - 1] = row } else { shown.append(row) }
                }
            }
            out += try json(["setting": setting, "lines": shown, "shrunk": shrunk, "lost": lost])
        }
    }
    try out.write(toFile: arguments[7], atomically: true, encoding: .utf8)
    exit(0)
}

/// A stretch of speech given in a run of the app (its summary.log): seconds into the recording, and the seconds of quiet
/// after it, as SpeechListener.Speech's (a stretch too quiet to transcribe has no length).
struct LoggedStretch {
    let start, end, pause: Double
    /// Where the stretch the classifier heard ended and where the one before it did.
    var before = Double.infinity, after = 0.0
    var endsVoice: Bool { pause.isInfinite }
}

func loggedStretches(_ path: String) throws -> [LoggedStretch] {
    let pattern = try NSRegularExpression(pattern: #"speech ([\d.]+)–([\d.]+) s, (?:finely ([\d.]+)–([\d.]+) s|too quiet)(, voice ended|, ([\d.]+) s pause)?"#)
    let log = try String(contentsOfFile: path, encoding: .utf8)
    var previousEnd = 0.0
    return pattern.matches(in: log, range: NSRange(log.startIndex..., in: log)).map { match in
        let value = { (index: Int) in Range(match.range(at: index), in: log).flatMap { Double(log[$0]) } }
        let ended = Range(match.range(at: 5), in: log).map { log[$0] == ", voice ended" } ?? false
        let pause = ended ? .infinity : value(6) ?? 0
        defer { previousEnd = value(2) ?? previousEnd }
        guard let start = value(3), let end = value(4) else { return LoggedStretch(start: 0, end: 0, pause: pause) }
        return LoggedStretch(start: start, end: end, pause: pause, before: value(2) ?? .infinity, after: previousEnd)
    }
}

if arguments.count == 4, arguments[1] == "install", let model = SpeechModel(rawValue: arguments[2]) {
    let started = Date()
    try await SpeechRecognizer(model).installModels(from: URL(fileURLWithPath: arguments[3]))
    print(String(format: "installed and loaded in %.1f s", Date().timeIntervalSince(started)))
    exit(0)
}
guard arguments.count >= 5, let model = SpeechModel(rawValue: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: transcribe-cli <model> <models> <samples> <results> [domain ...]\n".utf8))
    exit(2)
}
let samples = URL(fileURLWithPath: arguments[3]), results = URL(fileURLWithPath: arguments[4])
let domains = arguments.count > 5 ? Array(arguments[5...]) : ["galgame", "anime", "reazon", "cv8", "fleurs"]

/// A 16-bit WAV's samples, -1 to 1.
func read(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        if id == "data" {
            return data[offset + 8..<min(offset + 8 + size, data.count)].withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
            }
        }
        offset += 8 + size + size % 2
    }
    throw CocoaError(.fileReadCorruptFile)
}

let recognizer = SpeechRecognizer(model, directory: URL(fileURLWithPath: arguments[2]))
let started = Date()
try await recognizer.load()
print(String(format: "loaded in %.1f s", Date().timeIntervalSince(started)))
/// The domain's language, as Yomitan's code.
func language(_ domain: String) -> String {
    domain.hasPrefix("eu-") ? String(domain.dropFirst(3).prefix { $0 != "_" }) : "ja"
}
_ = try await recognizer.transcribe(try read(samples.appendingPathComponent("\(domains[0])/000.wav")), language: language(domains[0]))
try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
for domain in domains {
    var out = ""
    let truth = try String(contentsOf: samples.appendingPathComponent("\(domain)/truth.jsonl"), encoding: .utf8)
    for line in truth.split(separator: "\n") {
        let file = (try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])["file"] as! String
        let audio = try read(samples.appendingPathComponent("\(domain)/\(file)"))
        let start = Date()
        let text = try await recognizer.transcribe(audio, language: language(domain)).text
        let ms = (Date().timeIntervalSince(start) * 10000).rounded() / 10
        out += String(decoding: try JSONSerialization.data(withJSONObject: ["file": file, "text": text, "ms": ms] as [String: Any]), as: UTF8.self) + "\n"
    }
    try out.write(to: results.appendingPathComponent("\(domain).jsonl"), atomically: true, encoding: .utf8)
    print(domain, "done")
}
