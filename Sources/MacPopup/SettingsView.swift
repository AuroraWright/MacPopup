import AVFoundation
import AppKit
import SwiftUI

/// What the Settings window asks of the app.
@MainActor
struct SettingsActions {
    var selectOCRWindow: () -> Void
    var importYomitan: () -> Void
    var importTexthooker: () -> Void
    var resetAll: () -> Void
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
                    .help("Yomitan: Settings → Backup → Export Settings. texthooker-ui: its settings export.")
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
                        Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .formStyle(.grouped)
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
                FieldLabel(field: field)
                wideControl
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
        case let .number(min, max, step):
            LabeledContent {
                NumberField(value: (value as? NSNumber)?.doubleValue ?? 0, min: min, max: max, decimals: step.map { $0 < 1 } ?? false) {
                    model.set(field.key, $0)
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
        case let .select(options, match):
            let stored = value as? String ?? ""
            let current = options.contains { $0.value == stored } ? stored : match?(stored) ?? stored
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
                    }
                }
                .frame(maxWidth: 320)
            } label: {
                FieldLabel(field: field)
            }
        case let .imported(describe, emptyText, details):
            let items = value as? [Any] ?? []
            LabeledContent {
                HStack {
                    Text(items.isEmpty ? emptyText : describe(items))
                        .foregroundStyle(.secondary).multilineTextAlignment(.leading).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .help("Use the whole screen")
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
        case .ankiTemplates:
            AnkiTemplatesControl(key: field.key, model: model)
        default:
            EmptyView()
        }
    }

    private var ocrWindowDescription: String {
        guard let window = value as? [String: Any], let owner = window["ownerName"] as? String else { return "None (whole screen)" }
        let title = window["title"] as? String ?? ""
        let name = title.isEmpty ? owner : "\(owner) — \(title)"
        let regions = (model["ocrRegions"] as? [Any] ?? []).count
        return "\(name) (\(regions == 0 ? "whole window" : "\(regions) area\(regions == 1 ? "" : "s")"))"
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
            return offset == 0 ? "\(name), main" : name
        }
    }

    var body: some View {
        Picker(selection: Binding(get: { index }, set: commit)) {
            ForEach(displays.indices, id: \.self) { Text(displays[$0]).tag($0) }
            // Kept until another is chosen: the overlay goes back to it when it's connected again.
            if !displays.indices.contains(index) {
                Text("Display \(index + 1) (not connected)").tag(index)
            }
        } label: {
            label
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Self.connectedDisplays()
        }
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
                    error = "Not saved: this isn’t a valid JSON array."
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

private struct TestButton: View {
    let test: SettingsField.ConnectionTest
    @ObservedObject var model: SettingsModel
    @State private var status: (text: String, ok: Bool)?
    @State private var running = false

    var body: some View {
        Button(running ? "Testing…" : "Test") {
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
                CommitTextField(value: value, placeholder: "hover", monospaced: true, bordered: true) { text in
                    let names = ScanInput.parse(text)
                    invalid = names.filter { !ScanInput.isValidName($0) }
                    if invalid.isEmpty { change(ScanInput.format(names)) }
                }
                RecordButton(id: id, title: "Record", recorder: recorder) { change($0) }
                Button {
                    change(nil)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            if !invalid.isEmpty {
                Text("Not supported by Yomitan scan inputs: \(invalid.joined(separator: ", "))").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct RecordButton: View {
    let id: String
    let title: String
    @ObservedObject var recorder: ScanInputRecorder
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
            Text(isActive ? (recorder.recorded.isEmpty ? "Press modifiers or buttons…" : ScanInput.format(recorder.recorded)) : title)
                .frame(minWidth: 60)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : nil)
        .help(isActive ? "Hold the keys and buttons, then release one. Esc cancels." : "")
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
                TextField("Try a line", text: $sample, prompt: Text("Try a line"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if !sample.isEmpty {
                    let result = SettingsSupport.shared.previewReplacements(sample, replacements: items)
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        Text(result.isEmpty ? "(empty: the line isn’t shown)" : result)
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
        ("g", "Global: replace every match, not just the first"),
        ("i", "Ignore case"),
        ("m", "Multiline: ^ and $ match at line breaks"),
        ("s", "Dot all: . matches line breaks too"),
        ("u", "Unicode: \\u{…}, \\p{…} and characters outside the BMP"),
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
                    CommitTextField(value: pattern, placeholder: "Pattern", monospaced: true, bordered: true) { change(.set("pattern", $0)) }
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
                    Text("Skipped: \(error)").font(.caption).foregroundStyle(.red)
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
        SettingsOption("text-to-speech", "Text-to-speech ⚠️"),
        SettingsOption("text-to-speech-reading", "Text-to-speech (Kana reading) ⚠️"),
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
                        placeholder: type == "custom" ? "URL of the audio" : "URL of the list of audio",
                        monospaced: true,
                        bordered: true
                    ) { change(.set("url", $0.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    Text(type == "custom"
                        ? "{term}, {reading} and {language} are replaced by the word, its reading and its language (ja)."
                        : "{term}, {reading} and {language} are replaced as for Custom URL. The URL returns {\"type\": \"audioSourceList\", \"audioSources\": [{\"url\", \"name\"}]}, e.g. a local audio server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case "text-to-speech", "text-to-speech-reading":
                    let voice = item["voice"] as? String ?? ""
                    let voices = Self.voices.contains { $0.value == voice } ? Self.voices : Self.voices + [SettingsOption(voice)]
                    Picker("Voice", selection: Binding(get: { voice }, set: { change(.set("voice", $0)) })) {
                        ForEach(voices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .fixedSize()
                    Text("Not supported in Anki: text-to-speech can be played, but not added to cards.")
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
                Text(fieldTemplates == nil ? "Yomitan’s default templates." : "Custom templates.").font(.caption).foregroundStyle(.secondary)
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
            guard status == 200 else { throw SettingsSupportError(message: "Yomitan API /yomitanVersion failed (\(status))") }
            let version = (SettingsSupport.decode(body)?["version"]).map { "\($0)" } ?? "?"
            return "Connected (Yomitan \(version))"
        case .anki:
            var request: [String: Any] = ["action": "version", "version": 6]
            if let key = settings["ankiConnectKey"] as? String, !key.isEmpty { request["key"] = key }
            let body: String
            do {
                body = try await post(settings["ankiConnectUrl"] as? String ?? "", body: request).body
            } catch {
                throw SettingsSupportError(message: "Anki not connected")
            }
            let result = SettingsSupport.decode(body)
            if let error = result?["error"] as? String { throw SettingsSupportError(message: error) }
            return "Connected (AnkiConnect v\(result?["result"].map { "\($0)" } ?? body))"
        }
    }

    private static func post(_ urlString: String, body: [String: Any]) async throws -> (status: Int, body: String) {
        guard let url = URL(string: urlString), url.scheme != nil else { throw SettingsSupportError(message: "Invalid URL") }
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
            if case .checkbox = field.kind { SettingsOption(field.key, "\(section.title): \(field.label)") } else { nil }
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
                Text("The same keys as a shortcut above, which is used instead.").font(.caption).foregroundStyle(.red)
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
            Text(isActive ? "Press keys…" : combination?.displayName ?? "Record Shortcut")
                .frame(minWidth: 90)
        }
        .help(isActive ? "Click to cancel" : "Click, then press the shortcut")
    }

    @ViewBuilder
    private var argumentControl: some View {
        switch action {
        case "nextEntry", "previousEntry":
            let count = Int(argument) ?? 1
            HStack(spacing: 2) {
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
            .help("The card formats of the Yomitan profile, in their order")
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
