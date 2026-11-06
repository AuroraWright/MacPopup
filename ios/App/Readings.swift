import CoreGraphics
import Foundation
import ImageIO
import OCREngines
import UniformTypeIdentifiers

/// A picture to read: as shown (rotated by its orientation), at full size, and its file for the page when Safari shows
/// that format.
struct Picture: @unchecked Sendable {
    let image: CGImage
    /// The file as it came, with its extension, or nil when it's saved as PNG.
    let file: (data: Data, pathExtension: String)?

    /// Formats Safari shows still and rotated the way the picture is read.
    private static let shownTypes: [UTType] = [.png, .jpeg, .heic, .heif, .webP]

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = Self.image(source) else { return nil }
        self.image = image
        let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        if let type, Self.shownTypes.contains(type), CGImageSourceGetCount(source) == 1 {
            file = (data, type.preferredFilenameExtension ?? "png")
        } else {
            file = nil
        }
    }

    init(image: CGImage) {
        self.image = image
        file = nil
    }

    /// The test-corpus tools' loading (tools/shared/Picture.swift).
    private static func image(_ source: CGImageSource) -> CGImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A saved reading, as listed: Documents/readings/<id>/{reading.json, image.<ext>}, served at /r/<id>.
struct Reading: Identifiable, Sendable {
    let id: String
    let createdAt: Date
    let engine: String
    /// The text, lines joined, for lists.
    let text: String
    let imageFile: URL
}

/// The saved readings. Used from the main actor and the page server's queue.
final class ReadingStore: @unchecked Sendable {
    static let shared = ReadingStore()

    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("readings", isDirectory: true)

    private let lock = NSLock()
    private var cached: [Reading]?

    /// Newest first.
    var readings: [Reading] {
        lock.withLock {
            if let cached { return cached }
            let ids = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let readings = ids.compactMap(load).sorted { $0.createdAt > $1.createdAt }
            cached = readings
            return readings
        }
    }

    func reading(_ id: String) -> Reading? {
        readings.first { $0.id == id }
    }

    /// Removes readings with their pictures. Safari drops its copies the next time it lists the readings.
    func delete(_ ids: Set<String>) {
        lock.withLock {
            for id in ids {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
            }
            cached = cached?.filter { !ids.contains($0.id) }
        }
    }

    /// Reads the picture and saves the reading.
    func read(_ picture: Picture, engine: Engine, language: String, stripsFurigana: Bool) async throws -> Reading {
        let lines = try await engine.recognize(picture.image, language: language)
        let reading = Self.page(picture.image, lines: lines, engine: engine, language: language, stripsFurigana: stripsFurigana)
        return try save(picture, reading: reading)
    }

    /// The page's data, as OCRController.lines(from:) makes it for one area, in the picture's pixels: {image: {width,
    /// height}, lines: [{vertical, area, cloud, chars: [[text, x, y, width, height]]}], engine, language, createdAt}.
    static func page(
        _ image: CGImage, lines items: [RecognizedLine], engine: Engine, language: String, stripsFurigana: Bool
    ) -> [String: Any] {
        let size = CGSize(width: image.width, height: image.height)
        let toPixels = { (box: CGRect) in
            CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        let gray = GrayImage(image)
        let kept = items.filter { OCRLanguage.contains($0.text, language: language) }
        var lines = kept.map { OCRLayout.layOut($0, image: gray, size: size, exactBoxes: engine.hasExactBoxes, toWindow: toPixels) }
        if stripsFurigana { lines = OCRLayout.removingFurigana(lines) }
        let ordered = engine.ordersLines ? OCRLayout.keepingRowsTogether(lines) : OCRLayout.inReadingOrder(lines)
        return [
            "image": ["width": image.width, "height": image.height],
            "engine": engine.rawValue,
            "language": language,
            "createdAt": (Date().timeIntervalSince1970 * 1000).rounded(),
            "lines": ordered.map { line in
                [
                    "vertical": line.vertical, "area": 0, "cloud": false,
                    "chars": line.chars.map { [$0.text, $0.box.minX, $0.box.minY, $0.box.width, $0.box.height] as [Any] },
                ] as [String: Any]
            },
        ]
    }

    private func save(_ picture: Picture, reading: [String: Any]) throws -> Reading {
        let id = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let directory = folder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let file = picture.file {
            try file.data.write(to: directory.appendingPathComponent("image.\(file.pathExtension)"))
        } else {
            let url = directory.appendingPathComponent("image.png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw AppError("Couldn’t save the picture.")
            }
            CGImageDestinationAddImage(destination, picture.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw AppError("Couldn’t save the picture.") }
        }
        try JSONSerialization.data(withJSONObject: reading).write(to: directory.appendingPathComponent("reading.json"))
        guard let saved = load(id) else { throw AppError("Couldn’t save the reading.") }
        lock.withLock { cached = cached.map { [saved] + $0 } }
        return saved
    }

    private func load(_ id: String) -> Reading? {
        let directory = folder.appendingPathComponent(id, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("reading.json")),
              let reading = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let image = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.first(where: { $0.hasPrefix("image.") })
        else { return nil }
        let lines = reading["lines"] as? [[String: Any]] ?? []
        let text = lines.map { line in
            (line["chars"] as? [[Any]] ?? []).compactMap { $0.first as? String }.joined()
        }.joined(separator: " ")
        return Reading(
            id: id,
            createdAt: Date(timeIntervalSince1970: (reading["createdAt"] as? Double ?? 0) / 1000),
            engine: reading["engine"] as? String ?? "",
            text: text,
            imageFile: directory.appendingPathComponent(image)
        )
    }
}
