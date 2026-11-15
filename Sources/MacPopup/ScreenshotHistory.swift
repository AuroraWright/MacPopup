import CoreGraphics
import Foundation

/// Screenshots of the captured window for the most recent lines (Settings → Anki Screenshot), so a card gets the
/// screenshot of the line it was scanned in rather than whatever is on screen when it's added (see anki-notes.js). Each is taken a
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
        /// The line's id (see ShownLines).
        let id: Int
        var data: Data?
        var format: Format?
        /// OCR saw the line's text settle, and the screenshot was taken then (see noteLine).
        var settled = false
        /// Counts the captures started for this line, so an earlier one that finishes late can't replace a newer one.
        var generation = 0
        var pending: Task<Void, Never>?
    }

    private let capture: (_ fullResolution: Bool) async throws -> CGImage?
    /// The lines' screenshots, oldest first.
    private var shots: [Shot] = []

    /// - Parameter capture: Takes a picture of the captured window, or returns nil if there isn't one.
    init(capture: @escaping (_ fullResolution: Bool) async throws -> CGImage?) {
        self.capture = capture
    }

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private var count: Int { (settings["screenshotHistory"] as? NSNumber)?.intValue ?? 20 }

    /// The line with `id` (see ShownLines) was shown in the text box or read by OCR: a new line (`isNew`), or the last
    /// one again (`grew`: longer than before). `settled` means OCR read it after its text stopped changing.
    func noteLine(id: Int, isNew: Bool, grew: Bool, settled: Bool) {
        let count = count
        // Only with Anki integration on: the screenshots are for its cards.
        guard count > 0, settings["ankiEnabled"] as? Bool ?? true, settings["ocrWindow"] is [String: Any] else {
            clear()
            return
        }
        let delay = settled ? 0 : ((settings["screenshotDelay"] as? NSNumber)?.doubleValue ?? 1000) / 1000
        if !isNew {
            guard let index = shots.lastIndex(where: { $0.id == id }) else { return }
            // Its screenshot is taken again while it may still be being drawn: it grew, or OCR saw it settle for the
            // first time. Not when it's read again later (e.g. it moved, or the game goes on behind it while a card is
            // added): the game may have moved on by then.
            if grew || (settled && !shots[index].settled) {
                if settled { shots[index].settled = true }
                schedule(index, after: delay)
            }
        } else {
            // If the previous line is still waiting for its screenshot, it's taken now, before much of this line is drawn.
            if let last = shots.indices.last, shots[last].pending != nil { schedule(last, after: 0) }
            shots.append(Shot(id: id, settled: settled))
            schedule(shots.count - 1, after: delay)
            if shots.count > count {
                shots.prefix(shots.count - count).forEach { $0.pending?.cancel() }
                shots.removeFirst(shots.count - count)
            }
        }
    }

    /// The screenshot of the line with `id`, if it was taken in `format`.
    func screenshot(forLine id: Int, format: Format) -> Data? {
        guard count > 0, let shot = shots.last(where: { $0.id == id }), shot.format == format else { return nil }
        return shot.data
    }

    private func clear() {
        shots.forEach { $0.pending?.cancel() }
        shots.removeAll()
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
