// transcribe-cli <whisper|animeWhisper|kitsune|senseVoice|parakeet> <unpacked zip> <samples folder> <results folder> [domain ...]:
// transcribes samples/<domain>/*.wav (16 kHz mono 16-bit, listed in truth.jsonl) with the app's speech recognizers and
// writes <results folder>/<domain>.jsonl ({"file", "text", "ms"}), for checking them against the Python ones
// (scratch-tools/asr). Japanese, except eu-<language>_<region> domains (FLEURS's European languages, e.g. eu-es_419).
// Prints how long loading took.
//
// transcribe-cli install <model> <zip>: loads the zip as Settings' Load button does, into MACPOPUP_MODELS_DIRECTORY
// (set it, or it's Application Support's).
import Foundation
import Transcription

let arguments = CommandLine.arguments
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
        let text = try await recognizer.transcribe(audio, language: language(domain))
        let ms = (Date().timeIntervalSince(start) * 10000).rounded() / 10
        out += String(decoding: try JSONSerialization.data(withJSONObject: ["file": file, "text": text, "ms": ms] as [String: Any]), as: UTF8.self) + "\n"
    }
    try out.write(to: results.appendingPathComponent("\(domain).jsonl"), atomically: true, encoding: .utf8)
    print(domain, "done")
}
