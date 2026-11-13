import AppKit

/// Settings → Window Mode → "Read copied text from clipboard" (as in Yomitan, which opens its
/// search page instead): while it's on, text copied in any app is sent to the page as a new line.
@MainActor
final class ClipboardMonitor {
    /// Marks what MacPopup copies itself (e.g. the "copy host selection" shortcut), which isn't a new line.
    static let ownType = NSPasteboard.PasteboardType("com.aury.macpopup.copy")
    /// The general pasteboard; MACPOPUP_PASTEBOARD names another one, for testing.
    static let pasteboard = ProcessInfo.processInfo.environment["MACPOPUP_PASTEBOARD"].map { NSPasteboard(name: .init($0)) } ?? .general

    /// MacPopup's own copies, and the types password managers and other apps add to data that shouldn't be
    /// recorded (http://nspasteboard.org).
    private static let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
        ownType, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
    ]

    private let overlay: OverlayController
    private var timer: Timer?
    private var changeCount = 0

    init(overlay: OverlayController) {
        self.overlay = overlay
        SettingsStore.shared.observe { [weak self] _ in self?.applySettings() }
        applySettings()
    }

    private func applySettings() {
        let enabled = SettingsStore.shared.dictionary["clipboardMonitor"] as? Bool ?? false
        if enabled == (timer != nil) { return }
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        // Only what's copied from now on.
        changeCount = Self.pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        let pasteboard = Self.pasteboard
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard !Set(pasteboard.types ?? []).contains(where: Self.ignoredTypes.contains),
              let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return }
        overlay.evaluate("window.__macpopupClipboard?.(\(json)[0])")
    }
}
