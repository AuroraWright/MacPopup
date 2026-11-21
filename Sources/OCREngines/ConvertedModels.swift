import CoreGraphics
import CoreML
import Foundation

/// The OCR engines, speech recognition models and SaT (sentence ends in transcriptions), whose models can't come with MacPopup: a script converts or packs them
/// on the user's Mac into a zip, which Settings → OCR or Transcription loads into Application Support.
public enum ConvertedModelsKind: String, CaseIterable, Sendable {
    case screenAI, oneOCR, whisper, animeWhisper, kitsune, senseVoice, parakeet, soda, sat

    /// The OCR engines' (the iPhone app's).
    public static let ocr: [ConvertedModelsKind] = [.screenAI, .oneOCR]

    public var name: String {
        switch self {
        case .screenAI: "Screen AI"
        case .oneOCR: "OneOCR"
        case .whisper: "Whisper"
        case .animeWhisper: "anime-whisper"
        case .kitsune: "Kitsune"
        case .senseVoice: "SenseVoice"
        case .parakeet: "Parakeet"
        case .soda: "Live Caption"
        case .sat: "SaT"
        }
    }

    /// The folder's name in Application Support/MacPopup.
    var folderName: String {
        switch self {
        case .screenAI: "ScreenAI"
        case .oneOCR: "OneOCR"
        case .whisper: "Whisper"
        case .animeWhisper: "AnimeWhisper"
        case .kitsune: "Kitsune"
        case .senseVoice: "SenseVoice"
        case .parakeet: "Parakeet"
        case .soda: "SODA"
        case .sat: "SaT"
        }
    }

    /// The script that makes the zip.
    public var script: String {
        switch self {
        case .screenAI: "scripts/convert-screenai.py"
        case .oneOCR: "scripts/convert-oneocr.py"
        case .whisper: "scripts/convert-whisper.py"
        case .animeWhisper: "scripts/convert-anime-whisper.py"
        case .kitsune: "scripts/convert-kitsune.py"
        case .senseVoice: "scripts/convert-sensevoice.py"
        case .parakeet: "scripts/convert-parakeet.py"
        case .soda: "scripts/convert-soda.py"
        case .sat: "scripts/convert-sat.py"
        }
    }

    /// Whether the zip has Core ML models (in coreml/): all but Live Caption's, which are TFLite models run by MacPopup.
    var hasCoreMLModels: Bool { self != .soda }

    /// The file the script writes at the zip's root, with the format's version.
    public var infoFileName: String {
        "\(folderName.lowercased()).json"
    }

    /// The Settings section with its Load button.
    public var settingsSection: String {
        Self.ocr.contains(self) ? "OCR" : "Transcription"
    }

    /// The loaded models: the archive's files, with its Core ML models compiled. In Application Support/MacPopup, or
    /// in MACPOPUP_MODELS_DIRECTORY (for test runs).
    public var directory: URL {
        let base = DevelopmentEnvironment["MACPOPUP_MODELS_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPopup", isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private var infoFile: URL { directory.appendingPathComponent(infoFileName) }

    public var installed: Bool { FileManager.default.fileExists(atPath: infoFile.path) }

    /// When the loaded models were converted, if they are.
    public var convertedDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: infoFile.path)[.modificationDate] as? Date
    }

    /// The kinds run by other modules (transcription's), which the app registers when it starts.
    @MainActor private static var registered: [ConvertedModelsKind: any ConvertedModelsStore] = [:]

    @MainActor public static func register(_ store: any ConvertedModelsStore, for kind: ConvertedModelsKind) {
        registered[kind] = store
    }

    @MainActor public var store: any ConvertedModelsStore {
        switch self {
        case .screenAI: return ScreenAIOCR.shared.models
        case .oneOCR: return OneOCROCR.shared.models
        default:
            guard let store = Self.registered[self] else { preconditionFailure("\(name)’s models aren’t registered") }
            return store
        }
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?

        public init(_ description: String) {
            errorDescription = description
        }
    }

    /// Unpacks a zip made by the kind's script next to its models directory, checks its format and compiles its Core
    /// ML packages for this device (models already compiled, .mlmodelc, are kept). Returns the unpacked folder, which
    /// the caller removes if it doesn't move it in.
    public func unpack(_ archive: URL) async throws -> URL {
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("\(folderName)-\(UUID().uuidString)", isDirectory: true)
        do {
            try await Self.unzip(archive, to: staging)
            let info = (try? Data(contentsOf: staging.appendingPathComponent(infoFileName)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let info else {
                throw Failure("This isn’t a \(name) models archive (made by \(script)).")
            }
            guard info["format"] as? Int == 1 else {
                throw Failure("These models were converted by a newer version of \(script) than this version of MacPopup reads.")
            }
            guard hasCoreMLModels else { return staging }
            let coreml = staging.appendingPathComponent("coreml", isDirectory: true)
            let models = (try? manager.contentsOfDirectory(at: coreml, includingPropertiesForKeys: nil))?
                .filter { ["mlpackage", "mlmodelc"].contains($0.pathExtension) } ?? []
            guard !models.isEmpty else { throw Failure("The archive has no Core ML models.") }
            for package in models where package.pathExtension == "mlpackage" {
                let compiled = try await MLModel.compileModel(at: package)
                try manager.moveItem(at: compiled, to: coreml.appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".mlmodelc"))
                try manager.removeItem(at: package)
            }
            return staging
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Replaces the models directory with a folder from unpack.
    public func moveIn(_ staging: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            _ = try manager.replaceItemAt(directory, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: directory)
        }
    }

    private static func unzip(_ archive: URL, to directory: URL) async throws {
        #if os(macOS)
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
                    continuation.resume(throwing: Failure("Couldn’t unpack the archive" + (message.isEmpty ? "." : ": \(message)")))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #else
        // iOS has no ditto.
        try await Task.detached(priority: .userInitiated) { try ZipArchive.unpack(archive, to: directory) }.value
        #endif
    }
}

public protocol ConvertedModelsStore: Sendable {
    func installModels(from archive: URL) async throws
    func removeModels() async throws
}

/// One engine's converted models: loading them from a zip, removing them, and running the engine on them, one
/// reading at a time and off the main thread.
public final class ConvertedModels<Engine>: ConvertedModelsStore, @unchecked Sendable {
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
            throw ConvertedModelsKind.Failure("\(kind.name)’s models aren’t loaded (Settings → \(kind.settingsSection) → \(kind.name) models)")
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

    /// Replaces the models with those in a zip made by the kind's script, after checking that they load.
    public func installModels(from archive: URL) async throws {
        let staging = try await kind.unpack(archive)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Fails here, rather than when OCR starts, if something is missing.
        _ = try make(staging)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.engine = nil
                continuation.resume(with: Result { try self.kind.moveIn(staging) })
            }
        }
    }

    /// Lets the loaded engine go, to free its memory; the next run loads it again.
    func unload() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.engine = nil
                continuation.resume()
            }
        }
    }

    public func removeModels() async throws {
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
}

/// Whether an engine's converted models are loaded, for Settings.
@MainActor
public final class ConvertedModelsStatus: ObservableObject {
    private static var instances: [ConvertedModelsKind: ConvertedModelsStatus] = [:]

    public static func shared(_ kind: ConvertedModelsKind) -> ConvertedModelsStatus {
        if let status = instances[kind] { return status }
        let status = ConvertedModelsStatus(kind)
        instances[kind] = status
        return status
    }

    public let kind: ConvertedModelsKind
    /// When the loaded models were converted; nil when there are none.
    @Published public private(set) var converted: Date?
    /// Models are being loaded or removed.
    @Published public var busy = false

    private init(_ kind: ConvertedModelsKind) {
        self.kind = kind
        refresh()
    }

    public func refresh() {
        converted = kind.installed ? kind.convertedDate ?? .distantPast : nil
    }
}
