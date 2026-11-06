import AppIntents
import Foundation
import UIKit

/// For Back Tap or the Action button: a Shortcut with Take Screenshot, then this. The image comes from the action
/// before it without wiring it, and it opens the page itself. It runs with the app in the background.
struct ReadImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Image"
    static let description = IntentDescription(
        "Reads the text in an image with MacPopup and opens the reading in Safari, where your dictionary extension looks it up. Put it after Take Screenshot to read what’s on the screen."
    )

    @Parameter(title: "Image", supportedContentTypes: [.image], inputConnectionBehavior: .connectToPreviousIntentResult)
    var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & OpensIntent {
        IntentLog.append("Read Image: started")
        do {
            let url = try await AppModel.shared.pageForIntent(image.data)
            IntentLog.append("Read Image: opening \(url.absoluteString), app state \(UIApplication.shared.applicationState.rawValue)")
            return .result(value: url, opensIntent: OpenURLIntent(url))
        } catch {
            IntentLog.append("Read Image: failed: \(error.localizedDescription)")
            throw error
        }
    }
}

struct MacPopupShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReadLatestScreenshotIntent(),
            phrases: ["Read my latest screenshot with \(.applicationName)", "Read screenshot with \(.applicationName)"],
            shortTitle: "Read Latest Screenshot",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: ReadImageIntent(),
            phrases: ["Read image with \(.applicationName)"],
            shortTitle: "Read Image",
            systemImageName: "photo"
        )
    }
}

extension AppModel {
    /// Reads a picture for a Shortcuts action or the control: the page's URL, served while Safari opens it.
    func pageForIntent(_ data: Data) async throws -> URL {
        guard let picture = await Self.picture(data) else { throw AppError("This file isn’t a picture that can be read.") }
        let url = PageServer.url(try await reading(picture))
        serve()
        return url
    }
}
