import Foundation
import OCREngines

/// The Floating Window's lines as shown, oldest first, without the words heard so far ("Show words as they're heard"):
/// the page sends them whenever they change (see sendLines in overlay.js). Export → Floating Window Lines saves them to
/// a file, and Import puts a file's lines in their place. With "Keep lines after quitting" (Settings → Floating Window),
/// they're also saved for the next launch, and the file is deleted when it's turned off.
@MainActor
final class SavedLines {
    static let shared = SavedLines()

    struct Line: Codable {
        var text: String
        /// When it was shown.
        var time: Date
    }

    /// The saved lines' file and an export: the lines with what made them.
    private struct File: Codable {
        var format: String
        var version: String
        var lines: [Line]
    }

    private static let format = "macpopup-lines"
    /// The most lines saved for the next launch (the newest), since "Maximum lines kept" can be unlimited.
    private static let maxSaved = 1000

    /// Application Support/MacPopup/lines.json; MACPOPUP_LINES_FILE for test runs.
    private static let url = DevelopmentEnvironment["MACPOPUP_LINES_FILE"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPopup/lines.json")

    /// Replaces the text box's lines (for Import and Reset All).
    var onReplace: (([Line]) -> Void)?

    private(set) var lines: [Line] = []
    private var keeping: Bool
    private var pendingWrite: Task<Void, Never>?

    private init() {
        keeping = Self.isOn(SettingsStore.shared.dictionary)
        // The last launch's lines, for the page to start with (also when it reloads before it sent any).
        if keeping, let data = try? Data(contentsOf: Self.url), let file = try? Self.decode(data) {
            lines = file.lines
        }
        SettingsStore.shared.observe { [weak self] _ in self?.settingsChanged() }
    }

    private static func isOn(_ settings: [String: Any]) -> Bool {
        settings["floatingWindowKeepLines"] as? Bool == true
    }

    /// The lines the text box starts with: with "Keep lines after quitting", those it showed before it (re)loaded.
    var linesToRestore: [Line] {
        keeping ? lines : []
    }

    /// The text box's lines changed.
    func shown(_ lines: [Line]) {
        self.lines = lines
        guard keeping, pendingWrite == nil else { return }
        // At most once a second, as a line can grow many times a second; also when the app quits (see save).
        pendingWrite = Task { [weak self] in
            // Not when cancelled: save, clearing or turning the setting off already dealt with the change.
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            self?.save()
        }
    }

    /// Saves the lines now if a change is waiting to be saved.
    func save() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard keeping else { return }
        guard !lines.isEmpty else {
            try? FileManager.default.removeItem(at: Self.url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(lines.suffix(Self.maxSaved)).write(to: Self.url, options: .atomic)
        } catch {
            DebugLog.note("Couldn’t save the Floating Window’s lines: \(error.localizedDescription)")
        }
    }

    /// Clears the text box, and the saved lines (Reset All).
    func clear() {
        lines = []
        pendingWrite?.cancel()
        pendingWrite = nil
        try? FileManager.default.removeItem(at: Self.url)
        onReplace?([])
    }

    func export(to url: URL) throws {
        try encode(lines).write(to: url, options: .atomic)
    }

    /// The lines in an exported file.
    static func lines(in data: Data) throws -> [Line] {
        guard let file = try? decode(data) else { throw AppError("This is not a valid Floating Window lines file") }
        return file.lines
    }

    /// Puts `lines` in the text box's place (Import).
    func replace(with lines: [Line]) {
        onReplace?(lines)
    }

    private func settingsChanged() {
        let on = Self.isOn(SettingsStore.shared.dictionary)
        guard on != keeping else { return }
        keeping = on
        if on {
            save()
        } else {
            pendingWrite?.cancel()
            pendingWrite = nil
            try? FileManager.default.removeItem(at: Self.url)
        }
    }

    private func encode(_ lines: some Sequence<Line>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return try encoder.encode(File(format: Self.format, version: version, lines: Array(lines)))
    }

    private static func decode(_ data: Data) throws -> File {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: data)
        guard file.format == format else { throw AppError("Unknown format \(file.format)") }
        return file
    }
}
