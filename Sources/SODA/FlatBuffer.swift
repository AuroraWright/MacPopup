import Foundation

/// A table of a FlatBuffer (the TFLite model format), read in place. Offsets outside the buffer (a damaged file) read as
/// fields that aren't there, rather than reading past it.
struct FlatTable {
    let bytes: UnsafeRawBufferPointer
    let position: Int

    /// The root table of a buffer.
    init(root bytes: UnsafeRawBufferPointer) {
        self.init(bytes, Self.load(bytes, 0, as: UInt32.self).map(Int.init) ?? -1)
    }

    init(_ bytes: UnsafeRawBufferPointer, _ position: Int) {
        (self.bytes, self.position) = (bytes, position)
    }

    private static func load<T>(_ bytes: UnsafeRawBufferPointer, _ offset: Int, as type: T.Type) -> T? {
        guard offset >= 0, offset <= bytes.count - MemoryLayout<T>.size else { return nil }
        return bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
    }

    private func load<T>(_ offset: Int, as type: T.Type) -> T? {
        Self.load(bytes, offset, as: type)
    }

    /// Where field `index` is stored, or nil if it isn't.
    private func field(_ index: Int) -> Int? {
        guard let back = load(position, as: Int32.self) else { return nil }
        let vtable = position - Int(back)
        guard let size = load(vtable, as: UInt16.self), 4 + 2 * index < size,
              let offset = load(vtable + 4 + 2 * index, as: UInt16.self) else { return nil }
        return offset == 0 ? nil : position + Int(offset)
    }

    func scalar<T: FixedWidthInteger>(_ index: Int, _ default: T = 0) -> T {
        field(index).flatMap { load($0, as: T.self) } ?? `default`
    }

    func float(_ index: Int, _ default: Float = 0) -> Float {
        field(index).flatMap { load($0, as: Float.self) } ?? `default`
    }

    func bool(_ index: Int, _ default: Bool = false) -> Bool {
        field(index).flatMap { load($0, as: UInt8.self) }.map { $0 != 0 } ?? `default`
    }

    private func indirect(_ index: Int) -> Int? {
        field(index).flatMap { at in load(at, as: UInt32.self).map { at + Int($0) } }
    }

    func table(_ index: Int) -> FlatTable? {
        indirect(index).map { FlatTable(bytes, $0) }
    }

    func string(_ index: Int) -> String? {
        vector(index, elementSize: 1).map { count, start in
            String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<start + count]), as: UTF8.self)
        }
    }

    /// A vector's element count and where its elements (`elementSize` bytes each) start, if they're in the buffer.
    private func vector(_ index: Int, elementSize: Int) -> (count: Int, start: Int)? {
        guard let at = indirect(index), let count = load(at, as: UInt32.self).map(Int.init),
              count <= (bytes.count - at - 4) / elementSize else { return nil }
        return (count, at + 4)
    }

    func scalars<T: FixedWidthInteger>(_ index: Int, as: T.Type = T.self) -> [T] {
        guard let (count, start) = vector(index, elementSize: MemoryLayout<T>.size) else { return [] }
        return (0..<count).map { bytes.loadUnaligned(fromByteOffset: start + $0 * MemoryLayout<T>.size, as: T.self) }
    }

    func floats(_ index: Int) -> [Float] {
        guard let (count, start) = vector(index, elementSize: 4) else { return [] }
        return (0..<count).map { bytes.loadUnaligned(fromByteOffset: start + $0 * 4, as: Float.self) }
    }

    func data(_ index: Int) -> [UInt8] {
        dataBytes(index).map(Array.init) ?? []
    }

    /// A vector's bytes (of elements `elementSize` bytes each), in place.
    func dataBytes(_ index: Int, elementSize: Int = 1) -> UnsafeRawBufferPointer? {
        guard let (count, start) = vector(index, elementSize: elementSize) else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[start..<start + count * elementSize])
    }

    func tables(_ index: Int) -> [FlatTable] {
        guard let (count, start) = vector(index, elementSize: 4) else { return [] }
        return (0..<count).map { i in
            let at = start + 4 * i
            return FlatTable(bytes, at + Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
        }
    }
}
