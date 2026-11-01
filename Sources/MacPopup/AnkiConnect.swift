import Foundation

/// AnkiConnect and the Yomitan API, called from native code with the addresses in the settings (the
/// web side has its own clients, web/src/lib/anki-connect.js and yomitan-api.js).
enum AnkiConnect {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func invoke(_ action: String, _ params: [String: Any] = [:], settings: [String: Any]) async throws -> Any? {
        var body: [String: Any] = ["action": action, "version": 6, "params": params]
        if let key = settings["ankiConnectKey"] as? String, !key.isEmpty { body["key"] = key }
        let response: Any
        do {
            response = try await post(settings["ankiConnectUrl"] as? String ?? "http://127.0.0.1:8765", body: body, timeout: 30)
        } catch {
            throw Failure("Anki not connected")
        }
        guard let response = response as? [String: Any] else { throw Failure("Unexpected AnkiConnect response") }
        if let error = response["error"] as? String { throw Failure("Anki: \(error)") }
        return response["result"]
    }

    /// The field names of the note types of the Yomitan term card formats (not the kanji ones), from
    /// AnkiConnect, in the order of the card formats and of the fields.
    static func fieldNames(settings: [String: Any]) async throws -> [String] {
        var models: [String] = []
        for format in try await yomitanCardFormats(settings: settings) where format["type"] as? String == "term" {
            if let model = format["model"] as? String, !models.contains(model) { models.append(model) }
        }
        var fields: [String] = []
        for model in models {
            let names = try await invoke("modelFieldNames", ["modelName": model], settings: settings) as? [String] ?? []
            fields += names.filter { !fields.contains($0) }
        }
        return fields
    }

    /// The card formats of the Yomitan profile: [{name, type, deck, model, fields: {name: {value}}}].
    static func yomitanCardFormats(settings: [String: Any]) async throws -> [[String: Any]] {
        var base = settings["yomitanApiUrl"] as? String ?? "http://127.0.0.1:19633"
        while base.hasSuffix("/") { base.removeLast() }
        do {
            return try await post("\(base)/ankiCardFormats", body: [:], timeout: 10) as? [[String: Any]] ?? []
        } catch {
            throw Failure("Yomitan API not connected")
        }
    }

    /// For each note type of the term card formats, its field filled with the sentence: `{sentence}`,
    /// or else the sentence with furigana, or a cloze.
    static func sentenceFields(settings: [String: Any]) async throws -> [String: String] {
        let markers = ["{sentence}", "{sentence-furigana}", "{sentence-furigana-plain}", "{cloze-prefix}"]
        var result: [String: String] = [:]
        var rank: [String: Int] = [:]
        for format in try await yomitanCardFormats(settings: settings) where format["type"] as? String == "term" {
            guard let model = format["model"] as? String, let fields = format["fields"] as? [String: Any] else { continue }
            for name in fields.keys.sorted() {
                let field = fields[name]
                let value = (field as? [String: Any])?["value"] as? String ?? field as? String ?? ""
                guard let index = markers.firstIndex(where: { value.contains($0) }), index < rank[model] ?? markers.count else { continue }
                result[model] = name
                rank[model] = index
            }
        }
        return result
    }

    private static func post(_ urlString: String, body: [String: Any], timeout: TimeInterval) async throws -> Any {
        guard let url = URL(string: urlString), url.scheme != nil else { throw Failure("Invalid URL") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data)
    }
}
