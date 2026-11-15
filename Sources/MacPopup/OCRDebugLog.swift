import Foundation

/// With "Debug" (Settings → OCR) on, the page writes each OCR reading and WebSocket line here, one JSON object per
/// line (see logOcrDebug in web/src/overlay.js), what happens around them (controller focus, the pause and scan
/// shortcut), and OCRController and GamePause what they do (what triggers readings, how long they take, the window, the
/// game being paused), after a session record with the settings: Application Support/MacPopup/ocr-debug.jsonl, or the
/// folder in MACPOPUP_DEBUG_OCR_DIR. Over 20 MB, it's moved to ocr-debug.old.jsonl and a new one is started. Both are
/// deleted when the setting is turned off (and at launch while it's off), so they don't build up over time.
enum OCRDebugLog {
    private static let queue = DispatchQueue(label: "OCRDebugLog")
    private static let maxSize = 20_000_000

    static var url: URL {
        let folder = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_OCR_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPopup")
        return folder.appendingPathComponent("ocr-debug.jsonl")
    }

    /// Whether the log is written (Settings → OCR → Debug).
    @MainActor static var isOn: Bool { SettingsStore.shared.dictionary["ocrShowBoxes"] as? Bool == true }

    private static var oldURL: URL { url.deletingLastPathComponent().appendingPathComponent("ocr-debug.old.jsonl") }

    @MainActor private static var wasOn = false

    /// Called at launch.
    @MainActor static func start() {
        wasOn = isOn
        if !wasOn { delete() }
        SettingsStore.shared.observe { _ in
            let on = isOn
            if wasOn, !on { delete() }
            wasOn = on
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

    /// A message from OCRController or GamePause, with the system uptime (as in the test tools' logs); also to stderr
    /// with MACPOPUP_DEBUG_OCR set.
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
        let record = fields.merging(["time": timeFormat.string(from: Date())]) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        append(json)
    }

    /// The settings that change how OCR Mode reads and shows text, pauses the game, and what the controller does.
    @MainActor static var ocrSettings: [String: Any] {
        SettingsStore.shared.dictionary.filter { key, _ in
            key.hasPrefix("ocr") || key.hasPrefix("gamePause") || key.hasPrefix("gamepad") || ["language", "websocketUrls", "floatingWindowOCR"].contains(key)
        }
    }

    /// What a log from someone else needs to be read: MacPopup's version, the Mac's, and the settings.
    @MainActor static func session(window: [String: Any]?) {
        guard isOn else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        var fields: [String: Any] = [
            "type": "session",
            "version": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "built": built.map { timeFormat.string(from: $0) } ?? "?",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "mac": String(cString: model),
            "settings": ocrSettings,
        ]
        if let window { fields["window"] = window }
        record(fields)
    }

    /// As the page's records (toISOString).
    private static let timeFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    static func append(_ json: String) {
        guard let data = (json + "\n").data(using: .utf8) else { return }
        let url = url
        queue.async {
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
                let old = oldURL
                try? files.removeItem(at: old)
                try? files.moveItem(at: url, to: old)
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
