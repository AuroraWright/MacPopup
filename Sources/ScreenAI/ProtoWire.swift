import Foundation

/// Minimal protobuf wire format, for the models' config files and the goodoc layout dump.
enum WireType: UInt64 {
    case varint = 0, fixed64 = 1, len = 2, fixed32 = 5
}

struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v | 0x80))
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func tag(_ field: Int, _ type: WireType) { varint(UInt64(field) << 3 | type.rawValue) }

    mutating func int(_ field: Int, _ v: Int) {
        tag(field, .varint)
        varint(UInt64(bitPattern: Int64(v)))
    }

    mutating func bool(_ field: Int, _ v: Bool) { int(field, v ? 1 : 0) }

    mutating func float(_ field: Int, _ v: Float) {
        tag(field, .fixed32)
        withUnsafeBytes(of: v.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func double(_ field: Int, _ v: Double) {
        tag(field, .fixed64)
        withUnsafeBytes(of: v.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func bytes<C: Collection>(_ field: Int, _ s: C) where C.Element == UInt8 {
        tag(field, .len)
        varint(UInt64(s.count))
        bytes.append(contentsOf: s)
    }

    mutating func string(_ field: Int, _ s: String) { bytes(field, Array(s.utf8)) }

    mutating func message(_ field: Int, _ w: ProtoWriter) { bytes(field, w.bytes) }
}

/// Iterates the fields of one serialized message: `while r.next() { switch r.field ... }`.
struct ProtoReader {
    private let buf: ArraySlice<UInt8>
    private var p: Int
    private(set) var ok = true
    private(set) var field = 0
    private(set) var wireType = WireType.varint
    private(set) var varint: UInt64 = 0
    private var fixed32: UInt32 = 0
    private var fixed64: UInt64 = 0
    private(set) var bytes: ArraySlice<UInt8> = []

    init(_ data: ArraySlice<UInt8>) {
        buf = data
        p = data.startIndex
    }

    init(_ data: [UInt8]) { self.init(data[...]) }

    var int64: Int64 { Int64(bitPattern: varint) }
    var int: Int { Int(truncatingIfNeeded: int64) }
    var float32: Float { Float(bitPattern: fixed32) }
    var float64: Double { Double(bitPattern: fixed64) }
    var string: String { String(decoding: bytes, as: UTF8.self) }

    mutating func next() -> Bool {
        guard p < buf.endIndex, ok else { return false }
        guard let key = readVarint() else { return false }
        field = Int(key >> 3)
        guard let type = WireType(rawValue: key & 7) else { return fail() }
        wireType = type
        switch type {
        case .varint:
            guard let v = readVarint() else { return false }
            varint = v
        case .fixed64:
            guard buf.endIndex - p >= 8 else { return fail() }
            fixed64 = 0
            for i in 0..<8 { fixed64 |= UInt64(buf[p + i]) << (8 * i) }
            p += 8
        case .fixed32:
            guard buf.endIndex - p >= 4 else { return fail() }
            fixed32 = 0
            for i in 0..<4 { fixed32 |= UInt32(buf[p + i]) << (8 * i) }
            p += 4
        case .len:
            guard let n = readVarint(), UInt64(buf.endIndex - p) >= n else { return fail() }
            bytes = buf[p..<p + Int(n)]
            p += Int(n)
        }
        return true
    }

    private mutating func fail() -> Bool {
        ok = false
        return false
    }

    private mutating func readVarint() -> UInt64? {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 && p < buf.endIndex {
            let b = buf[p]
            p += 1
            v |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return v }
            shift += 7
        }
        ok = false
        return nil
    }
}
