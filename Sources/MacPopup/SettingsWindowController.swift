import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model = SettingsModel()
    private let recorder = ScanInputRecorder()
    private let selectOCRWindow: () -> Void
    private var window: NSWindow?

    init(selectOCRWindow: @escaping () -> Void) {
        self.selectOCRWindow = selectOCRWindow
        super.init()
    }

    /// Lets the scan input recorder see buttons pressed outside the window, such as side buttons.
    func mouseButtonEvent(button: Int, isDown: Bool) {
        recorder.mouseButton(button, isDown: isDown)
    }

    func show(above level: NSWindow.Level) {
        if window == nil {
            let actions = SettingsActions(
                selectOCRWindow: { [weak self] in self?.selectOCRWindow() },
                importYomitan: { [weak self] in self?.importYomitan() },
                importTexthooker: { [weak self] in self?.importTexthooker() },
                resetAll: { [weak self] in self?.resetAll() },
                loadModels: { [weak self] in self?.loadModels($0) },
                removeModels: { [weak self] in self?.removeModels($0) }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacPopup Settings"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model, recorder: recorder, actions: actions))
            window.setContentSize(NSSize(width: 820, height: 640))
            window.center()
            self.window = window
        }
        window?.level = NSWindow.Level(rawValue: level.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
        // Saves a field that's still being edited.
        window?.makeFirstResponder(nil)
        window = nil
    }

    // MARK: Actions

    private func importYomitan() {
        guard let json = chooseFile(message: "Choose a Yomitan settings export (Yomitan Settings → Backup → Export Settings).") else { return }
        do {
            let support = SettingsSupport.shared
            let (profiles, current) = try support.yomitanProfiles(json: json)
            guard let profile = profiles.count > 1 ? chooseProfile(profiles, current: current) : 0 else { return }
            let imported = try support.convertYomitan(json: json, profile: profile, current: model.values)
            model.merge(imported)
            inform("Imported \(imported.count) settings from the Yomitan profile “\(profiles[profile])”.")
        } catch {
            inform("Import failed", detail: error.localizedDescription, style: .warning)
        }
    }

    private func importTexthooker() {
        guard let json = chooseFile(message: "Choose a texthooker-ui settings export.") else { return }
        do {
            let imported = try SettingsSupport.shared.convertTexthooker(json: json, current: model.values)
            model.merge(imported)
            inform("Imported \(imported.count) settings.")
        } catch {
            inform("Import failed", detail: error.localizedDescription, style: .warning)
        }
    }

    private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to their defaults?"
        alert.informativeText = "This includes the OCR window and areas, the scan inputs and everything imported from Yomitan."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if runModal(alert) == .alertFirstButtonReturn {
            window?.makeFirstResponder(nil)
            model.reset()
        }
    }

    private func loadModels(_ kind: ConvertedModelsKind) {
        let panel = NSOpenPanel()
        panel.message = "Choose the zip made by \(kind.script)."
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let models = ConvertedModelsStatus.shared(kind)
        models.busy = true
        Task {
            do {
                try await kind.store.installModels(from: url)
            } catch {
                inform("Couldn’t load the models", detail: error.localizedDescription, style: .warning)
            }
            models.busy = false
            models.refresh()
        }
    }

    private func removeModels(_ kind: ConvertedModelsKind) {
        let alert = NSAlert()
        alert.messageText = "Remove \(kind.name)’s models?"
        alert.informativeText = "\(kind.name) can’t read text until they’re loaded again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        let models = ConvertedModelsStatus.shared(kind)
        models.busy = true
        Task {
            do {
                try await kind.store.removeModels()
            } catch {
                inform("Couldn’t remove the models", detail: error.localizedDescription, style: .warning)
            }
            models.busy = false
            models.refresh()
        }
    }

    private func chooseFile(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            inform("Couldn’t read the file", detail: error.localizedDescription, style: .warning)
            return nil
        }
    }

    /// The chosen profile's index, or nil if cancelled.
    private func chooseProfile(_ profiles: [String], current: Int) -> Int? {
        let alert = NSAlert()
        alert.messageText = "Import Yomitan profile"
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popUp.addItems(withTitles: profiles.enumerated().map { $0.offset == current ? "\($0.element) (current)" : $0.element })
        popUp.selectItem(at: current)
        alert.accessoryView = popUp
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return runModal(alert) == .alertFirstButtonReturn ? popUp.indexOfSelectedItem : nil
    }

    private func inform(_ message: String, detail: String = "", style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = style
        _ = runModal(alert)
    }

    /// Above the Settings window, which floats above the overlay.
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.window.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        return alert.runModal()
    }
}
