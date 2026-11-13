import AppKit
import Combine

/// The settings as the Settings window shows and edits them: the stored ones over the defaults.
/// Saved the same way as by the web pages, so every window sees the change.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var values: [String: Any] = [:]

    private let defaults = SettingsSupport.shared.defaults

    init() {
        reload()
        SettingsStore.shared.observe { [weak self] _ in self?.reload() }
    }

    private func reload() {
        values = defaults.merging(SettingsStore.shared.dictionary) { _, stored in stored }
    }

    subscript(key: String) -> Any? {
        values[key].flatMap { $0 is NSNull ? nil : $0 }
    }

    func set(_ key: String, _ value: Any?) {
        var changes: [String: Any] = [key: value ?? NSNull()]
        // Switching to custom scan inputs starts from the simple mode that was selected.
        let customInputsKey = ["scanModifier": "scanInputs", "popupScanModifier": "popupScanInputs"][key]
        if let customInputsKey, value as? String == "custom", (self[customInputsKey] as? [Any] ?? []).isEmpty {
            let previous = self[key] as? String ?? "none"
            changes[customInputsKey] = [previous == "none" ? "" : previous]
        }
        merge(changes)
    }

    /// Saves several settings at once, e.g. imported ones.
    func merge(_ changes: [String: Any]) {
        save(values.merging(changes) { _, new in new })
    }

    func reset() {
        SettingsStore.shared.update(json: "{}")
    }

    private func save(_ settings: [String: Any]) {
        SettingsStore.shared.update(json: SettingsSupport.encode(settings))
    }
}

/// Scan inputs as in web/src/lib/scan-inputs.js: modifier keys and mouse buttons by name, e.g. "ctrl mouse1".
enum ScanInput {
    static let modifierNames = ["meta", "ctrl", "alt", "shift"]

    /// What an input looks up when it has one of these (Yomitan's per-input "Search terms" and "Search kanji").
    static let lookupNames = ["terms", "kanji"]

    /// A modifier key or mouse button, one with a leading "-" that must not be held (Yomitan's "exclude"),
    /// or a lookup name.
    static func isValidName(_ name: String) -> Bool {
        if lookupNames.contains(name) { return true }
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return modifierNames.contains(base) || (base.count == 6 && base.hasPrefix("mouse") && ("0"..."5").contains(base.suffix(1)))
    }

    static func parse(_ input: String) -> [String] {
        input.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    /// Canonical text, ordered like Yomitan: modifier keys, then mouse buttons, then the excluded ones, then
    /// the lookup names.
    static func format(_ names: some Collection<String>) -> String {
        let rank = { (name: String) -> Int in
            if let index = lookupNames.firstIndex(of: name) { return 200 + index }
            let excluded = name.hasPrefix("-")
            let base = excluded ? String(name.dropFirst()) : name
            return (excluded ? 100 : 0) + (base.hasPrefix("mouse") ? 10 + (Int(base.dropFirst(5)) ?? 0) : modifierNames.firstIndex(of: base) ?? 0)
        }
        return Set(names).sorted { rank($0) < rank($1) }.joined(separator: " ")
    }
}

/// Records the modifier keys and mouse buttons pressed until the first one is released, for a scan input.
@MainActor
final class ScanInputRecorder: ObservableObject {
    /// The control that's recording, and what's been pressed so far.
    @Published private(set) var activeID: String?
    @Published private(set) var recorded: [String] = []

    private var monitor: Any?
    private var completion: ((String?) -> Void)?

    func start(id: String, completion: @escaping (String?) -> Void) {
        cancel()
        activeID = id
        recorded = []
        self.completion = completion
        // Starts after the click on the record button, which has already happened.
        let events: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func cancel() {
        finish(nil)
    }

    /// Buttons as seen by the whole app, which include ones pressed outside the Settings window.
    func mouseButton(_ number: Int, isDown: Bool) {
        guard activeID != nil, number <= 5 else { return }
        isDown ? add("mouse\(number)") : release()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53, recorded.isEmpty { finish(nil) }
        case .flagsChanged:
            let flags: [(NSEvent.ModifierFlags, String)] = [(.command, "meta"), (.control, "ctrl"), (.option, "alt"), (.shift, "shift")]
            let held = flags.filter { event.modifierFlags.contains($0.0) }.map(\.1)
            if held.contains(where: { !recorded.contains($0) }) {
                held.forEach(add)
            } else {
                release()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.buttonNumber <= 5 { add("mouse\(event.buttonNumber)") }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            release()
        default:
            break
        }
    }

    private func add(_ name: String) {
        if !recorded.contains(name) { recorded.append(name) }
    }

    private func release() {
        if !recorded.isEmpty { finish(ScanInput.format(recorded)) }
    }

    private func finish(_ value: String?) {
        guard activeID != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        activeID = nil
        recorded = []
        let completion = completion
        self.completion = nil
        completion?(value)
    }
}
