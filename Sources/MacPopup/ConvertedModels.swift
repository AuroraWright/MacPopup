import CoreGraphics
import CoreML
import Foundation

/// The OCR engines whose models can't come with MacPopup: a script converts them on the user's Mac into a zip,
/// which Settings → OCR Mode loads into Application Support.
enum ConvertedModelsKind: String, CaseIterable {
    case screenAI, oneOCR

    var name: String {
        switch self {
        case .screenAI: "Screen AI"
        case .oneOCR: "OneOCR"
        }
    }

    /// Of the folder in Application Support/MacPopup.
    var folderName: String {
        switch self {
        case .screenAI: "ScreenAI"
        case .oneOCR: "OneOCR"
        }
    }

    /// The script that makes the zip, which writes this file (with the format's version) at its root.
    var script: String {
        switch self {
        case .screenAI: "scripts/convert-screenai.py"
        case .oneOCR: "scripts/convert-oneocr.py"
        }
    }

    var infoFileName: String {
        switch self {
        case .screenAI: "screenai.json"
        case .oneOCR: "oneocr.json"
        }
    }

    /// The loaded models: the archive's files, with its Core ML models compiled.
    var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPopup/\(folderName)", isDirectory: true)
    }

    private var infoFile: URL { directory.appendingPathComponent(infoFileName) }

    var installed: Bool { FileManager.default.fileExists(atPath: infoFile.path) }

    /// When the loaded models were converted, if they are.
    var convertedDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: infoFile.path)[.modificationDate] as? Date
    }

    @MainActor var store: any ConvertedModelsStore {
        switch self {
        case .screenAI: ScreenAIOCR.shared.models
        case .oneOCR: OneOCROCR.shared.models
        }
    }
}

protocol ConvertedModelsStore: Sendable {
    func installModels(from archive: URL) async throws
    func removeModels() async throws
}

/// One engine's converted models: loading them from a zip, removing them, and running the engine on them, one
/// reading at a time and off the main thread.
final class ConvertedModels<Engine>: ConvertedModelsStore, @unchecked Sendable {
    let kind: ConvertedModelsKind
    private let make: (URL) throws -> Engine
    private let warmUp: (Engine, CGImage) throws -> Void
    private let queue: DispatchQueue
    private var engine: Engine?

    /// - Parameters:
    ///   - make: Loads the engine from a models directory.
    ///   - warmUp: Reads a blank picture, as the first prediction takes longer (Core ML prepares the models).
    init(_ kind: ConvertedModelsKind, make: @escaping (URL) throws -> Engine,
         warmUp: @escaping (Engine, CGImage) throws -> Void) {
        self.kind = kind
        self.make = make
        self.warmUp = warmUp
        queue = DispatchQueue(label: kind.folderName, qos: .userInitiated)
    }

    private var directory: URL { kind.directory }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Runs body with the engine, loading it first if needed.
    func run<T>(_ body: @escaping (Engine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self.loadedEngine()) })
            }
        }
    }

    private func loadedEngine() throws -> Engine {
        if let engine { return engine }
        guard kind.installed else {
            throw Failure(errorDescription: "\(kind.name)’s models aren’t loaded (Settings → OCR Mode → \(kind.name) models)")
        }
        let loaded = try make(directory)
        if let blank = Self.blankImage() { try warmUp(loaded, blank) }
        engine = loaded
        return loaded
    }

    private static func blankImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()
    }

    /// Replaces the models with those in a zip made by the kind's script: unpacks it next to the models directory,
    /// compiles its Core ML models for this Mac and checks that they load before swapping it in.
    func installModels(from archive: URL) async throws {
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("\(kind.folderName)-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try await Self.unzip(archive, to: staging)

        let info = (try? Data(contentsOf: staging.appendingPathComponent(kind.infoFileName)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let info else {
            throw Failure(errorDescription: "This isn’t a \(kind.name) models archive (made by \(kind.script)).")
        }
        guard info["format"] as? Int == 1 else {
            throw Failure(errorDescription: "These models were converted by a newer version of \(kind.script) than this version of MacPopup reads.")
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
        _ = try make(staging)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.engine = nil
                continuation.resume(with: Result {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: self.directory.path) {
                        _ = try manager.replaceItemAt(self.directory, withItemAt: staging)
                    } else {
                        try manager.moveItem(at: staging, to: self.directory)
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
                    if FileManager.default.fileExists(atPath: self.directory.path) {
                        try FileManager.default.removeItem(at: self.directory)
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

/// Whether an engine's converted models are loaded, for Settings.
@MainActor
final class ConvertedModelsStatus: ObservableObject {
    private static var instances: [ConvertedModelsKind: ConvertedModelsStatus] = [:]

    static func shared(_ kind: ConvertedModelsKind) -> ConvertedModelsStatus {
        if let status = instances[kind] { return status }
        let status = ConvertedModelsStatus(kind)
        instances[kind] = status
        return status
    }

    let kind: ConvertedModelsKind
    /// When the loaded models were converted; nil when there are none.
    @Published private(set) var converted: Date?
    /// Models are being loaded or removed.
    @Published var busy = false

    private init(_ kind: ConvertedModelsKind) {
        self.kind = kind
        refresh()
    }

    func refresh() {
        converted = kind.installed ? kind.convertedDate ?? .distantPast : nil
    }
}
