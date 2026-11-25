import CoreGraphics
import Foundation
import ImageIO
import LiveText
import OCREngines

/// ocr-cli read: see main.swift.
@MainActor func read(_ arguments: [String]) async throws {
    var arguments = arguments
    var limit = Int.max
    if let index = arguments.firstIndex(of: "--limit"), index + 1 < arguments.count {
        limit = Int(arguments[index + 1]) ?? .max
        arguments.removeSubrange(index...index + 1)
    }
    var language: String?
    if let index = arguments.firstIndex(of: "--language"), index + 1 < arguments.count {
        language = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
    }
    if let index = arguments.firstIndex(of: "--cpu") {
        OCRCompute.cpuOnly = true
        arguments.remove(at: index)
    }
    guard arguments.count == 4, let engine = Engine(rawValue: arguments[0]) else { usage() }
    let paths = try String(contentsOfFile: arguments[1], encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let picturesFolder = URL(fileURLWithPath: arguments[2])
    let outputFolder = URL(fileURLWithPath: arguments[3]).appendingPathComponent(engine.rawValue)
    try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
    let failures = outputFolder.appendingPathComponent("failures.txt")
    let liveTextLocales: [String] = {
        let locales = OCRLanguage.liveTextLocales(for: "ja")
        return locales.contains { $0.hasPrefix("en") } ? locales : locales + ["en"]
    }()

    func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        switch engine {
        case .liveText:
            let items: [MPLiveTextItem] = try await withCheckedThrowingContinuation { continuation in
                MPLiveText.recognizeImage(image, locales: liveTextLocales) { lines, error in
                    if let lines {
                        continuation.resume(returning: lines)
                    } else {
                        continuation.resume(throwing: error ?? Failure(errorDescription: "Live Text failed"))
                    }
                }
            }
            return items.map(RecognizedLine.init)
        case .screenAI:
            return try await ScreenAIOCR.shared.recognize(image, language: language)
        case .oneOCR:
            return try await OneOCROCR.shared.recognize(image)
        case .meikiocr:
            return try await MeikiOCR.shared.recognize(image)
        case .ppocrManga:
            return try await PPOCRManga.shared.recognize(image)
        case .midaVOCR6:
            return try await MidaVOCR6.shared.recognize(image)
        }
    }

    let todo = paths.filter { !FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent($0 + ".json").path) }
    let count = min(todo.count, limit)
    print("\(paths.count - todo.count) of \(paths.count) already read, \(count) to read with \(engine.rawValue)")
    var done = 0
    var recognizing: TimeInterval = 0
    let started = Date()
    for path in todo.prefix(limit) {
        guard let picture = loadPicture(picturesFolder.appendingPathComponent(path)) else {
            print("failed \(path): can't read the picture")
            appendLine("\(path)\tcan't read the picture", to: failures)
            continue
        }
        do {
            let start = Date()
            let lines = try await recognize(picture)
            if done > 0 { recognizing += Date().timeIntervalSince(start) }
            let raw = lines.map { line in
                var item: [String: Any] = ["text": line.text, "box": rectArray(line.box), "words": line.words.map { [$0.text] + rectArray($0.box).map { $0 as Any } }]
                item["corners"] = line.savedCorners
                return item
            }
            let output = outputFolder.appendingPathComponent(path + ".json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: raw).write(to: output)
            done += 1
            if done % 100 == 0 || done == count {
                print("\(done)/\(count) in \(Int(Date().timeIntervalSince(started)))s")
            }
        } catch {
            print("failed \(path): \(error.localizedDescription)")
            appendLine("\(path)\t\(error.localizedDescription)", to: failures)
        }
    }
    print("done: \(done) read" + (done > 1 ? String(format: ", %.1f ms each after the first", recognizing * 1000 / Double(done - 1)) : ""))
}

private enum Engine: String {
    case liveText, screenAI, oneOCR, meikiocr, ppocrManga, midaVOCR6
}

private struct Failure: LocalizedError {
    let errorDescription: String?
}

/// A picture as it's shown (photos carry their orientation separately), at full size, as the test corpus' tools load
/// them, so their boxes refer to the same pixels.
private func loadPicture(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Appends a line to a log file (failures.txt), making it if needed.
private func appendLine(_ line: String, to url: URL) {
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

/// [x, y, width, height].
private func rectArray(_ box: CGRect) -> [Double] {
    [box.minX, box.minY, box.width, box.height]
}
