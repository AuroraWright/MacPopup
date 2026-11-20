import Foundation

/// The prediction network: the output for a label, with the label before it as its state. Outputs are cached by
/// label pair.
final class PredictionNetwork {
    private let interpreter: Interpreter
    private var cache: [Int: [Float]] = [:]

    init(_ url: URL) throws {
        interpreter = try Interpreter(contentsOf: url)
        guard interpreter.inputs.count == 2 else { throw SODAError("unexpected prediction network signature") }
    }

    func output(previous: Int, label: Int) throws -> [Float] {
        let key = previous << 32 | label
        if let cached = cache[key] { return cached }
        let out = try interpreter.run([Tensor([Int32(label)], shape: [1]), Tensor([Int32(previous)], shape: [1])])[0].floats
        cache[key] = out
        return out
    }

    func clearCache() { cache.removeAll() }
}

/// The joint network: label probabilities for one encoder frame against decoder outputs.
final class JointNetwork {
    private let interpreter: Interpreter
    /// Inputs of rank 3 ([1, 1, D] and [B, 1, D]): one encoder frame against a fixed batch of decoder outputs.
    private let batch: Int?
    let outputSize: Int

    init(_ url: URL) throws {
        interpreter = try Interpreter(contentsOf: url)
        guard interpreter.inputs.count == 2 else { throw SODAError("unexpected joint network signature") }
        let decoder = interpreter.inputs[1].shape
        batch = interpreter.inputs[0].shape.count == 3 ? decoder[0] : nil
        outputSize = interpreter.outputs[0].shape[1]
    }

    /// Rows of `outputSize` probabilities, one per decoder output.
    func run(_ frame: [Float], _ decoderOutputs: [[Float]]) throws -> [Float] {
        let encoderSize = frame.count, decoderSize = decoderOutputs[0].count
        guard let batch else {
            let b = decoderOutputs.count
            let encoder = Tensor([Float]((0..<b).map { _ in frame }.joined()), shape: [b, encoderSize])
            let decoder = Tensor([Float](decoderOutputs.joined()), shape: [b, decoderSize])
            return try interpreter.run([encoder, decoder])[0].floats
        }
        // Unused rows of a batch repeat the first.
        var probabilities: [Float] = []
        for start in stride(from: 0, to: decoderOutputs.count, by: batch) {
            let n = min(batch, decoderOutputs.count - start)
            let rows = (0..<batch).map { decoderOutputs[start + ($0 < n ? $0 : 0)] }
            let out = try interpreter.run([Tensor(frame, shape: [1, 1, encoderSize]),
                                           Tensor([Float](rows.joined()), shape: [batch, 1, decoderSize])])[0].floats
            probabilities += out[0..<n * outputSize]
        }
        return probabilities
    }
}

struct Hypothesis {
    var labels: [Int] = []
    /// The encoder frame of each label.
    var labelFrames: [Int] = []
    /// Accumulated cost (-log p, smoothed).
    var cost: Float = 0
    /// The label before last and the last: the decoder's state.
    var previousLabel = 0
    var lastLabel = 0
}

/// greco's breadth-first transducer search (speech/decoder2/dual, BREADTH_FIRST) over a graph that accepts any label
/// sequence, as opensoda's BeamSearch (transducer.cc) reproduces it.
///
/// On each frame, every hypothesis takes the blank into the next frame, and those within the local beam of the
/// previous frame's best also take every label whose cost is under the label limit. The new hypotheses are pruned
/// with a cost histogram and expanded again, until none are left. A label that reaches the label sequence of a
/// hypothesis the previous frame ended with adds that hypothesis's probability. The blank successors are then merged
/// by label sequence, keeping the cheaper, and pruned with the histogram again.
final class BeamSearch {
    /// greco's infinite cost.
    static let noCost: Float = 1e20

    private let decoder: PredictionNetwork
    private let joint: JointNetwork
    private let config: PipelineConfig.Decoder
    private let maxLabelCost: Float
    private let maxExpansions: Int
    private var beam: [Hypothesis] = []
    /// The label sequences the previous frame ended with (before pruning), and whether they survived its pruning.
    private var ended: [[Int]: (cost: Float, labelFrames: [Int], kept: Bool)] = [:]
    private var bestIndex = 0
    /// The context the segment started from.
    private var start = Hypothesis()
    /// Of the hypotheses entering this frame.
    private var bestCost = noCost
    private(set) var frames = 0

    init(decoder: PredictionNetwork, joint: JointNetwork, config: PipelineConfig.Decoder) {
        (self.decoder, self.joint, self.config) = (decoder, joint, config)
        maxLabelCost = config.maxModelCost > 0 ? config.maxModelCost : Self.noCost
        maxExpansions = max(1, config.maxExpansions)
        reset()
    }

    var best: Hypothesis { beam[bestIndex] }

    /// Starts a new segment from <S>.
    func reset() {
        start = Hypothesis(previousLabel: config.decoderInitialValue, lastLabel: config.sosID)
        beam = [start]
        ended = [:]
        bestIndex = 0
        bestCost = Self.noCost
        frames = 0
    }

    /// Starts a new segment from the best hypothesis's last labels (the decoder's state), without its labels. A context
    /// ending in `ignoredSuffix` resumes from the context before it.
    func resume(ignoredSuffix: Int? = nil) {
        let b = best, l = b.labels, n = l.count
        if let ignoredSuffix, n > 0, l[n - 1] == ignoredSuffix {
            start = Hypothesis(previousLabel: n >= 3 ? l[n - 3] : n == 2 ? start.lastLabel : start.previousLabel,
                               lastLabel: n >= 2 ? l[n - 2] : start.lastLabel)
        } else {
            start = Hypothesis(previousLabel: b.previousLabel, lastLabel: b.lastLabel)
        }
        beam = [start]
        ended = [:]
        bestIndex = 0
        bestCost = Self.noCost
        frames = 0
    }

    /// Label costs for each hypothesis on this frame: -log of p^(1/T), renormalized.
    private func score(_ frame: [Float], _ hypotheses: [Hypothesis]) throws -> [[Float]] {
        let outputs = try hypotheses.map { try decoder.output(previous: $0.previousLabel, label: $0.lastLabel) }
        let probabilities = try joint.run(frame, outputs)
        let vocabulary = joint.outputSize
        let inverseTemperature = 1 / config.smoothingTemperature
        return hypotheses.indices.map { i in
            var c = [Float](repeating: 0, count: vocabulary)
            var norm = -Float.infinity
            for k in 0..<vocabulary {
                c[k] = Foundation.log(max(probabilities[i * vocabulary + k], 1e-30)) * inverseTemperature
                norm = Self.logAdd(norm, c[k])
            }
            for k in 0..<vocabulary { c[k] = norm - c[k] }
            return c
        }
    }

    private static func logAdd(_ x: Float, _ y: Float) -> Float {
        let (a, b) = x < y ? (y, x) : (x, y)
        if b == -.infinity { return a }
        return a + log1p(exp(b - a))
    }

    /// -log(e^-a + e^-b), as greco merges path costs.
    private static func costAdd(_ a: Float, _ b: Float) -> Float {
        let (low, high) = a >= b ? (b, a) : (a, b)
        return low - log1p(exp(-(high - low)))
    }

    /// The pruning threshold from greco's ScoreHistogram for `hypotheses` relative to `best`, starting from
    /// `threshold`.
    private func histogramThreshold(_ hypotheses: [Hypothesis], best: Float, threshold: Float) -> Float {
        let maxArcs = config.maxArcs, minArcs = config.minArcs
        if hypotheses.count <= maxArcs && minArcs <= 0 { return threshold }
        // Bins of width histogramScale / histogramBuckets, rounded, from `best`.
        let buckets = config.histogramBuckets
        let width = config.histogramScale / Float(buckets)
        let scale = Float(buckets) / config.histogramScale
        var counts = [Int](repeating: 0, count: buckets)
        for h in hypotheses {
            let b = (h.cost - best) * scale + 0.5
            var k = 0
            if b.isNaN || b.rounded(.towardZero) < -2_147_483_648 {
                k = 0
            } else if b >= 2_147_483_648 {
                continue
            } else {
                k = max(0, Int(b))
            }
            if k < buckets { counts[k] += 1 }
        }
        // The first bin where more than `limit` hypotheses have been counted.
        func bin(_ limit: Int) -> Int {
            var total = 0
            for k in 0..<buckets {
                total += counts[k]
                if total > limit { return k }
            }
            return buckets
        }
        var threshold = threshold
        if hypotheses.count > maxArcs { threshold = min(threshold, best + Float(bin(maxArcs)) * width) }
        if minArcs >= 1 { threshold = max(threshold, best + Float(bin(minArcs)) * width) }
        return threshold
    }

    func advance(_ frame: [Float]) throws {
        let vocabulary = joint.outputSize
        // Hypotheses expand labels while within the local beam of the previous frame's best; each round's new
        // hypotheses are pruned relative to the best cost seen on this frame.
        let threshold = bestCost + config.localBeam
        var best = bestCost
        var round = beam
        let entering = beam
        var blanks: [Hypothesis] = []
        var expansion = 0
        while expansion < maxExpansions && !round.isEmpty {
            let costs = try score(frame, round)
            let expand = expansion < maxExpansions - 1
            var next: [Hypothesis] = []
            for (h, c) in zip(round, costs) {
                if c[0] < Self.noCost {
                    var b = h
                    b.cost = c[0] + h.cost
                    blanks.append(b)
                }
                if !expand || !(h.cost < threshold) { continue }
                // Hypotheses that entered the frame and extend h: their labels after h's carry alignments still
                // alive in libsoda's prefix tree.
                let extensions = entering.filter { $0.labels.count > h.labels.count && $0.labels.starts(with: h.labels) }
                // Ended. A resumed search keeps </S> as decoder context only, so it is judged by the hypothesis's own
                // labels.
                if config.eosID > 0 && h.labels.last == config.eosID { continue }
                for k in 1..<vocabulary where k != config.sosID {
                    var cost = c[k]
                    if k == config.eosID {
                        // </S> can only end an utterance that has content.
                        if !(config.eosPenalty > 0) || h.labels.isEmpty { continue }
                        cost -= Foundation.log(config.eosPenalty)
                    }
                    if !(cost < Self.noCost) || !(cost <= maxLabelCost) { continue }
                    var e = Hypothesis(labels: h.labels + [k], labelFrames: h.labelFrames + [frames],
                                       cost: (h.cost + cost) + config.wordPenalty, previousLabel: h.lastLabel, lastLabel: k)
                    // Another alignment of these labels ended the previous frame; the merged hypothesis keeps that
                    // earlier alignment if it survived the previous frame's pruning (as libsoda's word times show),
                    // and its cost either way.
                    if let other = ended[e.labels] {
                        if other.kept { e.labelFrames = other.labelFrames }
                        e.cost = Self.costAdd(e.cost, other.cost)
                    } else if let g = extensions.first(where: { $0.labels[h.labels.count] == k }) {
                        // Otherwise a surviving longer hypothesis may still hold these labels' node from an earlier
                        // frame, which the expansion reuses with its time.
                        e.labelFrames = Array(g.labelFrames[..<e.labels.count])
                    }
                    best = min(best, e.cost)
                    next.append(e)
                }
            }
            let t = histogramThreshold(next, best: best, threshold: threshold)
            round = next.filter { $0.cost < t }
            expansion += 1
        }

        // Blank successors with the same labels merge into the cheaper one (the first on ties).
        var index: [[Int]: Int] = [:]
        var nextBest = Self.noCost
        beam = []
        for b in blanks {
            nextBest = min(nextBest, b.cost)
            if let i = index[b.labels] {
                if b.cost < beam[i].cost { beam[i] = b }
            } else {
                index[b.labels] = beam.count
                beam.append(b)
            }
        }
        ended = [:]
        for h in beam where ended[h.labels] == nil { ended[h.labels] = (h.cost, h.labelFrames, false) }
        let t = histogramThreshold(beam, best: nextBest, threshold: nextBest + config.localBeam)
        var b = 0  // The best hypothesis, if every one is pruned.
        for i in beam.indices.dropFirst() where beam[i].cost < beam[b].cost { b = i }
        if !(beam[b].cost < t) {
            // greco drops every hypothesis when more than maxArcs fall in the best one's histogram bin; keep the best.
            beam = [beam[b]]
        } else {
            beam.removeAll { !($0.cost < t) }
        }
        for h in beam { ended[h.labels]?.kept = true }
        bestIndex = 0
        for i in beam.indices.dropFirst() where beam[i].cost < beam[bestIndex].cost { bestIndex = i }
        bestCost = nextBest
        frames += 1
    }
}
