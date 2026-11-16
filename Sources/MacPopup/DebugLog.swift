import AppKit

/// With Settings → General → Debug on, what MacPopup does is written here, one JSON object per line, for bug reports:
/// a session record (MacPopup's version, the Mac, permissions, controllers, displays and settings) at launch and when
/// the setting is turned on, then settings as they change, the page's records (OCR readings, lines, popups, shortcuts,
/// cards added, messages shown; see logDebug in web/src/overlay.js) and the app's messages (OCR, Game Pause, Anki
/// Audio, Anki Screenshot, lines noted, failed requests): Application Support/MacPopup/debug.jsonl, or the folder in
/// MACPOPUP_DEBUG_OCR_DIR. Over 20 MB, it's moved to debug.old.jsonl and a new one is started. Both are deleted when
/// the setting is turned off (and at launch while it's off), so they don't build up over time.
enum DebugLog {
    private static let queue = DispatchQueue(label: "DebugLog")
    private static let maxSize = 20_000_000

    static var url: URL { folder.appendingPathComponent("debug.jsonl") }

    private static var folder: URL {
        ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_OCR_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPopup")
    }

    /// Whether the log is written (Settings → General → Debug, whose key is from when it was about OCR only).
    @MainActor static var isOn: Bool { SettingsStore.shared.dictionary["ocrShowBoxes"] as? Bool == true }

    private static var oldURL: URL { folder.appendingPathComponent("debug.old.jsonl") }

    /// The log's names before it was about more than OCR.
    private static var formerURLs: [URL] { ["ocr-debug.jsonl", "ocr-debug.old.jsonl"].map { folder.appendingPathComponent($0) } }

    @MainActor private static var wasOn = false

    /// Called after each session record, to log what's going on then (e.g. the window OCR reads).
    @MainActor static var onSession: (() -> Void)?

    /// The settings as last logged (each as JSON, to compare): changes are logged as they're made.
    @MainActor private static var loggedSettings: [String: String] = [:]

    /// Called at launch.
    @MainActor static func start() {
        wasOn = isOn
        let former = formerURLs
        queue.async {
            for file in former { try? FileManager.default.removeItem(at: file) }
        }
        if wasOn { session() } else { delete() }
        SettingsStore.shared.observe { _ in
            let on = isOn
            defer { wasOn = on }
            if wasOn, !on {
                delete()
            } else if !wasOn, on {
                // A new log starts (the last was deleted as it was turned off).
                session()
            } else if on {
                logSettingsChanges()
            }
        }
    }

    /// Shows the log in Finder (or its folder, while there's none).
    @MainActor static func reveal() {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// After what's still being written.
    private static func delete() {
        let files = [url, oldURL]
        queue.async {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static let printsToStderr = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_OCR"] != nil

    /// A message from the app, with the system uptime (as in the test tools' logs); also to stderr with
    /// MACPOPUP_DEBUG_OCR set.
    @MainActor static func note(_ message: @autoclosure () -> String) {
        let toFile = isOn
        guard printsToStderr || toFile else { return }
        let message = message(), uptime = ProcessInfo.processInfo.systemUptime
        if printsToStderr {
            FileHandle.standardError.write("[ocr \(String(format: "%.3f", uptime))] \(message)\n".data(using: .utf8)!)
        }
        if toFile { record(["type": "log", "uptime": (uptime * 1000).rounded() / 1000, "message": message]) }
    }

    /// A record (its type and fields), with the time.
    static func record(_ fields: [String: Any]) {
        let record = fields.merging(["time": timeFormat.string(from: OCRClock.now)]) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        append(json)
    }

    /// The settings logged: those that change how OCR reads and shows text, how lines and popups are scanned, Game Pause,
    /// the controller, the popup shortcuts, the overlay switch, Anki (but not its key), Anki Screenshot, Anki Audio and
    /// IINA.
    @MainActor static var settings: [String: Any] {
        let prefixes = ["ocr", "gamePause", "gamepad", "scan", "popupScan", "overlaySwitch", "anki", "screenshot", "sentenceAudio", "iina"]
        let keys: Set<String> = ["language", "websocketUrls", "floatingWindowOCR", "hotkeys", "duplicateBehavior", "checkForDuplicates"]
        return SettingsStore.shared.dictionary.filter { key, _ in
            key != "ankiConnectKey" && (keys.contains(key) || prefixes.contains { key.hasPrefix($0) })
        }
    }

    @MainActor private static func logSettingsChanges() {
        let current = settings.mapValues(json)
        defer { loggedSettings = current }
        let changed = Set(current.keys).union(loggedSettings.keys).filter { current[$0] != loggedSettings[$0] }
        guard !changed.isEmpty else { return }
        let values = settings
        record(["type": "settings", "changed": Dictionary(uniqueKeysWithValues: changed.map { ($0, values[$0] ?? NSNull()) })])
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a log from someone else needs to be read: MacPopup's version, the Mac's, the permissions, controllers,
    /// displays and settings. Then, once they answer, the versions of AnkiConnect and the Yomitan API.
    @MainActor private static func session() {
        let info = Bundle.main.infoDictionary ?? [:]
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let permissions: [(String, Permission)] = [
            ("screenRecording", .screenRecording), ("audioCapture", .audioCapture), ("accessibility", .accessibility),
            ("pauseHelper", .pauseHelper),
        ]
        let current = settings
        loggedSettings = current.mapValues(json)
        record([
            "type": "session",
            "version": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "built": built.map { timeFormat.string(from: $0) } ?? "?",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "mac": String(cString: model),
            "permissions": Dictionary(uniqueKeysWithValues: permissions.map { ($0.0, $0.1.status == .granted) }),
            "controllers": GamepadController.shared.connected.map { ["model": $0.id, "name": $0.name, "count": $0.count] },
            "displays": NSScreen.screens.map { screen in
                ["name": screen.localizedName, "size": [screen.frame.width, screen.frame.height], "scale": screen.backingScaleFactor]
            },
            "settings": current,
        ])
        onSession?()
        Task {
            var connections: [String: Any] = ["type": "connections"]
            for (name, test) in [("anki", SettingsField.ConnectionTest.anki), ("yomitanApi", .yomitan)] {
                do {
                    connections[name] = try await ConnectionTester.run(test, settings: SettingsStore.shared.dictionary)
                } catch {
                    connections[name] = "failed: \(error.localizedDescription)"
                }
            }
            if isOn { record(connections) }
        }
    }

    /// As the page's records (toISOString).
    private static let timeFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    /// Waits for the records so far to be written (before quitting).
    static func flush() {
        queue.sync {}
    }

    static func append(_ json: String) {
        guard let data = (json + "\n").data(using: .utf8) else { return }
        let url = url, oldURL = oldURL
        queue.async {
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
                try? files.removeItem(at: oldURL)
                try? files.moveItem(at: url, to: oldURL)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
