import Accelerate
import AVFoundation

/// Keeps the last few minutes of the game's audio (see AudioTap) in memory as 16-bit samples, about 11 MB a minute for
/// stereo at 48 kHz. This lets SentenceAudioController take a line's voice after the line was shown, without replaying
/// it. Times are on GameClock (the system uptime without the time the game was frozen).
final class AudioHistory: @unchecked Sendable {
    /// About a second of interleaved audio at most, starting at `start`.
    private struct Block {
        let start: Double
        var samples: [Int16] = []
    }

    private let queue = DispatchQueue(label: "com.aury.macpopup.audio-history")
    /// Finding a voice takes a moment, so it runs here rather than on the queue that receives the tap's audio.
    private let detection = DispatchQueue(label: "com.aury.macpopup.audio-history.voice")
    private var tap: AudioTap?
    private var processes: AudioTap.Processes?
    // Only used on `queue`:
    private var format: AVAudioFormat?
    private var blocks: [Block] = []
    private var keep = 0.0

    /// Whether audio is currently being kept.
    var isRecording: Bool { tap != nil }

    /// Starts keeping the last `minutes` of the audio of `processes`. With nil or 0 minutes, stops and forgets what was
    /// kept. Called on the main thread.
    func record(_ processes: AudioTap.Processes?, minutes: Double) {
        let keep = minutes * 60
        queue.async { self.keep = keep }
        guard let processes, keep > 0 else {
            stop()
            return
        }
        guard processes != self.processes || tap == nil else { return }
        stop()
        // Larger buffers of about 85 ms (at 48 kHz) instead of the usual 10 ms, so MacPopup wakes up less often.
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

    /// Stops on the queue without waiting for it (it may be busy with Core Audio).
    private func stop() {
        guard let tap else { return }
        queue.async {
            tap.stop()
            self.format = nil
            self.blocks = []
        }
        self.tap = nil
        processes = nil
    }

    /// Called on `queue` with each new buffer from the tap. While the game is frozen (see GamePause), its silence isn't
    /// kept: times are on GameClock, which stands still meanwhile.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard !GameClock.isFrozen else { return }
        let now = GameClock.now
        if buffer.format != format {
            format = buffer.format
            blocks = []
        }
        guard let channels = buffer.floatChannelData else { return }
        let rate = buffer.format.sampleRate, channelCount = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        let start = now - Double(frames) / rate
        // Starts a new block every second, or when there's a gap in the audio (after the tap was recreated).
        let continues = blocks.last.map { last in
            let lastFrames = last.samples.count / channelCount
            return lastFrames < Int(rate) && abs(last.start + Double(lastFrames) / rate - start) < 0.05
        } ?? false
        if !continues {
            blocks.append(Block(start: start))
        }
        let index = blocks.count - 1
        blocks[index].samples.reserveCapacity(Int(rate) * channelCount)
        // Clips, scales and rounds each channel, interleaving it with the others.
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

    /// The audio from `start` to `end`, and where the voice is in it, in seconds from the clip's start (see
    /// VoiceDetector.find). Nil when the audio from `start` is no longer kept.
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
