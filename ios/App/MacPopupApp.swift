import ImageIO
import OCREngines
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct MacPopupApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { model.launched() }
                .onOpenURL { url in
                    if url == Inbox.readURL { Task { await model.readShared() } }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        PageServer.shared.start()
                        model.refresh()
                        Screenshots.shared.refresh()
                        Continuous.shared.appBecameActive()
                        Task { await model.readShared() }
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var photo: PhotosPickerItem?
    @State private var importsFile = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        importsFile = true
                    } label: {
                        Label("Choose File", systemImage: "folder")
                    }
                    PasteButton(supportedContentTypes: [.image]) { providers in
                        Task { await paste(providers) }
                    }
                }
                Section {
                    NavigationLink("Continuous Reading") { ContinuousView() }
                }
                ScreenshotsSection()
                Section {
                    if model.readings.isEmpty {
                        Text("Readings open in Safari, where your dictionary extension looks up their text.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.readings) { reading in
                        Button {
                            model.open(PageServer.url(reading))
                        } label: {
                            ReadingRow(reading: reading)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        model.delete(Set(offsets.map { model.readings[$0].id }))
                    }
                } header: {
                    HStack {
                        Text("Readings")
                        Spacer()
                        if !model.readings.isEmpty {
                            Button("Open in Safari") { model.open(PageServer.home) }
                                .font(.footnote)
                                .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("MacPopup")
            .toolbar {
                Button {
                    showsSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            .overlay {
                if model.isReading {
                    ProgressView("Reading…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .disabled(model.isReading)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView().environmentObject(model)
        }
        .fullScreenCover(item: $model.cropping) { request in
            NavigationStack {
                CropView(picture: request.picture) { part in
                    Task { await model.read(request.picture.cropped(to: part)) }
                }
            }
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    model.error = "Couldn’t open \(url.lastPathComponent)."
                    return
                }
                await model.choose(data)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    model.error = "Couldn’t open the photo."
                    return
                }
                await model.choose(data)
            }
        }
        .alert("Couldn’t read the picture", isPresented: Binding { model.error != nil } set: { if !$0 { model.error = nil } }) {
            Button("OK") {}
        } message: {
            Text(model.error ?? "")
        }
    }

    private func paste(_ providers: [NSItemProvider]) async {
        guard let provider = providers.first else { return }
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in continuation.resume(returning: data) }
        }
        guard let data else {
            model.error = "Couldn’t paste the picture."
            return
        }
        await model.choose(data)
    }
}

struct ReadingRow: View {
    let reading: Reading
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Color(.secondarySystemFill)
                .frame(width: 56, height: 56)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.text.isEmpty ? "No text found" : reading.text)
                    .lineLimit(2)
                    .foregroundStyle(reading.text.isEmpty ? .secondary : .primary)
                Text(reading.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .task(id: reading.id) {
            let url = reading.imageFile
            thumbnail = await Task.detached { Self.thumbnail(url) }.value
        }
    }

    private nonisolated static func thumbnail(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 168,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.engine) private var engine = Engine.liveText.rawValue
    @AppStorage(SettingsKey.language) private var language = "ja"
    @AppStorage(SettingsKey.stripsFurigana) private var stripsFurigana = true
    @AppStorage(SettingsKey.cropsPictures) private var cropsPictures = false
    @State private var confirmsDeletingAll = false
    /// The engine picker lists Screen AI and OneOCR once their models are loaded.
    @ObservedObject private var screenAIModels = ConvertedModelsStatus.shared(.screenAI)
    @ObservedObject private var oneOCRModels = ConvertedModelsStatus.shared(.oneOCR)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $engine) {
                        ForEach(Engine.allCases.filter(\.isAvailable)) { Text($0.name).tag($0.rawValue) }
                    }
                } header: {
                    Text("Text recognition")
                } footer: {
                    Text(engineHint)
                }
                ImportedModelsSection()
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(model.languages, id: \.iso) { Text($0.name).tag($0.iso) }
                    }
                    if language == "ja" {
                        Toggle("Ignore furigana", isOn: $stripsFurigana)
                    }
                } footer: {
                    Text("Lines without the language’s characters are left out. Ignoring furigana skips small kana readings above or beside kanji.")
                }
                Section {
                    Toggle("Crop before reading", isOn: $cropsPictures)
                } footer: {
                    Text("Pictures chosen in the app (not from Shortcuts, Control Center or the share sheet) open in a crop view first, to read only part of them.")
                }
                Section {
                    Button("Delete All Readings…", role: .destructive) { confirmsDeletingAll = true }
                        .disabled(model.readings.isEmpty)
                } footer: {
                    Text("To delete one, swipe it left in the list.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .onChange(of: engine) {
            Task { await model.prepareEngine() }
        }
        .confirmationDialog("Delete all \(model.readings.count) readings?", isPresented: $confirmsDeletingAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { model.delete(Set(model.readings.map(\.id))) }
        } message: {
            Text("Their pictures are deleted too.")
        }
    }

    private var engineHint: String {
        var hint = "Live Text is built into iOS. meikiocr (by rtr46) is fast and specialized for Japanese game text. PP-OCRv6 Manga (by Kellenok) is specialized for Japanese and Chinese manga. Screen AI and OneOCR appear once their models are loaded below."
        if !OCRLanguage.isRead(language, by: engine) {
            let name = model.languages.first { $0.iso == language }?.name ?? language
            hint += "\n\n\(name) isn’t supported by this engine: "
                + (engine == Engine.liveText.rawValue ? "Live Text will only recognize English."
                    : engine == Engine.meikiocr.rawValue ? "meikiocr only recognizes Japanese." : "PP-OCRv6 Manga only recognizes Japanese and Chinese.")
        }
        return hint
    }
}
