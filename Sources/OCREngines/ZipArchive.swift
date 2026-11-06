import Compression
import Foundation

/// Unpacks a zip on iOS, which has no ditto: the stored and deflated entries Python's zipfile writes (the converted
/// models' scripts), including Zip64. Entries are streamed to disk, so large models don't need their size in memory.
enum ZipArchive {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    static func unpack(_ archive: URL, to directory: URL) throws {
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in try entries(data) {
            let components = entry.name.split(separator: "/", omittingEmptySubsequences: true)
            guard !entry.name.hasPrefix("/"), !components.contains(where: { $0 == ".." || $0 == "." }) else {
                throw Failure(errorDescription: "The archive has an unsafe path: \(entry.name)")
            }
            let url = components.reduce(directory) { $0.appendingPathComponent(String($1)) }
            if entry.name.hasSuffix("/") {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            guard entry.flags & 1 == 0 else { throw Failure(errorDescription: "The archive is encrypted.") }
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let offset = Int(entry.localHeaderOffset)
            guard offset + 30 <= data.count, data.uint32(at: offset) == 0x0403_4B50 else { throw corrupt }
            let start = offset + 30 + Int(data.uint16(at: offset + 26)) + Int(data.uint16(at: offset + 28))
            guard start + Int(entry.compressedSize) <= data.count else { throw corrupt }
            let contents = data[start..<(start + Int(entry.compressedSize))]
            guard manager.createFile(atPath: url.path, contents: nil), let file = try? FileHandle(forWritingTo: url) else {
                throw Failure(errorDescription: "Couldn’t write \(entry.name).")
            }
            defer { try? file.close() }
            var written: UInt64 = 0
            switch entry.method {
            case 0:
                try file.write(contentsOf: contents)
                written = UInt64(contents.count)
            case 8:
                // Compression's ZLIB is raw deflate, as in zips.
                let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                    guard let chunk else { return }
                    try file.write(contentsOf: chunk)
                    written += UInt64(chunk.count)
                }
                let step = 1 << 20
                var position = contents.startIndex
                while position < contents.endIndex {
                    let end = min(position + step, contents.endIndex)
                    try filter.write(contents[position..<end])
                    position = end
                }
                try filter.finalize()
            default:
                throw Failure(errorDescription: "The archive uses an unsupported compression method (\(entry.method)).")
            }
            guard written == entry.size else { throw corrupt }
        }
    }

    private static var corrupt: Failure { Failure(errorDescription: "The archive is damaged.") }

    /// The central directory's entries.
    private static func entries(_ data: Data) throws -> [Entry] {
        // The end of central directory record, before a comment of up to 64 KB.
        guard data.count >= 22, let end = stride(from: data.count - 22, through: max(0, data.count - 22 - 0xFFFF), by: -1)
            .first(where: { data.uint32(at: $0) == 0x0605_4B50 })
        else { throw Failure(errorDescription: "This isn’t a zip archive.") }
        var count = UInt64(data.uint16(at: end + 10))
        var directoryOffset = UInt64(data.uint32(at: end + 16))
        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            // Zip64: the locator before the record points to the Zip64 record.
            let locator = end - 20
            guard locator >= 0, data.uint32(at: locator) == 0x0706_4B50 else { throw corrupt }
            let record = Int(data.uint64(at: locator + 8))
            guard record >= 0, record + 56 <= data.count, data.uint32(at: record) == 0x0606_4B50 else { throw corrupt }
            count = data.uint64(at: record + 32)
            directoryOffset = data.uint64(at: record + 48)
        }
        var entries: [Entry] = []
        var position = Int(directoryOffset)
        for _ in 0..<count {
            guard position + 46 <= data.count, data.uint32(at: position) == 0x0201_4B50 else { throw corrupt }
            let nameLength = Int(data.uint16(at: position + 28))
            let extraLength = Int(data.uint16(at: position + 30))
            let commentLength = Int(data.uint16(at: position + 32))
            guard position + 46 + nameLength + extraLength <= data.count else { throw corrupt }
            let name = String(decoding: data[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            var compressedSize = UInt64(data.uint32(at: position + 20))
            var size = UInt64(data.uint32(at: position + 24))
            var localHeaderOffset = UInt64(data.uint32(at: position + 42))
            // Zip64's extra field has the sizes and offset that didn't fit, in this order.
            var extra = position + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.uint16(at: extra)
                let length = Int(data.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    func next(_ value: inout UInt64) {
                        guard value == 0xFFFF_FFFF, field + 8 <= extra + 4 + length else { return }
                        value = data.uint64(at: field)
                        field += 8
                    }
                    next(&size)
                    next(&compressedSize)
                    next(&localHeaderOffset)
                }
                extra += 4 + length
            }
            entries.append(Entry(
                name: name, method: data.uint16(at: position + 10), flags: data.uint16(at: position + 8),
                compressedSize: compressedSize, size: size, localHeaderOffset: localHeaderOffset
            ))
            position += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}
