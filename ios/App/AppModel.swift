import OCREngines
import SwiftUI
import UIKit

/// The settings, under the names MacPopup's settings use, with its defaults.
enum SettingsKey {
    static let engine = "ocrEngine"
    static let language = "language"
    static let stripsFurigana = "ocrStripFurigana"
    /// iOS only: pictures chosen in the app can be cropped before they're read.
    static let cropsPictures = "cropBeforeReading"
}

/// Reads pictures and opens their pages in Safari.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var readings: [Reading] = []
    @Published private(set) var isReading = false
    @Published var error: String?
    /// A picture chosen in the app, to crop before reading (with Crop before reading on).
    @Published var cropping: CropRequest?

    /// Yomitan's languages (web/src/lib/languages.js), as the viewer build lists them.
    let languages: [(iso: String, name: String)] = {
        guard let url = Bundle.main.url(forResource: "languages", withExtension: "json", subdirectory: "Viewer"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [("ja", "Japanese")] }
        return list.compactMap { item in item["iso"].flatMap { iso in item["name"].map { (iso, $0) } } }
    }()

    private let defaults = UserDefaults.standard
    /// The engine whose models are loaded, if any.
    private var loadedEngine: Engine?
    /// The background time for serving the page last opened.
    private var servingTask = UIBackgroundTaskIdentifier.invalid

    private init() {
        defaults.register(defaults: [SettingsKey.engine: Engine.liveText.rawValue, SettingsKey.language: "ja", SettingsKey.stripsFurigana: true])
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.unloadEngine() }
        }
    }

    /// The engine in Settings, or Live Text when its models aren't there.
    var engine: Engine {
        let engine = Engine(rawValue: defaults.string(forKey: SettingsKey.engine) ?? "") ?? .liveText
        return engine.isAvailable ? engine : .liveText
    }

    var language: String {
        defaults.string(forKey: SettingsKey.language) ?? "ja"
    }

    /// Furigana are left out of readings only in Japanese (as on the Mac).
    var stripsFurigana: Bool {
        language == "ja" && defaults.bool(forKey: SettingsKey.stripsFurigana)
    }

    /// For testing on a device with `xcrun devicectl`: `-installModels <screenAI|oneOCR> <name>` loads the models in that
    /// zip in Documents; `-readFile <name>` reads that file in Documents as if it were chosen, along with the settings
    /// as arguments (e.g. `-ocrEngine meikiocr`); `-readLive <name> …` reads those files in Documents into the live
    /// page, 3 s apart, as if continuous mode had captured them.
    func launched() {
        PageServer.shared.start()
        refresh()
        Task {
            let arguments = ProcessInfo.processInfo.arguments
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let index = arguments.firstIndex(of: "-installModels"), index + 2 < arguments.count,
               let kind = ConvertedModelsKind(rawValue: arguments[index + 1]) {
                let start = Date()
                do {
                    try await kind.store.installModels(from: documents.appendingPathComponent(arguments[index + 2]))
                    ConvertedModelsStatus.shared(kind).refresh()
                    IntentLog.append(String(format: "Loaded %@’s models in %.1f s", kind.name, Date().timeIntervalSince(start)))
                } catch {
                    IntentLog.append("Loading \(kind.name)’s models failed: \(error.localizedDescription)")
                }
            }
            if let index = arguments.firstIndex(of: "-readLive") {
                PageServer.shared.start()
                for name in arguments[(index + 1)...].prefix(while: { !$0.hasPrefix("-") }) {
                    try? await Task.sleep(for: .seconds(3))
                    guard let data = try? Data(contentsOf: documents.appendingPathComponent(name)), let picture = await Self.picture(data) else { continue }
                    await Continuous.shared.read(picture)
                }
            } else if let index = arguments.firstIndex(of: "-readFile"), index + 1 < arguments.count {
                guard let data = try? Data(contentsOf: documents.appendingPathComponent(arguments[index + 1])) else {
                    error = "Couldn’t open \(arguments[index + 1])."
                    return
                }
                await choose(data)
            } else {
                await prepareEngine()
            }
        }
    }

    func refresh() {
        readings = ReadingStore.shared.readings
    }

    /// Loads the engine in Settings, freeing the one loaded before (their models take up to about 1 GB).
    /// - Parameter engine: Another engine than Settings' (continuous mode's, see Continuous.engine).
    func prepareEngine(_ engine: Engine? = nil) async {
        let engine = engine ?? self.engine
        if let loadedEngine, loadedEngine != engine { await unloadEngine() }
        loadedEngine = engine
        try? await engine.prepare(language: language)
    }

    /// The imported models the loaded engine runs on, if any.
    var loadedEngineModels: ConvertedModelsKind? {
        loadedEngine?.convertedModels
    }

    func unloadEngine() async {
        guard let engine = loadedEngine else { return }
        loadedEngine = nil
        await engine.unload()
    }

    /// A picture chosen in the app: cropped first when that's on, then read.
    func choose(_ data: Data) async {
        guard defaults.bool(forKey: SettingsKey.cropsPictures) else { return await read(data) }
        guard let picture = await Self.picture(data) else {
            error = "This file isn’t a picture that can be read."
            return
        }
        cropping = CropRequest(picture: picture)
    }

    func delete(_ ids: Set<String>) {
        ReadingStore.shared.delete(ids)
        refresh()
    }

    func read(_ data: Data) async {
        guard let picture = await Self.picture(data) else {
            error = "This file isn’t a picture that can be read."
            return
        }
        await read(picture)
    }

    func read(_ picture: Picture) async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        do {
            open(PageServer.url(try await reading(picture)))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reads the pictures shared to the app (Share/) and opens the last one's page.
    func readShared() async {
        guard !isReading else { return }
        let pictures = Inbox.take()
        guard !pictures.isEmpty else { return }
        isReading = true
        defer { isReading = false }
        var last: Reading?
        for data in pictures {
            do {
                guard let picture = await Self.picture(data) else { throw AppError("The shared file isn’t a picture that can be read.") }
                last = try await reading(picture)
            } catch {
                self.error = error.localizedDescription
            }
        }
        if let last { open(PageServer.url(last)) }
    }

    nonisolated static func picture(_ data: Data) async -> Picture? {
        await Task.detached { Picture(data: data) }.value
    }

    /// Reads the picture with the engine in Settings and saves the reading (also for the Shortcuts actions).
    func reading(_ picture: Picture) async throws -> Reading {
        let reading = try ReadingStore.shared.save(picture, reading: try await page(picture))
        refresh()
        return reading
    }

    /// Reads the picture with the engine in Settings: the page's data, not saved (see ReadingStore.page).
    func page(_ picture: Picture, engine: Engine? = nil) async throws -> [String: Any] {
        let engine = engine ?? self.engine
        if loadedEngine != engine { await prepareEngine(engine) }
        return try await ReadingStore.read(picture, engine: engine, language: language, stripsFurigana: stripsFurigana)
    }

    /// Opens a page in Safari.
    func open(_ url: URL) {
        serve()
        UIApplication.shared.open(url)
    }

    /// Keeps the page server up for the background time iOS gives (about 30 s), while Safari loads a page; after that
    /// the page's service worker has it.
    func serve() {
        PageServer.shared.start()
        endServing()
        servingTask = UIApplication.shared.beginBackgroundTask(withName: "Serve the page") {
            MainActor.assumeIsolated { AppModel.shared.endServing() }
        }
    }

    private func endServing() {
        guard servingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(servingTask)
        servingTask = .invalid
    }
}
