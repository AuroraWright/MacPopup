import AVFoundation
import SoundAnalysis

/// Finds speech with Apple's sound classifier.
public final class VoiceDetector: NSObject, SNResultsObserving {
    /// The classifier's labels that are a voice.
    private static let voiceLabels = ["speech", "shout", "yell", "whispering", "laughter"]
    private static let threshold = 0.5

    private let analyzer: SNAudioStreamAnalyzer
    private let onResult: (CMTimeRange, Bool) -> Void

    /// - Parameters:
    ///   - window: How long each classified stretch is, in seconds (at least 0.5).
    ///   - overlap: How much of each stretch the next one repeats, so results come every
    ///     `window * (1 - overlap)` seconds.
    public init(format: AVAudioFormat, window: Double = 1, overlap: Double = 0.75, onResult: @escaping (CMTimeRange, Bool) -> Void) throws {
        analyzer = SNAudioStreamAnalyzer(format: format)
        self.onResult = onResult
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: window, preferredTimescale: 1000)
        request.overlapFactor = overlap
        try analyzer.add(request, withObserver: self)
    }

    /// Where the voice is in `clip`, from the first stretch of speech to the last: as the classifier places it (`coarse`,
    /// a second at a time, so up to most of a second wider than the voice) and with the edges refined (`fine`, see
    /// refine; the coarse one when that finds none), which ends nearer where the voice does.
    public static func find(in clip: AudioClip) -> (coarse: (Double, Double), fine: (Double, Double))? {
        var coarse: (Double, Double)?
        guard let detector = try? VoiceDetector(format: clip.format, onResult: { range, isSpeech in
            guard isSpeech else { return }
            coarse = (min(coarse?.0 ?? range.start.seconds, range.start.seconds), max(coarse?.1 ?? 0, range.end.seconds))
        }) else { return nil }
        var position: AVAudioFramePosition = 0
        for buffer in clip.buffers {
            detector.analyze(buffer, at: position)
            position += AVAudioFramePosition(buffer.frameLength)
        }
        detector.finish()
        guard let found = coarse else { return nil }
        let placed = (found.0, min(found.1, clip.duration))
        return (placed, refine(clip, start: placed.0, end: placed.1) ?? placed)
    }

    /// Where the voice is in `clip` between about `start` and `end` (from a coarse pass), placed more
    /// finely with short stretches: from the middle of the first one with speech to the middle of the
    /// last one.
    public static func refine(_ clip: AudioClip, start: Double, end: Double) -> (Double, Double)? {
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
    public func analyze(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition) {
        analyzer.analyze(buffer, atAudioFramePosition: position)
    }

    public func finish() {
        analyzer.completeAnalysis()
    }

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = Self.voiceLabels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
        onResult(result.timeRange, confidence >= Self.threshold)
    }
}

/// Recorded audio, kept in memory.
public struct AudioClip {
    public let format: AVAudioFormat
    public let buffers: [AVAudioPCMBuffer]

    public init(format: AVAudioFormat, buffers: [AVAudioPCMBuffer]) {
        self.format = format
        self.buffers = buffers
    }

    public var frameCount: Int { buffers.reduce(0) { $0 + Int($1.frameLength) } }
    public var duration: Double { Double(frameCount) / format.sampleRate }

    /// The voice found between `start` and `end`, with `padding` seconds on each side, starting no later than `latest`.
    public func trimmed(voiceFrom start: Double, to end: Double, padding: Double, startingBy latest: Double = .infinity) -> AudioClip {
        let range = voiceRange(from: start, to: end, padding: padding, startingBy: latest)
        return slice(from: range.lowerBound, to: range.upperBound)
    }

    /// Where `trimmed` cuts, in seconds. Nothing is taken off the voice as the classifier placed it: tightening it to
    /// where it's loud, or placing it more finely (VoiceDetector.refine), cut the first and last syllables of many
    /// lines over music (scratch-tools/diarization/bocchi).
    public func voiceRange(from start: Double, to end: Double, padding: Double, startingBy latest: Double = .infinity) -> ClosedRange<Double> {
        let lower = max(0, min(start - padding, latest))
        return lower...max(lower, min(duration, end + padding))
    }

    public func slice(from start: Double, to end: Double) -> AudioClip {
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
    public func write(to url: URL) throws {
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

/// A second-order low-pass filter (RBJ's, Q 0.707).
struct LowPass {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(cutoff: Double, sampleRate: Double) {
        let w = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate, alpha = sin(w) / (2 * 0.7071), a0 = 1 + alpha
        b1 = Float((1 - cos(w)) / a0)
        b0 = b1 / 2
        b2 = b1 / 2
        a1 = Float(-2 * cos(w) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func callAsFunction(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}

/// Converts the buffers of a stream, one after another, to another format, carrying the converter's state from one to
/// the next so that they join as if converted together (fewer channels are mixed down).
public final class StreamConverter {
    private let converter: AVAudioConverter

    public var inputFormat: AVAudioFormat { converter.inputFormat }

    public init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = input.channelCount > output.channelCount
        self.converter = converter
    }

    /// The buffer converted, or nil if it can't be (or gives no frames yet).
    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) else { return nil }
        var given = false
        var error: NSError?
        // No more for now (rather than the end of the stream): the converter keeps what it needs of this buffer.
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// Converts the pieces of a recording, one after another, to mono at another sample rate (see StreamConverter).
final class StreamResampler {
    private let converter: StreamConverter

    init?(from format: AVAudioFormat, to sampleRate: Double) {
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = StreamConverter(from: mono, to: output) else { return nil }
        self.converter = converter
    }

    func convert(_ clip: AudioClip) -> [Float] {
        guard let mono = clip.monoBuffer(), let output = converter.convert(mono), let samples = output.floatChannelData?[0]
        else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}

extension AudioClip {
    /// The clip mixed to mono and converted to `sampleRate`.
    public func monoSamples(sampleRate: Double) -> [Float]? {
        guard let mono = monoBuffer(),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono.format, to: outputFormat) else { return nil }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * sampleRate / format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let samples = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }

    /// The clip mixed to mono, at its sample rate.
    public func monoBuffer() -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(frameCount)
        guard frames > 0, let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let target = mono.floatChannelData?[0] else { return nil }
        var position = 0
        for buffer in buffers {
            guard let source = buffer.floatChannelData else { continue }
            let length = Int(buffer.frameLength), channels = Int(format.channelCount)
            for frame in 0..<length {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[channel][frame] }
                target[position + frame] = sum / Float(channels)
            }
            position += length
        }
        mono.frameLength = frames
        return mono
    }
}
