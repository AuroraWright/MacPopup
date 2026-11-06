import OCREngines
import SwiftUI
import UIKit

extension Engine {
    /// The converted models it runs on, for the engines whose models can't come with the app.
    var convertedModels: ConvertedModelsKind? {
        switch self {
        case .screenAI: .screenAI
        case .oneOCR: .oneOCR
        default: nil
        }
    }
}

/// Settings' rows for Screen AI's and OneOCR's models: the same zips MacPopup for Mac loads, made by its scripts on a
/// Mac, loaded from Files and compiled on the iPhone.
struct ImportedModelsSection: View {
    var body: some View {
        Section {
            ForEach(ConvertedModelsKind.allCases, id: \.self) { kind in
                ImportedModelsRow(status: ConvertedModelsStatus.shared(kind))
            }
        } header: {
            Text("Imported engines")
        } footer: {
            Text("Screen AI (Chrome’s OCR) and OneOCR (the Windows Snipping Tool’s) recognize most languages automatically. Their models can’t come with MacPopup: make the .zip on a Mac with scripts/convert-screenai.py or scripts/convert-oneocr.py (the same file MacPopup for Mac loads), put it in Files (iCloud Drive, AirDrop), then load it here.")
        }
    }
}

private struct ImportedModelsRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var status: ConvertedModelsStatus
    @AppStorage(SettingsKey.engine) private var engine = Engine.liveText.rawValue
    @State private var importing = false
    @State private var confirmsRemoval = false
    @State private var error: String?

    private var kind: ConvertedModelsKind { status.kind }

    /// As MacPopup for Mac's (ConvertedModelsControl): whether they're loaded, then Load… and Remove on the right.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(kind.name)
                Spacer()
                // The status's words when they fit (a narrow iPhone may only have room for its icon).
                ViewThatFits {
                    controls.labelStyle(.titleAndIcon)
                    controls.labelStyle(.iconOnly)
                }
            }
            if status.busy {
                Text("Loading and compiling the models… This takes a minute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            Task { await install(url) }
        }
        .confirmationDialog("Remove \(kind.name)’s models?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("You can load them again from the .zip.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if status.converted != nil {
                Label("Loaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Not loaded", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            Button("Load…") { importing = true }
                .disabled(status.busy)
            Button("Remove", role: .destructive) { confirmsRemoval = true }
                .disabled(status.busy || status.converted == nil)
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private func install(_ url: URL) async {
        error = nil
        status.busy = true
        // Keeps going for a while if the app is left (compiling takes long).
        let task = UIApplication.shared.beginBackgroundTask(withName: "Load \(kind.name)")
        defer {
            UIApplication.shared.endBackgroundTask(task)
            status.busy = false
            status.refresh()
        }
        // A copy, since the file picker's access ends with this scope.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            self.error = "Couldn’t open \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        if model.loadedEngineModels == kind { await model.unloadEngine() }
        do {
            try await kind.store.installModels(from: copy)
            IntentLog.append("Loaded \(kind.name)’s models from \(url.lastPathComponent)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        error = nil
        status.busy = true
        defer {
            status.busy = false
            status.refresh()
        }
        if model.loadedEngineModels == kind { await model.unloadEngine() }
        if Engine(rawValue: engine)?.convertedModels == kind { engine = Engine.liveText.rawValue }
        do {
            try await kind.store.removeModels()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
