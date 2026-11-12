import Combine
import SwiftUI

// Settings for game controllers (see Gamepads.swift): learning them, and recording button combinations.

/// The connected controllers and those learned before, each with a button to learn it, and the learning in progress.
struct GamepadsControl: View {
    @ObservedObject private var gamepads = GamepadController.shared

    private struct Row: Identifiable {
        let id: String
        let name: String
        let isConnected: Bool
        let layout: GamepadLayout?
    }

    private var rows: [Row] {
        let connected = gamepads.connected.map { Row(id: $0.id, name: $0.name, isConnected: true, layout: gamepads.layouts[$0.id]) }
        let others = gamepads.layouts.filter { key, _ in !connected.contains { $0.id == key } }.sorted { $0.key < $1.key }
            .map { Row(id: $0.key, name: $0.value.name, isConnected: false, layout: $0.value) }
        return connected + others
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let learning = gamepads.learning {
                GamepadLearningPanel(learning: learning)
            } else if rows.isEmpty {
                Text("No controllers connected. Connect one via Bluetooth or USB.").foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: "gamecontroller").foregroundStyle(row.isConnected ? .primary : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text(status(row)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if row.layout != nil {
                            Button("Forget") { gamepads.setLayout(nil, for: row.id) }
                        }
                        Button(row.layout == nil ? "Set Up…" : "Set Up Again…") { gamepads.startLearning(key: row.id) }
                            .disabled(!row.isConnected)
                    }
                }
            }
        }
        .onAppear { gamepads.retain() }
        .onDisappear {
            gamepads.stopLearning(save: false)
            gamepads.release()
        }
    }

    private func status(_ row: Row) -> String {
        guard row.layout != nil else { return "Not set up yet—MacPopup won’t use it until it’s set up" }
        return row.isConnected ? "Ready" : "Ready · Not connected"
    }
}

/// Learning a controller: which of its controls are learned, and a button for each to learn it from one press.
private struct GamepadLearningPanel: View {
    let learning: GamepadController.Learning
    @ObservedObject private var gamepads = GamepadController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setting Up \(learning.name)").font(.headline)
            Text(
                learning.hasGameController
                    ? "Press each button, D-pad direction and trigger a few times, one at a time, then push each stick all the way in every direction. A check mark appears next to each control MacPopup has picked up. If one stays unchecked, click its Learn button and press it once."
                    : "macOS doesn’t recognize this controller’s buttons, so set them up one at a time: click Learn next to a control, then press it on the controller."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(learning.controls, id: \.self) { control in
                    let isLearned = learning.learned[control] != nil || learning.pressedOnce[control] != nil
                    let isWaiting = learning.waitingFor == control
                    HStack(spacing: 6) {
                        Image(systemName: isLearned ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isLearned ? Color.green : Color.secondary)
                        Text(control).fontWeight(learning.held.contains(control) ? .semibold : .regular)
                        Spacer(minLength: 4)
                        Button(isWaiting ? "Press Now…" : "Learn") {
                            if isWaiting { gamepads.cancelPress() } else { gamepads.learnPress(control) }
                        }
                        .controlSize(.small)
                        .help(isWaiting ? "Press this control on the controller now, or click to cancel" : "Click, then press this control once on the controller")
                    }
                }
            }
            HStack {
                Button("Done") { gamepads.stopLearning(save: true) }.keyboardShortcut(.defaultAction)
                Button("Cancel") { gamepads.stopLearning(save: false) }
            }
            .padding(.top, 4)
        }
    }
}

extension Notification.Name {
    /// Posted by a Settings recorder (keys or controller buttons) as it starts, with itself as the object: the others
    /// cancel theirs, so only one records at a time.
    static let settingsRecordingStarted = Notification.Name("MacPopupSettingsRecordingStarted")
}

/// Records a combination of controller buttons: the buttons held together, once they're all let go. D-pad and stick
/// directions don't count (they move between words).
@MainActor
final class GamepadComboRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// The buttons held so far.
    @Published private(set) var held: Set<String> = []
    private var subscription: AnyCancellable?
    private var completion: (([String]) -> Void)?
    private var othersStarting: AnyCancellable?

    init() {
        othersStarting = NotificationCenter.default.publisher(for: .settingsRecordingStarted).sink { [weak self] note in
            MainActor.assumeIsolated {
                if note.object as AnyObject? !== self { self?.cancel() }
            }
        }
    }

    func start(completion: @escaping ([String]) -> Void) {
        cancel()
        NotificationCenter.default.post(name: .settingsRecordingStarted, object: self)
        let gamepads = GamepadController.shared
        gamepads.retain()
        gamepads.beginRecording()
        isRecording = true
        held = []
        self.completion = completion
        subscription = gamepads.$pressed.dropFirst().sink { [weak self] pressed in
            guard let self else { return }
            let buttons = pressed.filter { !GamepadControls.isDirection($0) }
            if buttons.isEmpty, !held.isEmpty {
                let combination = held.sorted()
                let completion = self.completion
                cancel()
                completion?(combination)
            } else {
                held.formUnion(buttons)
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        subscription = nil
        completion = nil
        isRecording = false
        held = []
        GamepadController.shared.endRecording()
        GamepadController.shared.release()
    }
}

/// How a combination is shown, e.g. "LB + A".
func gamepadComboName(_ buttons: [String]) -> String {
    buttons.map(GamepadControls.shortName).joined(separator: " + ")
}

/// A button that records a controller combination (see GamepadComboRecorder), once a controller is set up.
struct GamepadComboButton: View {
    let buttons: [String]
    let commit: ([String]) -> Void
    @StateObject private var recorder = GamepadComboRecorder()
    @ObservedObject private var gamepads = GamepadController.shared

    var body: some View {
        let title = buttons.isEmpty ? "Record Buttons" : gamepadComboName(buttons)
        let recording = recorder.held.isEmpty ? "Press buttons…" : gamepadComboName(recorder.held.sorted())
        Button {
            if recorder.isRecording {
                recorder.cancel()
            } else {
                recorder.start(completion: commit)
            }
        } label: {
            SteadyLabel(recorder.isRecording ? recording : title, reserving: [title, "Press buttons…"]).frame(minWidth: 90)
        }
        .help(
            gamepads.layouts.isEmpty
                ? "Set up a controller in Settings → Controllers first"
                : recorder.isRecording ? "Hold the buttons together, then let go. Click to cancel." : "Click, then press a button combination on your game controller"
        )
        .disabled(gamepads.layouts.isEmpty && !recorder.isRecording)
        .onDisappear { recorder.cancel() }
    }
}

/// A controller combination setting, with a button to clear it.
struct GamepadComboControl: View {
    let buttons: [String]
    let commit: ([String]) -> Void

    var body: some View {
        HStack {
            GamepadComboButton(buttons: buttons, commit: commit)
            Button("Clear") { commit([]) }.disabled(buttons.isEmpty)
        }
    }
}
