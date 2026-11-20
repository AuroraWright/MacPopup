import Foundation

/// A table of a FlatBuffer (the TFLite model format), read in place.
struct FlatTable {
    let bytes: UnsafeRawBufferPointer
    let position: Int

    /// The root table of a buffer.
    init(root bytes: UnsafeRawBufferPointer) {
        self.init(bytes, Int(bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
    }

    init(_ bytes: UnsafeRawBufferPointer, _ position: Int) {
        (self.bytes, self.position) = (bytes, position)
    }

    /// Where field `index` is stored, or nil if it isn't.
    private func field(_ index: Int) -> Int? {
        let vtable = position - Int(bytes.loadUnaligned(fromByteOffset: position, as: Int32.self))
        let size = Int(bytes.loadUnaligned(fromByteOffset: vtable, as: UInt16.self))
        guard 4 + 2 * index < size else { return nil }
        let offset = Int(bytes.loadUnaligned(fromByteOffset: vtable + 4 + 2 * index, as: UInt16.self))
        return offset == 0 ? nil : position + offset
    }

    func scalar<T: FixedWidthInteger>(_ index: Int, _ default: T = 0) -> T {
        field(index).map { bytes.loadUnaligned(fromByteOffset: $0, as: T.self) } ?? `default`
    }

    func float(_ index: Int, _ default: Float = 0) -> Float {
        field(index).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) } ?? `default`
    }

    func bool(_ index: Int, _ default: Bool = false) -> Bool {
        field(index).map { bytes[$0] != 0 } ?? `default`
    }

    private func indirect(_ index: Int) -> Int? {
        field(index).map { $0 + Int(bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)) }
    }

    func table(_ index: Int) -> FlatTable? {
        indirect(index).map { FlatTable(bytes, $0) }
    }

    func string(_ index: Int) -> String? {
        indirect(index).map { start in
            let count = Int(bytes.loadUnaligned(fromByteOffset: start, as: UInt32.self))
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start + 4..<start + 4 + count]), as: UTF8.self)
        }
    }

    /// A vector's element count and where its elements start.
    private func vector(_ index: Int) -> (count: Int, start: Int)? {
        indirect(index).map { (Int(bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)), $0 + 4) }
    }

    func scalars<T: FixedWidthInteger>(_ index: Int, as: T.Type = T.self) -> [T] {
        guard let (count, start) = vector(index) else { return [] }
        return (0..<count).map { bytes.loadUnaligned(fromByteOffset: start + $0 * MemoryLayout<T>.size, as: T.self) }
    }

    func floats(_ index: Int) -> [Float] {
        guard let (count, start) = vector(index) else { return [] }
        return (0..<count).map { bytes.loadUnaligned(fromByteOffset: start + $0 * 4, as: Float.self) }
    }

    func data(_ index: Int) -> [UInt8] {
        dataBytes(index).map(Array.init) ?? []
    }

    /// A vector's bytes (of elements `elementSize` bytes each), in place.
    func dataBytes(_ index: Int, elementSize: Int = 1) -> UnsafeRawBufferPointer? {
        guard let (count, start) = vector(index) else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[start..<start + count * elementSize])
    }

    func tables(_ index: Int) -> [FlatTable] {
        guard let (count, start) = vector(index) else { return [] }
        return (0..<count).map { i in
            let at = start + 4 * i
            return FlatTable(bytes, at + Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
        }
    }
}
