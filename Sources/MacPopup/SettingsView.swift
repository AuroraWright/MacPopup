import AVFoundation
import AppKit
import OCREngines
import SwiftUI

/// What the Settings window asks of the app.
@MainActor
struct SettingsActions {
    var selectOCRWindow: () -> Void
    var importYomitan: () -> Void
    var importTexthooker: () -> Void
    var resetAll: () -> Void
    var loadModels: (ConvertedModelsKind) -> Void
    var removeModels: (ConvertedModelsKind) -> Void
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
                    Menu("Import") {
                        Button("Yomitan Settings…", action: actions.importYomitan)
                        Button("texthooker-ui Settings…", action: actions.importTexthooker)
                    }
                    .help("Import a settings backup file from Yomitan (Settings → Backup → Export Settings) or texthooker-ui.")
                    Button("Reset All…", role: .destructive, action: actions.resetAll)
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
        .onChange(of: selection) { recorder.cancel() }
    }
}

private struct SectionForm: View {
    let section: SettingsSection
    @ObservedObject var model: SettingsModel
    @ObservedObject var recorder: ScanInputRecorder
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                ForEach(section.fields.filter { $0.showIf?(model.values) ?? true }) { field in
                    FieldRow(field: field, model: model, recorder: recorder, actions: actions)
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
}

/// A section's description. As a Text, its last line could be cut off: the form measures the header without
/// the line breaking that keeps a last line from being too short, then draws it with it, which can take a
/// line more. This label measures and draws its text the same way.
private struct HeaderDescription: NSViewRepresentable {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
            if let hint = field.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
                // A field that's all of its section (Shortcuts) has no label of its own.
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
        case let .slider(min, max, step):
            LabeledContent {
                NumberSlider(value: (value as? NSNumber)?.doubleValue ?? min, range: min...max, step: step) { model.set(field.key, Int($0)) }
            } label: {
                FieldLabel(field: field)
            }
        case let .numberSelect(options):
            let current = (value as? NSNumber).map { "\($0)" } ?? ""
            let shown = options.contains { $0.value == current } ? options : options + [SettingsOption(current)]
            Picker(selection: Binding(get: { current }, set: { new in
                guard let number = Double(new) else { return }
                model.set(field.key, number.rounded() == number ? Int(number) as Any : number)
            })) {
                ForEach(shown, id: \.value) { Text($0.label).tag($0.value) }
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
        case .keySequence:
            KeySequenceControl(items: (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }) { model.set(field.key, $0) } label: {
                FieldLabel(field: field)
            }
        case let .permission(permission):
            // The status and buttons on their own line, so they're in the same place whatever their width.
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(field: field)
                HStack {
                    Spacer()
                    PermissionControl(permission: permission)
                }
            }
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
        case .ankiField:
            AnkiFieldPicker(name: value as? String ?? "", settings: model.values) { model.set(field.key, $0) } label: {
                FieldLabel(field: field)
            }
        case let .select(options):
            let current = value as? String ?? ""
            // A value the menu doesn't offer (e.g. imported) is shown rather than dropped.
            let shown = options.contains { $0.value == current } ? options : options + [SettingsOption(current)]
            Picker(selection: Binding(get: { current }, set: { model.set(field.key, $0) })) {
                ForEach(shown, id: \.value) { Text($0.label).tag($0.value) }
            } label: {
                FieldLabel(field: field)
            }
        case let .text(test):
            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        CommitTextField(value: value as? String ?? "", placeholder: "None") { model.set(field.key, $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        if let test { TestButton(test: test, model: model) }
                        if test == .yomitan { InstallYomitanAPIButton() }
                    }
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
                    if !items.isEmpty {
                        Button("Clear") { model.set(field.key, [Any]()) }
                    }
                }
            } label: {
                FieldLabel(field: field)
            }
        case .ocrWindow:
            LabeledContent {
                HStack {
                    Text(ocrWindowDescription).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
        case .lines:
            CodeEditor(text: (value as? [String] ?? []).joined(separator: "\n"), height: 60) { text in
                model.set(field.key, text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
        case .json:
            JSONEditor(value: value as? [Any] ?? []) { model.set(field.key, $0) }
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
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, prompt: Text(placeholder))
            .labelsHidden()
            .modifier(RoundedBorder(isOn: bordered))
            .font(monospaced ? .body.monospaced() : .body)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onChange(of: value) { if !focused { draft = value } }
            .onAppear { draft = value }
            .onDisappear(perform: save)
    }

    private func save() {
        if draft != value { commit(draft) }
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

    var body: some View {
        Picker(selection: Binding(get: { index }, set: commit)) {
            ForEach(displays.indices, id: \.self) { Text(displays[$0]).tag($0) }
            // Kept until another is chosen: the overlay goes back to it when it's connected again.
            if !displays.indices.contains(index) {
                Text("Display \(index + 1) (disconnected)").tag(index)
            }
        } label: {
            label
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Self.connectedDisplays()
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
                if let converted = models.converted {
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
                // While loading, the chosen field (a menu is as wide as its chosen item, so the text beside it stays put).
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
        Picker(selection: Binding(get: { name }, set: commit)) {
            if name.isEmpty { Text("Choose a field").tag("") }
            ForEach(fields, id: \.self) { Text($0).tag($0) }
            // Kept until another is chosen.
            if !name.isEmpty && !fields.contains(name) { Text("\(name) (not found)").tag(name) }
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

private func keyCombination(_ item: [String: Any]?) -> KeyCombination? {
    guard let key = item?["key"] as? String, !key.isEmpty else { return nil }
    return KeyCombination(key: key, modifiers: item?["modifiers"] as? [String] ?? [])
}

/// Records one keyboard shortcut.
private struct ShortcutControl: View {
    let value: [String: Any]?
    let commit: ([String: Any]?) -> Void
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        HStack {
            let isActive = recorder.activeIndex != nil
            Button {
                if isActive {
                    recorder.cancel()
                } else {
                    recorder.start(index: 0) { commit(["key": $0.key, "modifiers": $0.modifiers]) }
                }
            } label: {
                let title = keyCombination(value)?.displayName ?? "Record Shortcut"
                SteadyLabel(isActive ? "Press keys…" : title, reserving: [title, "Press keys…"]).frame(minWidth: 90)
            }
            .help(isActive ? "Click to cancel" : "Click, then press a key combination")
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
                let isActive = recorder.activeIndex != nil
                let title = items.isEmpty ? "Record Key" : "Add Key"
                Button {
                    if isActive {
                        recorder.cancel()
                    } else {
                        recorder.start(index: 0) { commit(items + [["key": $0.key, "modifiers": $0.modifiers]]) }
                    }
                } label: {
                    SteadyLabel(isActive ? "Press a key…" : title, reserving: [title, "Press a key…"])
                }
                .help(isActive ? "Click to cancel" : "Click, then press a key (with any modifier keys)")
            } label: {
                label
            }
            if !items.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 2) {
                            Text(keyCombination(item)?.displayName ?? "?").monospacedDigit()
                            Button {
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

private struct NumberSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let commit: (Double) -> Void

    var body: some View {
        HStack {
            Slider(
                value: Binding(get: { value }, set: { new in
                    let rounded = (new / step).rounded() * step
                    if rounded != value { commit(rounded) }
                }),
                in: range
            )
            .frame(width: 200)
            Text("\(Int(value))")
                .monospacedDigit()
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
            Picker(field.label, selection: Binding(get: { current }, set: { model.set(field.key, $0) })) {
                ForEach(shown, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
        default:
            EmptyView()
        }
    }
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
        // The hidden text sets the width; a little more leaves room for the caret.
        Text(draft.isEmpty ? "0" : draft)
            .hidden()
            .padding(.horizontal, 3)
            .frame(minWidth: 24, alignment: .trailing)
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
        commit(number.rounded() == number && abs(number) < 1e15 ? Int(number) as Any : number as Any)
    }
}

private struct NumberField: View {
    let value: Double
    let min: Double?
    let max: Double?
    let decimals: Bool
    let commit: (Any) -> Void

    var body: some View {
        TextField("", value: Binding(get: { value }, set: save), format: .number.grouping(.never).precision(.fractionLength(0...(decimals ? 3 : 0))))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
    }

    private func save(_ newValue: Double) {
        var clamped = newValue
        if let min { clamped = Swift.max(clamped, min) }
        if let max { clamped = Swift.min(clamped, max) }
        guard clamped != value else { return }
        commit(clamped.rounded() == clamped && abs(clamped) < 1e15 ? Int(clamped) as Any : clamped as Any)
    }
}

/// A plain text editor for code (CSS, JSON, templates): monospaced, without smart quotes or other
/// substitutions, saving when editing ends.
private struct CodeEditor: NSViewRepresentable {
    let text: String
    var height: CGFloat = 120
    var isInvalid = false
    let commit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .lineBorder
        let textView = scrollView.documentView as! NSTextView
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.committed = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.commit = commit
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
        var committed = ""

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

private struct ScanInputsControl: View {
    let key: String
    let values: [String]
    @ObservedObject var model: SettingsModel
    @ObservedObject var recorder: ScanInputRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                ScanInputRow(id: "\(key)#\(index)", value: value, recorder: recorder) { newValue in
                    var updated = values
                    if let newValue { updated[index] = newValue } else { updated.remove(at: index) }
                    model.set(key, updated)
                }
            }
            RecordButton(id: "\(key)#new", title: "Record New Input", recorder: recorder) { model.set(key, values + [$0]) }
            Text(SettingsSchema.scanInputsHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
                Text(isActive ? (recorder.recorded.isEmpty ? "Hold keys or mouse buttons…" : ScanInput.format(recorder.recorded)) : title)
                    .frame(minWidth: 60)
            } else {
                SteadyLabel(isActive ? "Recording…" : title, reserving: [title, "Recording…"]).frame(minWidth: 60)
            }
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : nil)
        .help(isActive ? "Hold the keys and mouse buttons you want to use, then release one. Press Esc to cancel." : "")
    }
}

/// Replacements applied to lines: a row for each, and a field to try them on a sample line.
private struct ReplacementsControl: View {
    let key: String
    @ObservedObject var model: SettingsModel
    @State private var sample = ""
    @State private var showJSON = false

    private var items: [[String: Any]] {
        (model[key] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                ReplacementRow(item: item, isFirst: index == 0, isLast: index == items.count - 1) { change in
                    var updated = items
                    switch change {
                    case let .set(field, value): updated[index][field] = value
                    case let .move(offset): updated.swapAt(index, index + offset)
                    case .remove: updated.remove(at: index)
                    }
                    model.set(key, updated)
                }
            }
            HStack {
                Button("Add Replacement") {
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
    }
}

private struct ReplacementRow: View {
    enum Change {
        case set(String, Any)
        case move(Int)
        case remove
    }

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
    let change: (Change) -> Void

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
        SettingsOption("text-to-speech", "Text-to-speech"),
        SettingsOption("text-to-speech-reading", "Text-to-speech (Kana reading)"),
        SettingsOption("custom", "Custom URL"),
        SettingsOption("custom-json", "Custom URL (JSON)"),
    ]

    private var items: [[String: Any]] {
        (model[key] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                AudioSourceRow(index: index, item: item, isFirst: index == 0, isLast: index == items.count - 1) { change in
                    var updated = items
                    switch change {
                    case let .set(field, value): updated[index][field] = value
                    case let .move(offset): updated.swapAt(index, index + offset)
                    case .remove: updated.remove(at: index)
                    }
                    model.set(key, updated)
                }
            }
            Button("Add Audio Source") {
                model.set(key, items + [["type": unusedType(), "url": "", "voice": ""]])
            }
        }
    }

    /// As in Yomitan: the first of its usual sources that isn't listed yet.
    private func unusedType() -> String {
        let usual = ["jpod101", "jisho", "language-pod-101", "lingua-libre", "wiktionary", "text-to-speech", "custom"]
        let used = Set(items.compactMap { $0["type"] as? String })
        return usual.first { !used.contains($0) } ?? usual[0]
    }
}

private struct AudioSourceRow: View {
    enum Change {
        case set(String, Any)
        case move(Int)
        case remove
    }

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
    let change: (Change) -> Void

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
        // Settings from before an import keep the import's other values (dictionaries, output modes).
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
        let isDefault = templates == nil || templates!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || templates == SettingsSupport.shared.defaultFieldTemplates
        value["fieldTemplates"] = isDefault ? NSNull() : templates!
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
            guard status == 200 else { throw SettingsSupportError(message: "Yomitan API returned an error (HTTP \(status))") }
            let version = (SettingsSupport.decode(body)?["version"]).map { "\($0)" } ?? "?"
            return "Connected (Yomitan \(version))"
        case .anki:
            var request: [String: Any] = ["action": "version", "version": 6]
            if let key = settings["ankiConnectKey"] as? String, !key.isEmpty { request["key"] = key }
            let body: String
            do {
                body = try await post(settings["ankiConnectUrl"] as? String ?? "", body: request).body
            } catch {
                throw SettingsSupportError(message: "Could not connect to Anki (make sure Anki is running with AnkiConnect installed)")
            }
            let result = SettingsSupport.decode(body)
            if let error = result?["error"] as? String { throw SettingsSupportError(message: error) }
            return "Connected (AnkiConnect v\(result?["result"].map { "\($0)" } ?? body))"
        }
    }

    private static func post(_ urlString: String, body: [String: Any]) async throws -> (status: Int, body: String) {
        guard let url = URL(string: urlString), url.scheme != nil else { throw SettingsSupportError(message: "Invalid URL format") }
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
    @Published private(set) var activeIndex: Int?
    private var monitor: Any?
    private var completion: ((KeyCombination) -> Void)?

    func start(index: Int, completion: @escaping (KeyCombination) -> Void) {
        cancel()
        activeIndex = index
        self.completion = completion
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let combination = KeyCombination(event: event) else { return nil }
            let completion = self.completion
            cancel()
            completion?(combination)
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        activeIndex = nil
        completion = nil
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
                        Text("Type")
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
                            characterField(index, "character1")
                            if isQuote {
                                characterField(index, "character2")
                            } else {
                                Text("—").foregroundStyle(.secondary).frame(width: 40)
                            }
                            HStack(spacing: 12) {
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
        SettingsOption("viewNotes", "View notes"),
        SettingsOption("playAudio", "Play audio"),
        SettingsOption("playAudioFromSource", "Play audio from source"),
        SettingsOption("copyHostSelection", "Copy host window selection"),
        SettingsOption("toggleOption", "Toggle option"),
    ]

    /// An action's argument when it's chosen, as in Yomitan.
    static func defaultArgument(_ action: String) -> String {
        switch action {
        case "nextEntry", "previousEntry": "1"
        case "addNote", "viewNotes": "0"
        case "playAudioFromSource": "jpod101"
        default: ""
        }
    }

    private var items: [[String: Any]] {
        (model[key] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HotkeyRow(index: index, item: item, isDuplicate: isDuplicate(index), recorder: recorder) { change in
                    var updated = items
                    switch change {
                    case let .set(values): updated[index].merge(values) { _, new in new }
                    case .remove: updated.remove(at: index)
                    }
                    model.set(key, updated)
                }
            }
            HStack {
                Button("Add Shortcut") {
                    model.set(key, items + [["action": "close", "argument": "", "key": "", "modifiers": [String](), "enabled": true]])
                }
                Button("Reset to Defaults") { confirmingReset = true }
            }
            .padding(.top, 8)
        }
        .onDisappear { recorder.cancel() }
        .confirmationDialog("Replace all keyboard shortcuts with Yomitan’s defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.set(key, SettingsSupport.shared.defaults[key] ?? [Any]()) }
        }
    }

    private static func combination(_ item: [String: Any]) -> KeyCombination? {
        guard let key = item["key"] as? String, !key.isEmpty else { return nil }
        return KeyCombination(key: key, modifiers: item["modifiers"] as? [String] ?? [])
    }

    /// Whether an enabled shortcut above has the same keys (only the first one works).
    private func isDuplicate(_ index: Int) -> Bool {
        guard items[index]["enabled"] as? Bool ?? true, let combination = Self.combination(items[index]) else { return false }
        return items[..<index].contains { ($0["enabled"] as? Bool ?? true) && Self.combination($0) == combination }
    }
}

private struct HotkeyRow: View {
    enum Change {
        case set([String: Any])
        case remove
    }

    let index: Int
    let item: [String: Any]
    let isDuplicate: Bool
    @ObservedObject var recorder: ShortcutRecorder
    let change: (Change) -> Void

    /// MacPopup's on/off settings, for "Toggle option".
    private static let toggleOptions: [SettingsOption] = SettingsSchema.sections.flatMap { section in
        section.fields.compactMap { field in
            switch field.kind {
            case .checkbox: SettingsOption(field.key, "\(section.title): \(field.label)")
            case let .toggleChoice(_, on): SettingsOption(field.key, "\(section.title): \(on)")
            default: nil
            }
        }
    }

    private var action: String { item["action"] as? String ?? "" }
    private var argument: String { item["argument"] as? String ?? "" }

    private var combination: KeyCombination? {
        guard let key = item["key"] as? String, !key.isEmpty else { return nil }
        return KeyCombination(key: key, modifiers: item["modifiers"] as? [String] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { item["enabled"] as? Bool ?? true }, set: { change(.set(["enabled": $0])) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Enabled")
                recordButton
                let actions = HotkeysControl.actions.contains { $0.value == action }
                    ? HotkeysControl.actions : HotkeysControl.actions + [SettingsOption(action)]
                Picker("", selection: Binding(get: { action }, set: { change(.set(["action": $0, "argument": HotkeysControl.defaultArgument($0)])) })) {
                    ForEach(actions, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
                argumentControl
                Spacer()
                Button { change(.remove) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
            if isDuplicate {
                Text("Already used by an earlier shortcut, which takes priority.").font(.caption).foregroundStyle(.red)
            } else if let combination, combination.keyCode == nil {
                Text("\(combination.key) isn’t a key MacPopup can use.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var recordButton: some View {
        let isActive = recorder.activeIndex == index
        return Button {
            if isActive {
                recorder.cancel()
            } else {
                recorder.start(index: index) { combination in
                    change(.set(["key": combination.key, "modifiers": combination.modifiers]))
                }
            }
        } label: {
            let title = combination?.displayName ?? "Record Shortcut"
            SteadyLabel(isActive ? "Press keys…" : title, reserving: [title, "Press keys…"]).frame(minWidth: 90)
        }
        .help(isActive ? "Click to cancel" : "Click, then press a key combination")
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
        case "addNote", "viewNotes":
            let index = Int(argument) ?? 0
            Picker("", selection: Binding(get: { index }, set: { change(.set(["argument": String($0)])) })) {
                ForEach(0..<max(6, index + 1), id: \.self) { Text("Card format \($0 + 1)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Card formats from your active Yomitan profile, in order")
        case "playAudioFromSource":
            let types = AudioSourcesControl.types.contains { $0.value == argument }
                ? AudioSourcesControl.types : AudioSourcesControl.types + [SettingsOption(argument)]
            Picker("", selection: Binding(get: { argument }, set: { change(.set(["argument": $0])) })) {
                ForEach(types, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
        case "toggleOption":
            let options = Self.toggleOptions.contains { $0.value == argument }
                ? Self.toggleOptions : [SettingsOption(argument, argument.isEmpty ? "Choose a setting" : "\(argument) (not a MacPopup setting)")] + Self.toggleOptions
            Picker("", selection: Binding(get: { argument }, set: { change(.set(["argument": $0])) })) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            // Setting labels can be long; a fixed width keeps the row inside the window.
            .frame(width: 240)
        default:
            EmptyView()
        }
    }
}
