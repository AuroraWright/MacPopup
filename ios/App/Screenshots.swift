import Photos
import SwiftUI

/// The latest screenshots in Photos. They need full access: with limited access, only the photos the user picked are
/// seen, so new screenshots aren't.
@MainActor
final class Screenshots: ObservableObject {
    static let shared = Screenshots()

    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var latest: [PHAsset] = []

    private let changes = LibraryChanges()

    private init() {
        changes.onChange = { Task { @MainActor in Screenshots.shared.refresh() } }
    }

    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            latest = []
            return
        }
        changes.register()
        latest = Self.latest(24)
    }

    func requestAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    nonisolated static func latest(_ count: Int) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = count
        let result = PHAsset.fetchAssets(with: .image, options: options)
        return result.objects(at: IndexSet(integersIn: 0..<result.count))
    }

    /// The newest screenshot's file, for "Read Latest Screenshot".
    nonisolated static func newest() async throws -> Data {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: break
        case .limited: throw AppError("MacPopup can only see the photos you picked. Allow full access to Photos in Settings → Apps → MacPopup.")
        default: throw AppError("MacPopup can’t see your screenshots. Allow full access to Photos in the app, or in Settings → Apps → MacPopup.")
        }
        guard let asset = latest(1).first else { throw AppError("There are no screenshots in Photos.") }
        return try await data(asset)
    }

    /// The screenshot's file as shown (with its edits), downloaded from iCloud if needed.
    nonisolated static func data(_ asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? AppError("Couldn’t load the screenshot."))
                }
            }
        }
    }
}

/// Tells when Photos changes (e.g. a screenshot is taken while the app is open).
private final class LibraryChanges: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    var onChange: () -> Void = {}
    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

/// The screenshots section: why it needs Photos access before asking for it, then the latest screenshots.
struct ScreenshotsSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var screenshots = Screenshots.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            switch screenshots.status {
            case .notDetermined:
                Text("MacPopup can show your latest screenshots here, and read the newest one from a Shortcut (Back Tap, the Action button) or Control Center. For that it needs to see your photos: choose “Allow Full Access” when iOS asks, since with limited access new screenshots stay hidden. Photos never leave your iPhone.")
                    .font(.callout)
                Button("Continue") {
                    Task { await screenshots.requestAccess() }
                }
            case .authorized, .limited:
                if screenshots.status == .limited {
                    Text("MacPopup can only see the photos you picked, so new screenshots don’t appear. Allow full access to Photos in Settings.")
                        .font(.callout)
                    settingsButton
                }
                if screenshots.latest.isEmpty {
                    Text("No screenshots yet.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                        ForEach(screenshots.latest, id: \.localIdentifier) { asset in
                            Button {
                                Task { await read(asset) }
                            } label: {
                                ScreenshotThumbnail(asset: asset)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            default:
                Text("MacPopup can’t see your photos. To read your latest screenshots, allow full access to Photos in Settings.")
                    .font(.callout)
                settingsButton
            }
        } header: {
            Text("Screenshots")
        }
    }

    private var settingsButton: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }

    private func read(_ asset: PHAsset) async {
        do {
            await model.choose(try await Screenshots.data(asset))
        } catch {
            model.error = error.localizedDescription
        }
    }
}

struct ScreenshotThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(0.6, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                image = await thumbnail()
            }
    }

    private func thumbnail() async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let size = CGSize(width: 240, height: 400)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
