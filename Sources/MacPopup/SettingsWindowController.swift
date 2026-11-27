import AppKit
import OCREngines
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model = SettingsModel()
    private let recorder = ScanInputRecorder()
    private let selectOCRWindow: () -> Void
    private let clearVideoTranscripts: () throws -> Void
    private var window: NSWindow?

    init(selectOCRWindow: @escaping () -> Void, clearVideoTranscripts: @escaping () throws -> Void) {
        self.selectOCRWindow = selectOCRWindow
        self.clearVideoTranscripts = clearVideoTranscripts
        super.init()
    }

    /// Lets the scan input recorder see buttons pressed outside the window, such as side buttons.
    func mouseButtonEvent(button: Int, isDown: Bool) {
        recorder.mouseButton(button, isDown: isDown)
    }

    /// Opens the window, on a section (its title) when given.
    func show(above level: NSWindow.Level, section: String? = nil) {
        if let section {
            // The sidebar's selection (see SettingsSidebar), which follows it while the window is open too.
            SettingsStore.shared.defaults.set(section, forKey: "settingsSection")
        }
        if window == nil {
            let actions = SettingsActions(
                selectOCRWindow: { [weak self] in self?.selectOCRWindow() },
                importYomitan: { [weak self] in self?.importYomitan() },
                importTexthooker: { [weak self] in self?.importTexthooker() },
                importBackup: { [weak self] in self?.importBackup() },
                importLines: { [weak self] in self?.importLines() },
                exportBackup: { [weak self] in self?.exportBackup() },
                exportLines: { [weak self] in self?.exportLines() },
                resetAll: { [weak self] in self?.resetAll() },
                loadModels: { [weak self] in self?.loadModels($0) },
                removeModels: { [weak self] in self?.removeModels($0) },
                clearTranscripts: { [weak self] in self?.clearTranscripts() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                // Full size: the sidebar goes up under the title bar.
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            // Not shown: the sections' own titles name them (still the window's name in Mission Control and the Window menu).
            window.title = "MacPopup Settings"
            window.titleVisibility = .hidden
            // Nor a bar behind it when the form scrolls under it.
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            // A split view with macOS's own sidebar: the full height of the window, under its title bar, and on macOS 26
            // a pane of Liquid Glass. Neither resizable nor collapsible, as the sections' layout is made for the width
            // left, and the window is resizable in height only, from its default height up: the hosting controllers make
            // the views' size limits the window's (replacing contentMinSize and contentMaxSize).
            let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SettingsSidebar(actions: actions)
                .defaultAppStorage(SettingsStore.shared.defaults)))
            sidebar.minimumThickness = 190
            sidebar.maximumThickness = 190
            sidebar.canCollapse = false
            let detail = NSSplitViewItem(viewController: NSHostingController(rootView: SettingsDetail(model: model, recorder: recorder, actions: actions)
                .defaultAppStorage(SettingsStore.shared.defaults)
                .frame(width: 629)
                // Not shorter than it opens: the form's height there is the window's below its title bar.
                .frame(minHeight: window.contentLayoutRect.height, maxHeight: .infinity)
                // Up to the window's top: the title bar shows nothing over the form.
                .ignoresSafeArea(edges: .top)))
            let split = NSSplitViewController()
            split.splitViewItems = [sidebar, detail]
            window.contentViewController = split
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
        FontPanelTarget.shared.close()
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

    /// What Export saves and Import → MacPopup Settings reads: the stored settings, as the web pages save them, with what
    /// made them.
    private static let backupFormat = "macpopup-settings"

    private func importBackup() {
        guard let json = chooseFile(message: "Choose a MacPopup settings file to import.") else { return }
        guard let data = json.data(using: .utf8),
              let backup = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              backup["format"] as? String == Self.backupFormat,
              let settings = backup["settings"] as? [String: Any] else {
            inform("Import failed", detail: "This is not a valid MacPopup settings file", style: .warning)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Replace all settings?"
        alert.informativeText = "Settings not in the file are reset to their defaults."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        window?.makeFirstResponder(nil)
        SettingsStore.shared.update(json: SettingsSupport.encode(settings))
        inform("Imported \(settings.count) settings.")
    }

    private func exportBackup() {
        // Saves a field that's still being edited.
        window?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.message = "Select a folder to export"
        panel.allowedContentTypes = [.json]
        let date = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        panel.nameFieldStringValue = "macpopup-settings-\(date).json"
        guard runModal(panel) == .OK, let url = panel.url else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let backup: [String: Any] = [
            "format": Self.backupFormat,
            "version": info["CFBundleShortVersionString"] as? String ?? "?",
            "settings": SettingsStore.shared.dictionary,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            inform("Export failed", detail: error.localizedDescription, style: .warning)
        }
    }

    private func importLines() {
        guard let json = chooseFile(message: "Choose a Floating Window lines file to import.") else { return }
        let lines: [SavedLines.Line]
        do {
            lines = try SavedLines.lines(in: Data(json.utf8))
        } catch {
            inform("Import failed", detail: error.localizedDescription, style: .warning)
            return
        }
        if !SavedLines.shared.lines.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the Floating Window’s lines?"
            alert.informativeText = "The lines in the text box are replaced with the ones in the file."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard runModal(alert) == .alertFirstButtonReturn else { return }
        }
        SavedLines.shared.replace(with: lines)
        // The text box keeps only the newest of them past Maximum lines kept.
        let most = (SettingsStore.shared.dictionary["maxLines"] as? NSNumber)?.intValue ?? 0
        let kept = most > 0 ? min(lines.count, most) : lines.count
        inform("Imported \(kept) \(kept == 1 ? "line" : "lines").",
               detail: kept < lines.count ? "The file has \(lines.count): the oldest are left out, as Maximum lines kept is \(most)." : "")
    }

    private func exportLines() {
        guard !SavedLines.shared.lines.isEmpty else {
            inform("There are no lines to export", detail: "The Floating Window’s text box is empty.")
            return
        }
        let panel = NSSavePanel()
        panel.message = "Select a folder to export"
        panel.allowedContentTypes = [.json]
        let date = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        panel.nameFieldStringValue = "macpopup-lines-\(date).json"
        guard runModal(panel) == .OK, let url = panel.url else { return }
        do {
            try SavedLines.shared.export(to: url)
        } catch {
            inform("Export failed", detail: error.localizedDescription, style: .warning)
        }
    }

    private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to their defaults?"
        alert.informativeText = "The Floating Window’s lines are cleared too. This operation cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if runModal(alert) == .alertFirstButtonReturn {
            window?.makeFirstResponder(nil)
            model.reset()
            SavedLines.shared.clear()
        }
    }

    private func loadModels(_ kind: ConvertedModelsKind) {
        let panel = NSOpenPanel()
        panel.message = "Choose the .zip file made by \(kind.script)."
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        guard runModal(panel) == .OK, let url = panel.url else { return }
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
        alert.informativeText = "\(kind.name) won’t work until its models are loaded again."
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

    private func clearTranscripts() {
        let alert = NSAlert()
        alert.messageText = "Clear saved transcriptions?"
        alert.informativeText = "Previously transcribed videos will need to be transcribed again."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        do {
            try clearVideoTranscripts()
        } catch {
            inform("Couldn’t clear the transcriptions", detail: error.localizedDescription, style: .warning)
        }
    }

    private func chooseFile(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard runModal(panel) == .OK, let url = panel.url else { return nil }
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

    /// As a sheet on the Settings window, which floats above the overlay: runModal puts alerts and file panels at
    /// the modal panel level, under it.
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return alert.runModal() }
        alert.beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: alert.window)
    }

    private func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return panel.runModal() }
        panel.beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: panel)
    }
}
