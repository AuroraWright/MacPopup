import Accelerate
import AVFoundation

/// The last minutes of the game's audio (see AudioTap), kept in memory as 16-bit samples (about 11 MB a minute for
/// stereo at 48 kHz), so that a line's voice can be taken from it after the line was shown, without replaying it
/// (see SentenceAudioController). Times are the system uptime.
final class AudioHistory: @unchecked Sendable {
    /// Up to about a second of audio, from `start` on, interleaved.
    private struct Block {
        let start: Double
        var samples: [Int16] = []
    }

    private let queue = DispatchQueue(label: "com.aury.macpopup.audio-history")
    /// Finds voices, which takes a moment, away from the queue the tap gives its audio on.
    private let detection = DispatchQueue(label: "com.aury.macpopup.audio-history.voice")
    private var tap: AudioTap?
    private var processes: AudioTap.Processes?
    // On the queue:
    private var format: AVAudioFormat?
    private var blocks: [Block] = []
    private var keep = 0.0

    /// Whether audio is being kept.
    var isRecording: Bool { tap != nil }

    /// Keeps the audio of `processes` for `minutes`, or none (forgetting what was kept) with nil or 0. Called on the
    /// main thread.
    func record(_ processes: AudioTap.Processes?, minutes: Double) {
        let keep = minutes * 60
        queue.async { self.keep = keep }
        guard let processes, keep > 0 else {
            stop()
            return
        }
        guard processes != self.processes || tap == nil else { return }
        stop()
        // About 85 ms at a time (at 48 kHz), instead of about 10.
        let tap = AudioTap(processes: processes, bufferFrames: 4096, queue: queue) { [weak self] buffer in self?.append(buffer) }
        do {
            try tap.start()
        } catch {
            sentenceAudioLog("couldn't keep the audio: \(error.localizedDescription)")
            return
        }
        self.tap = tap
        self.processes = processes
    }

    private func stop() {
        guard let tap else { return }
        queue.sync {
            tap.stop()
            format = nil
            blocks = []
        }
        self.tap = nil
        processes = nil
    }

    /// Called on the queue with each part of the tap's recording.
    private func append(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        if buffer.format != format {
            format = buffer.format
            blocks = []
        }
        guard let channels = buffer.floatChannelData else { return }
        let rate = buffer.format.sampleRate, channelCount = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        let start = now - Double(frames) / rate
        // A new block each second, or where the audio doesn't follow on from the last (the tap was made again).
        let continues = blocks.last.map { last in
            let lastFrames = last.samples.count / channelCount
            return lastFrames < Int(rate) && abs(last.start + Double(lastFrames) / rate - start) < 0.05
        } ?? false
        if !continues {
            blocks.append(Block(start: start))
        }
        let index = blocks.count - 1
        blocks[index].samples.reserveCapacity(Int(rate) * channelCount)
        // Each channel clipped, scaled and rounded into its place among the others.
        var scaled = [Float](repeating: 0, count: frames)
        let samples = [Int16](unsafeUninitializedCapacity: frames * channelCount) { samples, count in
            var low: Float = -1, high: Float = 1, scale: Float = 32767
            for channel in 0..<channelCount {
                vDSP_vclip(channels[channel], 1, &low, &high, &scaled, 1, vDSP_Length(frames))
                vDSP_vsmul(scaled, 1, &scale, &scaled, 1, vDSP_Length(frames))
                vDSP_vfixr16(scaled, 1, samples.baseAddress! + channel, vDSP_Stride(channelCount), vDSP_Length(frames))
            }
            count = frames * channelCount
        }
        blocks[index].samples.append(contentsOf: samples)
        while let first = blocks.first, first.start < now - keep - 1 {
            blocks.removeFirst()
        }
    }

    /// The audio from `start` to `end` and where the voice is in it (in seconds into it, see VoiceDetector.find), or
    /// nil when it isn't kept from `start` on.
    func voice(from start: Double, to end: Double) async -> (clip: AudioClip, voice: (Double, Double)?)? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let clip = self.slice(from: start, to: end) else { return continuation.resume(returning: nil) }
                self.detection.async { continuation.resume(returning: (clip, VoiceDetector.find(in: clip))) }
            }
        }
    }

    private func slice(from start: Double, to end: Double) -> AudioClip? {
        guard let format, let first = blocks.first, first.start <= start else { return nil }
        let rate = format.sampleRate, channelCount = Int(format.channelCount)
        var buffers: [AVAudioPCMBuffer] = []
        for block in blocks {
            let frames = block.samples.count / channelCount
            let from = max(0, Int((start - block.start) * rate)), to = min(frames, Int((end - block.start) * rate))
            guard from < to, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(to - from)),
                  let channels = buffer.floatChannelData else { continue }
            buffer.frameLength = AVAudioFrameCount(to - from)
            block.samples.withUnsafeBufferPointer { samples in
                for frame in from..<to {
                    for channel in 0..<channelCount {
                        channels[channel][frame - from] = Float(samples[frame * channelCount + channel]) / 32767
                    }
                }
            }
            buffers.append(buffer)
        }
        return AudioClip(format: format, buffers: buffers)
    }
}
