import Foundation

/// The encoder's input frames from 16 kHz audio, following greco's feature streams as libsoda computes them (so the
/// frames are bit-identical to opensoda's and libsoda's):
///
///   Framer → Window (pre-emphasis, dither, Hann) → FFT (|X|²) → FilterBank (mel, √ magnitudes, log) → FrameStacker
///   → SubsampleStream → FrameNormalizeStream → AppendClusterIdStream → FrameStacker → SubsampleStream.
struct Frontend {
    private let config: PipelineConfig.Frontend
    private let frameLength: Int
    private let frameStep: Int
    private let window: [Float]
    private let noise: [Float]
    private let fft: PowerSpectrum
    private let mel: MelFilterbank
    private let mean: [Float], stddev: [Float]
    private var stack1: FrameStacker, stack2: FrameStacker

    /// Samples not yet framed.
    private var pending: [Float] = []
    /// Frames since the start (the dither's phase).
    private var frameIndex: UInt32 = 0
    /// Frames out of the first stacker.
    private var stackedFrames = 0
    /// With subsampleAfterGate, the stacked frames seen by the subsampler.
    private var passed = 0
    /// Each output frame's end: the first stacker's frames up to its newest one. The caller takes them with the frames.
    var ends: [Int] = []

    // Size of greco's precomputed dither table, and the strides it's walked with.
    private static let noiseTableSize = 16127
    private static let noiseSampleStride: UInt32 = 613
    private static let noiseFrameStride: UInt32 = 1301

    var outputSize: Int { stack2.outputSize }
    /// Milliseconds of audio a unit of `ends` covers.
    var stackedFrameMs: Float { config.frameStepMs * Float(config.subsampleAfterGate ? 1 : config.stack1.subsample) }

    init(_ config: PipelineConfig.Frontend, mean: [Float], stddev: [Float]) throws {
        self.config = config
        let rate = 16000.0
        func samples(_ ms: Float) -> Int { Int((Double(ms) * 0.001 * rate).rounded()) }
        frameLength = samples(config.frameSizeMs)
        frameStep = samples(config.frameStepMs)
        let windowLength = samples(config.windowSizeMs)
        guard windowLength == frameLength, frameLength > 0, frameStep > 0 else { throw SODAError("unsupported framing") }
        guard config.windowType == 1 else { throw SODAError("only Hann windows are implemented") }
        // HANNING: a Hann window sampled at half-sample offsets, with the step rounded to float as greco does.
        let step = Double(Float(2 * Double.pi / Double(Float(windowLength))))
        window = (0..<windowLength).map { n in Float(0.5 - cos((Double(n) + 0.5) * step) * 0.5) }
        // The dither table is drawn once from a default-seeded mt19937, with libc++'s normal distribution.
        var generator = MersenneTwister()
        var normal = NormalDistribution()
        noise = (0..<Self.noiseTableSize).map { _ in Float(normal.next(&generator)) }

        var fftSize = max(samples(Float(config.fftInputLengthMs)), config.minFftSize)
        if config.fftOverdrive { fftSize <<= 1 }
        var power = 1
        while power < fftSize { power <<= 1 }
        fft = PowerSpectrum(size: power)
        mel = MelFilterbank(bins: power / 2 + 1, sampleRate: rate, channels: config.channelCount,
                            lower: Double(config.lowerBandLimit), upper: Double(config.upperBandLimit))
        var first = config.stack1
        if config.subsampleAfterGate { first.subsample = 1 }
        stack1 = FrameStacker(first, size: config.channelCount)
        let normalized = stack1.outputSize
        // Some packs (en-US) share one table with the VAD, whose input also has a one-hot cluster id; the stacked
        // features use its first entries.
        guard mean.count >= normalized, mean.count == stddev.count else {
            throw SODAError("mean/stddev size doesn't match the stacked features")
        }
        self.mean = Array(mean[..<normalized])
        self.stddev = Array(stddev[..<normalized])
        stack2 = FrameStacker(config.stack2, size: normalized + (config.clusterID >= 0 ? 1 : 0))
    }

    /// Takes samples on the 16-bit scale; appends the encoder frames that are ready.
    mutating func accept(_ samples: [Float], into out: inout [[Float]]) {
        pending += samples
        var start = 0
        while pending.count - start >= frameLength + 1 {
            pending.withUnsafeBufferPointer { process(UnsafeBufferPointer(rebasing: $0[start...]), into: &out) }
            start += frameStep
        }
        pending.removeFirst(start)
    }

    /// At the end of the audio: emits the frames held back for right context.
    mutating func flush(into out: inout [[Float]]) {
        var stacked: [[Float]] = []
        stack1.flush(into: &stacked)
        for frame in stacked { forward(frame, into: &out) }
        let before = out.count
        stack2.flush(into: &out)
        ends += repeatElement(stackedFrames, count: out.count - before)
        pending = []
    }

    private mutating func process(_ x: UnsafeBufferPointer<Float>, into out: inout [[Float]]) {
        // greco's framer passes frameLength + 1 samples; its window (with htk_preemphasis_compatibility) windows the
        // first frameLength, pre-emphasizing the first against itself as (1 - p) x[0]; the extra sample only counts
        // towards the dither index.
        var sumAbs: Float = 0
        for i in 0...frameLength { sumAbs += abs(x[i]) }
        // The start index also advances with the frame number, so even silent frames get different dither.
        let table = UInt32(Self.noiseTableSize)
        var noiseIndex = (UInt32(sumAbs) % table &+ Self.noiseFrameStride &* frameIndex) % table
        frameIndex &+= 1

        var windowed = [Float](repeating: 0, count: frameLength)
        let p = config.preemphasis, scale = config.noiseScale, dither = scale > 0
        for k in 0..<frameLength {
            let n = scale * noise[Int(noiseIndex)]
            noiseIndex = (noiseIndex + Self.noiseSampleStride) % table
            if k > 0 {
                let v = x[k] - p * x[k - 1]
                windowed[k] = window[k] * (dither ? n + v : v)
            } else if dither {
                // greco takes the first sample in double.
                windowed[k] = Float(((1.0 - Double(p)) * Double(x[0]) + Double(n)) * Double(window[k]))
            } else {
                windowed[k] = Float((1.0 - Double(p)) * Double(window[k] * x[0]))
            }
        }
        var bank = mel.compute(fft.compute(windowed))
        // greco's FilterBank takes the double-precision log.
        for i in bank.indices { bank[i] = Float(log(Double(max(bank[i], config.fbankOutputFloor)))) }
        var stacked: [[Float]] = []
        stack1.push(bank, into: &stacked)
        for frame in stacked { forward(frame, into: &out) }
    }

    private mutating func forward(_ frame: [Float], into out: inout [[Float]]) {
        stackedFrames += 1
        var end = stackedFrames
        if config.subsampleAfterGate {
            // libsoda dates a kept frame by the last of the frames it stands for.
            passed += 1
            if (passed - 1) % config.stack1.subsample != 0 { return }
            end += config.stack1.subsample - 1
        }
        // Like greco's FrameNormalizeStream, divide (multiplying by the inverse rounds differently).
        var f = frame
        for i in f.indices { f[i] = (f[i] - mean[i]) / stddev[i] }
        if config.clusterID >= 0 { f.append(Float(config.clusterID)) }
        let before = out.count
        stack2.push(f, into: &out)
        ends += repeatElement(end, count: out.count - before)
    }
}

/// Stacks context frames, then keeps every `subsample`-th stacked frame.
struct FrameStacker {
    private let config: PipelineConfig.FrameStack
    private let size: Int
    private var window: [[Float]] = []
    private var started = false
    private var emitted = 0

    var outputSize: Int { size * config.span }

    init(_ config: PipelineConfig.FrameStack, size: Int) {
        (self.config, self.size) = (config, size)
    }

    private mutating func emit(into out: inout [[Float]]) {
        defer { emitted += 1 }
        guard emitted % config.subsample == 0 else { return }
        out.append(Array(window.joined()))
    }

    mutating func push(_ frame: [Float], into out: inout [[Float]]) {
        if !started {
            started = true
            // Missing left context is zeros with frame_zero_padding, and copies of the first frame otherwise, so
            // output starts with the first input frame.
            for _ in 0..<config.leftContext {
                window.append(config.zeroPadding ? [Float](repeating: 0, count: size) : frame)
            }
        }
        window.append(frame)
        if window.count == config.span {
            emit(into: &out)
            window.removeFirst()
        }
    }

    mutating func flush(into out: inout [[Float]]) {
        if config.zeroPadding, started {
            // Each held-back frame gets zero frames as its missing right context.
            for _ in 0..<(window.count - config.leftContext) {
                window.append([Float](repeating: 0, count: size))
                if window.count == config.span {
                    emit(into: &out)
                    window.removeFirst()
                }
            }
        }
        (window, started, emitted) = ([], false, 0)
    }
}

/// greco's triangular mel filterbank (TensorFlow's MfccMelFilterbank), summing weighted magnitudes.
struct MelFilterbank {
    private let channels: Int
    private let startIndex: Int, endIndex: Int
    private var weights: [Float]
    private var bandMapper: [Int]

    private static func mel(_ hz: Double) -> Float { Float(1127.0 * log(hz / 700.0 + 1.0)) }

    init(bins: Int, sampleRate: Double, channels: Int, lower: Double, upper: Double) {
        self.channels = channels
        // Channel edges are equally spaced in mel between the band limits.
        let melLow = Self.mel(lower), melHigh = Self.mel(upper)
        let spacing = (melHigh - melLow) / Float(channels + 1)
        let centers = (0...channels).map { spacing * Float($0 + 1) + melLow }
        let hzPerBin = Float(sampleRate * 0.5 / Double(bins - 1))
        startIndex = Int(Float(lower) / hzPerBin + 1.5)
        endIndex = min(bins - 1, Int(Float(upper) / hzPerBin))
        bandMapper = [Int](repeating: -2, count: bins)
        var channel = 0
        for i in 0..<bins where i >= startIndex && i <= endIndex {
            let mel = Self.mel(Double(hzPerBin * Float(i)))
            while channel < channels && centers[channel] < mel { channel += 1 }
            bandMapper[i] = channel - 1
        }
        weights = [Float](repeating: 0, count: bins)
        if startIndex <= endIndex {
            for i in startIndex...endIndex {
                let mel = Self.mel(Double(hzPerBin * Float(i)))
                let c = bandMapper[i]
                weights[i] = c >= 0 ? (centers[c + 1] - mel) / (centers[c + 1] - centers[c])
                    : (centers[0] - mel) / (centers[0] - melLow)
            }
        }
    }

    /// `power` holds the bins' squared magnitudes.
    func compute(_ power: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: channels)
        guard startIndex <= endIndex else { return out }
        for i in startIndex...endIndex {
            let magnitude = power[i].squareRoot()
            let weighted = magnitude * weights[i]
            var c = bandMapper[i]
            if c >= 0 { out[c] += weighted }
            c += 1
            if c < channels { out[c] += magnitude - weighted }
        }
        return out
    }
}

/// greco's FFT (speech/portable/fft): djbfft's conjugate-pair split-radix transform. A radix-4 pass splits n points
/// into a half and two quarters, transformed in turn, down to 16- and 8-point kernels; following its order of operations
/// gives bit-identical spectra.
struct PowerSpectrum {
    private let n: Int
    /// Per pass size: cos and sin of 2πk/n for k = 1 ..< n/4.
    private var twiddles: [Int: [Float]] = [:]
    /// The output index of each frequency 0...n/2.
    private var positions: [Int] = []

    init(size: Int) {
        n = size
        var m = 32
        while m <= n {
            var values: [Float] = []
            values.reserveCapacity(max(0, m / 4 - 1) * 2)
            for k in 1..<m / 4 {
                let angle = 2 * Double.pi * Double(k) / Double(m)
                values.append(Float(cos(angle)))
                values.append(Float(sin(angle)))
            }
            twiddles[m] = values
            m *= 2
        }
        // Where each frequency lands, from the transform of a unit impulse at sample 1, whose output at frequency f is
        // e^{2πif/n}.
        var buffer = [Float](repeating: 0, count: 2 * n)
        buffer[2] = 1
        buffer.withUnsafeMutableBufferPointer { transform($0.baseAddress!, n) }
        positions = [Int](repeating: 0, count: n / 2 + 1)
        for p in 0..<n {
            let turns = atan2(Double(buffer[2 * p + 1]), Double(buffer[2 * p])) / (2 * Double.pi)
            let f = (Int((turns * Double(n)).rounded()) % n + n) % n
            // The transform uses e^{+i}; frequency k of e^{-i} is its -k.
            let k = (n - f) % n
            if k <= n / 2 { positions[k] = p }
        }
    }

    /// |X[k]|² for k = 0...n/2 of a real frame (zero-padded to n).
    func compute(_ frame: [Float]) -> [Float] {
        var buffer = [Float](repeating: 0, count: 2 * n)
        for i in 0..<min(n, frame.count) { buffer[2 * i] = frame[i] }
        buffer.withUnsafeMutableBufferPointer { transform($0.baseAddress!, n) }
        return positions.map { p in
            let re = buffer[2 * p], im = buffer[2 * p + 1]
            return re * re + im * im
        }
    }

    private func transform(_ a: UnsafeMutablePointer<Float>, _ n: Int) {
        if n == 8 { return Self.fft8(a) }
        if n == 16 { return Self.fft16(a) }
        pass(a, n)
        transform(a + n, n / 4)
        transform(a + 3 * n / 2, n / 4)
        transform(a, n / 2)
    }

    private static let sqrtHalf = Float(cos(Double.pi / 4))

    private func pass(_ a: UnsafeMutablePointer<Float>, _ n: Int) {
        // Quarters A, B, C, D: A ← A + C, B ← B + D, and C and D get (A - C) ± i(B - D) times w^k and w^-k. Above 512
        // points the second half of the twiddles comes from the first by symmetry, and k = n/8 uses √½ directly.
        let q = n / 4, m = n / 8
        let symmetric = n >= 1024
        let w = twiddles[n]!
        let h = Self.sqrtHalf
        for k in 0..<q {
            let A = a + 2 * k, B = A + 2 * q, C = B + 2 * q, D = C + 2 * q
            let ar = A[0], ai = A[1], br = B[0], bi = B[1]
            let cr = C[0], ci = C[1], dr = D[0], di = D[1]
            A[0] = ar + cr
            A[1] = ai + ci
            B[0] = br + dr
            B[1] = bi + di
            let t0 = ar - cr, t1 = ai - ci, u0 = br - dr, u1 = bi - di
            let z1r = t0 - u1, z1i = u0 + t1, z3r = t0 + u1, z3i = t1 - u0
            if k == 0 {
                (C[0], C[1], D[0], D[1]) = (z1r, z1i, z3r, z3i)
            } else if symmetric && k == m {
                C[0] = (z1r - z1i) * h
                C[1] = (z1r + z1i) * h
                D[0] = (z3r + z3i) * h
                D[1] = (z3i - z3r) * h
            } else {
                let w0: Float, w1: Float
                if symmetric && k > m {
                    (w0, w1) = (w[2 * (q - k - 1) + 1], w[2 * (q - k - 1)])
                } else {
                    (w0, w1) = (w[2 * (k - 1)], w[2 * (k - 1) + 1])
                }
                C[0] = z1r * w0 - z1i * w1
                C[1] = z1r * w1 + w0 * z1i
                D[0] = z3r * w0 + z3i * w1
                D[1] = w0 * z3i - z3r * w1
            }
        }
    }

    /// djbfft's 8-point kernel.
    private static func fft8(_ x: UnsafeMutablePointer<Float>) {
        let h = sqrtHalf
        let r8 = x[8], i8 = x[9], i0 = x[1]
        let a0 = i0 - i8, a1 = i8 + i0
        let r12 = x[12], i12 = x[13], r4 = x[4], i4 = x[5]
        let a2 = r4 - r12, a3 = r12 + r4
        let a4 = a0 - a2, a5 = a0 + a2
        let a6 = i4 - i12, a7 = i12 + i4
        let a8 = x[0] - r8, a9 = r8 + x[0]
        let a10 = a8 - a6, a11 = a6 + a8
        let r10 = x[10], i10 = x[11], r2 = x[2], i2 = x[3]
        let b0 = r2 - r10, b1 = r10 + r2
        let r14 = x[14], i14 = x[15], r6 = x[6], i6 = x[7]
        let b2 = i6 - i14, b3 = i14 + i6
        let b4 = b0 - b2, b5 = b0 + b2
        let b6 = i2 - i10, b7 = i10 + i2
        let b8 = r6 - r14, b9 = r14 + r6
        let b10 = b6 - b8, b11 = b6 + b8
        let c0 = (b4 - b11) * h, c1 = (b4 + b11) * h
        x[10] = a10 - c0
        x[11] = a5 - c1
        x[8] = a10 + c0
        x[9] = a5 + c1
        let c2 = (b10 - b5) * h, c3 = (b5 + b10) * h
        x[14] = a11 - c3
        x[15] = a4 - c2
        x[12] = a11 + c3
        x[13] = a4 + c2
        let d0 = a9 - a3, d1 = a3 + a9, d2 = a1 - a7, d3 = a1 + a7
        x[6] = d0 + (b7 - b3)
        x[7] = d2 - (b1 - b9)
        x[4] = d0 - (b7 - b3)
        x[5] = d2 + (b1 - b9)
        x[0] = d1 + (b1 + b9)
        x[1] = d3 + (b3 + b7)
        x[2] = d1 - (b1 + b9)
        x[3] = d3 - (b3 + b7)
    }

    /// djbfft's 16-point kernel: a pass, two 4-point transforms and fft8, with the compiler's interleaving of loads
    /// and stores kept (some values are stored and read back).
    private static func fft16(_ x: UnsafeMutablePointer<Float>) {
        let c = Float(cos(Double.pi / 8)), s = Float(sin(Double.pi / 8)), h = sqrtHalf
        let v2 = x[16], v3 = x[17], v4 = x[1]
        let v5 = x[0] - v2, v6 = v2 + x[0]
        let v7 = x[8], v8 = x[9], v10 = x[25], v9 = x[26]
        let v11 = v5 - (v8 - v10), v12 = v5 + (v8 - v10), v13 = v10 + v8
        let v14 = x[23], v15 = x[24]
        x[8] = v15 + v7
        x[9] = v13
        x[17] = (v7 - v15) + (v4 - v3)
        let v16 = (v4 - v3) - (v7 - v15)
        x[0] = v6
        x[1] = v3 + v4
        let v17 = x[2], v18 = x[3], v19 = x[17], v20 = x[18]
        let v21 = v17 - v20, v22 = v20 + v17
        let v24 = x[10], v23 = x[11], v25 = x[27], v26 = x[28]
        let v27 = v21 - (v23 - v25), v28 = v21 + (v23 - v25)
        let v29 = v28 * c, v30 = v24 - v9
        x[10] = v9 + v24
        x[11] = v25 + v23
        let v31 = v28 * s, v32 = x[19], v33 = x[20], v34 = v18 - v32
        x[2] = v22
        x[3] = v32 + v18
        let v35 = v30 + (v18 - v32)
        x[18] = (v27 * c) - (s * v35)
        x[19] = (v27 * s) + (c * v35)
        let v36 = (c * (v34 - v30)) - v31
        x[25] = v16
        x[26] = v29 + (s * (v34 - v30))
        let v37 = x[4], v38 = x[5], v39 = v37 - v33, v40 = v33 + v37
        let v42 = x[12], v41 = x[13], v43 = x[29], v44 = x[30]
        let v45 = v39 - (v41 - v43), v46 = v39 + (v41 - v43), v47 = v43 + v41, v48 = v42 - v26
        x[12] = v26 + v42
        x[13] = v47
        let v49 = x[21], v50 = x[22]
        let v51 = v48 + (v38 - v49), v52 = (v38 - v49) - v48
        x[4] = v40
        x[5] = v49 + v38
        let v53 = (v46 + v52) * h, v54 = (v52 - v46) * h
        let v55 = (v45 - v51) * h, v56 = (v45 + v51) * h
        let v57 = x[6], v58 = x[7], v59 = v57 - v50, v60 = v50 + v57
        let v61 = x[31], v63 = x[14], v62 = x[15]
        let v64 = v59 - (v62 - v61), v65 = v59 + (v62 - v61)
        x[14] = v44 + v63
        x[15] = v61 + v62
        let v66 = v58 - v14
        x[6] = v60
        x[7] = v14 + v58
        let v67 = (v63 - v44) + (v58 - v14), v68 = v66 - (v63 - v44)
        let v69 = (s * v64) - (c * v67), v70 = (c * v64) + (s * v67)
        let v71 = (s * v68) - (c * v65), v72 = (s * v65) + (c * v68)
        let v73 = v11 - v55, v74 = v11 + v55
        let v75 = x[18], v76 = x[19]
        let v77 = v75 - v69, v78 = v69 + v75, v79 = v74 + v78, v80 = v74 - v78
        let v81 = v19 - v56, v82 = v56 + v19
        x[22] = v73 + (v76 - v70)
        x[23] = v81 - v77
        x[20] = v73 - (v76 - v70)
        x[21] = v77 + v81
        let v83 = v70 + v76
        x[16] = v79
        x[17] = v82 + v83
        x[18] = v80
        x[19] = v82 - v83
        let v84 = v12 - v53, v85 = v12 + v53
        let v87 = x[25], v86 = x[26]
        let v88 = v86 - v72, v89 = v72 + v86, v90 = v85 + v89
        x[26] = v85 - v89
        x[27] = v36
        x[31] = (v87 - v54) - v88
        let v91 = x[27]
        x[29] = v88 + (v87 - v54)
        x[30] = v84 + (v91 - v71)
        let v92 = v84 - (v91 - v71), v93 = v71 + v91
        x[24] = v90
        x[25] = (v54 + v87) + v93
        x[27] = (v54 + v87) - v93
        x[28] = v92
        fft8(x)
    }
}

/// greco's automatic gain control (the SAMPLE_LEVEL_TARGET_RANGE estimator, en-US): a decaying peak follower feeds a
/// smoothed level, and the gain steers that level towards a target, fading out below lower_level_target.
struct GainControl {
    private let config: PipelineConfig.GainControl
    private let decay: Float
    private let attack: Float
    private var peak: Float, level: Float
    private var delayLine: [Float]
    private var delayPosition = 0

    init(_ config: PipelineConfig.GainControl) {
        self.config = config
        let rate = 16000
        decay = exp2(-1 / (Float(rate) * config.halfLifeSeconds))
        let delay = config.delayMs * rate / 1000
        // The level settles over the attack window when there's one.
        let window = config.attackWindowMs > 0 ? config.attackWindowMs * rate / 1000 : delay
        attack = window < 1 ? 1 : 1 / Float(window)
        delayLine = [Float](repeating: 0, count: max(delay, 0))
        (peak, level) = (config.floor, config.floor)
    }

    /// Scales 16-bit-scale samples in place.
    mutating func process(_ samples: inout [Float]) {
        guard config.activated else { return }
        for i in samples.indices {
            let x = samples[i]
            peak *= decay
            let magnitude = abs(x) / 32768
            // As greco does: a louder sample sets the peak even below the floor.
            if peak < magnitude {
                peak = magnitude
            } else if peak < config.floor {
                peak = config.floor
            }
            level += attack * ((peak - level) + (peak - level))
            let gain = (config.levelTarget + level * 0.1) / (level + config.curvature)
                * (config.gainScale / (exp(config.lowerTargetTransition * (config.lowerLevelTarget - level)) + 1))
            // The gain applies to the sample delay_ms back.
            var delayed = x
            if !delayLine.isEmpty {
                delayed = delayLine[delayPosition]
                delayLine[delayPosition] = x
                delayPosition = (delayPosition + 1) % delayLine.count
            }
            samples[i] = gain * delayed
        }
    }
}

/// std::mt19937 with its default seed.
struct MersenneTwister {
    private var state = [UInt32](repeating: 0, count: 624)
    private var index = 624

    init(seed: UInt32 = 5489) {
        state[0] = seed
        for i in 1..<624 { state[i] = 1_812_433_253 &* (state[i - 1] ^ (state[i - 1] >> 30)) &+ UInt32(i) }
    }

    mutating func next() -> UInt32 {
        if index >= 624 {
            for i in 0..<624 {
                let y = (state[i] & 0x8000_0000) | (state[(i + 1) % 624] & 0x7FFF_FFFF)
                state[i] = state[(i + 397) % 624] ^ (y >> 1) ^ (y & 1 == 0 ? 0 : 0x9908_B0DF)
            }
            index = 0
        }
        var y = state[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9D2C_5680
        y ^= (y << 15) & 0xEFC6_0000
        return y ^ (y >> 18)
    }
}

/// libc++'s std::normal_distribution<double>(0, 1): the Marsaglia polar method, keeping the second value, over
/// uniform values from generate_canonical<double, 53> (two 32-bit draws).
struct NormalDistribution {
    private var saved: Double?

    mutating func next(_ g: inout MersenneTwister) -> Double {
        if let saved {
            self.saved = nil
            return saved
        }
        func uniform() -> Double {
            let low = Double(g.next())
            let s = low + Double(g.next()) * 4_294_967_296.0
            return 2 * (s / 18_446_744_073_709_551_616.0) - 1
        }
        var u, v, s: Double
        repeat {
            u = uniform()
            v = uniform()
            s = u * u + v * v
        } while s > 1 || s == 0
        let f = (-2 * log(s) / s).squareRoot()
        saved = v * f
        return u * f
    }
}
