import Foundation
import Network
import UniformTypeIdentifiers

/// Serves the reading pages to Safari from http://127.0.0.1:47101 (a secure context there, so the page's service worker
/// registers and keeps pages working after the app is suspended or quit):
/// - `/` (the list of readings) and `/r/<id>` (a reading): the viewer page, built from web/src/viewer;
/// - `/readings.json`: [{id, createdAt, text}], newest first;
/// - `/r/<id>/reading.json` and `/r/<id>/image`: a reading's data and picture;
/// - `/live` (continuous mode's readings, newest first), `/live.json` ([{id, createdAt}]), `/l/<id>/…` (a live
///   reading, as `/r/<id>/…`) and `/live/events` (server-sent events: `{id}` for each new live reading); the live page
///   asks for `/live.json?visible` every second while it's in front, so continuous mode pauses (Continuous.pageIsVisible).
final class PageServer: @unchecked Sendable {
    static let port: UInt16 = 47101
    static let shared = PageServer()

    static let home = URL(string: "http://127.0.0.1:\(port)/")!
    static let live = URL(string: "http://127.0.0.1:\(port)/live")!

    static func url(_ reading: Reading) -> URL {
        URL(string: "http://127.0.0.1:\(port)/r/\(reading.id)")!
    }

    private let queue = DispatchQueue(label: "PageServer")
    private var listener: NWListener?
    private let viewer = Bundle.main.resourceURL!.appendingPathComponent("Viewer", isDirectory: true)
    /// The live pages' event streams.
    private var subscribers: [ObjectIdentifier: NWConnection] = [:]

    /// Listens, unless it already does; `fresh` listens again anyway, since a listener can stop answering after the app
    /// was suspended for a while without saying it failed.
    func start(fresh: Bool = false) {
        queue.async { [self] in
            if fresh, let listener {
                // Once the old one has let go of the port (else "Address already in use").
                let next = { [weak self, weak listener] in
                    guard let self, self.listener === listener else { return }
                    self.listener = nil
                    start()
                }
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state { next() }
                }
                queue.asyncAfter(deadline: .now() + 1, execute: next)
                listener.cancel()
                return
            }
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard case .failed(let error) = state, let self, self.listener === listener else { return }
                    IntentLog.append("Page server: \(error), listening again")
                    restart()
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
        for connection in subscribers.values { connection.cancel() }
        subscribers = [:]
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
            if let target = Self.requestTarget(buffer), target == "/live/events" {
                subscribe(connection)
            } else if let target = Self.requestTarget(buffer) {
                let response = target.map { target in
                    self.respond(to: String(target.prefix { $0 != "?" }), query: String(target.drop { $0 != "?" }.dropFirst()))
                } ?? (status: "405 Method Not Allowed", type: "text/plain", body: Data())
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

    /// Keeps the connection open, to send it events.
    private func subscribe(_ connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\nretry: 2000\n\n"
        subscribers[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled: if let connection { self?.subscribers[ObjectIdentifier(connection)] = nil }
            default: break
            }
        }
        send(Data(head.utf8), to: connection)
    }

    /// Tells the live pages about a new live reading.
    func announce(_ reading: Reading) {
        let event = Data("data: {\"id\":\"\(reading.id)\"}\n\n".utf8)
        queue.async { [self] in
            for connection in subscribers.values { send(event, to: connection) }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            self?.subscribers[ObjectIdentifier(connection)] = nil
            connection.cancel()
        })
    }

    /// The path and query of a complete GET request's head (nil for other methods), or nil while the head is incomplete.
    private static func requestTarget(_ data: Data) -> String?? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let line = String(decoding: data[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return .some(nil) }
        return .some(String(parts[1].prefix { $0 != "#" }))
    }

    private func respond(to path: String, query: String) -> (status: String, type: String, body: Data) {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.count {
        case 0:
            return file(viewer.appendingPathComponent("viewer.html"))
        case 1 where parts[0] == "live":
            return file(viewer.appendingPathComponent("viewer.html"))
        case 1 where parts[0] == "readings.json":
            let readings = ReadingStore.shared.readings.map { reading in
                ["id": reading.id, "createdAt": (reading.createdAt.timeIntervalSince1970 * 1000).rounded(), "text": reading.text] as [String: Any]
            }
            return ok("application/json", try? JSONSerialization.data(withJSONObject: readings))
        case 1 where parts[0] == "live.json":
            // The live page says it's in front (a query on a path the page's older service workers pass through).
            if query == "visible" { Task { @MainActor in Continuous.shared.pageIsVisible() } }
            let readings = ReadingStore.live.readings.map { reading in
                ["id": reading.id, "createdAt": (reading.createdAt.timeIntervalSince1970 * 1000).rounded()] as [String: Any]
            }
            return ok("application/json", try? JSONSerialization.data(withJSONObject: readings))
        case 1 where ["viewer.html", "viewer.js", "viewer.css", "sw.js"].contains(parts[0]):
            return file(viewer.appendingPathComponent(parts[0]))
        case 2 where parts[0] == "r":
            return file(viewer.appendingPathComponent("viewer.html"))
        case 3 where parts[0] == "r" || parts[0] == "l":
            guard let reading = (parts[0] == "r" ? ReadingStore.shared : ReadingStore.live).reading(parts[1]) else { return notFound }
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
