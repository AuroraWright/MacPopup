import AppIntents
import SwiftUI
import WidgetKit

@main
struct Controls: WidgetBundle {
    var body: some Widget {
        ReadScreenshotControl()
    }
}

/// A Control Center (and Lock Screen, Action button) button: reads the newest screenshot and opens it in Safari.
struct ReadScreenshotControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.aury.macpopup.ios.read-latest-screenshot") {
            ControlWidgetButton(action: ReadLatestScreenshotIntent()) {
                Label("Read Screenshot", systemImage: "text.viewfinder")
            }
        }
        .displayName("Read Latest Screenshot")
        .description("Reads your newest screenshot and opens it in Safari.")
    }
}
