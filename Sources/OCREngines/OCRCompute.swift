import CoreML
import os

/// Where the engines run their models. They run on the CPU once an engine has crashed MacPopup while loading, and
/// in the iOS app's continuous mode, which reads while the app is in the background: there iOS doesn't let apps use the
/// GPU, and the Neural Engine stalled or failed while a game was in front. Models loaded before a change keep their
/// units until they're unloaded.
public enum OCRCompute {
    nonisolated(unsafe) public static var cpuOnly = false

    static func units(_ preferred: MLComputeUnits) -> MLComputeUnits {
        cpuOnly ? .cpuOnly : preferred
    }
}

extension DispatchQueue {
    /// Calls `body` with each of `indices` on up to `workers` threads at once, each taking the next index when it's done
    /// with one (dealt out by turns, a long line could keep one thread busy while the others wait), in the given order.
    static func concurrentForEach(_ indices: [Int], workers: Int, _ body: (Int) -> Void) {
        let next = OSAllocatedUnfairLock(initialState: 0)
        concurrentPerform(iterations: min(workers, indices.count)) { _ in
            while true {
                let k = next.withLock { n in
                    defer { n += 1 }
                    return n
                }
                guard k < indices.count else { return }
                body(indices[k])
            }
        }
    }
}
