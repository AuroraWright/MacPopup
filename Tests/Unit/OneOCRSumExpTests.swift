// OneOCR's recognizer softmax (RecognizerNet.swift's mlasSumExp, MLAS's exp): the four-lane version gives the same bits
// as the one-lane one, and both are exp. Inputs are random but seeded: ordinary logits, and any float bits.
import Foundation
import Testing
@testable import OneOCR

/// SplitMix64, so a failure repeats.
private struct SeededNumbers: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Logits around the range a softmax sees, every 7th any finite float (huge, tiny, subnormal, negative zero).
private func inputs(_ count: Int, seed: UInt64) -> [Float] {
    var numbers = SeededNumbers(state: seed)
    return (0..<count).map { index in
        guard index % 7 == 0 else { return Float.random(in: -120...30, using: &numbers) }
        let bits = Float(bitPattern: UInt32.random(in: 0...UInt32.max, using: &numbers))
        return bits.isFinite ? bits : 0
    }
}

private let negMaxes: [Float] = [0, -3.25, 17.5, -88]

@Test(arguments: negMaxes)
func fourLanesGiveTheSameBitsAsOne(negMax: Float) {
    let xs = inputs(400_000, seed: 0x5EED + UInt64(negMax.bitPattern))
    var different: [Float] = []
    for start in stride(from: 0, to: xs.count, by: 4) {
        let lanes = mlasSumExp(SIMD4(xs[start], xs[start + 1], xs[start + 2], xs[start + 3]), negMax)
        for lane in 0..<4 where lanes[lane].bitPattern != mlasSumExp(xs[start + lane], negMax).bitPattern {
            different.append(xs[start + lane])
        }
    }
    #expect(different.isEmpty, "\(different.count) differ, e.g. \(different.prefix(3))")
}

@Test func itIsExp() {
    // Within MLAS's polynomial's error (a few ulps), down to where exp underflows.
    for x in stride(from: Float(-87), through: 88, by: 0.37) {
        let expected = expf(x)
        #expect(abs(mlasSumExp(x, 0) - expected) <= expected * 4e-7, "exp(\(x))")
        #expect(abs(mlasSumExp(x + 5, -5) - expected) <= expected * 4e-6, "exp(\(x) + 5 - 5)")
    }
}

/// The kernel's sum and exps (eight lanes, then four, then one at a time) are the one-lane exps, added up as it does.
@Test(arguments: [0, 1, 3, 4, 7, 8, 13, 31])
func theKernelsExpsAreTheOneLaneOnes(count: Int) {
    let xs = inputs(count, seed: 42 + UInt64(count)).map { $0.magnitude < 50 ? $0 : $0.truncatingRemainder(dividingBy: 50) }
    let negMax = -(xs.max() ?? 0)
    var exps = [Float](repeating: .nan, count: count)
    let sum = xs.withUnsafeBufferPointer { x in exps.withUnsafeMutableBufferPointer { mlasSumExp(x, negMax, $0.baseAddress) } }
    let expected = xs.map { mlasSumExp($0, negMax) }
    #expect(exps.map(\.bitPattern) == expected.map(\.bitPattern))
    let total = expected.reduce(0, +)
    #expect(abs(sum - total) <= max(total, 1) * 1e-6, "sum \(sum), the exps' \(total)")
    let noOut = xs.withUnsafeBufferPointer { mlasSumExp($0, negMax, nil) }
    #expect(noOut.bitPattern == sum.bitPattern)
}
