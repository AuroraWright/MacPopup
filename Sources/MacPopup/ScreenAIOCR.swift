import CoreGraphics
import CoreML
import Foundation
import ScreenAI

/// Text recognition with Screen AI, Chrome's OCR (see Sources/ScreenAI), run with Core ML. Its models are Google's and
/// aren't shipped with the app: scripts/convert-screenai.py converts the ones Chrome downloads into a zip, which
/// Settings → OCR Mode loads (installModels) into Application Support.
final class ScreenAIOCR: @unchecked Sendable {
    static let shared = ScreenAIOCR()

    /// The loaded models: the archive's files, with its Core ML models compiled.
    static let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacPopup/ScreenAI", isDirectory: true)

    private static var infoFile: URL { modelsDirectory.appendingPathComponent("screenai.json") }

    static var modelsInstalled: Bool { FileManager.default.fileExists(atPath: infoFile.path) }

    /// When the loaded models were converted, if they are.
    static var modelsDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: infoFile.path)[.modificationDate] as? Date
    }

    /// Readings (and replacing the models) run one at a time, off the main thread.
    private let queue = DispatchQueue(label: "ScreenAI", qos: .userInitiated)
    private var engine: ScreenAIEngine?

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Loads the models, if they aren't yet. The first prediction takes longer (Core ML prepares the models for the
    /// GPU), so a blank picture is read too.
    func prepare() async throws {
        try await run { _ in }
    }

    func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try await run { engine in Self.lines(try engine.recognize(image), width: image.width, height: image.height) }
    }

    private func run<T>(_ body: @escaping (ScreenAIEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self.loadedEngine()) })
            }
        }
    }

    private func loadedEngine() throws -> ScreenAIEngine {
        if let engine { return engine }
        guard Self.modelsInstalled else {
            throw Failure(errorDescription: "Screen AI’s models aren’t loaded (Settings → OCR Mode → Screen AI models)")
        }
        let loaded = try ScreenAIEngine(modelsDirectory: Self.modelsDirectory)
        if let blank = Self.blankImage() { _ = try loaded.recognize(blank) }
        engine = loaded
        return loaded
    }

    private static func blankImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return context.makeImage()
    }

    /// Lines with a box per character where the recognizer gives them (its symbols), normalized to the image.
    private static func lines(_ lines: [ScreenAIEngine.Line], width: Int, height: Int) -> [RecognizedLine] {
        let w = CGFloat(width), h = CGFloat(height)
        func normalized(_ box: ScreenAIEngine.Box) -> CGRect {
            let b = box.bounds
            return CGRect(x: b.minX / w, y: b.minY / h, width: b.width / w, height: b.height / h)
        }
        return lines.map { line in
            let words = line.words.flatMap { word -> [(text: String, box: CGRect)] in
                word.symbols.isEmpty
                    ? [(word.text, normalized(word.box))]
                    : word.symbols.map { ($0.text, normalized($0.box)) }
            }
            return RecognizedLine(text: line.text, box: normalized(line.box), words: words)
        }
    }

    // MARK: Models

    /// Replaces the models with those in a zip made by scripts/convert-screenai.py: unpacks it next to the models
    /// directory, compiles its Core ML models for this Mac and checks that they load before swapping it in.
    func installModels(from archive: URL) async throws {
        let manager = FileManager.default
        let parent = Self.modelsDirectory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("ScreenAI-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try await Self.unzip(archive, to: staging)

        let info = (try? Data(contentsOf: staging.appendingPathComponent("screenai.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let info else {
            throw Failure(errorDescription: "This isn’t a Screen AI models archive (made by scripts/convert-screenai.py).")
        }
        guard info["format"] as? Int == 1 else {
            throw Failure(errorDescription: "These models were converted by a newer version of scripts/convert-screenai.py than this version of MacPopup reads.")
        }
        let coreml = staging.appendingPathComponent("coreml", isDirectory: true)
        let packages = (try? manager.contentsOfDirectory(at: coreml, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mlpackage" } ?? []
        guard !packages.isEmpty else { throw Failure(errorDescription: "The archive has no Core ML models.") }
        for package in packages {
            let compiled = try await MLModel.compileModel(at: package)
            try manager.moveItem(at: compiled, to: coreml.appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".mlmodelc"))
            try manager.removeItem(at: package)
        }
        // Fails here, rather than when OCR mode starts, if something is missing.
        _ = try ScreenAIEngine(modelsDirectory: staging)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.engine = nil
                continuation.resume(with: Result {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: Self.modelsDirectory.path) {
                        _ = try manager.replaceItemAt(Self.modelsDirectory, withItemAt: staging)
                    } else {
                        try manager.moveItem(at: staging, to: Self.modelsDirectory)
                    }
                })
            }
        }
    }

    func removeModels() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.engine = nil
                continuation.resume(with: Result {
                    if FileManager.default.fileExists(atPath: Self.modelsDirectory.path) {
                        try FileManager.default.removeItem(at: Self.modelsDirectory)
                    }
                })
            }
        }
    }

    private static func unzip(_ archive: URL, to directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errors = Pipe()
        process.standardError = errors
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(errorDescription: "Couldn’t unpack the archive" + (message.isEmpty ? "." : ": \(message)")))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Whether Screen AI's models are loaded, for Settings.
@MainActor
final class ScreenAIModels: ObservableObject {
    static let shared = ScreenAIModels()

    /// When the loaded models were converted; nil when there are none.
    @Published private(set) var converted: Date?
    /// Models are being loaded or removed.
    @Published var busy = false

    private init() {
        refresh()
    }

    func refresh() {
        converted = ScreenAIOCR.modelsInstalled ? ScreenAIOCR.modelsDate ?? .distantPast : nil
    }
}
