import AppKit
import WebKit

/// Functionality the bridge needs from the app.
@MainActor
protocol BridgeHost: AnyObject {
    func setHitRects(_ rects: [CGRect])
    func openSettings()
    func overlayDisplayID() -> CGDirectDisplayID?
    func overlayMenuBarHeight() -> Double
    func setOverlayVisible(_ visible: Bool)
    func snapshotOverlay() async throws -> Data
    func simulateMouse(x: Double, y: Double, shift: Bool)
    var overlayIgnoresMouseEvents: Bool { get }
}

/// JS -> native calls. Web code uses `window.webkit.messageHandlers.native.postMessage({cmd, ...})`,
/// which resolves with the reply (see web/src/lib/native.js).
@MainActor
final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "native"

    weak var host: BridgeHost?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return (nil, "Invalid message")
        }
        do {
            return (try await handle(cmd, body), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func handle(_ cmd: String, _ body: [String: Any]) async throws -> Any? {
        switch cmd {
        case "getSettings":
            return SettingsStore.shared.json
        case "setSettings":
            guard let json = body["json"] as? String else { throw BridgeError("Missing json") }
            SettingsStore.shared.update(json: json)
            return nil
        case "http":
            return try await http(body)
        case "setHitRects":
            let rects = (body["rects"] as? [[NSNumber]] ?? []).compactMap { values -> CGRect? in
                guard values.count == 4 else { return nil }
                return CGRect(x: values[0].doubleValue, y: values[1].doubleValue,
                              width: values[2].doubleValue, height: values[3].doubleValue)
            }
            host?.setHitRects(rects)
            return nil
        case "screenshot":
            guard let displayID = host?.overlayDisplayID() else { throw BridgeError("No display") }
            let format = body["format"] as? String ?? "jpeg"
            let quality = (body["quality"] as? NSNumber)?.doubleValue ?? 92
            let data = try await ScreenCapture.capture(displayID: displayID, format: format, quality: quality)
            return data.base64EncodedString()
        case "clipboard":
            let pasteboard = NSPasteboard.general
            var result: [String: Any] = [:]
            if let text = pasteboard.string(forType: .string) {
                result["text"] = text
            }
            if body["image"] as? Bool == true,
               let image = NSImage(pasteboard: pasteboard),
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                result["image"] = png.base64EncodedString()
            }
            return result
        case "openURL":
            guard let string = body["url"] as? String, let url = URL(string: string) else {
                throw BridgeError("Invalid URL")
            }
            NSWorkspace.shared.open(url)
            return nil
        case "frontmostApp":
            // Stands in for Yomitan's page title ({document-title}): the app being read, e.g. the game.
            return NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        case "menuBarHeight":
            return host?.overlayMenuBarHeight() ?? 0
        case "openSettings":
            host?.openSettings()
            return nil
        case "setOverlayVisible":
            host?.setOverlayVisible(body["visible"] as? Bool ?? true)
            return nil
        case "debugSnapshot":
            // Development hook, only available together with MACPOPUP_TEST_SCRIPT.
            guard ProcessInfo.processInfo.environment["MACPOPUP_TEST_SCRIPT"] != nil,
                  let path = body["path"] as? String, let host else { throw BridgeError("Unavailable") }
            try await host.snapshotOverlay().write(to: URL(fileURLWithPath: path))
            return nil
        case "debugMouse":
            guard ProcessInfo.processInfo.environment["MACPOPUP_TEST_SCRIPT"] != nil, let host else {
                throw BridgeError("Unavailable")
            }
            host.simulateMouse(
                x: (body["x"] as? NSNumber)?.doubleValue ?? 0,
                y: (body["y"] as? NSNumber)?.doubleValue ?? 0,
                shift: body["shift"] as? Bool ?? false
            )
            return ["ignoresMouseEvents": host.overlayIgnoresMouseEvents]
        case "log":
            FileHandle.standardError.write("[web] \(body["message"] ?? "")\n".data(using: .utf8)!)
            return nil
        default:
            throw BridgeError("Unknown command \(cmd)")
        }
    }

    private func http(_ body: [String: Any]) async throws -> [String: Any] {
        guard let string = body["url"] as? String, let url = URL(string: string) else {
            throw BridgeError("Invalid URL")
        }
        var request = URLRequest(url: url, timeoutInterval: (body["timeout"] as? NSNumber)?.doubleValue ?? 30)
        request.httpMethod = body["method"] as? String ?? "POST"
        if let requestBody = body["body"] as? String {
            request.httpBody = requestBody.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ["status": status, "body": String(decoding: data, as: UTF8.self)]
    }
}

struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
