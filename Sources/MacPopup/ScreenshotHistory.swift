import CoreGraphics
import Foundation

/// Screenshots of the captured window for the most recent lines (Settings → Anki Screenshot), so a card gets the
/// screenshot of its own line rather than whatever is on screen when it's added (see anki-notes.js). Each is taken a
/// moment after the line appears, once the game has drawn it, or right away when OCR saw the text settle or the next
/// line arrives. They're encoded as they're taken, just as a card's screenshot would be.
@MainActor
final class ScreenshotHistory {
    /// How screenshots are encoded (Settings → Anki Screenshot).
    struct Format: Equatable {
        let format: String
        let quality: Double
        let fullResolution: Bool
    }

    private struct Shot {
        let id: Int
        /// Every version of the line's text seen, without whitespace (see SentenceAudioController.ShownLine).
        var texts: [String]
        var data: Data?
        var format: Format?
        /// Counts the captures started for this line, so an earlier one that finishes late can't replace a newer one.
        var generation = 0
        var pending: Task<Void, Never>?
    }

    private let capture: (_ fullResolution: Bool) async throws -> CGImage?
    private var shots: [Shot] = []
    private var nextID = 0

    /// - Parameter capture: Takes a picture of the captured window, or returns nil if there isn't one.
    init(capture: @escaping (_ fullResolution: Bool) async throws -> CGImage?) {
        self.capture = capture
    }

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private var count: Int { (settings["screenshotHistory"] as? NSNumber)?.intValue ?? 20 }

    /// A line was shown in the text box or read by OCR. `settled` means its text had stopped changing.
    func noteLine(_ text: String, settled: Bool) {
        let count = count
        // Only with Anki integration on: the screenshots are for its cards.
        guard count > 0, settings["ankiEnabled"] as? Bool ?? true, settings["ocrWindow"] is [String: Any] else {
            clear()
            return
        }
        let text = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !text.isEmpty else { return }
        let delay = settled ? 0 : ((settings["screenshotDelay"] as? NSNumber)?.doubleValue ?? 1000) / 1000
        // The same line again (read by OCR after the WebSocket, or growing as it's drawn): its screenshot is taken
        // again.
        if let last = shots.indices.last, shots[last].texts.contains(where: { text.hasPrefix($0) || $0.hasPrefix(text) }) {
            if !shots[last].texts.contains(text) { shots[last].texts.append(text) }
            schedule(last, after: delay)
            return
        }
        // If the previous line is still waiting for its screenshot, it's taken now, before much of this line is drawn.
        if let last = shots.indices.last, shots[last].pending != nil { schedule(last, after: 0) }
        shots.append(Shot(id: nextID, texts: [text]))
        nextID += 1
        if shots.count > count {
            shots.prefix(shots.count - count).forEach { $0.pending?.cancel() }
            shots.removeFirst(shots.count - count)
        }
        schedule(shots.count - 1, after: delay)
    }

    /// The screenshot of the newest line that a card's sentence comes from, if it was taken in `format`.
    func screenshot(for sentence: String, format: Format) -> Data? {
        guard count > 0 else { return nil }
        let sentence = sentence.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let shot = shots.last(where: { $0.texts.contains { SentenceAudioController.isSameLine(sentence, $0) } }),
              shot.format == format else { return nil }
        return shot.data
    }

    private func clear() {
        shots.forEach { $0.pending?.cancel() }
        shots = []
    }

    private func schedule(_ index: Int, after delay: Double) {
        shots[index].pending?.cancel()
        shots[index].generation += 1
        let id = shots[index].id, generation = shots[index].generation
        let settings = settings
        let format = Format(
            format: settings["screenshotFormat"] as? String == "png" ? "png" : "jpeg",
            quality: (settings["screenshotQuality"] as? NSNumber)?.doubleValue ?? 92,
            fullResolution: settings["screenshotResolution"] as? String == "full"
        )
        shots[index].pending = Task { [weak self, capture] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.finished(id, generation)
            let data: Data?
            do {
                guard let image = try await capture(format.fullResolution) else { return }
                data = try await Task.detached { try ScreenCapture.encode(image, format: format.format, quality: format.quality) }.value
            } catch {
                return
            }
            guard let self, let index = shots.firstIndex(where: { $0.id == id }), shots[index].generation == generation else { return }
            shots[index].data = data
            shots[index].format = format
        }
    }

    /// Marks a line's capture as no longer waiting, since it's being taken now.
    private func finished(_ id: Int, _ generation: Int) {
        guard let index = shots.firstIndex(where: { $0.id == id }), shots[index].generation == generation else { return }
        shots[index].pending = nil
    }
}
