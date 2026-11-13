import Foundation

/// Persists the settings JSON blob shared by the overlay's page and the Settings window.
/// The web side owns the schema (web/src/lib/settings-defaults.js); Swift only reads the few keys it needs.
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaultsKey = "settings"
    /// MACPOPUP_SETTINGS_SUITE keeps the settings in another defaults domain (for test runs).
    let defaults = ProcessInfo.processInfo.environment["MACPOPUP_SETTINGS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    private var observers: [(String) -> Void] = []

    private(set) var json: String

    private init() {
        json = defaults.string(forKey: defaultsKey) ?? "{}"
    }

    func update(json newJSON: String) {
        json = newJSON
        defaults.set(newJSON, forKey: defaultsKey)
        for observer in observers {
            observer(newJSON)
        }
    }

    /// Saves `changes` over the stored settings.
    func update(_ changes: [String: Any]) {
        let settings = dictionary.merging(changes) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: settings),
              let json = String(data: data, encoding: .utf8) else { return }
        update(json: json)
    }

    func observe(_ observer: @escaping (String) -> Void) {
        observers.append(observer)
    }

    var dictionary: [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    func string(_ key: String) -> String? {
        dictionary[key] as? String
    }

    func int(_ key: String) -> Int? {
        (dictionary[key] as? NSNumber)?.intValue
    }
}
