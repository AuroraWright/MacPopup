import Accelerate
import CoreML
import Foundation
import OCREngines

/// NVIDIA's Parakeet TDT 0.6B v3 (scripts/convert-parakeet.py), in FluidInference's Core ML build: 25 European
/// languages, which it finds itself. The preprocessor (log-mel features) runs on the CPU and the encoder on the Neural
/// Engine, then greedy TDT decoding: for an encoder frame, the joint network picks a token (or blank) and how many
/// frames to move on, and the decoder (an LSTM over the tokens so far) runs once per token. The models read 15 seconds
/// at most; longer audio is split where it's quietest. Transcriptions may run at the same time: nothing changes after
/// init.
final class ParakeetRecognizer: Recognizer, @unchecked Sendable {
    /// The languages it reads, as Yomitan's codes ("sh": Croatian).
    static let languages: Set<String> = ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                                         "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sh", "sk", "sl", "sv", "uk"]
    /// NeMo's limit on tokens read at one frame, after which decoding moves on.
    private static let maxSymbolsPerFrame = 10

    private let preprocessor, encoder, decoder, joint: MLModel
    private let vocabulary: [String]
    /// The samples the models read (15 s).
    private let window: Int
    private let blank: Int
    /// The frames each of the joint network's durations moves on.
    private let durations: [Int]

    init(directory: URL) throws {
        guard let info = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("parakeet.json"))) as? [String: Any],
              let window = info["samples"] as? Int, let blank = info["blank"] as? Int, let durations = info["durations"] as? [Int]
        else { throw ConvertedModelsKind.parakeet.unexpectedModels }
        (self.window, self.blank, self.durations) = (window, blank, durations)
        let models = directory.appendingPathComponent("coreml")
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: models.appendingPathComponent("\(name).mlmodelc"), configuration: configuration)
        }
        preprocessor = try load("Preprocessor", .cpuOnly)
        // On the GPU it was slower (M1 Max: 131 ms against 99 ms a line).
        encoder = try load("Encoder", .cpuAndNeuralEngine)
        decoder = try load("Decoder", .cpuOnly)
        joint = try load("Joint", .cpuOnly)
        vocabulary = try loadVocabulary(directory.appendingPathComponent("vocab.json"))
        // The first prediction takes longer (Core ML prepares the models).
        _ = try transcribeWindow([Float](repeating: 0, count: 16000))
    }

    func transcribe(_ samples: [Float], language: String) async throws -> Transcript {
        var result = Transcript()
        for piece in pieces(samples) {
            let transcript = try transcribeWindow(Array(samples[piece]), offset: Double(piece.lowerBound) / 16000)
            guard !transcript.text.isEmpty else { continue }
            if !result.text.isEmpty { result.append(" ", at: transcript.times?.first ?? 0) }
            result.append(transcript)
        }
        return result
    }

    /// The audio's ranges of at most `window` samples, split where it's quietest (over 0.2 s) in the stretch where
    /// both sides fit; more than two windows' worth is split a window at a time.
    private func pieces(_ samples: [Float]) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = 0
        while samples.count - start > window {
            let remaining = samples.count - start
            let lowest = start + (remaining > 2 * window ? window / 2 : remaining - window)
            let split = quietest(samples, in: lowest..<start + window)
            pieces.append(start..<split)
            start = split
        }
        pieces.append(start..<samples.count)
        return pieces
    }

    /// Up to `window` samples to text, heard `offset` seconds into the audio.
    private func transcribeWindow(_ samples: [Float], offset: Double = 0) throws -> Transcript {
        guard !samples.isEmpty else { return Transcript() }
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: window - samples.count))
        let features = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: try multiArray(padded, shape: [1, window])),
            "audio_length": MLFeatureValue(multiArray: int32Array(samples.count)),
        ]))
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": features.featureValue(for: "mel")!,
            "mel_length": features.featureValue(for: "mel_length")!,
        ]))
        guard let length = encoded.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue else {
            throw ConvertedModelsKind.parakeet.unexpectedModels
        }
        // [frames][hidden], from [1, hidden, frames].
        let (frames, hidden) = try withOutput(encoded, "encoder") { values, shape, strides in
            let count = min(length, shape[2]), size = shape[1]
            var frames = [Float](repeating: 0, count: count * size)
            for frame in 0..<count {
                for index in 0..<size {
                    frames[frame * size + index] = values[frame * strides[2] + index * strides[1]]
                }
            }
            return (frames, size)
        }
        // An encoder frame is 80 ms (10 ms features, subsampled 8 times).
        return detokenize(try decode(frames, hidden: hidden), vocabulary: vocabulary, seconds: 0.08, offset: offset)
    }

    /// Greedy TDT decoding of the encoder's frames ([frames][hidden]), as NeMo's.
    private func decode(_ frames: [Float], hidden: Int) throws -> [FrameToken] {
        let count = frames.count / hidden
        let step = try MLMultiArray(shape: [1, NSNumber(value: hidden), 1], dataType: .float32)
        var state = try predict(token: blank, state: nil)
        var tokens: [FrameToken] = []
        var frame = 0, symbols = 0
        while frame < count {
            step.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
                frames.withUnsafeBufferPointer { memcpy(pointer.baseAddress!, $0.baseAddress! + frame * hidden, hidden * 4) }
            }
            let decision = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "encoder_step": MLFeatureValue(multiArray: step),
                "decoder_step": MLFeatureValue(multiArray: state.output),
            ]))
            guard let token = decision.featureValue(for: "token_id")?.multiArrayValue?[0].intValue,
                  let bin = decision.featureValue(for: "duration")?.multiArrayValue?[0].intValue, durations.indices.contains(bin)
            else { throw ConvertedModelsKind.parakeet.unexpectedModels }
            let duration = durations[bin]
            if token == blank {
                frame += max(duration, 1)
                symbols = 0
                continue
            }
            tokens.append((token, frame))
            state = try predict(token: token, state: state)
            symbols += 1
            if duration > 0 || symbols >= Self.maxSymbolsPerFrame {
                frame += max(duration, 1)
                symbols = 0
            }
        }
        return tokens
    }

    private struct DecoderState {
        var output, h, c: MLMultiArray
    }

    /// The decoder after reading `token`, from `state` (nil: the start, zeros).
    private func predict(token: Int, state: DecoderState?) throws -> DecoderState {
        let zeros = { try MLMultiArray(shape: [2, 1, 640], dataType: .float32).filled(with: Float(0)) }
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: try MLMultiArray(shape: [1, 1], dataType: .int32).filled(with: Int32(token))),
            "target_length": MLFeatureValue(multiArray: int32Array(1)),
            "h_in": MLFeatureValue(multiArray: try state?.h ?? zeros()),
            "c_in": MLFeatureValue(multiArray: try state?.c ?? zeros()),
        ]))
        guard let projection = output.featureValue(for: "decoder")?.multiArrayValue,
              let h = output.featureValue(for: "h_out")?.multiArrayValue,
              let c = output.featureValue(for: "c_out")?.multiArrayValue
        else { throw ConvertedModelsKind.parakeet.unexpectedModels }
        return DecoderState(output: projection, h: h, c: c)
    }
}

private extension MLMultiArray {
    func filled<T: MLShapedArrayScalar>(with value: T) -> MLMultiArray {
        withUnsafeMutableBufferPointer(ofType: T.self) { pointer, _ in pointer.update(repeating: value) }
        return self
    }
}

/// The middle of the quietest `span` 20 ms blocks of 16 kHz `samples` in `range` (its middle when it's shorter).
func quietest(_ samples: [Float], in range: Range<Int>, span: Int = 10) -> Int {
    let block = 320
    let energies = stride(from: range.lowerBound, to: range.upperBound - block, by: block).map { start in
        var energy: Float = 0
        samples.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &energy, vDSP_Length(block)) }
        return energy
    }
    guard energies.count > span else { return (range.lowerBound + range.upperBound) / 2 }
    var best = 0, bestSum = Float.infinity
    var sum = energies[0..<span].reduce(0, +)
    for first in 0...(energies.count - span) {
        if first > 0 { sum += energies[first + span - 1] - energies[first - 1] }
        if sum < bestSum { (best, bestSum) = (first, sum) }
    }
    return range.lowerBound + best * block + span * block / 2
}
