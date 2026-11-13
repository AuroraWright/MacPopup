import Foundation

/// What lines of recent readings were recognized as, by their pixels: a line that looks the same as in one of the last
/// few readings (e.g. while another part of the screen changes) isn't recognized again. A model gives the same pixels
/// the same result, so readings don't change; recognizing lines is most of a reading's time. The same file is in
/// Sources/OCREngines, Sources/ScreenAI and Sources/OneOCR (which don't depend on each other).
final class LineCache<Value>: @unchecked Sendable {
    /// Two hashes (with different seeds) of a line's pixels and of what else its result depends on (e.g. its size).
    struct Key: Hashable {
        let first: Int, second: Int

        init(_ pixels: UnsafeRawBufferPointer, _ tag: some Hashable) {
            var first = Hasher(), second = Hasher()
            second.combine(0x5bd1e995)
            first.combine(tag)
            second.combine(tag)
            first.combine(bytes: pixels)
            second.combine(bytes: pixels)
            (self.first, self.second) = (first.finalize(), second.finalize())
        }
    }

    /// Lines not seen in this many readings are dropped.
    private static var readings: Int { 4 }
    private let lock = NSLock()
    private var entries: [Key: (value: Value, seen: Int)] = [:]
    private var count = 0

    subscript(key: Key) -> Value? {
        get {
            lock.withLock {
                guard let entry = entries[key] else { return nil }
                entries[key]?.seen = count
                return entry.value
            }
        }
        set {
            lock.withLock { entries[key] = newValue.map { ($0, count) } }
        }
    }

    /// The value for `key`, made with `make` if there's none.
    func value(_ key: Key, make: () throws -> Value) rethrows -> Value {
        if let known = self[key] { return known }
        let value = try make()
        self[key] = value
        return value
    }

    /// A reading is done: lines it and the few before didn't have are dropped.
    func endReading() {
        lock.withLock {
            count += 1
            entries = entries.filter { count - $0.value.seen < Self.readings }
        }
    }

    func clear() {
        lock.withLock { entries = [:] }
    }
}
