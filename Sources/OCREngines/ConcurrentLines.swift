import CoreGraphics
import Foundation
import os

extension DispatchQueue {
    /// Calls `body` with each index below `count` on up to `workers` threads at once, each taking the next index when
    /// it's done with one (dealt out by turns, a long line could keep one thread busy while the others wait): those of
    /// the longest sizes for their thickness first, so the others share the time they take. After an error none are
    /// taken any more, and it's thrown.
    static func concurrentForEach(
        _ count: Int, workers: Int, longestFirst size: (Int) -> CGSize, _ body: (Int) throws -> Void
    ) throws {
        let order = (0..<count).map { index -> (Int, CGFloat) in
            let size = size(index)
            return (index, max(size.width, size.height) / max(min(size.width, size.height), 1))
        }.sorted { $0.1 > $1.1 }.map(\.0)
        let state = OSAllocatedUnfairLock(uncheckedState: (next: 0, failure: Error?.none))
        concurrentPerform(iterations: min(workers, count)) { _ in
            while true {
                let k = state.withLockUnchecked { state -> Int? in
                    guard state.failure == nil, state.next < order.count else { return nil }
                    defer { state.next += 1 }
                    return state.next
                }
                guard let k else { return }
                do {
                    try body(order[k])
                } catch {
                    state.withLockUnchecked { state in state.failure = state.failure ?? error }
                }
            }
        }
        if let failure = state.withLockUnchecked({ $0.failure }) { throw failure }
    }
}
