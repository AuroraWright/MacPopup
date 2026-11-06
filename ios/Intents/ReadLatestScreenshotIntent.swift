import AppIntents
import Foundation
import UIKit

/// Reads the newest screenshot in Photos and opens the reading in Safari. Also the Control Center control's action
/// (Controls/), so it's in both targets. A control runs a plain AppIntent in its extension, where it can't read or open
/// anything; as a LiveActivityIntent it runs in the app, in the background (no Live Activity is started).
struct ReadLatestScreenshotIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Read Latest Screenshot"
    static let description = IntentDescription(
        "Reads the text in your newest screenshot with MacPopup and opens the reading in Safari, where your dictionary extension looks it up."
    )

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        IntentLog.append("Read Latest Screenshot: started")
        return .result(opensIntent: OpenURLIntent(try await Self.page()))
    }

    @MainActor
    private static func page() async throws -> URL {
        #if CONTROLS_EXTENSION
        throw AppError("Open MacPopup to read your latest screenshot.")
        #else
        do {
            let url = try await AppModel.shared.pageForIntent(try await Screenshots.newest())
            IntentLog.append("Read Latest Screenshot: opening \(url.absoluteString), app state \(UIApplication.shared.applicationState.rawValue)")
            return url
        } catch {
            IntentLog.append("Read Latest Screenshot: failed: \(error.localizedDescription)")
            throw error
        }
        #endif
    }
}
