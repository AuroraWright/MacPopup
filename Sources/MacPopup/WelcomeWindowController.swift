import AppKit
import SwiftUI

/// Shown at the first launch: whether the Yomitan API answers, with where to install it, and the macOS permissions
/// (as in Settings → Permissions).
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private static let shownKey = "welcomeShown"
    private let yomitanAPI: YomitanAPIStatus
    private let openSettings: (_ section: String) -> Void
    private var window: NSWindow?

    /// No settings saved yet, and the window wasn't shown before. MACPOPUP_SHOW_WELCOME=1 shows it anyway (for testing,
    /// as test runs save their settings first).
    static var isFirstLaunch: Bool {
        let defaults = SettingsStore.shared.defaults
        let forced = ProcessInfo.processInfo.environment["MACPOPUP_SHOW_WELCOME"] == "1"
        return forced || defaults.object(forKey: "settings") == nil && !defaults.bool(forKey: shownKey)
    }

    init(yomitanAPI: YomitanAPIStatus, openSettings: @escaping (_ section: String) -> Void) {
        self.yomitanAPI = yomitanAPI
        self.openSettings = openSettings
        super.init()
    }

    func show(above level: NSWindow.Level) {
        SettingsStore.shared.defaults.set(true, forKey: Self.shownKey)
        if window == nil {
            let view = WelcomeView(
                yomitanAPI: yomitanAPI,
                openScanningSettings: { [weak self] in
                    // The section with the Yomitan API's URL and its Install button.
                    let scanning = SettingsSchema.sections.first { $0.fields.contains { $0.key == "yomitanApiUrl" } }
                    if let scanning { self?.openSettings(scanning.title) }
                },
                close: { [weak self] in self?.window?.close() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to MacPopup"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: view)
            window.setContentSize(NSSize(width: 540, height: 620))
            window.center()
            self.window = window
        }
        // Above the overlay, as the Settings window.
        window?.level = NSWindow.Level(rawValue: level.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct WelcomeView: View {
    @ObservedObject var yomitanAPI: YomitanAPIStatus
    let openScanningSettings: () -> Void
    let close: () -> Void

    /// Settings → Permissions.
    private let permissions = SettingsSchema.sections.first { section in
        section.fields.contains { if case .permission = $0.kind { true } else { false } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    YomitanAPIRow(state: yomitanAPI.state, openScanningSettings: openScanningSettings)
                } header: {
                    WelcomeHeader(
                        title: "Yomitan API",
                        description: "MacPopup looks up words with Yomitan’s dictionaries, through the Yomitan API."
                    )
                }
                if let permissions {
                    Section {
                        ForEach(permissions.fields) { field in
                            if case let .permission(permission) = field.kind {
                                PermissionRow(field: field, permission: permission)
                            }
                        }
                    } header: {
                        WelcomeHeader(title: permissions.title, description: permissions.description)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("You can find all of these in Settings later.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        // More often than the menu bar icon's check, so that the status changes soon after the API is set up.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                yomitanAPI.check()
            }
        }
    }
}

private struct WelcomeHeader: View {
    let title: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold()).foregroundStyle(.primary)
            if let description {
                HeaderDescription(text: description)
            }
        }
        .padding(.bottom, 4)
    }
}

/// Whether the Yomitan API answers, laid out as a permission's row, with a link to Settings → Scanning when it doesn't.
private struct YomitanAPIRow: View {
    let state: YomitanAPIStatus.State
    let openScanningSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Yomitan API")
                Text("If it’s not detected, install it in Settings → Scanning (Install button, next to the Yomitan API URL), then enable Advanced settings in Yomitan and turn on Enable Yomitan API (no need to follow the other steps Yomitan mentions: Install takes care of them).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                switch state {
                case .unknown:
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                case .reachable:
                    Label("Detected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .unreachable:
                    Label("Not detected", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Button("Open Settings → Scanning", action: openScanningSettings)
                }
            }
        }
    }
}
