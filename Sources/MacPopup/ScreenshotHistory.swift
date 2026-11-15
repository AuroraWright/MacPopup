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
        var data: Data?
        var format: Format?
        /// OCR saw the line's text settle, and the screenshot was taken then (see noteLine).
        var settled = false
        /// Counts the captures started for this line, so an earlier one that finishes late can't replace a newer one.
        var generation = 0
        var pending: Task<Void, Never>?
    }

    private let capture: (_ fullResolution: Bool) async throws -> CGImage?
    /// The lines, each with its screenshot.
    private var shots = ShownLines<Shot>()

    /// - Parameter capture: Takes a picture of the captured window, or returns nil if there isn't one.
    init(capture: @escaping (_ fullResolution: Bool) async throws -> CGImage?) {
        self.capture = capture
    }

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private var count: Int { (settings["screenshotHistory"] as? NSNumber)?.intValue ?? 20 }

    /// A line was shown in the text box or read by OCR. `settled` means OCR saw its text stop changing (it's then a
    /// page, with `breaks`: see ShownLines.note).
    func noteLine(_ text: String, settled: Bool, breaks: Set<Int>) {
        let count = count
        // Only with Anki integration on: the screenshots are for its cards.
        guard count > 0, settings["ankiEnabled"] as? Bool ?? true, settings["ocrWindow"] is [String: Any] else {
            clear()
            return
        }
        let delay = settled ? 0 : ((settings["screenshotDelay"] as? NSNumber)?.doubleValue ?? 1000) / 1000
        switch shots.note(text, page: settled, breaks: breaks, info: { Shot(settled: settled) }) {
        case nil:
            break
        case .again(let index, let grew):
            // Its screenshot is taken again while it may still be being drawn: it grew, or OCR saw it settle for the
            // first time. Not when it's read again later (e.g. it moved, or the game goes on behind it while a card is
            // added): the game may have moved on by then.
            if grew || (settled && !shots[index].info.settled) {
                if settled { shots[index].info.settled = true }
                schedule(index, after: delay)
            }
        case .new(let index):
            // If the previous line is still waiting for its screenshot, it's taken now, before much of this line is drawn.
            if index > 0, shots[index - 1].info.pending != nil { schedule(index - 1, after: 0) }
            schedule(index, after: delay)
            if shots.count > count {
                shots.prefix(shots.count - count).forEach { $0.info.pending?.cancel() }
                shots.removeFirst(shots.count - count)
            }
        }
    }

    /// The screenshot of the newest line that a card's sentence comes from, if it was taken in `format`.
    func screenshot(for sentence: String, format: Format) -> Data? {
        guard count > 0 else { return nil }
        guard let index = shots.lastIndex(of: sentence), shots[index].info.format == format else { return nil }
        return shots[index].info.data
    }

    private func clear() {
        shots.forEach { $0.info.pending?.cancel() }
        shots.removeAll()
    }

    private func schedule(_ index: Int, after delay: Double) {
        shots[index].info.pending?.cancel()
        shots[index].info.generation += 1
        let id = shots[index].id, generation = shots[index].info.generation
        let settings = settings
        let format = Format(
            format: settings["screenshotFormat"] as? String == "png" ? "png" : "jpeg",
            quality: (settings["screenshotQuality"] as? NSNumber)?.doubleValue ?? 92,
            fullResolution: settings["screenshotResolution"] as? String == "full"
        )
        shots[index].info.pending = Task { [weak self, capture] in
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
            guard let self, let index = shots.firstIndex(where: { $0.id == id }), shots[index].info.generation == generation else { return }
            shots[index].info.data = data
            shots[index].info.format = format
        }
    }

    /// Marks a line's capture as no longer waiting, since it's being taken now.
    private func finished(_ id: Int, _ generation: Int) {
        guard let index = shots.firstIndex(where: { $0.id == id }), shots[index].info.generation == generation else { return }
        shots[index].info.pending = nil
    }
}
