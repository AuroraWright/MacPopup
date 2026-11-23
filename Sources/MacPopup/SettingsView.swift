import AVFoundation
import AppKit
import Combine
import OCREngines
import SwiftUI

/// What the Settings window asks of the app.
@MainActor
struct SettingsActions {
    var selectOCRWindow: () -> Void
    var importYomitan: () -> Void
    var importTexthooker: () -> Void
    var importBackup: () -> Void
    var exportBackup: () -> Void
    var resetAll: () -> Void
    var loadModels: (ConvertedModelsKind) -> Void
    var removeModels: (ConvertedModelsKind) -> Void
    var clearTranscripts: () -> Void
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var recorder: ScanInputRecorder
    let actions: SettingsActions
    @AppStorage("settingsSection") private var selection = SettingsSchema.sections[0].title

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(SettingsSchema.sections, selection: $selection) { section in
                    Label(section.title, systemImage: section.symbol).tag(section.title)
                }
                .listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    // The same width: the sidebar's, with the titles on the left, where a menu draws its own.
                    Menu("Import") {
                        Button("Yomitan Settings…", action: actions.importYomitan)
                        Button("texthooker-ui Settings…", action: actions.importTexthooker)
                        Divider()
                        Button("MacPopup Settings…", action: actions.importBackup)
                    }
                    .frame(maxWidth: .infinity)
                    .help("Import settings from Yomitan, texthooker-ui or a MacPopup settings file.")
                    Button(action: actions.exportBackup) { Text("Export…").frame(maxWidth: .infinity, alignment: .leading) }
                        .help("Save all settings to a file.")
                    Button(role: .destructive, action: actions.resetAll) {
                        Text("Reset All…").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 200)
            Divider()
            if let section = SettingsSchema.sections.first(where: { $0.title == selection }) ?? SettingsSchema.sections.first {
                SectionForm(section: section, model: model, recorder: recorder, actions: actions)
                    .id(section.title)
            }
        }
        .onChange(of: selection) {
            recorder.cancel()
            FontPanelTarget.shared.close()
        }
    }
}

private struct SectionForm: View {
    let section: SettingsSection
    @ObservedObject var model: SettingsModel
    @ObservedObject var recorder: ScanInputRecorder
    let actions: SettingsActions
    @ObservedObject private var yomitan = YomitanAPIStatus.shared

    var body: some View {
        Form {
            Section {
                ForEach(section.fields.filter { $0.showIf?(model.values) ?? true }) { field in
                    let fromYomitan = isFromYomitan(field)
                    FieldRow(field: field, model: model, recorder: recorder, actions: actions)
                        .disabled(fromYomitan)
                        .environment(\.settingsFieldNote, fromYomitan ? "Controlled by your Yomitan settings." : nil)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.title2.bold()).foregroundStyle(.primary)
                    if let description = section.description {
                        HeaderDescription(text: description)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .formStyle(.grouped)
    }

    /// A setting the Yomitan profile gives (see SettingsSchema.yomitanDisplayKeys).
    private func isFromYomitan(_ field: SettingsField) -> Bool {
        guard yomitan.givesProfile else { return false }
        return SettingsSchema.yomitanDictionaryKeys.contains(field.key)
            || (model.values["useYomitanDisplay"] as? Bool == true && SettingsSchema.yomitanDisplayKeys.contains(field.key))
    }
}

/// A line under a field's hint, if any.
private struct SettingsFieldNoteKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    fileprivate var settingsFieldNote: String? {
        get { self[SettingsFieldNoteKey.self] }
        set { self[SettingsFieldNoteKey.self] = newValue }
    }
}

/// A section's description. As a Text, its last line could be cut off: the form measures the header without
/// the line breaking that keeps a last line from being too short, then draws it with it, which can take a
/// line more. This label measures and draws its text the same way.
struct HeaderDescription: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabelColor
        label.lineBreakStrategy = []
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView label: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let cell = label.cell else { return nil }
        // The size is the label's alignment rectangle, and its frame (where the text goes) is wider.
        let insets = label.alignmentRectInsets
        let frameWidth = width + insets.left + insets.right
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: frameWidth, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height) - insets.top - insets.bottom)
    }
}

private struct FieldLabel: View {
    let field: SettingsField
    @Environment(\.settingsFieldNote) private var note

    var body: some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
            if let hint = field.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note).font(.caption.italic()).foregroundStyle(.secondary)
            }
        }
        if let optionClick = field.optionClick {
            label
                .contentShape(Rectangle())
                .gesture(TapGesture().modifiers(.option).onEnded { optionClick() })
        } else {
            label
        }
    }
}

private struct FieldRow: View {
    let field: SettingsField
    @ObservedObject var model: SettingsModel
    @ObservedObject var recorder: ScanInputRecorder
    let actions: SettingsActions

    private var value: Any? { model[field.key] }

    var body: some View {
        if field.isWide {
            VStack(alignment: .leading, spacing: 6) {
                // A field that's all of its section (Popup Shortcuts, Controllers) has no label of its own.
                if !field.label.isEmpty || field.hint != nil { FieldLabel(field: field) }
                wideControl
            }
        } else if let warning = field.warning?(model.values) {
            VStack(alignment: .trailing, spacing: 4) {
                control
                Text(warning).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
            }
        } else {
            control
        }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .checkbox:
            Toggle(isOn: Binding(get: { value as? Bool ?? false }, set: { model.set(field.key, $0) })) {
                FieldLabel(field: field)
            }
            .toggleStyle(.switch)
        case let .toggleChoice(off, on):
            Picker(selection: Binding(get: { value as? Bool ?? false }, set: { model.set(field.key, $0) })) {
                Text(off).tag(false)
                Text(on).tag(true)
            } label: {
                FieldLabel(field: field)
            }
            .pickerStyle(.segmented)
        case let .number(min, max, step):
            LabeledContent {
                NumberField(value: (value as? NSNumber)?.doubleValue ?? 0, min: min, max: max, decimals: step.map { $0 < 1 } ?? false) {
                    model.set(field.key, $0)
                }
            } label: {
                FieldLabel(field: field)
            }
        case let .group(fields):
            LabeledContent {
                // Each label right before its control, so it moves left as the control widens.
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(fields) { field in
                        // (A menu has its own padding before its text.)
                        HStack(spacing: field.isMenu ? 2.5 : 8) {
                            Text(field.label).foregroundStyle(.secondary)
                            GroupedControl(field: field, model: model)
                        }
                    }
                }
            } label: {
                FieldLabel(field: field)
            }
        case let .percentSlider(step):
            LabeledContent {
                PercentSlider(value: (value as? NSNumber)?.doubleValue ?? 0, step: step) { model.set(field.key, $0) }
            } label: {
                FieldLabel(field: field)
            }
        case let .numberSelect(options):
            let current = (value as? NSNumber).map { "\($0)" } ?? ""
            let shown = options.contains { $0.value == current } ? options : options + [SettingsOption(current)]
            LabeledContent {
                SteadyMenu(labels: shown.map(\.label)) {
                    Picker(field.label, selection: Binding(get: { current }, set: { new in
                        guard let number = Double(new) else { return }
                        model.set(field.key, storedNumber(number))
                    })) {
                        ForEach(shown, id: \.value) { Text($0.label).tag($0.value) }
                    }
                }
            } label: {
                FieldLabel(field: field)
            }
        case .display:
            DisplayPicker(index: (value as? NSNumber)?.intValue ?? 0) { model.set(field.key, $0) } label: {
                FieldLabel(field: field)
            }
        case .shortcut:
            LabeledContent {
                ShortcutControl(value: value as? [String: Any]) { model.set(field.key, $0 ?? NSNull()) }
            } label: {
                FieldLabel(field: field)
            }
        case .gamepadCombo:
            LabeledContent {
                GamepadComboControl(buttons: value as? [String] ?? []) { model.set(field.key, $0) }
            } label: {
                FieldLabel(field: field)
            }
        case let .shortcutAndButtons(buttonsKey):
            LabeledContent {
                VStack(alignment: .trailing, spacing: 6) {
                    ShortcutControl(value: value as? [String: Any]) { model.set(field.key, $0 ?? NSNull()) }
                    GamepadComboControl(buttons: model[buttonsKey] as? [String] ?? []) { model.set(buttonsKey, $0) }
                }
            } label: {
                FieldLabel(field: field)
            }
        case let .font(sizeKey, effectsKey):
            let keys = [field.key, sizeKey, effectsKey]
            let defaults = SettingsSupport.shared.defaults
            let name = value as? String ?? ""
            let size = (model[sizeKey] as? NSNumber)?.doubleValue ?? 16
            let effects = model[effectsKey] as? [String: Any] ?? [:]
            // The font is shown below the buttons, so it doesn't change the room for the label and its hint.
            VStack(alignment: .trailing, spacing: 6) {
                LabeledContent {
                    FontControl(
                        name: name, size: size, effects: effects,
                        isDefault: keys.allSatisfy { (model[$0] as? NSObject)?.isEqual(defaults[$0]) ?? (defaults[$0] == nil) }
                    ) { name, size, effects in
                        model.merge([field.key: name, sizeKey: storedNumber(size), effectsKey: effects])
                    } clear: {
                        model.merge(Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults[$0] ?? NSNull()) }))
                    }
                } label: {
                    FieldLabel(field: field)
                }
                FontPreview(name: name, size: size, effects: effects)
                    .fixedSize()
            }
        case .keySequence:
            KeySequenceControl(items: (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }) { model.set(field.key, $0) } label: {
                FieldLabel(field: field)
            }
        case let .permission(permission):
            PermissionRow(field: field, permission: permission)
        case let .convertedModels(kind):
            LabeledContent {
                ConvertedModelsControl(kind: kind, load: actions.loadModels, remove: actions.removeModels)
            } label: {
                FieldLabel(field: field)
            }
        case .iinaPlugin:
            LabeledContent {
                InstallIINAPluginButton()
            } label: {
                FieldLabel(field: field)
            }
        case .iinaTranscripts:
            LabeledContent {
                VideoTranscriptsControl(clear: actions.clearTranscripts)
            } label: {
                FieldLabel(field: field)
            }
        case .ankiField:
            AnkiFieldPicker(name: value as? String ?? "", settings: model.values) { model.set(field.key, $0) } label: {
                FieldLabel(field: field)
            }
        case let .select(options):
            let current = value as? String ?? ""
            // A value the menu doesn't offer (e.g. imported) is shown rather than dropped.
            let shown = options.contains { $0.value == current } ? options : options + [SettingsOption(current)]
            LabeledContent {
                SteadyMenu(labels: shown.map(\.label)) {
                    Picker(field.label, selection: Binding(get: { current }, set: { model.set(field.key, $0) })) {
                        ForEach(shown, id: \.value) { Text($0.label).tag($0.value) }
                    }
                }
            } label: {
                FieldLabel(field: field)
            }
        case let .text(test):
            LabeledContent {
                HStack {
                    CommitTextField(value: value as? String ?? "", placeholder: "None") { model.set(field.key, $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if let test { TestButton(test: test, model: model) }
                    if test == .yomitan { InstallYomitanAPIButton() }
                }
                .frame(maxWidth: 320)
            } label: {
                FieldLabel(field: field)
            }
        case let .imported(describe, emptyText, details, isList):
            let items = value as? [Any] ?? []
            LabeledContent {
                HStack {
                    Text(items.isEmpty ? emptyText : describe(items))
                        .foregroundStyle(.secondary).multilineTextAlignment(isList ? .leading : .trailing).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: isList ? .leading : .trailing)
                        .help(items.isEmpty ? "" : details?(items) ?? "")
                    Button("Clear") { model.set(field.key, [Any]()) }.disabled(items.isEmpty)
                }
                // The same width whatever's imported, so the label's hint doesn't rewrap when it changes.
                .frame(width: 280)
            } label: {
                FieldLabel(field: field)
            }
        case .ocrWindow:
            LabeledContent {
                HStack {
                    // The same width whatever the window, so the label's hint doesn't rewrap when another is selected.
                    Text(ocrWindowDescription).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(width: 200, alignment: .trailing)
                        .help(ocrWindowDescription)
                    Button("Select…", action: actions.selectOCRWindow)
                    Button("Clear") { model.merge(["ocrWindow": NSNull(), "ocrRegions": [Any]()]) }
                        .disabled(!(value is [String: Any]))
                        .help("Use the entire screen instead of a single window")
                }
            } label: {
                FieldLabel(field: field)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var wideControl: some View {
        switch field.kind {
        case .textarea:
            CodeEditor(text: value as? String ?? "", height: 120) { model.set(field.key, $0) }
        case .lines(let max):
            LinesEditor(lines: value as? [String] ?? [], limit: max) { model.set(field.key, $0) }
        case .replacements:
            ReplacementsControl(key: field.key, model: model)
        case .audioSources:
            AudioSourcesControl(key: field.key, model: model)
        case .scanInputs:
            ScanInputsControl(key: field.key, values: value as? [String] ?? [], model: model, recorder: recorder)
        case .hotkeys:
            HotkeysControl(key: field.key, model: model)
        case .terminationCharacters:
            TerminationCharactersControl(key: field.key, model: model)
        case .ankiTemplates:
            AnkiTemplatesControl(key: field.key, model: model)
        case .gamepads:
            GamepadsControl()
        default:
            EmptyView()
        }
    }

    private var ocrWindowDescription: String {
        guard let window = value as? [String: Any], let owner = window["ownerName"] as? String else { return "None (entire screen)" }
        let title = window["title"] as? String ?? ""
        let name = title.isEmpty ? owner : "\(owner) — \(title)"
        let regions = (model["ocrRegions"] as? [Any] ?? []).count
        return "\(name) (\(regions == 0 ? "entire window" : "\(regions) area\(regions == 1 ? "" : "s")"))"
    }
}

// MARK: Controls

/// A text field that saves when editing ends (Return or leaving it), not on every key.
private struct CommitTextField: View {
    let value: String
    var placeholder = ""
    var monospaced = false
    /// With a border, for fields that aren't a form row's value.
    var bordered = false
    let commit: (String) -> Void
    @State private var draft = ""
    /// The value the draft started from. Only an edit is saved: a list's rows are reused by position, so by the time a
    /// field goes away, `value` and `commit` can be another item's.
    @State private var original = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, prompt: Text(placeholder))
            .labelsHidden()
            .modifier(RoundedBorder(isOn: bordered))
            .font(monospaced ? .body.monospaced() : .body)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onChange(of: value) { if !focused { reset() } }
            .onAppear(perform: reset)
            .onDisappear(perform: save)
    }

    private func reset() {
        draft = value
        original = value
    }

    private func save() {
        guard draft != original else { return reset() }
        original = draft
        commit(draft)
    }
}

/// The connected displays by name, kept up to date as they're connected and disconnected.
private struct DisplayPicker<Label: View>: View {
    let index: Int
    let commit: (Int) -> Void
    @ViewBuilder let label: Label
    @State private var displays: [String] = Self.connectedDisplays()

    private static func connectedDisplays() -> [String] {
        NSScreen.screens.enumerated().map { offset, screen in
            let size = screen.frame.size
            let name = "\(screen.localizedName) (\(Int(size.width))×\(Int(size.height)))"
            return offset == 0 ? "\(name) — Main" : name
        }
    }

    private var disconnected: String { "Display \(index + 1) (disconnected)" }

    var body: some View {
        LabeledContent {
            SteadyMenu(labels: displays + [disconnected]) {
                Picker("Display", selection: Binding(get: { index }, set: { commit($0) })) {
                    ForEach(displays.indices, id: \.self) { Text(displays[$0]).tag($0) }
                    // Kept until another is chosen: the overlay goes back to it when it's connected again.
                    if !displays.indices.contains(index) {
                        Text(disconnected).tag(index)
                    }
                }
            }
        } label: {
            label
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Self.connectedDisplays()
        }
    }
}

/// A permission's row in Settings → Permissions and the welcome window: its status and buttons on their own line, so
/// they're in the same place whatever their width.
struct PermissionRow: View {
    let field: SettingsField
    let permission: Permission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(field: field)
            HStack {
                Spacer()
                PermissionControl(permission: permission)
            }
        }
    }
}

/// Whether a permission is granted (checked again every second, as it's changed in System Settings),
/// and buttons to ask for it.
private struct PermissionControl: View {
    let permission: Permission
    @State private var status: Permission.Status?

    var body: some View {
        HStack(spacing: 8) {
            if let status {
                if status == .granted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Not granted", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Button("Request Access") {
                        Task {
                            await permission.request()
                            self.status = permission.status
                        }
                    }
                    if status == .notGranted {
                        Button("Open System Settings") { permission.openSystemSettings() }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                status = permission.status
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Whether an engine's converted models are loaded (and when they were converted), with buttons to load and remove
/// them.
private struct ConvertedModelsControl: View {
    let load: (ConvertedModelsKind) -> Void
    let remove: (ConvertedModelsKind) -> Void
    @ObservedObject private var models: ConvertedModelsStatus

    init(kind: ConvertedModelsKind, load: @escaping (ConvertedModelsKind) -> Void,
         remove: @escaping (ConvertedModelsKind) -> Void) {
        self.load = load
        self.remove = remove
        models = ConvertedModelsStatus.shared(kind)
    }

    var body: some View {
        HStack(spacing: 8) {
            // As wide as the wider status, and Remove always there, so the buttons don't move.
            ZStack(alignment: .trailing) {
                loaded.hidden()
                notLoaded.hidden()
                loading.hidden()
                if models.busy {
                    // Speech models can take up to 3 minutes the first time, while Core ML prepares them.
                    loading
                } else if let converted = models.converted {
                    loaded.help("Converted \(converted.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    notLoaded
                }
            }
            Button("Load…") { load(models.kind) }.disabled(models.busy)
            Button("Remove") { remove(models.kind) }.disabled(models.busy || models.converted == nil)
        }
    }

    private var loaded: some View {
        Label("Loaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }

    private var notLoaded: some View {
        Label("Not loaded", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
    }

    private var loading: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            Text("Working…")
        }
    }
}

/// The field names of the note types of the Yomitan term card formats, loaded from AnkiConnect when
/// shown.
private struct AnkiFieldPicker<Label: View>: View {
    let name: String
    let settings: [String: Any]
    let commit: (String) -> Void
    @ViewBuilder let label: Label
    @State private var fields: [String]?
    @State private var error: String?

    var body: some View {
        Group {
            if let fields {
                picker(fields)
            } else if error == nil {
                // While loading, the chosen field.
                picker(name.isEmpty ? [] : [name]).disabled(true)
            } else {
                LabeledContent {
                    if let error {
                        HStack(spacing: 6) {
                            Text(error).foregroundStyle(.secondary)
                            Button("Retry") { Task { await load() } }
                        }
                    }
                } label: {
                    label
                }
            }
        }
        .task { await load() }
    }

    private func picker(_ fields: [String]) -> some View {
        LabeledContent {
            SteadyMenu(labels: fields + ["Choose a field", "\(name) (not found)"]) {
                Picker("Field", selection: Binding(get: { name }, set: { commit($0) })) {
                    if name.isEmpty { Text("Choose a field").tag("") }
                    ForEach(fields, id: \.self) { Text($0).tag($0) }
                    // Kept until another is chosen.
                    if !name.isEmpty && !fields.contains(name) { Text("\(name) (not found)").tag(name) }
                }
            }
        } label: {
            label
        }
    }

    private func load() async {
        error = nil
        do {
            fields = try await AnkiConnect.fieldNames(settings: settings)
        } catch {
            self.error = "Couldn’t load Anki fields: \(error.localizedDescription)"
        }
    }
}

/// The tooltip for a shortcut's record button. It shows the whole shortcut, since the label may be truncated.
private func recordHelp(_ combination: KeyCombination?) -> String {
    combination.map { "\($0.displayName). Click to record a different key combination" } ?? "Click, then press a key combination"
}

/// Records one keyboard shortcut.
private struct ShortcutControl: View {
    let value: [String: Any]?
    let commit: ([String: Any]?) -> Void
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        HStack {
            let isActive = recorder.activeID != nil
            Button {
                if isActive {
                    recorder.cancel()
                } else {
                    recorder.start(id: 0) { commit(["key": $0.key, "modifiers": $0.modifiers]) }
                }
            } label: {
                RecordingLabel(isActive ? "Press keys…" : KeyCombination(setting: value)?.displayName ?? "Record Shortcut")
            }
            .help(isActive ? "Click to cancel" : recordHelp(KeyCombination(setting: value)))
            // While recording, it stops without changing the shortcut.
            Button("Clear") {
                if isActive {
                    recorder.cancel()
                } else {
                    commit(nil)
                }
            }
            .disabled(value == nil && !isActive)
        }
        .onDisappear { recorder.cancel() }
    }
}

/// The buttons for a font, size and effects (FontEffects): Choose… opens the Fonts panel, Clear goes back to the
/// defaults.
private struct FontControl: View {
    /// A PostScript name (or, as WebKit also takes, a family name), "" for the system font.
    let name: String
    let size: Double
    let effects: [String: Any]
    let isDefault: Bool
    let commit: (String, Double, [String: Any]) -> Void
    let clear: () -> Void
    private let panel = FontPanelTarget.shared

    var body: some View {
        HStack {
            Button("Choose…") { panel.show(name: name, size: size, effects: effects, commit: commit) }
            Button("Clear", action: clear)
                .disabled(isDefault)
        }
        .onChange(of: [name, "\(size)", SettingsSupport.encode(effects)]) { panel.update(name: name, size: size, effects: effects) }
    }
}

/// The font's name and size, in that font (at the usual size) with its effects.
private struct FontPreview: NSViewRepresentable {
    let name: String
    let size: Double
    let effects: [String: Any]

    func makeNSView(context: Context) -> NSTextField {
        NSTextField(labelWithString: "")
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let font = name.isEmpty ? nil : FontPanelTarget.font(name, size: NSFont.systemFontSize)
        var attributes = FontEffects.attributes(effects)
        attributes[NSAttributedString.Key.font.rawValue] = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = "\(name.isEmpty ? "System font" : font?.displayName ?? name), \(size.formatted()) px"
        field.attributedStringValue = NSAttributedString(
            string: text, attributes: Dictionary(uniqueKeysWithValues: attributes.map { (NSAttributedString.Key($0.key), $0.value) })
        )
        field.backgroundColor = FontEffects.color(effects["backgroundColor"])
        field.drawsBackground = field.backgroundColor != nil
    }
}

/// The Fonts panel's effects as boxFontEffects stores them (see web/src/lib/settings-defaults.js), to and from the
/// text attributes the panel uses.
private enum FontEffects {
    /// The underline and strikethrough: their names in boxFontEffects, and their attributes.
    private static let lines: [(name: String, style: NSAttributedString.Key, color: NSAttributedString.Key)] = [
        ("underline", .underlineStyle, .underlineColor), ("strikethrough", .strikethroughStyle, .strikethroughColor),
    ]

    /// The attributes, by their raw keys as NSFontManager takes them.
    static func attributes(_ effects: [String: Any]) -> [String: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes[.foregroundColor] = color(effects["color"])
        for line in lines {
            if let style = effects[line.name] as? String {
                attributes[line.style] = (style == "double" ? NSUnderlineStyle.double : .single).rawValue
            }
            attributes[line.color] = color(effects[line.name + "Color"])
        }
        if let shadow = effects["shadow"] as? [String: Any] {
            let value = { (key: String) in (shadow[key] as? NSNumber)?.doubleValue ?? 0 }
            let nsShadow = NSShadow()
            // Up in AppKit, down in CSS.
            nsShadow.shadowOffset = NSSize(width: value("x"), height: -value("y"))
            nsShadow.shadowBlurRadius = value("blur")
            nsShadow.shadowColor = color(shadow["color"])
            attributes[.shadow] = nsShadow
        }
        return Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.rawValue, $0.value) })
    }

    static func effects(_ attributes: [String: Any], backgroundColor: NSColor?) -> [String: Any] {
        let attribute = { (key: NSAttributedString.Key) in attributes[key.rawValue] }
        var effects: [String: Any] = [:]
        effects["color"] = (attribute(.foregroundColor) as? NSColor).map(css)
        for line in lines {
            // The panel keeps a line's color after the line is removed.
            guard let style = (attribute(line.style) as? NSNumber)?.intValue, style != 0 else { continue }
            effects[line.name] = style & 0xF == NSUnderlineStyle.double.rawValue ? "double" : "single"
            effects[line.name + "Color"] = (attribute(line.color) as? NSColor).map(css)
        }
        if let shadow = attribute(.shadow) as? NSShadow {
            let rounded = { (value: CGFloat) -> Any in storedNumber(Double((value * 10).rounded() / 10)) }
            effects["shadow"] = [
                "x": rounded(shadow.shadowOffset.width), "y": rounded(-shadow.shadowOffset.height),
                "blur": rounded(shadow.shadowBlurRadius), "color": css(shadow.shadowColor ?? NSColor.black.withAlphaComponent(1.0 / 3)),
            ]
        }
        effects["backgroundColor"] = backgroundColor.map(css)
        return effects
    }

    /// "#rrggbbaa", in sRGB.
    static func css(_ color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "#000000ff" }
        let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        return "#" + components.map { String(format: "%02x", min(max(Int(($0 * 255).rounded()), 0), 255)) }.joined()
    }

    /// The color of a "#rrggbbaa" or "#rrggbb" value.
    static func color(_ value: Any?) -> NSColor? {
        guard let text = value as? String, text.hasPrefix("#"), [7, 9].contains(text.count),
              let number = UInt32(text.dropFirst(), radix: 16) else { return nil }
        let rgba = text.count == 9 ? number : number << 8 | 0xFF
        let component = { (shift: UInt32) in CGFloat((rgba >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: component(24), green: component(16), blue: component(8), alpha: component(0))
    }
}

/// Receives the Fonts panel's changes for a FontControl: the typeface and size (changeFont) and the effects
/// (changeAttributes) as NSFontManager's target, and the background color (changeDocumentBackgroundColor), which
/// goes to the key window's responder chain, from right after the window.
///
/// One for the Settings window, closed with it or when another section is shown: not with the Font row, which the form
/// unloads when it's scrolled out of view. (Never freed, as the Settings window's responder chain points to it while
/// the panel is open.)
@MainActor
final class FontPanelTarget: NSResponder, NSFontChanging {
    static let shared = FontPanelTarget()

    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var attributes: [String: Any] = [:]
    private var backgroundColor: NSColor?
    private weak var window: NSWindow?
    private var commit: ((String, Double, [String: Any]) -> Void)?

    /// The font with that PostScript or family name.
    static func font(_ name: String, size: Double) -> NSFont? {
        NSFont(name: name, size: size) ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
    }

    func show(name: String, size: Double, effects: [String: Any], commit: @escaping (String, Double, [String: Any]) -> Void) {
        self.commit = commit
        NSFontManager.shared.target = self
        // The Settings window, even when it isn't key (e.g. pressed by accessibility).
        if window == nil, let window = NSApp.windows.first(where: { $0.delegate is SettingsWindowController }) {
            nextResponder = window.nextResponder
            window.nextResponder = self
            self.window = window
        }
        // Otherwise a text field being edited would take the background color.
        window?.makeFirstResponder(nil)
        NSFontManager.shared.orderFrontFontPanel(nil)
        // Settings is above the overlay (SettingsWindowController), where the panel would be behind it. (Once it's
        // shown, as showing it sets its own level.)
        if let window { NSFontPanel.shared.level = window.level }
        // Active, instead of Settings. (The background color still reaches this through Settings, the main window.)
        NSFontPanel.shared.makeKey()
        // After it's shown, as the panel doesn't take a shadow before.
        update(name: name, size: size, effects: effects)
    }

    /// Shows the settings in the panel while this is its target, e.g. after Clear.
    func update(name: String, size: Double, effects: [String: Any]) {
        font = (name.isEmpty ? nil : Self.font(name, size: size)) ?? NSFont.systemFont(ofSize: size)
        attributes = FontEffects.attributes(effects)
        backgroundColor = FontEffects.color(effects["backgroundColor"])
        guard NSFontManager.shared.target === self else { return }
        NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        NSFontManager.shared.setSelectedAttributes(attributes, isMultiple: false)
    }

    func close() {
        if let window, window.nextResponder === self { window.nextResponder = nextResponder }
        window = nil
        guard NSFontManager.shared.target === self else { return }
        NSFontManager.shared.target = nil
        NSFontPanel.shared.orderOut(nil)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        font = sender.convert(font)
        save()
    }

    @objc func changeAttributes(_ sender: Any?) {
        // Sent by the panel's effects, which convert the attributes like NSFontManager.
        attributes = (sender as AnyObject?)?.convertAttributes?(attributes) ?? attributes
        save()
    }

    @objc func changeDocumentBackgroundColor(_ sender: Any?) {
        backgroundColor = (sender as? NSColorWell)?.color ?? (sender as? NSColorPanel)?.color ?? backgroundColor
        save()
    }

    private func save() {
        // The system font's names are hidden (".SFNS-Regular"): it's stored as "".
        let name = font.fontName.hasPrefix(".") ? "" : font.fontName
        commit?(name, (font.pointSize * 10).rounded() / 10, FontEffects.effects(attributes, backgroundColor: backgroundColor))
    }
}

/// Keys pressed in turn: each can be removed, and more recorded. They're listed at the bottom right of the row, so
/// they don't take room from the label and its hint.
private struct KeySequenceControl<Label: View>: View {
    let items: [[String: Any]]
    let commit: ([[String: Any]]) -> Void
    @ViewBuilder let label: Label
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            LabeledContent {
                let isActive = recorder.activeID != nil
                let title = items.isEmpty ? "Record Key" : "Add Key"
                Button {
                    if isActive {
                        recorder.cancel()
                    } else {
                        recorder.start(id: 0) { commit(items + [["key": $0.key, "modifiers": $0.modifiers]]) }
                    }
                } label: {
                    RecordingLabel(isActive ? "Press keys…" : title)
                }
                .help(isActive ? "Click to cancel" : "Click, then press a key (with any modifier keys)")
            } label: {
                label
            }
            if !items.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 2) {
                            Text(KeyCombination(setting: item)?.displayName ?? "?").monospacedDigit()
                            Button {
                                // A recording would add its key to the list as it was before.
                                recorder.cancel()
                                var updated = items
                                updated.remove(at: index)
                                commit(updated)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
        }
        .onDisappear { recorder.cancel() }
    }
}

/// Saves as it's dragged (only when the value reaches another step), so the overlay shows the change.
private struct PercentSlider: View {
    let value: Double
    let step: Double
    let commit: (Double) -> Void

    var body: some View {
        HStack {
            Slider(
                value: Binding(get: { value }, set: { new in
                    // Rounded so the setting doesn't pick up floating point noise like 0.35000000000000003.
                    let rounded = (new / step).rounded() * step
                    let clean = (rounded * 1000).rounded() / 1000
                    if clean != value { commit(clean) }
                }),
                in: 0...1
            )
            .frame(width: 200)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                // A form draws text beside a labeled control in the secondary color.
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct RoundedBorder: ViewModifier {
    let isOn: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isOn { content.textFieldStyle(.roundedBorder) } else { content }
    }
}

private extension SettingsField {
    var isMenu: Bool {
        if case .select = kind { true } else { false }
    }
}

/// A menu or number of a group of settings (see SettingsField.Kind.group), without its label.
private struct GroupedControl: View {
    let field: SettingsField
    @ObservedObject var model: SettingsModel

    var body: some View {
        let value = model[field.key]
        switch field.kind {
        case let .number(min, max, step):
            FittingNumberField(value: (value as? NSNumber)?.doubleValue ?? 0, min: min, max: max, decimals: step.map { $0 < 1 } ?? false) {
                model.set(field.key, $0)
            }
        case let .select(options):
            let current = value as? String ?? ""
            // A value the menu doesn't offer (e.g. imported) is shown rather than dropped.
            let shown = options.contains { $0.value == current } ? options : options + [SettingsOption(current)]
            SteadyMenu(labels: shown.map(\.label)) {
                Picker(field.label, selection: Binding(get: { current }, set: { model.set(field.key, $0) })) {
                    ForEach(shown, id: \.value) { Text($0.label).tag($0.value) }
                }
            }
            .fixedSize()
        default:
            EmptyView()
        }
    }
}

/// A menu (its label hidden) as wide as the widest of `labels`. A menu is as wide as its chosen item, so choosing
/// another would change the width left for the label beside it, and rewrap the label's hint.
private struct SteadyMenu<Menu: View>: View {
    let labels: [String]
    @ViewBuilder let menu: Menu

    var body: some View {
        ZStack(alignment: .trailing) {
            // A menu with only the widest item sets the width.
            Picker("", selection: .constant(0)) { Text(widest).tag(0) }
                .labelsHidden()
                .hidden()
                .accessibilityHidden(true)
            menu.labelsHidden()
        }
    }

    private var widest: String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        return labels.max { ($0 as NSString).size(withAttributes: attributes).width < ($1 as NSString).size(withAttributes: attributes).width } ?? ""
    }
}

/// A number as it's saved: an integer when it's a whole one.
private func storedNumber(_ number: Double) -> Any {
    number.rounded() == number && abs(number) < 1e15 ? Int(number) as Any : number as Any
}

/// A number field as wide as the number in it (growing to the left while typing), saving when editing ends.
private struct FittingNumberField: View {
    let value: Double
    let min: Double?
    let max: Double?
    let decimals: Bool
    let commit: (Any) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var formatted: String { Self.text(value) }

    /// Plain digits (a locale's minus sign or decimal comma wouldn't parse back).
    private static func text(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    var body: some View {
        // The hidden text sets the width, at least four digits' so that the usual numbers don't change it (which would
        // rewrap the label's hint); a little more leaves room for the caret.
        ZStack(alignment: .trailing) {
            Text("0000")
            Text(draft)
        }
        .hidden()
        .padding(.horizontal, 3)
        .overlay {
            TextField("", text: $draft)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(save)
        }
        .onAppear { draft = formatted }
        .onChange(of: value) { if !focused { draft = formatted } }
        .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard var number = Double(draft.trimmingCharacters(in: .whitespaces)) else {
            draft = formatted
            return
        }
        if let min { number = Swift.max(number, min) }
        if let max { number = Swift.min(number, max) }
        if !decimals { number = number.rounded() }
        draft = Self.text(number)
        guard number != value else { return }
        commit(storedNumber(number))
    }
}

private struct NumberField: View {
    let value: Double
    let min: Double?
    let max: Double?
    let decimals: Bool
    let commit: (Any) -> Void

    var body: some View {
        TextField("", value: Binding(get: { value }, set: { save($0) }), format: .number.grouping(.never).precision(.fractionLength(0...(decimals ? 3 : 0))))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
    }

    private func save(_ newValue: Double) {
        var clamped = newValue
        if let min { clamped = Swift.max(clamped, min) }
        if let max { clamped = Swift.min(clamped, max) }
        guard clamped != value else { return }
        commit(storedNumber(clamped))
    }
}

/// A plain text editor for code (CSS, JSON, templates): monospaced, without smart quotes or other
/// substitutions, saving when editing ends.
private struct CodeEditor: NSViewRepresentable {
    let text: String
    var height: CGFloat = 120
    var isInvalid = false
    /// Called with the text as it's typed, before it's saved.
    var edited: ((String) -> Void)?
    /// At most this many lines: Return beeps on the last, and pasted text keeps the lines that fit.
    var maxLines: Int?
    let commit: (String) -> Void

    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private static let inset = NSSize(width: 2, height: 4)

    /// The height that shows this many lines without scrolling: theirs, the insets and the border.
    static func height(lines: Int) -> CGFloat {
        (NSLayoutManager().defaultLineHeight(for: font) * CGFloat(lines) + 2 * inset.height + 2).rounded(.up)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .lineBorder
        let textView = scrollView.documentView as! NSTextView
        textView.font = Self.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = Self.inset
        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.committed = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.commit = commit
        context.coordinator.edited = edited
        context.coordinator.maxLines = maxLines
        let textView = scrollView.documentView as! NSTextView
        textView.textColor = isInvalid ? .systemRed : .textColor
        // Not while it's being edited.
        if textView.window?.firstResponder !== textView, textView.string != text {
            textView.string = text
            context.coordinator.committed = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: height)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.save(scrollView.documentView as! NSTextView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var commit: (String) -> Void = { _ in }
        var edited: ((String) -> Void)?
        var maxLines: Int?
        var committed = ""

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let maxLines, let text, let replaced = Range(range, in: textView.string) else { return true }
            var rest = textView.string
            rest.removeSubrange(replaced)
            // The line breaks the text can still take.
            let free = maxLines - rest.split(separator: "\n", omittingEmptySubsequences: false).count
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count - 1 > free else { return true }
            let fitting = lines.prefix(max(free, 0) + 1).joined(separator: "\n")
            if fitting.isEmpty {
                NSSound.beep()
            } else {
                textView.insertText(fitting, replacementRange: range)
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            edited?(textView.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            save(textView)
        }

        func save(_ textView: NSTextView) {
            guard textView.string != committed else { return }
            committed = textView.string
            commit(textView.string)
        }
    }
}

/// A list edited one item per line (SettingsField.Kind.lines), keeping the first `limit`: as tall as its lines and an
/// empty one where the next is typed, up to `limit` lines, following the text as it's typed.
private struct LinesEditor: View {
    let lines: [String]
    let limit: Int
    let commit: ([String]) -> Void
    /// The text as it's typed, until it's saved.
    @State private var typed: String?

    var body: some View {
        let text = lines.prefix(limit).joined(separator: "\n")
        CodeEditor(text: text, height: CodeEditor.height(lines: rows(typed ?? text)), edited: { typed = $0 }, maxLines: limit) { text in
            typed = nil
            commit(Array(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(limit)))
        }
    }

    /// The text's rows and an empty one below them (where Return goes on to).
    private func rows(_ text: String) -> Int {
        min((text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count) + 1, limit)
    }
}

private struct JSONEditor: View {
    let value: [Any]
    let commit: ([Any]) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CodeEditor(text: Self.format(value), height: 140, isInvalid: error != nil) { text in
                let data = Data((text.isEmpty ? "[]" : text).utf8)
                if let array = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any] {
                    error = nil
                    commit(array)
                } else {
                    error = "Changes not saved: please enter a valid JSON array."
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private static func format(_ value: [Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A record button's label. It's always as wide as `width` ("Record Shortcut" by default, so all record buttons
/// match), even while recording, and longer text is truncated with "…".
struct RecordingLabel: View {
    let text: String
    var width: String

    init(_ text: String, width: String = "Record Shortcut") {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(width).hidden().overlay { Text(text).lineLimit(1).truncationMode(.tail) }
    }
}

/// A button's label that keeps the width of the widest of `labels`, so what's beside the button doesn't move when
/// the label changes (e.g. to "Press keys…" while recording).
private struct SteadyLabel: View {
    let text: String
    let labels: [String]

    init(_ text: String, reserving labels: [String]) {
        self.text = text
        self.labels = labels
    }

    var body: some View {
        ZStack {
            ForEach(labels, id: \.self) { Text($0).hidden() }
            Text(text)
        }
    }
}

private struct TestButton: View {
    let test: SettingsField.ConnectionTest
    @ObservedObject var model: SettingsModel
    @State private var status: (text: String, ok: Bool)?
    @State private var running = false

    var body: some View {
        Button("Test") {
            running = true
            Task {
                do {
                    status = (try await ConnectionTester.run(test, settings: model.values), true)
                } catch {
                    status = (error.localizedDescription, false)
                }
                running = false
            }
        }
        .disabled(running)
        .popover(isPresented: Binding(get: { status != nil && !running }, set: { if !$0 { status = nil } })) {
            if let status {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(status.ok ? .green : .red)
                    .padding()
            }
        }
    }
}

/// Installs MacPopup's Yomitan API host for a browser (see YomitanAPIInstaller).
private struct InstallYomitanAPIButton: View {
    @State private var showing = false
    @State private var browser = YomitanAPIInstaller.likelyBrowser
    @State private var ids = ""
    @State private var result: (text: String, ok: Bool)?

    private var otherIDs: [String] {
        ids.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { $0 != browser.defaultID }
    }

    var body: some View {
        Button("Install") {
            result = nil
            browser = YomitanAPIInstaller.likelyBrowser
            ids = YomitanAPIInstaller.otherIDs(browser).joined(separator: ", ")
            showing = true
        }
        .popover(isPresented: $showing) {
            Group {
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                        .fixedSize()
                } else {
                    form
                }
            }
            .padding()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Browser").gridColumnAlignment(.trailing)
                    Picker("Browser", selection: $browser) {
                        ForEach(YomitanAPIInstaller.browsers) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: browser) { ids = YomitanAPIInstaller.otherIDs(browser).joined(separator: ", ") }
                }
                GridRow {
                    Text("ID")
                    // (The settings form's trailing alignment carries over into the popover.)
                    TextField("ID", text: $ids, prompt: Text("\(browser.defaultID) (default)"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(width: 420)
                }
            }
            let invalid = otherIDs.filter { !YomitanAPIInstaller.isValid($0, for: browser) }
            Group {
                if invalid.isEmpty {
                    Text("For a Yomitan built from source, add its extension ID. The default ID stays allowed.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("This may not be a valid extension ID (expected: \(browser.idFormat)). It will still be added.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 480, alignment: .leading)
            HStack {
                Spacer()
                Button("Confirm") {
                    do {
                        try YomitanAPIInstaller.install(browser, otherIDs: otherIDs)
                        result = ("Installed.\nEnable the Yomitan API in Yomitan settings and restart \(browser.name) to start the API.", true)
                    } catch {
                        result = (error.localizedDescription, false)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Opens MacPopup's IINA plugin (iina-plugin/, packaged by scripts/build.sh) in IINA, which asks to install it.
private struct InstallIINAPluginButton: View {
    @State private var error: String?

    var body: some View {
        Button("Install") {
            error = nil
            guard let iina = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") else {
                error = "IINA isn’t installed."
                return
            }
            guard let package = Bundle.main.url(forResource: "MacPopup", withExtension: "iinaplgz") else {
                error = "This build of MacPopup has no IINA plugin (see scripts/build.sh)."
                return
            }
            NSWorkspace.shared.open([package], withApplicationAt: iina, configuration: NSWorkspace.OpenConfiguration()) { _, openError in
                if let openError {
                    Task { @MainActor in error = "IINA couldn’t open the plugin: \(openError.localizedDescription)" }
                }
            }
        }
        .popover(isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Label(error ?? "", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize()
                .padding()
        }
    }
}

/// The transcripts of IINA's videos kept (VideoTranscriber), looked up again as they change while they're shown.
@MainActor
final class VideoTranscripts: ObservableObject {
    static let shared = VideoTranscripts()
    @Published private(set) var kept: (videos: Int, bytes: Int64)?
    private var shown = 0

    private init() {
        NotificationCenter.default.addObserver(forName: VideoTranscriber.transcriptsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shown > 0 else { return }
                self.refresh()
            }
        }
    }

    func appeared() {
        shown += 1
        refresh()
    }

    func disappeared() {
        shown -= 1
    }

    private func refresh() {
        Task {
            let kept = await Task.detached { VideoTranscriber.kept() }.value
            self.kept = kept
        }
    }
}

/// How many videos' transcripts are kept and their size, with a button to clear them.
private struct VideoTranscriptsControl: View {
    let clear: () -> Void
    @ObservedObject private var transcripts = VideoTranscripts.shared

    var body: some View {
        HStack(spacing: 8) {
            if let kept = transcripts.kept {
                Text(kept.videos == 0 ? "None"
                    : "\(kept.videos) \(kept.videos == 1 ? "video" : "videos"), \(ByteCountFormatter.string(fromByteCount: kept.bytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
            Button("Clear…", action: clear).disabled((transcripts.kept?.videos ?? 0) == 0)
        }
        .onAppear { transcripts.appeared() }
        .onDisappear { transcripts.disappeared() }
    }
}

private struct ScanInputsControl: View {
    let key: String
    let values: [String]
    @ObservedObject var model: SettingsModel
    @ObservedObject var recorder: ScanInputRecorder
    @State private var rows = RowIDs()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(zip(rows(values.count), values.indices)), id: \.0) { id, index in
                ScanInputRow(id: "\(key)#\(id)", value: values[index], recorder: recorder) { newValue in
                    // The list as it is now (`values` is as it was drawn).
                    var updated = model[key] as? [String] ?? []
                    guard let index = rows.index(id), updated.indices.contains(index) else { return }
                    if let newValue {
                        updated[index] = newValue
                    } else {
                        rows.remove(at: index)
                        updated.remove(at: index)
                    }
                    model.set(key, updated)
                }
            }
            RecordButton(id: "\(key)#new", title: "Record New Input", recorder: recorder) { value in
                rows.append()
                model.set(key, (model[key] as? [String] ?? []) + [value])
            }
            Text(SettingsSchema.scanInputsHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { rows.sync(values.count) }
        .onChange(of: values.count) { rows.sync(values.count) }
    }
}

private struct ScanInputRow: View {
    let id: String
    let value: String
    @ObservedObject var recorder: ScanInputRecorder
    /// The new value, or nil to remove it.
    let change: (String?) -> Void
    @State private var invalid: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // While recording, the field shows the keys and mouse buttons held.
                let recording = recorder.activeID == id
                CommitTextField(
                    value: recording ? ScanInput.format(recorder.recorded) : value,
                    placeholder: recording ? "Hold keys or mouse buttons…" : "hover", monospaced: true, bordered: true
                ) { text in
                    let names = ScanInput.parse(text)
                    invalid = names.filter { !ScanInput.isValidName($0) }
                    if invalid.isEmpty { change(ScanInput.format(names)) }
                }
                RecordButton(id: id, title: "Record", recorder: recorder, showsInput: false) { change($0) }
                Button {
                    change(nil)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            if !invalid.isEmpty {
                Text("Unrecognized input: \(invalid.joined(separator: ", "))").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct RecordButton: View {
    let id: String
    let title: String
    @ObservedObject var recorder: ScanInputRecorder
    /// Whether the label shows what's held while recording (rather than "Recording…", for a row whose field shows it).
    var showsInput = true
    let recorded: (String) -> Void

    var body: some View {
        let isActive = recorder.activeID == id
        Button {
            if isActive {
                recorder.cancel()
            } else {
                recorder.start(id: id) { value in
                    if let value { recorded(value) }
                }
            }
        } label: {
            if showsInput {
                RecordingLabel(isActive ? (recorder.recorded.isEmpty ? "Hold keys or mouse buttons…" : ScanInput.format(recorder.recorded)) : title, width: title)
            } else {
                SteadyLabel(isActive ? "Recording…" : title, reserving: [title, "Recording…"]).frame(minWidth: 60)
            }
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : nil)
        .help(isActive ? "Hold the keys and mouse buttons you want to use, then release one. Press Esc to cancel." : "")
    }
}

/// A change to a row of a list that can be reordered (replacements, audio sources).
private enum ListRowChange {
    case set(String, Any)
    case move(Int)
    case remove

    func apply(to items: [[String: Any]], at index: Int) -> [[String: Any]] {
        var updated = items
        switch self {
        case let .set(field, value): updated[index][field] = value
        case let .move(offset): updated.swapAt(index, index + offset)
        case .remove: updated.remove(at: index)
        }
        return updated
    }
}

/// Buttons that move a list's row up or down, and remove it.
private struct ListRowButtons: View {
    let isFirst: Bool
    let isLast: Bool
    let change: (ListRowChange) -> Void

    var body: some View {
        Group {
            Button { change(.move(-1)) } label: { Image(systemName: "chevron.up") }
                .disabled(isFirst).help("Move up")
            Button { change(.move(1)) } label: { Image(systemName: "chevron.down") }
                .disabled(isLast).help("Move down")
            Button { change(.remove) } label: { Image(systemName: "minus.circle") }
                .help("Remove")
        }
        .buttonStyle(.borderless)
    }
}

/// Identities for a list's rows that move with their items, so a row's views (a field being edited, a recording) stay
/// with its item, and its changes go to that item wherever it is by then. Until `sync` gives them identities (when the
/// list appears, and when it changed elsewhere, e.g. by Import), rows are identified by position.
private struct RowIDs {
    private var ids: [UUID] = []

    func callAsFunction(_ count: Int) -> [AnyHashable] {
        (0..<count).map { ids.indices.contains($0) ? AnyHashable(ids[$0]) : AnyHashable($0) }
    }

    /// Where the row with that identity is now.
    func index(_ id: AnyHashable) -> Int? {
        if let uuid = id.base as? UUID { return ids.firstIndex(of: uuid) }
        return id.base as? Int
    }

    mutating func sync(_ count: Int) {
        if ids.count != count { ids = (0..<count).map { _ in UUID() } }
    }

    mutating func append() {
        ids.append(UUID())
    }

    mutating func remove(at index: Int) {
        if ids.indices.contains(index) { ids.remove(at: index) }
    }

    /// The list with the change made to the row with that identity, or nil if it's gone.
    mutating func apply(_ change: ListRowChange, to id: AnyHashable, in items: [[String: Any]]) -> [[String: Any]]? {
        guard let index = index(id), items.indices.contains(index) else { return nil }
        switch change {
        case .set: break
        case let .move(offset):
            guard items.indices.contains(index + offset) else { return nil }
            if ids.indices.contains(index), ids.indices.contains(index + offset) { ids.swapAt(index, index + offset) }
        case .remove: remove(at: index)
        }
        return change.apply(to: items, at: index)
    }
}

/// Replacements applied to lines: a row for each, and a field to try them on a sample line.
private struct ReplacementsControl: View {
    let key: String
    @ObservedObject var model: SettingsModel
    @State private var sample = ""
    @State private var showJSON = false
    @State private var rows = RowIDs()

    private var items: [[String: Any]] {
        (model[key] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(zip(rows(items.count), items.indices)), id: \.0) { id, index in
                ReplacementRow(item: items[index], isFirst: index == 0, isLast: index == items.count - 1) { change in
                    if let updated = rows.apply(change, to: id, in: items) { model.set(key, updated) }
                }
            }
            HStack {
                Button("Add Replacement") {
                    rows.append()
                    model.set(key, items + [["pattern": "", "replaces": "", "flags": ["g"], "enabled": true]])
                }
                Spacer()
                Toggle("Edit as JSON", isOn: $showJSON).toggleStyle(.checkbox)
            }
            if showJSON {
                JSONEditor(value: items) { model.set(key, $0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Test replacements on sample text…", text: $sample, prompt: Text("Test replacements on sample text…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if !sample.isEmpty {
                    let result = SettingsSupport.shared.previewReplacements(sample, replacements: items)
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        Text(result.isEmpty ? "(Empty result — this line will be hidden)" : result)
                            .font(.body.monospaced())
                            .foregroundStyle(result.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear { rows.sync(items.count) }
        .onChange(of: items.count) { rows.sync(items.count) }
    }
}

private struct ReplacementRow: View {
    /// Regular expression flags, as in JavaScript.
    private static let flags: [(name: String, help: String)] = [
        ("g", "Global: replace all matches in the line, not just the first"),
        ("i", "Case-insensitive: ignore uppercase/lowercase differences"),
        ("m", "Multiline: ^ and $ match the start and end of each line"),
        ("s", "Dot matches all: allow . to match line breaks"),
        ("u", "Unicode: support \\u{…} and \\p{…} patterns, and treat emoji as single characters"),
    ]

    let item: [String: Any]
    let isFirst: Bool
    let isLast: Bool
    let change: (ListRowChange) -> Void

    private var pattern: String { item["pattern"] as? String ?? "" }
    private var flags: [String] { item["flags"] as? [String] ?? [] }
    private var isEnabled: Bool { item["enabled"] as? Bool ?? true }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { isEnabled }, set: { change(.set("enabled", $0)) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Enabled")
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    CommitTextField(value: pattern, placeholder: "Find (regex pattern)", monospaced: true, bordered: true) { change(.set("pattern", $0)) }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    CommitTextField(value: item["replaces"] as? String ?? "", placeholder: "Replace with", monospaced: true, bordered: true) {
                        change(.set("replaces", $0))
                    }
                }
                HStack(spacing: 4) {
                    ForEach(Self.flags, id: \.name) { flag in
                        Toggle(isOn: Binding(
                            get: { flags.contains(flag.name) },
                            set: { on in change(.set("flags", Self.flags.map(\.name).filter { $0 == flag.name ? on : flags.contains($0) })) }
                        )) {
                            Text(flag.name).font(.body.monospaced())
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(flag.help)
                    }
                    Spacer()
                    ListRowButtons(isFirst: isFirst, isLast: isLast, change: change)
                }
                if let error = SettingsSupport.shared.patternError(pattern, flags: flags) {
                    Text("Invalid pattern (skipped): \(error)").font(.caption).foregroundStyle(.red)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }
}

/// Yomitan's audio sources: a row for each with its type and, for some types, a URL or a voice.
private struct AudioSourcesControl: View {
    let key: String
    @ObservedObject var model: SettingsModel

    /// Yomitan's audio source types, with its names.
    static let types: [SettingsOption] = [
        SettingsOption("jpod101", "JapanesePod101"),
        SettingsOption("language-pod-101", "LanguagePod101"),
        SettingsOption("jisho", "Jisho.org"),
        SettingsOption("lingua-libre", "(Commons) Lingua Libre"),
        SettingsOption("wiktionary", "(Commons) Wiktionary"),
        SettingsOption("forvo", "Forvo"),
        SettingsOption("text-to-speech", "Text-to-speech"),
        SettingsOption("text-to-speech-reading", "Text-to-speech (Kana reading)"),
        SettingsOption("custom", "Custom URL"),
        SettingsOption("custom-json", "Custom URL (JSON)"),
    ]

    @State private var rows = RowIDs()

    private var items: [[String: Any]] {
        (model[key] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(zip(rows(items.count), items.indices)), id: \.0) { id, index in
                AudioSourceRow(index: index, item: items[index], isFirst: index == 0, isLast: index == items.count - 1) { change in
                    if let updated = rows.apply(change, to: id, in: items) { model.set(key, updated) }
                }
            }
            Button("Add Audio Source") {
                rows.append()
                model.set(key, items + [["type": unusedType(), "url": "", "voice": "", "apiKey": ""]])
            }
        }
        .onAppear { rows.sync(items.count) }
        .onChange(of: items.count) { rows.sync(items.count) }
    }

    /// As in Yomitan: the first of its usual sources that isn't listed yet.
    private func unusedType() -> String {
        let usual = ["jpod101", "jisho", "language-pod-101", "lingua-libre", "wiktionary", "text-to-speech", "custom"]
        let used = Set(items.compactMap { $0["type"] as? String })
        return usual.first { !used.contains($0) } ?? usual[0]
    }
}

private struct AudioSourceRow: View {
    /// The voices WebKit's speech synthesis can use (not the Siri ones), Japanese first, as in Yomitan.
    private static let voices: [SettingsOption] = {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { !$0.identifier.contains(".siri") }
        let sorted = all.filter { $0.language.hasPrefix("ja") } + all.filter { !$0.language.hasPrefix("ja") }
        return [SettingsOption("", "None")] + sorted.map { SettingsOption($0.identifier, "\($0.name) (\($0.language))") }
    }()

    let index: Int
    let item: [String: Any]
    let isFirst: Bool
    let isLast: Bool
    let change: (ListRowChange) -> Void

    private var type: String { item["type"] as? String ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    let options = AudioSourcesControl.types.contains { $0.value == type }
                        ? AudioSourcesControl.types : AudioSourcesControl.types + [SettingsOption(type)]
                    Picker("", selection: Binding(get: { type }, set: { change(.set("type", $0)) })) {
                        ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    ListRowButtons(isFirst: isFirst, isLast: isLast, change: change)
                }
                switch type {
                case "custom", "custom-json":
                    CommitTextField(
                        value: item["url"] as? String ?? "",
                        placeholder: type == "custom" ? "Audio file URL" : "Audio list JSON URL",
                        monospaced: true,
                        bordered: true
                    ) { change(.set("url", $0.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    Text(type == "custom"
                        ? "Placeholders {term}, {reading}, and {language} are replaced with the looked-up word, its reading, and its language code (e.g. ja)."
                        : "Supports {term}, {reading}, and {language} placeholders. Expects a JSON list of audio files in Yomitan’s custom audio format (e.g. from a local audio server).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case "text-to-speech", "text-to-speech-reading":
                    let voice = item["voice"] as? String ?? ""
                    let voices = Self.voices.contains { $0.value == voice } ? Self.voices : Self.voices + [SettingsOption(voice)]
                    Picker("Voice", selection: Binding(get: { voice }, set: { change(.set("voice", $0)) })) {
                        ForEach(voices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .fixedSize()
                    Text("Text-to-speech can be played in popups, but cannot be saved to Anki cards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case "forvo":
                    CommitTextField(value: item["apiKey"] as? String ?? "", placeholder: "API key", monospaced: true, bordered: true) {
                        change(.set("apiKey", $0.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    Text("Plays pronunciations from Forvo in the language set in General: those of speakers from countries where the language is spoken natively first, each the best rated first. When Forvo has none for the term, those of its reading are played. Forvo needs an API key, which comes with a plan from Forvo’s API site (api.forvo.com).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }
}

/// The handlebars templates in yomitanAnkiTemplates. Shows Yomitan's defaults until they're changed.
private struct AnkiTemplatesControl: View {
    let key: String
    @ObservedObject var model: SettingsModel

    private var stored: [String: Any] {
        // Null until Yomitan settings are imported, so until then the other values (dictionaries, output modes) are
        // Yomitan's defaults. Saving keeps whichever are there.
        model[key] as? [String: Any] ?? ["fieldTemplates": NSNull(), "dictionaries": [Any](), "resultOutputMode": "group", "readingMode": NSNull()]
    }

    private var fieldTemplates: String? { stored["fieldTemplates"] as? String }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeEditor(text: fieldTemplates ?? SettingsSupport.shared.defaultFieldTemplates, height: 220) { save($0) }
            HStack {
                Text(fieldTemplates == nil ? "Using Yomitan’s default templates." : "Using custom templates.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if fieldTemplates != nil {
                    Button("Reset to Yomitan Defaults") { save(nil) }
                }
            }
        }
    }

    private func save(_ templates: String?) {
        var value = stored
        if let templates, !templates.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, templates != SettingsSupport.shared.defaultFieldTemplates {
            value["fieldTemplates"] = templates
        } else {
            value["fieldTemplates"] = NSNull()
        }
        model.set(key, value)
    }
}

// MARK: Connection tests

enum ConnectionTester {
    static func run(_ test: SettingsField.ConnectionTest, settings: [String: Any]) async throws -> String {
        switch test {
        case .yomitan:
            var base = settings["yomitanApiUrl"] as? String ?? ""
            while base.hasSuffix("/") { base.removeLast() }
            let (status, body) = try await post("\(base)/yomitanVersion", body: [:])
            guard status == 200 else { throw AppError("Yomitan API returned an error (HTTP \(status))") }
            let version = (SettingsSupport.decode(body)?["version"]).map { "\($0)" } ?? "?"
            return "Connected (Yomitan \(version))"
        case .anki:
            var request: [String: Any] = ["action": "version", "version": 6]
            if let key = settings["ankiConnectKey"] as? String, !key.isEmpty { request["key"] = key }
            let body: String
            do {
                body = try await post(settings["ankiConnectUrl"] as? String ?? "", body: request).body
            } catch {
                throw AppError("Could not connect to Anki (make sure Anki is running with AnkiConnect installed)")
            }
            let result = SettingsSupport.decode(body)
            if let error = result?["error"] as? String { throw AppError(error) }
            return "Connected (AnkiConnect v\(result?["result"].map { "\($0)" } ?? body))"
        }
    }

    private static func post(_ urlString: String, body: [String: Any]) async throws -> (status: Int, body: String) {
        guard let url = URL(string: urlString), url.scheme != nil else { throw AppError("Invalid URL format") }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = Data(SettingsSupport.encode(body).utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }
}

/// Records the next key press, with the modifier keys held, for a keyboard shortcut.
@MainActor
private final class ShortcutRecorder: ObservableObject {
    /// The row that's recording.
    @Published private(set) var activeID: AnyHashable?
    private var monitor: Any?
    private var completion: ((KeyCombination) -> Void)?
    /// The key just recorded. Its repeats and release are still held back from the window.
    private var releasing: UInt16?
    private var othersStarting: AnyCancellable?

    init() {
        // Another recorder starting (see Notification.Name.settingsRecordingStarted) cancels this one's recording.
        othersStarting = NotificationCenter.default.publisher(for: .settingsRecordingStarted).sink { [weak self] note in
            MainActor.assumeIsolated {
                if note.object as AnyObject? !== self { self?.cancel() }
            }
        }
    }

    func start(id: AnyHashable, completion: @escaping (KeyCombination) -> Void) {
        cancel()
        NotificationCenter.default.post(name: .settingsRecordingStarted, object: self)
        activeID = id
        self.completion = completion
        // After a section is clicked, the sidebar has keyboard focus and would jump to the section starting with the
        // pressed letter, even with Control held (⌃A opened Anki). So nothing has focus while recording.
        NSApp.keyWindow?.makeFirstResponder(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if let releasing {
                // Once recorded, the key's repeats and release are swallowed until another key is pressed.
                if event.type == .flagsChanged || event.keyCode != releasing || (event.type == .keyDown && !event.isARepeat) {
                    cancel()
                    return event
                }
                if event.type == .keyUp { cancel() }
                return nil
            }
            switch event.type {
            case .flagsChanged:
                return event
            case .keyUp:
                return nil
            default:
                break
            }
            guard let combination = KeyCombination(event: event) else { return nil }
            let completion = self.completion
            activeID = nil
            self.completion = nil
            releasing = event.keyCode
            completion?(combination)
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        activeID = nil
        completion = nil
        releasing = nil
    }
}

/// Yomitan's sentence termination characters, edited as in its “Configure…” dialog.
private struct TerminationCharactersControl: View {
    let key: String
    @ObservedObject var model: SettingsModel
    @State private var confirmingReset = false

    private var items: [[String: Any]] {
        (model[key] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("No terminators defined.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("#")
                        Text("Enabled")
                        // Lines up with the dropdowns' text, which is inset from their edge.
                        Text("Type").padding(.leading, 11)
                        Text("Character 1")
                        Text("Character 2")
                        Text("Include character in sentence")
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        let isQuote = item["character2"] is String
                        GridRow {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Toggle("", isOn: binding(index, "enabled", true))
                                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            Picker("", selection: Binding(get: { isQuote }, set: { quote in
                                // As in Yomitan, a quote starts out as the first character twice.
                                update(index, ["character2": quote ? item["character1"] as? String ?? "" : NSNull()])
                            })) {
                                Text("Terminator").tag(false)
                                Text("Quote").tag(true)
                            }
                            .labelsHidden()
                            .fixedSize()
                            // Matches the inset of its text (see the header).
                            .padding(.trailing, 11)
                            characterField(index, "character1")
                            if isQuote {
                                characterField(index, "character2")
                            } else {
                                Text("—").foregroundStyle(.secondary).frame(width: 40)
                            }
                            HStack(spacing: 24) {
                                Toggle("At start", isOn: binding(index, "includeCharacterAtStart", false)).toggleStyle(.checkbox)
                                Toggle("At end", isOn: binding(index, "includeCharacterAtEnd", false)).toggleStyle(.checkbox)
                            }
                            .fixedSize()
                            Button {
                                var updated = items
                                updated.remove(at: index)
                                model.set(key, updated)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                            // Pinned to the right edge, as in the other lists.
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            HStack {
                Button("Add") {
                    model.set(key, items + [[
                        "enabled": true, "character1": "\"", "character2": "\"",
                        "includeCharacterAtStart": false, "includeCharacterAtEnd": false,
                    ]])
                }
                Button("Reset to Defaults") { confirmingReset = true }
            }
            .padding(.top, 8)
        }
        .confirmationDialog("Replace all sentence termination characters with Yomitan’s defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.set(key, SettingsSupport.shared.defaults[key] ?? [Any]()) }
        }
    }

    private func update(_ index: Int, _ changes: [String: Any]) {
        var updated = items
        guard updated.indices.contains(index) else { return }
        updated[index].merge(changes) { _, new in new }
        model.set(key, updated)
    }

    private func binding(_ index: Int, _ field: String, _ fallback: Bool) -> Binding<Bool> {
        Binding(get: { items.indices.contains(index) ? items[index][field] as? Bool ?? fallback : fallback }, set: { update(index, [field: $0]) })
    }

    /// One character: typing replaces it (Yomitan's field takes one character).
    private func characterField(_ index: Int, _ field: String) -> some View {
        TextField("", text: Binding(
            get: { items.indices.contains(index) ? items[index][field] as? String ?? "" : "" },
            set: { update(index, [field: $0.last.map(String.init) ?? ""]) }
        ))
        // The borderless field at its own size, centered in a drawn border: a bordered field grows
        // with the taller line of the font Japanese punctuation falls back to, so they wouldn't line up.
        // Sized to its character, which the box centers (the form aligns field text to the right).
        .fixedSize()
        .frame(minWidth: 12)
        .frame(width: 40, height: 28)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct HotkeysControl: View {
    let key: String
    @ObservedObject var model: SettingsModel
    @StateObject private var recorder = ShortcutRecorder()
    @State private var confirmingReset = false
    @State private var rows = RowIDs()

    /// Yomitan's popup shortcut actions, with its names (switching profiles isn't supported).
    static let actions: [SettingsOption] = [
        SettingsOption("close", "Close"),
        SettingsOption("nextEntry", "Go to next entry"),
        SettingsOption("previousEntry", "Go to previous entry"),
        SettingsOption("lastEntry", "Go to last entry"),
        SettingsOption("firstEntry", "Go to first entry"),
        SettingsOption("nextEntryDifferentDictionary", "Go to next dictionary"),
        SettingsOption("previousEntryDifferentDictionary", "Go to previous dictionary"),
        SettingsOption("historyBackward", "Navigate backward in history"),
        SettingsOption("historyForward", "Navigate forward in history"),
        SettingsOption("addNote", "Add note"),
        // MacPopup's own action, the same as Option-clicking the add button (see popup.js).
        SettingsOption("addNoteSentenceAudio", "Add note (sentence audio)"),
        SettingsOption("viewNotes", "View notes"),
        SettingsOption("playAudio", "Play audio"),
        SettingsOption("playAudioFromSource", "Play audio from source"),
        SettingsOption("copyHostSelection", "Copy host window selection"),
    ]

    /// An action's argument when it's chosen, as in Yomitan.
    static func defaultArgument(_ action: String) -> String {
        switch action {
        case "nextEntry", "previousEntry": "1"
        case "addNote", "addNoteSentenceAudio", "viewNotes": "0"
        case "playAudioFromSource": "jpod101"
        default: ""
        }
    }

    private var items: [[String: Any]] {
        (model[key] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(zip(rows(items.count), items.indices)), id: \.0) { id, index in
                HotkeyRow(id: id, item: items[index], isDuplicate: isDuplicate(index), buttonsNote: buttonsNote(index), recorder: recorder) { change in
                    var updated = items
                    guard let index = rows.index(id), updated.indices.contains(index) else { return }
                    switch change {
                    case let .set(values): updated[index].merge(values) { _, new in new }
                    case .remove:
                        rows.remove(at: index)
                        updated.remove(at: index)
                    }
                    model.set(key, updated)
                }
            }
            HStack {
                Button("Add Shortcut") {
                    rows.append()
                    model.set(key, items + [["action": "close", "argument": "", "key": "", "modifiers": [String](), "enabled": true]])
                }
                Button("Reset to Defaults") { confirmingReset = true }
            }
            .padding(.top, 8)
        }
        .onAppear { rows.sync(items.count) }
        .onChange(of: items.count) { rows.sync(items.count) }
        .onDisappear { recorder.cancel() }
        .confirmationDialog("Replace all keyboard shortcuts with Yomitan’s defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.set(key, SettingsSupport.shared.defaults[key] ?? [Any]()) }
        }
    }

    /// Whether an enabled shortcut above has the same keys (only the first one works).
    private func isDuplicate(_ index: Int) -> Bool {
        guard items[index]["enabled"] as? Bool ?? true, let combination = KeyCombination(setting: items[index]) else { return false }
        return items[..<index].contains { ($0["enabled"] as? Bool ?? true) && KeyCombination(setting: $0) == combination }
    }

    /// Why a shortcut's controller buttons don't work, if they don't: the controller scan key or an earlier shortcut
    /// has them.
    private func buttonsNote(_ index: Int) -> String? {
        let buttons = Set(items[index]["buttons"] as? [String] ?? [])
        guard !buttons.isEmpty, items[index]["enabled"] as? Bool ?? true else { return nil }
        if Set(model["gamepadScanButtons"] as? [String] ?? []) == buttons {
            return "These controller buttons are already used by the controller scan key, which takes priority."
        }
        if SentenceAudioController.isEnabled(model.values), Set(model["sentenceAudioButtons"] as? [String] ?? []) == buttons {
            return "Anki Audio already uses these buttons, so it takes priority."
        }
        if Set(model["overlayHideButtons"] as? [String] ?? []) == buttons {
            return "The overlay hide key/buttons already use these buttons, so they take priority."
        }
        if Set(model["overlaySwitchButtons"] as? [String] ?? []) == buttons {
            return "The overlay switch already uses these buttons, so it takes priority."
        }
        let earlier = items[..<index].contains { ($0["enabled"] as? Bool ?? true) && Set($0["buttons"] as? [String] ?? []) == buttons }
        return earlier ? "These controller buttons are already used by an earlier shortcut, which takes priority." : nil
    }
}

private struct HotkeyRow: View {
    enum Change {
        case set([String: Any])
        case remove
    }

    let id: AnyHashable
    let item: [String: Any]
    let isDuplicate: Bool
    let buttonsNote: String?
    @ObservedObject var recorder: ShortcutRecorder
    let change: (Change) -> Void

    private var action: String { item["action"] as? String ?? "" }
    private var argument: String { item["argument"] as? String ?? "" }

    private var combination: KeyCombination? { KeyCombination(setting: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // No spacing: the dropdowns' own margins keep them apart, and the argument sits right next to the action.
            HStack(spacing: 0) {
                let actions = HotkeysControl.actions.contains { $0.value == action }
                    ? HotkeysControl.actions : HotkeysControl.actions + [SettingsOption(action)]
                // Keeps the action right next to its checkbox.
                HStack(spacing: 0) {
                    Toggle("", isOn: Binding(get: { item["enabled"] as? Bool ?? true }, set: { change(.set(["enabled": $0])) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Enabled")
                    Picker("", selection: Binding(get: { action }, set: { change(.set(["action": $0, "argument": HotkeysControl.defaultArgument($0)])) })) {
                        ForEach(actions, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                }
                .fixedSize()
                argumentControl
                Spacer(minLength: 8)
                // The keyboard and controller buttons, stacked on the right at full width. In a crowded row, the
                // action's dropdown gets truncated instead (see shrinking).
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 2) {
                        clearButton("Clear the keyboard shortcut", hidden: combination == nil) {
                            if recorder.activeID == id { recorder.cancel() }
                            change(.set(["key": "", "modifiers": [String]()]))
                        }
                        recordButton
                    }
                    buttonsControl
                }
                .fixedSize()
                Button { change(.remove) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .padding(.leading, 8)
            }
            if isDuplicate {
                Text("These keyboard keys are already used by an earlier shortcut, which takes priority.").font(.caption).foregroundStyle(.red)
            } else if let combination, combination.keyCode == nil {
                Text("\(combination.key) isn’t a key MacPopup can use.").font(.caption).foregroundStyle(.red)
            }
            if let buttonsNote {
                Text(buttonsNote).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Controller buttons for the shortcut (see GamepadComboButton), which can be removed.
    private var buttonsControl: some View {
        let buttons = item["buttons"] as? [String] ?? []
        return HStack(spacing: 2) {
            clearButton("Clear the controller buttons", hidden: buttons.isEmpty) {
                change(.set(["buttons": [String]()]))
            }
            GamepadComboButton(buttons: buttons) { change(.set(["buttons": $0])) }
        }
    }

    /// A button that clears the keyboard shortcut or controller buttons next to it. It still takes up space when
    /// there's nothing to clear, so the controls in every row line up.
    private func clearButton(_ help: String, hidden: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
            .opacity(hidden ? 0 : 1)
            .disabled(hidden)
            .accessibilityHidden(hidden)
    }

    private var recordButton: some View {
        let isActive = recorder.activeID == id
        return Button {
            if isActive {
                recorder.cancel()
            } else {
                recorder.start(id: id) { combination in
                    change(.set(["key": combination.key, "modifiers": combination.modifiers]))
                }
            }
        } label: {
            RecordingLabel(isActive ? "Press keys…" : combination?.displayName ?? "Record Shortcut")
        }
        .help(isActive ? "Click to cancel" : recordHelp(combination))
    }

    @ViewBuilder
    private var argumentControl: some View {
        switch action {
        case "nextEntry", "previousEntry":
            let count = Int(argument) ?? 1
            HStack(spacing: 5) {
                Text("by \(count)").monospacedDigit()
                Stepper("", value: Binding(get: { count }, set: { change(.set(["argument": String($0)])) }), in: 1...99)
                    .labelsHidden()
            }
            .fixedSize()
            // The same gap from the action as a dropdown's margin.
            .padding(.leading, 6)
        case "addNote", "addNoteSentenceAudio", "viewNotes":
            let index = Int(argument) ?? 0
            shrinking(Picker("", selection: Binding(get: { index }, set: { change(.set(["argument": String($0)])) })) {
                ForEach(0..<max(6, index + 1), id: \.self) { Text("Card format \($0 + 1)").tag($0) }
            }
            .labelsHidden())
            .help("Card formats from your active Yomitan profile, in order")
        case "playAudioFromSource":
            let types = AudioSourcesControl.types.contains { $0.value == argument }
                ? AudioSourcesControl.types : AudioSourcesControl.types + [SettingsOption(argument)]
            shrinking(Picker("", selection: Binding(get: { argument }, set: { change(.set(["argument": $0])) })) {
                ForEach(types, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden())
        default:
            EmptyView()
        }
    }

    /// Shows the action's dropdown at full width when the row has room, and otherwise narrower with its title
    /// truncated ("…"), so it doesn't push the rest of the row, like the remove button, out of the window.
    private func shrinking(_ picker: some View) -> some View {
        ViewThatFits(in: .horizontal) {
            picker.fixedSize()
            picker.frame(minWidth: 60, maxWidth: .infinity)
        }
        // Gets the row's width before the spacer after it does.
        .layoutPriority(1)
    }
}
