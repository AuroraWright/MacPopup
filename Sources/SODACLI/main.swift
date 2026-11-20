import Foundation
@testable import SODA

// soda-cli features <pack SODAModels> <file.wav> <out>: the front end's encoder input frames.
// soda-cli search <pack SODAModels> <symbols.json> <encoder frames>: the best hypothesis's raw text after the beam
// search over encoder outputs (from soda-ref --encoder).
// Frame files: int32 dimension, then float32 frames.

func readWAV(_ path: String) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) })
        if id == "data" {
            return data.withUnsafeBytes { raw in
                (0..<min(size, data.count - offset - 8) / 2).map {
                    Float(raw.loadUnaligned(fromByteOffset: offset + 8 + 2 * $0, as: Int16.self))
                }
            }
        }
        offset += 8 + size + size % 2
    }
    throw SODAError("no data chunk in \(path)")
}

func readFrames(_ path: String) throws -> [[Float]] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return data.withUnsafeBytes { raw in
        let dim = Int(raw.loadUnaligned(as: Int32.self))
        let count = (data.count - 4) / 4 / dim
        return (0..<count).map { f in (0..<dim).map { raw.loadUnaligned(fromByteOffset: 4 + 4 * (f * dim + $0), as: Float.self) } }
    }
}

func writeFrames(_ frames: [[Float]], _ path: String) throws {
    var data = Data()
    withUnsafeBytes(of: Int32(frames.first?.count ?? 0)) { data.append(contentsOf: $0) }
    for f in frames { f.withUnsafeBytes { data.append(contentsOf: $0) } }
    try data.write(to: URL(fileURLWithPath: path))
}

func loadConfig(_ models: URL) throws -> PipelineConfig {
    try SODAPack.config(models)
}

func json(_ r: SODAResult) -> String {
    func q(_ s: String) -> String { String(decoding: try! JSONEncoder().encode(s), as: UTF8.self) }
    let words = r.words.map { "[\($0.startMs),\(q($0.rawText)),\(q($0.text))]" }.joined(separator: ",")
    return "{\"start\":\(r.startMs),\"end\":\(r.endMs),\"raw\":\(q(r.rawText)),\"text\":\(q(r.text)),\"words\":[\(words)]}"
}

/// opensoda's tflite-run tensor files: int32 type, int32 rank, int32 dims, raw data.
func readTensor(_ path: String) throws -> Tensor {
    let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    func int(_ at: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: at, as: Int32.self)) } }
    let shape = (0..<int(4)).map { int(8 + 4 * $0) }
    let raw = Array(data[(8 + 4 * shape.count)...])
    func values<T>(_: T.Type) -> [T] {
        raw.withUnsafeBytes { r in (0..<raw.count / MemoryLayout<T>.size).map { r.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self) } }
    }
    let data_: TensorData = switch int(0) {
    case 0, 1: .float(values(Float.self))
    case 2: .int32(values(Int32.self))
    case 3: .uint8(raw)
    case 4: .int64(values(Int64.self))
    case 5: .string(TFLiteModel.strings(raw))
    case 6: .bool(raw.map { $0 != 0 })
    case 9: .int8(values(Int8.self))
    default: fatalError("tensor type \(int(0))")
    }
    return Tensor(shape: shape, data: data_)
}

func writeTensor(_ t: Tensor, _ path: String) throws {
    var out = Data()
    func int(_ v: Int) { withUnsafeBytes(of: Int32(v)) { out.append(contentsOf: $0) } }
    func raw<T>(_ v: [T]) { v.withUnsafeBytes { out.append(contentsOf: $0) } }
    let type: Int = switch t.data {
    case .float: 1
    case .int32: 2
    case .uint8: 3
    case .int64: 4
    case .string: 5
    case .bool: 6
    case .int8: 9
    case .int16: 7
    case .resource: 13
    }
    int(type)
    int(t.shape.count)
    t.shape.forEach(int)
    switch t.data {
    case .float(let v): raw(v)
    case .int32(let v): raw(v)
    case .uint8(let v): raw(v)
    case .int64(let v): raw(v)
    case .int8(let v): raw(v)
    case .int16(let v): raw(v)
    case .bool(let v): raw(v.map { $0 ? UInt8(1) : 0 })
    case .string(let v):
        // TFLite's string buffer: count, offsets, bytes.
        int(v.count)
        var offset = 4 * (v.count + 2)
        for s in v { int(offset); offset += s.count }
        int(offset)
        v.forEach { out.append(contentsOf: $0) }
    case .resource: break
    }
    try out.write(to: URL(fileURLWithPath: path))
}

var args = CommandLine.arguments
if args[1] == "sentence" {
    // sentence <out> <word>...: the Roadrunner capitalization model's input for the words, as a tensor file.
    let s = RoadrunnerCapitalizer.sentence(args[3...].map { Array($0.utf8) }[...])
    try! writeTensor(Tensor(shape: [1], data: .string([s])), args[2])
    exit(0)
}
if args[1] == "tflite" {
    // tflite <model.tflite> <out dir> <input>...: every tensor of the model's first subgraph after a run, as
    // opensoda's tflite-run --all writes them.
    do {
        let interpreter = try Interpreter(contentsOf: URL(fileURLWithPath: args[2]))
        let start = Date()
        let values = try interpreter.runAll(try args[4...].map(readTensor))
        print(String(format: "%.1f ms", Date().timeIntervalSince(start) * 1000))
        for (i, t) in values.enumerated() {
            guard let t, interpreter.model.subgraphs[0].tensors[i].constant == nil else { continue }
            try writeTensor(t, "\(args[3])/\(i).bin")
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
    exit(0)
}
do {
    let models = URL(fileURLWithPath: args[2])
    var config = try loadConfig(models)
    // --eos-penalty <x>: the first pass's </S> penalty instead of the config's (above 0, the model can end utterances
    // mid-stretch), for checking those finals against soda-ref --eos-penalty.
    if let i = args.firstIndex(of: "--eos-penalty"), i + 1 < args.count, let x = Float(args[i + 1]) {
        config.decoder.eosPenalty = x
        args.removeSubrange(i...(i + 1))
    }
    // --no-resume-search: a final mid-stretch restarts the search from <S> (as soda-ref --no-resume-search).
    if let i = args.firstIndex(of: "--no-resume-search") {
        config.decoder.resumeSearch = false
        args.remove(at: i)
    }
    switch args[1] {
    case "stages":
        // stages <models>: the caption text stages the config lists.
        for d in config.denormalizers {
            print(d.spokenPunctuationSettings.isEmpty ? (d.classNormalizer ? "class" : "fst") : "pqrnn-spoken",
                  d.file, d.beforeCapitalization ? "precase" : "")
        }
        if !config.capitalizationTransducerFile.isEmpty { print("truecaser", config.capitalizationTransducerFile) }
        if !config.capitalizationModelFile.isEmpty { print("capitalizer", config.capitalizationModelFile) }
        if let t = config.spokenPunctuationType { print("spoken-punctuation type", t) }
        print("symbols", config.symbolsFile)
        if !config.cascade.encoder.file.isEmpty { print("cascade", config.cascade.encoder.file) }
        print("eos", config.decoder.eosID, config.decoder.eosPenalty, config.cascade.decoder.eosID,
              config.cascade.decoder.eosPenalty)
    case "capitalize":
        // capitalize <models> <word>...: the pack's Roadrunner capitalization of the words.
        let c = try RoadrunnerCapitalizer(model: models.appendingPathComponent(config.capitalizationModelFile),
                                          window: config.capitalizationWindow, left: config.capitalizationLeft,
                                          right: config.capitalizationRight)
        print("window", config.capitalizationWindow, config.capitalizationLeft, config.capitalizationRight)
        var words = Array(args[3...])
        c.apply(&words)
        print(words.joined(separator: " "))
    case "encoder-inputs":
        // encoder-inputs <models> <wav> <T> <out dir>: the encoder's inputs for its first call on T frames (zero
        // states), as tensor files 0.bin, 1.bin... for tflite-run and soda-cli tflite.
        let (mean, stddev) = try loadMeanStddev(models.appendingPathComponent(config.frontend.meanStddevFile))
        var frontend = try Frontend(config.frontend, mean: mean, stddev: stddev)
        var frames: [[Float]] = []
        var audio = try readWAV(args[3])
        var gain = GainControl(config.gainControl)
        gain.process(&audio)
        frontend.accept(audio, into: &frames)
        let t = Int(args[4])!
        let interpreter = try Interpreter(contentsOf: models.appendingPathComponent(config.encoder.file))
        let graph = interpreter.model.subgraphs[0]
        for (slot, i) in graph.inputs.enumerated() {
            let info = graph.tensors[i]
            let n = info.shape.reduce(1, *)
            let tensor: Tensor = switch slot == 0 ? .float32 : info.type {
            case _ where slot == 0: Tensor(frames.prefix(t).flatMap { $0 }, shape: [1, t, info.shape[2]])
            case .bool: Tensor(shape: info.shape, data: .bool([Bool](repeating: false, count: n)))
            case .int32: Tensor(shape: info.shape, data: .int32([Int32](repeating: info.name == "domain_id" ? Int32(config.encoder.domainIDs["CAPTION"] ?? max(0, config.encoder.defaultDomainID)) : 0, count: n)))
            default: Tensor(shape: info.shape, data: .float([Float](repeating: 0, count: n)))
            }
            try writeTensor(tensor, "\(args[5])/in\(slot).bin")
        }
    case "features":
        let (mean, stddev) = try loadMeanStddev(models.appendingPathComponent(config.frontend.meanStddevFile))
        var frontend = try Frontend(config.frontend, mean: mean, stddev: stddev)
        var frames: [[Float]] = []
        var audio = try readWAV(args[3])
        var gain = GainControl(config.gainControl)
        gain.process(&audio)
        frontend.accept(audio, into: &frames)
        frontend.flush(into: &frames)
        try writeFrames(frames, args[4])
        print(frames.count, "frames")
    case "search":
        let symbols = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let decoder = try PredictionNetwork(models.appendingPathComponent(config.decoder.decoderFile))
        let joint = try JointNetwork(models.appendingPathComponent(config.decoder.jointFile))
        let search = BeamSearch(decoder: decoder, joint: joint, config: config.decoder)
        let start = Date()
        for frame in try readFrames(args[4]) { try search.advance(frame) }
        let labels = search.best.labels
        print(labels.map { symbols[$0] }.joined(separator: " "))
        print(String(format: "%.2f s, %d frames", Date().timeIntervalSince(start), search.frames))
    case "recognize":
        // recognize <models> <symbols.json> <file.wav>=<encoder outputs>...: one JSON line per file, as soda-ref's.
        // --no-punctuation leaves the punctuation model out.
        let symbols = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let punctuation = !args.contains("--no-punctuation")
        for pair in args[4...] where pair != "--no-punctuation" {
            // <file.wav>[=<encoder outputs>[,<cascade encoder outputs>]]: without outputs, the pack's encoders run
            // in the Swift TFLite interpreter.
            let parts = pair.split(separator: "=").map(String.init)
            let encoder: FrameEncoder, cascade: FrameEncoder?
            if parts.count > 1 {
                let files = parts[1].split(separator: ",").map(String.init)
                encoder = RecordedEncoder(try readFrames(files[0]))
                cascade = files.count > 1 ? RecordedEncoder(try readFrames(files[1])) : nil
            } else {
                func load(_ e: PipelineConfig.Encoder) throws -> TFLiteEncoder {
                    let encoder = try TFLiteEncoder(contentsOf: models.appendingPathComponent(e.file))
                    if e.defaultDomainID >= 0 { encoder.domainID = e.domainIDs["CAPTION"] ?? e.defaultDomainID }
                    return encoder
                }
                encoder = try load(config.encoder)
                cascade = config.cascade.encoder.file.isEmpty ? nil : try load(config.cascade.encoder)
            }
            let recognizer = try SODARecognizer(models: models, config: config, symbols: symbols, encoder: encoder,
                                                cascadeEncoder: cascade, punctuation: punctuation)
            let wav = parts[0]
            // SODA_ENCODER_OUT=<file>: the encoder outputs, as soda-ref --encoder writes them (and <file>2 the
            // cascaded encoder's).
            var tapped: [[[Float]]] = [[], []]
            if ProcessInfo.processInfo.environment["SODA_ENCODER_OUT"] != nil {
                recognizer.encoderTap = { tapped[$0].append($1) }
            }
            let start = Date()
            let r = try recognizer.recognize(try readWAV(wav))
            if let out = ProcessInfo.processInfo.environment["SODA_ENCODER_OUT"] {
                try writeFrames(tapped[0], out)
                if !tapped[1].isEmpty { try writeFrames(tapped[1], out + "2") }
            }
            if ProcessInfo.processInfo.environment["SODA_TIME"] != nil {
                FileHandle.standardError.write(String(format: "%.3f s\n", Date().timeIntervalSince(start)).data(using: .utf8)!)
            }
            // Each final, as soda-ref prints them.
            for f in recognizer.finals.count > 1 ? recognizer.finals : [r] { print(json(f)) }
        }
    default:
        print("unknown command")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
