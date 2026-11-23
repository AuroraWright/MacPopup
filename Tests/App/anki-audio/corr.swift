// corr <clip> <reference>...: where each reference (a line's voice) fits in the clip best, by normalized
// cross-correlation, and whether the clip holds the reference's whole speech (where it's above -40 dB of its loudest, in
// 20 ms steps). Any audio file AVFoundation reads (m4a, aiff, wav), compared as 8 kHz mono. One line a reference:
// "<name> <correlation> <starts s> <speech start s> <speech end s> <clip s> whole|CUT". Built with tools/build.sh.
import AVFoundation
import Accelerate

let rate = 8000.0

func load(_ path: String) -> [Float] {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
        print("corr: can't read \(path)")
        exit(1)
    }
    let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let input = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: max(frames, 1)), (try? file.read(into: source)) != nil,
          let converter = AVAudioConverter(from: input, to: output) else {
        print("corr: can't decode \(path)")
        exit(1)
    }
    // Mono: the channels mixed down, as the clip's are.
    converter.downmix = true
    let capacity = AVAudioFrameCount(Double(frames) * rate / input.sampleRate) + 1024
    let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
    var given = false
    var error: NSError?
    converter.convert(to: result, error: &error) { _, status in
        if given {
            status.pointee = .endOfStream
            return nil
        }
        given = true
        status.pointee = .haveData
        return source
    }
    return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength)))
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: corr <clip> <reference>...")
    exit(2)
}
let clip = load(args[1])
for path in args.dropFirst(2) {
    let ref = load(path)
    guard !ref.isEmpty, !clip.isEmpty else {
        print("\((path as NSString).lastPathComponent) 0 0 0 0 0 CUT")
        continue
    }
    // Lags from -ref.count to clip.count: the clip padded so every placement is a full-length window.
    let padded = [Float](repeating: 0, count: ref.count) + clip + [Float](repeating: 0, count: ref.count)
    let lags = clip.count + ref.count
    var out = [Float](repeating: 0, count: lags)
    vDSP_conv(padded, 1, ref, 1, &out, 1, vDSP_Length(lags), vDSP_Length(ref.count))
    var refEnergy: Float = 0
    vDSP_svesq(ref, 1, &refEnergy, vDSP_Length(ref.count))
    // Each window's energy, from running sums of squares.
    var sums = [Double](repeating: 0, count: padded.count + 1)
    for i in padded.indices { sums[i + 1] = sums[i] + Double(padded[i]) * Double(padded[i]) }
    var best = (lag: 0, score: Float(-1))
    for i in 0..<lags {
        let energy = Float(sums[i + ref.count] - sums[i])
        guard energy > 1e-9 else { continue }
        let score = out[i] / sqrt(energy * refEnergy)
        if score > best.score { best = (i - ref.count, score) }
    }
    // The reference's speech: 20 ms steps above -40 dB of its loudest.
    let step = Int(rate * 0.02)
    let levels = stride(from: 0, to: ref.count - step, by: step).map { i -> Float in
        var rms: Float = 0
        vDSP_rmsqv(Array(ref[i..<i + step]), 1, &rms, vDSP_Length(step))
        return rms
    }
    let peak = levels.max() ?? 0
    let voiced = levels.indices.filter { levels[$0] > peak * 0.01 }
    let speech = (Double(voiced.first ?? 0) * 0.02, Double((voiced.last ?? 0) + 1) * 0.02)
    let at = Double(best.lag) / rate
    let length = Double(clip.count) / rate
    let whole = at + speech.0 >= -0.005 && at + speech.1 <= length + 0.005
    print(String(format: "%@ %.3f %.3f %.3f %.3f %.3f %@", (path as NSString).lastPathComponent, best.score, at,
                 at + speech.0, at + speech.1, length, whole ? "whole" : "CUT"))
}
