import Foundation
import JavaScriptCore

/// The settings logic shared with the web pages (web/src/settings-support.js): the defaults, option
/// lists and imports, run in JavaScriptCore so they exist only once.
@MainActor
final class SettingsSupport {
    static let shared = SettingsSupport()

    private let context = JSContext()!
    private var exception: String?

    let defaults: [String: Any]
    let themes: [String]
    let onlineFonts: [String]
    /// Yomitan's languages: ISO code and name.
    let languages: [(iso: String, name: String)]
    let defaultFieldTemplates: String

    private init() {
        let url = WebViewFactory.webRoot.appendingPathComponent("settings-support.js")
        if let source = try? String(contentsOf: url, encoding: .utf8) {
            context.evaluateScript(source, withSourceURL: url)
        }
        let support = context.objectForKeyedSubscript("MacPopupSettingsSupport")
        defaults = support?.invokeMethod("defaultsJSON", withArguments: [])?.toString()
            .flatMap(Self.decode) ?? [:]
        themes = support?.objectForKeyedSubscript("themes")?.toArray() as? [String] ?? []
        onlineFonts = support?.objectForKeyedSubscript("onlineFonts")?.toArray() as? [String] ?? []
        languages = (support?.objectForKeyedSubscript("languages")?.toArray() as? [[String: String]] ?? []).compactMap {
            guard let iso = $0["iso"], let name = $0["name"] else { return nil }
            return (iso, name)
        }
        defaultFieldTemplates = support?.objectForKeyedSubscript("defaultFieldTemplates")?.toString() ?? ""
        context.exceptionHandler = { [weak self] _, value in
            self?.exception = value?.objectForKeyedSubscript("message")?.toString() ?? value?.toString()
        }
    }

    /// The profile names in a Yomitan settings export, and the index of its current profile.
    func yomitanProfiles(json: String) throws -> (names: [String], current: Int) {
        let result = try decode(call("yomitanProfiles", json))
        return (result["profiles"] as? [String] ?? [], (result["profileCurrent"] as? NSNumber)?.intValue ?? 0)
    }

    func convertYomitan(json: String, profile: Int, current: [String: Any]) throws -> [String: Any] {
        try decode(call("convertYomitan", json, profile, Self.encode(current)))
    }

    /// `text` with the replacements applied, as on lines.
    func previewReplacements(_ text: String, replacements: [Any]) -> String {
        (try? call("previewReplacements", text, Self.encode(replacements))) ?? text
    }

    /// Why a replacement's pattern can't be used (as a JavaScript regular expression), or nil if it can.
    func patternError(_ pattern: String, flags: [String]) -> String? {
        let error = (try? call("patternError", pattern, flags)) ?? ""
        return error.isEmpty ? nil : error
    }

    func convertTexthooker(json: String, current: [String: Any]) throws -> [String: Any] {
        try decode(call("convertTexthooker", json, Self.encode(current)))
    }

    private func call(_ name: String, _ arguments: Any...) throws -> String {
        exception = nil
        let result = context.objectForKeyedSubscript("MacPopupSettingsSupport")?.invokeMethod(name, withArguments: arguments)
        if let exception { throw AppError(exception) }
        guard let string = result?.toString() else { throw AppError("No result") }
        return string
    }

    private func decode(_ json: String) throws -> [String: Any] {
        guard let result = Self.decode(json) else { throw AppError("Invalid result") }
        return result
    }

    nonisolated static func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
