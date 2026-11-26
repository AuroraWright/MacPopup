import Accelerate
import CoreML
import Foundation
import OCREngines

/// A token and the frame it was read at.
typealias FrameToken = (token: Int, frame: Int)

/// Greedy CTC decoding: each frame's likeliest token, repeats merged, blanks dropped.
/// - Parameters:
///   - logits: [frames][vocabulary] floats, `rowStride` apart.
func ctcTokens(_ logits: UnsafePointer<Float>, frames: Int, vocabulary: Int, rowStride: Int, blank: Int) -> [FrameToken] {
    var tokens: [FrameToken] = []
    var previous = -1
    for frame in 0..<frames {
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(logits + frame * rowStride, 1, &value, &index, vDSP_Length(vocabulary))
        let token = Int(index)
        if token != previous && token != blank { tokens.append((token, frame)) }
        previous = token
    }
    return tokens
}

/// SentencePiece pieces to text ("▁" starts a word), each character heard when its piece was: at its frame times
/// `seconds`, plus `offset`.
func detokenize(_ tokens: [FrameToken], vocabulary: [String], seconds: Double, offset: Double = 0) -> Transcript {
    var scalars = String.UnicodeScalarView()
    var scalarTimes: [Double] = []
    for (token, frame) in tokens where token < vocabulary.count {
        for scalar in vocabulary[token].unicodeScalars {
            scalars.append(scalar == "▁" ? " " : scalar)
            scalarTimes.append(offset + Double(frame) * seconds)
        }
    }
    let text = String(scalars)
    var times: [Double] = []
    var index = 0
    for character in text {
        times.append(scalarTimes[index])
        index += character.unicodeScalars.count
    }
    return Transcript(text: text, times: times)
}

func loadVocabulary(_ url: URL) throws -> [String] {
    guard let vocabulary = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String] else {
        throw ConvertedModelsKind.Failure("\(url.lastPathComponent) isn’t a valid token list. Regenerate the model’s .zip archive.")
    }
    return vocabulary
}

/// Reads a model's output in body as 32-bit floats, with its shape and strides (16-bit outputs are converted).
func withOutput<T>(_ provider: MLFeatureProvider, _ name: String, _ body: (UnsafePointer<Float>, [Int], [Int]) throws -> T) throws -> T {
    guard let array = provider.featureValue(for: name)?.multiArrayValue,
          array.dataType == .float32 || array.dataType == .float16 else {
        throw ConvertedModelsKind.Failure("The model is missing output “\(name)”. Regenerate its .zip archive.")
    }
    let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
    guard array.dataType == .float16 else {
        return try array.withUnsafeBufferPointer(ofType: Float.self) { try body($0.baseAddress!, shape, strides) }
    }
    let count = zip(shape, strides).map { ($0 - 1) * $1 }.reduce(1, +)
    var converted = [Float](repeating: 0, count: count)
    array.withUnsafeBufferPointer(ofType: Float16.self) { source in
        converted.withUnsafeMutableBufferPointer { target in
            var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            var output = vImage_Buffer(data: target.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
            vImageConvert_Planar16FtoPlanarF(&input, &output, 0)
        }
    }
    return try converted.withUnsafeBufferPointer { try body($0.baseAddress!, shape, strides) }
}

func multiArray(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
    array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
        _ = values.withUnsafeBufferPointer { memcpy(pointer.baseAddress!, $0.baseAddress!, $0.count * 4) }
    }
    return array
}

func int32Array(_ value: Int) -> MLMultiArray {
    let array = try! MLMultiArray(shape: [1], dataType: .int32)
    array[0] = NSNumber(value: value)
    return array
}

/// Kitsune-Transcribe P-0.3B (scripts/convert-kitsune.py): Parakeet's log-mel features, computed here as transformers'
/// ParakeetFeatureExtractor does, then the encoder and CTC head on the Neural Engine. The model has one fixed-length
/// function per bucket of input lengths (with flexible lengths Core ML ran it all on the CPU). Only the longest bucket's
/// function is loaded, all audio padded to it, with the same text as with the bucket of each line's length (198 of 200
/// game clips; the others a character apart). On the Neural Engine it takes 84 ms (M1 Max; first load 20 s) and 68 MB,
/// leaving the GPU to the game; on the GPU, 43 ms but 710 MB. Transcriptions may run at the same time: nothing changes
/// after init.
final class KitsuneRecognizer: Recognizer, @unchecked Sendable {
    /// The input frames the model takes, the longest bucket's.
    private let frames: Int
    private let blank: Int
    private let kernel, stride, layers: Int
    private let preemphasis: Float
    private let fftSize, window, hop: Int
    private let mel: [Float]
    private let melCount: Int
    private let vocabulary: [String]
    private let hann: [Float]
    private let fft: FFTSetup
    /// The longest bucket's function, loaded in init and only read after.
    private let model: MLModel

    init(directory: URL) throws {
        guard let info = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("kitsune.json"))) as? [String: Any],
              let frames = (info["buckets"] as? [Int])?.max(), let blank = info["blank"] as? Int,
              let subsampling = info["subsampling"] as? [String: Int], let kernel = subsampling["kernel"],
              let stride = subsampling["stride"], let layers = subsampling["layers"],
              let preemphasis = info["preemphasis"] as? Double, let fftSize = info["nFFT"] as? Int,
              let window = info["window"] as? Int, let hop = info["hop"] as? Int, info["sampleRate"] as? Int == 16000
        else { throw ConvertedModelsKind.kitsune.unexpectedModels }
        self.frames = frames
        self.blank = blank
        (self.kernel, self.stride, self.layers) = (kernel, stride, layers)
        self.preemphasis = Float(preemphasis)
        (self.fftSize, self.window, self.hop) = (fftSize, window, hop)
        let bins = fftSize / 2 + 1
        mel = try Data(contentsOf: directory.appendingPathComponent("mel.bin")).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        melCount = mel.count / bins
        guard melCount * bins == mel.count, fftSize.nonzeroBitCount == 1 else {
            throw ConvertedModelsKind.kitsune.unexpectedModels
        }
        vocabulary = try loadVocabulary(directory.appendingPathComponent("vocab.json"))
        // torch.hann_window(window, periodic=False), centered in the FFT's frame as torch.stft pads it.
        let offset = (fftSize - window) / 2
        hann = (0..<fftSize).map { index in
            let n = index - offset
            guard n >= 0 && n < window else { return 0 }
            return Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(window - 1)))
        }
        fft = vDSP_create_fftsetup(vDSP_Length(fftSize.trailingZeroBitCount), FFTRadix(kFFTRadix2))!
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.functionName = "b\(frames)"
        model = try MLModel(contentsOf: directory.appendingPathComponent("coreml/Kitsune.mlmodelc"), configuration: configuration)
        // A prediction now, as the first one takes longer.
        _ = try predict(features: [Float](repeating: 0, count: frames * melCount), valid: 1)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }


    /// Normalized log-mel features, [frames][melCount], and how many frames are the audio's (the last one isn't).
    func features(_ samples: [Float]) -> (values: [Float], frames: Int, valid: Int) {
        let count = samples.count
        let bins = fftSize / 2 + 1
        let pad = fftSize / 2
        var signal = [Float](repeating: 0, count: count + 2 * pad)
        if count > 0 {
            signal[pad] = samples[0]
            for index in 1..<count {
                signal[pad + index] = samples[index] - preemphasis * samples[index - 1]
            }
        }
        let frames = 1 + count / hop
        let valid = count / hop
        var power = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2), imaginary = [Float](repeating: 0, count: fftSize / 2)
        let log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                for index in 0..<frames {
                    signal.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + index * hop, 1, hann, 1, &frame, 1, vDSP_Length(fftSize)) }
                    frame.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2)) }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip's results are twice the DFT's; the first pair holds the DC and Nyquist bins.
                    let row = index * bins
                    power[row] = (realPointer[0] / 2) * (realPointer[0] / 2)
                    power[row + bins - 1] = (imaginaryPointer[0] / 2) * (imaginaryPointer[0] / 2)
                    for bin in 1..<fftSize / 2 {
                        let re = realPointer[bin] / 2, im = imaginaryPointer[bin] / 2
                        power[row + bin] = re * re + im * im
                    }
                }
            }
        }
        // [frames][bins] × [melCount][bins]ᵀ, then log(x + 2⁻²⁴).
        var values = [Float](repeating: 0, count: frames * melCount)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(melCount), Int32(bins),
                    1, power, Int32(bins), mel, Int32(bins), 0, &values, Int32(melCount))
        for index in values.indices {
            values[index] = log(values[index] + 5.9604645e-8)
        }
        // Each mel band normalized over the audio's frames (variance with n - 1); the rest zero.
        for band in 0..<melCount {
            var sum: Float = 0
            for index in 0..<valid { sum += values[index * melCount + band] }
            let mean = sum / Float(max(valid, 1))
            var squares: Float = 0
            for index in 0..<valid {
                let difference = values[index * melCount + band] - mean
                squares += difference * difference
            }
            let deviation = (squares / Float(max(valid - 1, 1))).squareRoot()
            for index in 0..<frames {
                values[index * melCount + band] = index < valid ? (values[index * melCount + band] - mean) / (deviation + 1e-5) : 0
            }
        }
        return (values, frames, valid)
    }

    /// The encoder's output length for `frames` input frames.
    private func outputFrames(_ frames: Int) -> Int {
        var length = Double(frames)
        let padding = Double((kernel - 1) / 2 * 2 - kernel)
        for _ in 0..<layers {
            length = ((length + padding) / Double(stride) + 1).rounded(.down)
        }
        return Int(length)
    }

    /// The stretch so far again every 0.5 s (about 85 ms each time, however long it is).
    func live(language: String) async throws -> (any LiveTranscription)? {
        RepeatedTranscription(self, language: language, interval: 0.5)
    }

    func transcribe(_ samples: [Float], language: String) async throws -> Transcript {
        let longest = (frames - 1) * hop
        var (values, count, valid) = features(samples.count > longest ? Array(samples.prefix(longest)) : samples)
        guard valid > 0 else { return Transcript() }
        values += [Float](repeating: 0, count: (frames - count) * melCount)
        // An output frame is `stride` to the power of `layers` input frames, of `hop` samples at 16 kHz.
        let seconds = Double(hop) * pow(Double(stride), Double(layers)) / 16000
        return detokenize(try predict(features: values, valid: valid), vocabulary: vocabulary, seconds: seconds)
    }

    /// The tokens for features padded to `frames` frames, of which `valid` are the audio's.
    private func predict(features: [Float], valid: Int) throws -> [FrameToken] {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_features": MLFeatureValue(multiArray: try multiArray(features, shape: [1, frames, melCount])),
            "length": MLFeatureValue(multiArray: int32Array(valid)),
        ])
        let output = try model.prediction(from: input)
        return try withOutput(output, "logits") { logits, shape, strides in
            ctcTokens(logits, frames: min(outputFrames(valid), shape[1]), vocabulary: shape[2], rowStride: strides[1], blank: blank)
        }
    }
}

/// SenseVoice Small in FluidInference's Core ML build (scripts/convert-sensevoice.py): their preprocessor model (Kaldi
/// filter banks, stacked frames and normalization) on the CPU, the int8 encoder and CTC head on the Neural Engine, with
/// a set of input lengths.
final class SenseVoiceRecognizer: Recognizer, @unchecked Sendable {
    /// The encoder's embedding indices for its languages; the others are detected (0).
    static let languageIndex = ["zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12]
    /// Punctuation and inverse text normalization (numbers as digits).
    private static let withITN = 14

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let vocabulary: [String]
    /// The encoder's input lengths, in feature frames of 60 ms (sensevoice.json): the features are padded to the
    /// shortest that fits.
    private let buckets: [Int]

    init(directory: URL) throws {
        guard let info = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("sensevoice.json"))) as? [String: Any],
              let buckets = info["buckets"] as? [Int], !buckets.isEmpty
        else { throw ConvertedModelsKind.senseVoice.unexpectedModels }
        self.buckets = buckets.sorted()
        let models = directory.appendingPathComponent("coreml")
        let cpu = MLModelConfiguration()
        // Its filter bank values exceed 16-bit floats.
        cpu.computeUnits = .cpuOnly
        preprocessor = try MLModel(contentsOf: models.appendingPathComponent("SenseVoicePreprocessor.mlmodelc"), configuration: cpu)
        let neuralEngine = MLModelConfiguration()
        neuralEngine.computeUnits = .cpuAndNeuralEngine
        encoder = try MLModel(contentsOf: models.appendingPathComponent("SenseVoiceSmall_int8.mlmodelc"), configuration: neuralEngine)
        vocabulary = try loadVocabulary(directory.appendingPathComponent("vocab.json"))
    }

    /// The stretch so far again every 0.3 s (about 20 ms each time).
    func live(language: String) async throws -> (any LiveTranscription)? {
        RepeatedTranscription(self, language: language, interval: 0.3)
    }

    func transcribe(_ samples: [Float], language: String) async throws -> Transcript {
        guard !samples.isEmpty else { return Transcript() }
        // Kaldi's scale: 16-bit sample values.
        var scaled = samples
        var scale: Float = 32768
        vDSP_vsmul(samples, 1, &scale, &scaled, 1, vDSP_Length(samples.count))
        let features = try await preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "waveform": MLFeatureValue(multiArray: try multiArray(scaled, shape: [1, scaled.count])),
        ]))
        let largest = buckets.last!
        let (speech, frames) = try withOutput(features, "features") { values, shape, strides in
            let frames = min(shape[1], largest)
            let bucket = buckets.first { $0 >= frames } ?? largest
            var speech = [Float](repeating: 0, count: bucket * shape[2])
            for frame in 0..<frames {
                for index in 0..<shape[2] {
                    speech[frame * shape[2] + index] = values[frame * strides[1] + index * strides[2]]
                }
            }
            return (try multiArray(speech, shape: [1, bucket, shape[2]]), frames)
        }
        let output = try await encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": MLFeatureValue(multiArray: int32Array(frames)),
            "language": MLFeatureValue(multiArray: int32Array(Self.languageIndex[language] ?? 0)),
            "textnorm": MLFeatureValue(multiArray: int32Array(Self.withITN)),
        ]))
        // The first 4 outputs are the language, emotion, event and normalization tags.
        let tokens = try withOutput(output, "ctc_logits") { logits, shape, strides in
            ctcTokens(logits, frames: min(frames + 4, shape[1]), vocabulary: shape[2], rowStride: strides[1], blank: 0)
        }
        // Without the tags (each a token: <|ja|> and the like); a frame is 60 ms, after the 4 tags'.
        let spoken = tokens.filter { $0.token >= vocabulary.count || !vocabulary[$0.token].hasPrefix("<|") }
            .map { ($0.token, max($0.frame - 4, 0)) }
        return detokenize(spoken, vocabulary: vocabulary, seconds: 0.06)
    }
}
