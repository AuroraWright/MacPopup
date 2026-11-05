import Foundation

/// Installs the Yomitan API's native messaging host for a browser as install_yomitan_api.py (github.com/yomidevs/
/// yomitan-api) does on macOS, with MacPopup's Swift host (Contents/Helpers/yomitan_api) in place of yomitan_api.py.
/// It's copied where the script copies yomitan_api.py, next to the browser's manifest (browsers can't run files
/// from protected folders such as Documents), so either installer can replace the other's.
enum YomitanAPIInstaller {
    struct Browser: Identifiable, Hashable {
        let id: String
        let name: String
        /// The folder in Application Support with the browser's NativeMessagingHosts folder.
        let folder: String
        /// The manifest's list of the extensions that may start the host.
        let idKey: String
        let defaultID: String
        let idFormat: String
        let idPattern: String
    }

    static let name = "yomitan_api"

    private static let chromeID = "chrome-extension://likgccmbimhjbgkjambclfkhldnlhbnn/"
    private static let chromeFormat = "chrome-extension://xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/"
    private static let chromePattern = #"chrome-extension:\/\/[a-p]{32}\/"#

    static let browsers = [
        Browser(
            id: "chrome", name: "Chrome", folder: "Google/Chrome", idKey: "allowed_origins", defaultID: chromeID,
            idFormat: chromeFormat, idPattern: chromePattern
        ),
        Browser(
            id: "chromium", name: "Chromium", folder: "Chromium", idKey: "allowed_origins", defaultID: chromeID,
            idFormat: chromeFormat, idPattern: chromePattern
        ),
        Browser(
            id: "brave", name: "Brave", folder: "BraveSoftware/Brave-Browser", idKey: "allowed_origins", defaultID: chromeID,
            idFormat: chromeFormat, idPattern: chromePattern
        ),
        Browser(
            id: "firefox", name: "Firefox", folder: "Mozilla", idKey: "allowed_extensions",
            defaultID: "{6b733b82-9261-47ee-a595-2dda294a4d08}",
            idFormat: "{xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} or testextension@example.com",
            idPattern: #"(?:\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}|[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+)"#
        ),
    ]

    /// MACPOPUP_BROWSER_SUPPORT_DIR: a folder used in place of ~/Library/Application Support for the browsers'
    /// folders (for test runs).
    private static var applicationSupport: URL {
        if let path = ProcessInfo.processInfo.environment["MACPOPUP_BROWSER_SUPPORT_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func hostsFolder(_ browser: Browser) -> URL {
        applicationSupport.appendingPathComponent(browser.folder).appendingPathComponent("NativeMessagingHosts")
    }

    /// The first browser that's installed (has its folder), or Chrome.
    static var likelyBrowser: Browser {
        browsers.first { FileManager.default.fileExists(atPath: applicationSupport.appendingPathComponent($0.folder).path) } ?? browsers[0]
    }

    /// The extension IDs the browser's current manifest allows besides the default one.
    static func otherIDs(_ browser: Browser) -> [String] {
        let url = hostsFolder(browser).appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = manifest[browser.idKey] as? [String]
        else { return [] }
        return ids.filter { $0 != browser.defaultID }
    }

    static func isValid(_ id: String, for browser: Browser) -> Bool {
        id.wholeMatch(of: try! Regex(browser.idPattern)) != nil
    }

    /// Copies the host and writes the manifest, which allows the default extension ID and `otherIDs`.
    static func install(_ browser: Browser, otherIDs: [String]) throws {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SettingsSupportError(message: "The Yomitan API host is missing from MacPopup.app")
        }
        let folder = hostsFolder(browser)
        let host = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Removed rather than overwritten: a running host keeps its file.
        if FileManager.default.fileExists(atPath: host.path) { try FileManager.default.removeItem(at: host) }
        try FileManager.default.copyItem(at: source, to: host)
        // (A downloaded app's quarantine would keep the browser from starting it.)
        removexattr(host.path, "com.apple.quarantine", 0)

        var ids = [browser.defaultID]
        for id in otherIDs where !ids.contains(id) { ids.append(id) }
        let manifest: [String: Any] = [
            "name": name, "description": "Yomitan API", "type": "stdio", "path": host.path, browser.idKey: ids,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
