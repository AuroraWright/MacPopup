import ImageIO
import UIKit
import UniformTypeIdentifiers

/// "MacPopup" in the share sheet: puts the picture in the App Group's inbox and opens the app to read it, since the
/// extension hasn't the memory for the engines. Extensions can't open apps through public API, so it uses
/// UIApplication reached with NSClassFromString, then LSApplicationWorkspace; if neither works, the app reads the
/// inbox the next time it's opened.
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.text = "Sending to MacPopup…"
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await share() }
    }

    private func share() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        do {
            try Inbox.put(try await pictureData(providers))
        } catch {
            IntentLog.append("Share: failed: \(error.localizedDescription)")
            return fail(error.localizedDescription)
        }
        if await openThroughApplication(Inbox.readURL) || openThroughWorkspace(Inbox.readURL) {
            IntentLog.append("Share: opened the app")
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            IntentLog.append("Share: couldn't open the app")
            fail("Open MacPopup to read the picture.")
        }
    }

    private func fail(_ message: String) {
        spinner.stopAnimating()
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The picture when it's shared itself (Photos, Files), else the picture a shared URL points to: Safari shares only
    /// the image's URL when an image is long-pressed.
    private func pictureData(_ providers: [NSItemProvider]) async throws -> Data {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? AppError("Couldn’t load the picture."))
                    }
                }
            }
        }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) else {
            throw AppError("There’s no picture to read.")
        }
        let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        guard let url = (item as? URL) ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) else {
            throw AppError("There’s no picture to read.")
        }
        let data = url.isFileURL ? try Data(contentsOf: url) : try await URLSession.shared.data(from: url).0
        // Checked without decoding it (the extension's memory is small).
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw AppError("This isn’t a picture: share an image, or long-press it in Safari and share that.")
        }
        return data
    }

    /// UIApplication.sharedApplication's openURL:options:completionHandler:, which extensions aren't given.
    private func openThroughApplication(_ url: URL) async -> Bool {
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type,
              let application = applicationClass.value(forKey: "sharedApplication") as? NSObject
        else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard application.responds(to: selector) else { return false }
        typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let open = unsafeBitCast(application.method(for: selector), to: Open.self)
        return await withCheckedContinuation { continuation in
            open(application, selector, url as NSURL, [:] as NSDictionary) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    /// LSApplicationWorkspace's openURL:.
    private func openThroughWorkspace(_ url: URL) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return false }
        let selector = NSSelectorFromString("openURL:")
        guard workspace.responds(to: selector) else { return false }
        typealias Open = @convention(c) (NSObject, Selector, NSURL) -> Bool
        let open = unsafeBitCast(workspace.method(for: selector), to: Open.self)
        return open(workspace, selector, url as NSURL)
    }
}
