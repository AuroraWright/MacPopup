import Foundation
import Network
import UniformTypeIdentifiers

/// Serves the reading pages to Safari from http://127.0.0.1:47101 (a secure context there, so the page's service worker
/// registers and keeps pages working after the app is suspended or quit):
/// - `/` (the list of readings) and `/r/<id>` (a reading): the viewer page, built from web/src/viewer;
/// - `/readings.json`: [{id, createdAt, text}], newest first;
/// - `/r/<id>/reading.json` and `/r/<id>/image`: a reading's data and picture.
final class PageServer: @unchecked Sendable {
    static let port: UInt16 = 47101
    static let shared = PageServer()

    static let home = URL(string: "http://127.0.0.1:\(port)/")!

    static func url(_ reading: Reading) -> URL {
        URL(string: "http://127.0.0.1:\(port)/r/\(reading.id)")!
    }

    private let queue = DispatchQueue(label: "PageServer")
    private var listener: NWListener?
    private let viewer = Bundle.main.resourceURL!.appendingPathComponent("Viewer", isDirectory: true)

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.restart() }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
            }
        }
    }

    /// The port is lost when iOS reclaims it from a suspended app: listens again.
    private func restart() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let path = Self.requestPath(buffer) {
                let response = path.map(respond) ?? (status: "405 Method Not Allowed", type: "text/plain", body: Data())
                var head = "HTTP/1.1 \(response.status)\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\n"
                head += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil || buffer.count > 1 << 16 {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer)
            }
        }
    }

    /// The path of a complete GET request's head (nil for other methods), or nil while the head is incomplete.
    private static func requestPath(_ data: Data) -> String?? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let line = String(decoding: data[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return .some(nil) }
        return .some(String(parts[1].prefix { $0 != "?" && $0 != "#" }))
    }

    private func respond(to path: String) -> (status: String, type: String, body: Data) {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.count {
        case 0:
            return file(viewer.appendingPathComponent("viewer.html"))
        case 1 where parts[0] == "readings.json":
            let readings = ReadingStore.shared.readings.map { reading in
                ["id": reading.id, "createdAt": (reading.createdAt.timeIntervalSince1970 * 1000).rounded(), "text": reading.text] as [String: Any]
            }
            return ok("application/json", try? JSONSerialization.data(withJSONObject: readings))
        case 1 where ["viewer.html", "viewer.js", "viewer.css", "sw.js"].contains(parts[0]):
            return file(viewer.appendingPathComponent(parts[0]))
        case 2 where parts[0] == "r":
            return file(viewer.appendingPathComponent("viewer.html"))
        case 3 where parts[0] == "r":
            guard let reading = ReadingStore.shared.reading(parts[1]) else { return notFound }
            switch parts[2] {
            case "reading.json": return file(reading.imageFile.deletingLastPathComponent().appendingPathComponent("reading.json"))
            case "image": return file(reading.imageFile)
            default: return notFound
            }
        default:
            return notFound
        }
    }

    private func file(_ url: URL) -> (status: String, type: String, body: Data) {
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let text = type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true || type == .json
        return ok(text ? "\(mime); charset=utf-8" : mime, try? Data(contentsOf: url))
    }

    private func ok(_ type: String, _ body: Data?) -> (status: String, type: String, body: Data) {
        guard let body else { return notFound }
        return ("200 OK", type, body)
    }

    private var notFound: (status: String, type: String, body: Data) {
        ("404 Not Found", "text/plain", Data("Not found".utf8))
    }
}
