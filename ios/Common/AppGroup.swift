import Foundation

/// The App Group the app and its extensions share.
enum AppGroup {
    static let identifier = "group.com.aury.macpopup.ios"

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// A log the app and its extensions all write (the App Group's intents.log), to see which process runs an action and
/// how it ends. Continuous mode writes continuous.log.
enum IntentLog {
    static func append(_ message: String, to name: String = "intents.log") {
        guard let url = AppGroup.folder?.appendingPathComponent(name) else { return }
        let line = "\(Date().formatted(.iso8601)) \(Bundle.main.bundleIdentifier ?? "?"): \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Pictures shared to the app (Share/), waiting in the App Group until the app reads them.
enum Inbox {
    /// Opens the app to read them.
    static let readURL = URL(string: "macpopup://read-shared")!

    private static var folder: URL? {
        AppGroup.folder?.appendingPathComponent("shared", isDirectory: true)
    }

    static func put(_ data: Data) throws {
        guard let folder else { throw AppError("MacPopup’s App Group isn’t available.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).picture"), options: .atomic)
    }

    /// The waiting pictures, oldest first, removed from the inbox.
    static func take() -> [Data] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "picture" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            return try? Data(contentsOf: file)
        }
    }
}
