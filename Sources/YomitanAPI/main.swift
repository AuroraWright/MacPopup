// The Yomitan API's native messaging host (yomitan_api.py from github.com/yomidevs/yomitan-api) in Swift, so it
// runs without Python. Settings → Scanning → Install copies it to where the API's installer copies yomitan_api.py
// on macOS (next to the browser's native messaging manifest), as yomitan_api.
//
// The browser starts it when Yomitan's "Enable Yomitan API" is on. It serves http://127.0.0.1:19633 and passes each
// POST to Yomitan over stdin and stdout ({action, params, body} out, {params, responseStatusCode, data} back).
// Unlike the script, it quits when the browser closes its stdin. And as OwOtan's Safari app does, it lets Yomitan work
// on several requests at once, drops a request whose client went away while it waited its turn, and answers a client
// that waits too long with a 504.
import Darwin
import Foundation

let address = "127.0.0.1"
/// Test runs set another one with YOMITAN_API_PORT.
let port = ProcessInfo.processInfo.environment["YOMITAN_API_PORT"].flatMap(UInt16.init) ?? 19633
let processStartupWait: TimeInterval = 5
let nativeMessagingVersion = 1
let blacklistedPaths: Set = ["favicon.ico"]
let invalidMethods: Set = ["GET", "HEAD", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"]
/// How many requests Yomitan works on at once, so that quick ones (a version check, a lookup) aren't held up by a long
/// one (a tokenize of a long text). Further ones wait their turn, in the order they came.
let maxConcurrentRequests = 4
/// How long a client waits for Yomitan's answer from when its request came, before it gets a 504.
let requestTimeout: TimeInterval = 30
/// How long a request handed to Yomitan keeps its place among those it works on, when its answer doesn't come.
let workTimeout: TimeInterval = 120
/// The parameter that tells Yomitan's answers apart: Yomitan sends each request's params back with its answer, and
/// answers in the order it finishes.
let requestIdParam = "__macpopupRequestId"

let directory = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent()
let crowbarFile = directory.appendingPathComponent(".crowbar")

func errorLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let escaped = message.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    let line = Data("\(formatter.string(from: Date())), \(escaped), \n".utf8)
    let url = directory.appendingPathComponent("error.log")
    // (Nothing can be printed instead: stdout is the browser's.)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

// MARK: One instance

/// The arguments a process was started with, its executable's path first.
func arguments(of pid: pid_t) -> [String] {
    var argumentsMax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    var mib = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&mib, 2, &argumentsMax, &size, nil, 0) == 0, argumentsMax > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: Int(argumentsMax))
    size = buffer.count
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
    // argc, the executable's path, padding, then the arguments.
    let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var index = 4
    func next() -> String {
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        return String(decoding: buffer[start..<index], as: UTF8.self)
    }
    var result = [next()]
    while index < size, buffer[index] == 0 { index += 1 }
    while result.count <= count, index < size {
        result.append(next())
        index += 1
    }
    return result
}

/// Stops an earlier instance (this one or the script, which the browser may have left running), as the script
/// does with the pid in .crowbar. Only a process that is one of them is stopped, in case the pid was reused.
func ensureSingleInstance() {
    if let text = try? String(contentsOf: crowbarFile, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, pid != getpid(),
       arguments(of: pid).contains(where: { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("yomitan_api") }),
       kill(pid, SIGTERM) == 0
    {
        let deadline = Date().addingTimeInterval(processStartupWait)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
    }
    do {
        try String(getpid()).write(to: crowbarFile, atomically: false, encoding: .utf8)
    } catch {
        errorLog("Couldn't write \(crowbarFile.path): \(error)")
    }
}

func deleteCrowbarFile() {
    if let text = try? String(contentsOf: crowbarFile, encoding: .utf8), text == String(getpid()) {
        try? FileManager.default.removeItem(at: crowbarFile)
    }
}

func quit(_ status: Int32) -> Never {
    deleteCrowbarFile()
    exit(status)
}

// MARK: Native messaging

func readAll(_ fd: Int32, count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let read = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
        if read < 0, errno == EINTR { continue }
        guard read > 0 else { return nil }
        offset += read
    }
    return bytes
}

@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
    }
    return true
}

/// A message from the browser: its length in native byte order, then UTF-8 JSON. Nil once stdin is closed.
func getMessage() -> [UInt8]? {
    guard let header = readAll(STDIN_FILENO, count: 4) else { return nil }
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    return readAll(STDIN_FILENO, count: Int(length))
}

func sendMessage(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return }
    let length = withUnsafeBytes(of: UInt32(data.count)) { Array($0) }
    guard writeAll(STDOUT_FILENO, length + [UInt8](data)) else { quit(0) }
}

/// Whether a client closed its connection.
func isClosed(_ client: Int32) -> Bool {
    var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 0) > 0 else { return false }
    var byte: UInt8 = 0
    let count = recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    return count == 0 || count < 0 && errno != EAGAIN && errno != EINTR
}

/// A request for Yomitan.
final class Request {
    let id: Int
    let message: [String: Any]
    /// When it was handed to Yomitan, or nil while it waits its turn.
    var handedOut: Date?
    /// Yomitan's answer, as members(of:) splits it.
    var answer: [String: ArraySlice<UInt8>]?

    init(id: Int, message: [String: Any]) {
        self.id = id
        self.message = message
    }
}

/// The requests waiting for Yomitan and those it works on, with the browser's replies, read as they come so the host
/// quits when the browser closes stdin.
final class Requests {
    private let condition = NSCondition()
    private var lastId = 0
    private var waiting: [Request] = []
    private var working: [Int: Request] = [:]

    func start() {
        Thread.detachNewThread {
            while let message = getMessage() {
                self.received(message)
            }
            quit(0)
        }
    }

    /// Yomitan's answer to a request, or nil when it didn't come in time or the client closed its connection first.
    func send(action: String, params: [String: [String]], body: String, client: Int32) -> [String: ArraySlice<UInt8>]? {
        condition.lock()
        defer { condition.unlock() }
        lastId += 1
        var params = params
        params[requestIdParam] = [String(lastId)]
        let request = Request(id: lastId, message: ["action": action, "params": params, "body": body])
        waiting.append(request)
        let deadline = Date().addingTimeInterval(requestTimeout)
        // Wakes up now and then to check the client's connection and to let go of requests Yomitan never answered.
        while request.answer == nil, Date() < deadline, !isClosed(client) {
            handOut()
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.25)))
        }
        // One still waiting its turn isn't worth Yomitan's time any more; one Yomitan works on keeps its place until
        // it's answered, and the answer is dropped.
        waiting.removeAll { $0 === request }
        return request.answer
    }

    /// Hands the requests waiting their turn to Yomitan, as far as it has room for them. Called with the lock held.
    private func handOut() {
        let now = Date()
        working = working.filter { now.timeIntervalSince($0.value.handedOut ?? now) < workTimeout }
        while working.count < maxConcurrentRequests, !waiting.isEmpty {
            let request = waiting.removeFirst()
            request.handedOut = now
            working[request.id] = request
            sendMessage(request.message)
        }
    }

    private func received(_ message: [UInt8]) {
        let answer = members(of: message)
        let params = answer?["params"].flatMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        guard let answer, let id = (params?[requestIdParam] as? [String])?.first.flatMap({ Int($0) }) else {
            errorLog("Unexpected reply from Yomitan: \(String(decoding: message.prefix(1000), as: UTF8.self))")
            return
        }
        condition.lock()
        defer { condition.unlock() }
        // Not if Yomitan took too long with it: handOut has let it go.
        guard let request = working.removeValue(forKey: id) else { return }
        request.answer = answer
        handOut()
        condition.broadcast()
    }
}

// MARK: JSON

/// The members of a JSON object, each value as its bytes, so Yomitan's data is passed on as it was written.
func members(of json: [UInt8]) -> [String: ArraySlice<UInt8>]? {
    let quote = UInt8(ascii: "\"")
    func skipSpace(_ index: Int) -> Int {
        var index = index
        while index < json.count, [0x20, 0x09, 0x0A, 0x0D].contains(json[index]) { index += 1 }
        return index
    }
    // From an opening quote to after the closing one.
    func skipString(_ index: Int) -> Int? {
        var index = index + 1
        while index < json.count {
            if json[index] == UInt8(ascii: "\\") {
                index += 2
            } else if json[index] == quote {
                return index + 1
            } else {
                index += 1
            }
        }
        return nil
    }
    func skipValue(_ index: Int) -> Int? {
        guard index < json.count else { return nil }
        switch json[index] {
        case quote:
            return skipString(index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var index = index
            var depth = 0
            while index < json.count {
                switch json[index] {
                case quote:
                    guard let end = skipString(index) else { return nil }
                    index = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = index
            while index < json.count, !Array(",}] \t\r\n".utf8).contains(json[index]) { index += 1 }
            return index
        }
    }

    var index = skipSpace(0)
    guard index < json.count, json[index] == UInt8(ascii: "{") else { return nil }
    index += 1
    var result: [String: ArraySlice<UInt8>] = [:]
    while true {
        index = skipSpace(index)
        guard index < json.count else { return nil }
        if json[index] == UInt8(ascii: "}"), result.isEmpty { return result }
        guard json[index] == quote, let keyEnd = skipString(index),
              let key = try? JSONSerialization.jsonObject(with: Data(json[index..<keyEnd]), options: .fragmentsAllowed) as? String
        else { return nil }
        index = skipSpace(keyEnd)
        guard index < json.count, json[index] == UInt8(ascii: ":") else { return nil }
        index = skipSpace(index + 1)
        guard let valueEnd = skipValue(index), valueEnd > index else { return nil }
        result[key] = json[index..<valueEnd]
        index = skipSpace(valueEnd)
        guard index < json.count else { return nil }
        if json[index] == UInt8(ascii: "}") { return result }
        guard json[index] == UInt8(ascii: ",") else { return nil }
        index += 1
    }
}

// MARK: HTTP

func percentDecoded(_ text: Substring) -> String {
    var bytes: [UInt8] = []
    let utf8 = Array(text.replacingOccurrences(of: "+", with: " ").utf8)
    var index = 0
    while index < utf8.count {
        if utf8[index] == UInt8(ascii: "%"), index + 2 < utf8.count,
           let byte = UInt8(String(decoding: utf8[index + 1...index + 2], as: UTF8.self), radix: 16)
        {
            bytes.append(byte)
            index += 3
        } else {
            bytes.append(utf8[index])
            index += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// The query's parameters as Python's urllib.parse.parse_qs gives them: each name's values, without empty ones.
func parseQuery(_ query: Substring) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for pair in query.split(separator: "&") {
        guard let equals = pair.firstIndex(of: "=") else { continue }
        let value = pair[pair.index(after: equals)...]
        guard !value.isEmpty else { continue }
        result[percentDecoded(pair[..<equals]), default: []].append(percentDecoded(value))
    }
    return result
}

let reasons = [
    200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large",
    431: "Request Header Fields Too Large", 500: "Internal Server Error", 501: "Not Implemented", 504: "Gateway Timeout",
]

/// Sends a response; the API's own responses allow any page to read them, as the script's do.
func respond(_ client: Int32, status: Int, contentType: String, body: [UInt8], cors: Bool = true, allow: Bool = false) {
    var headers = ["HTTP/1.0 \(status) \(reasons[status] ?? "")", "Content-type: \(contentType)"]
    if cors {
        headers += [
            "Access-Control-Allow-Origin: *", "Access-Control-Allow-Methods: *", "Access-Control-Allow-Headers: *",
            "Cache-Control: no-store, no-cache, must-revalidate",
        ]
    }
    if allow { headers.append("Allow: POST") }
    headers += ["Content-Length: \(body.count)", "Connection: close"]
    writeAll(client, Array((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body)
}

func handle(_ client: Int32, requests: Requests) {
    // Up to 64 KB of headers, as Python's http.server allows.
    let headerEnd = Array("\r\n\r\n".utf8)
    var received: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    var headersLength: Int?
    while headersLength == nil {
        let count = read(client, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return }
        let searchStart = max(0, received.count - 3)
        received += buffer[..<count]
        if let range = received[searchStart...].firstRange(of: headerEnd) {
            headersLength = range.lowerBound
        } else if received.count > 65536 {
            respond(client, status: 431, contentType: "text/plain", body: [], cors: false)
            return
        }
    }
    let lines = String(decoding: received[..<headersLength!], as: UTF8.self).components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ")
    guard requestLine.count >= 2 else {
        respond(client, status: 400, contentType: "text/plain", body: [], cors: false)
        return
    }
    let method = String(requestLine[0])
    guard method == "POST" else {
        if invalidMethods.contains(method) {
            let message = "\(method) method not allowed, only POST is accepted"
            respond(client, status: 405, contentType: "text/plain", body: Array(message.utf8), cors: false, allow: true)
        } else {
            respond(client, status: 501, contentType: "text/plain", body: Array("Unsupported method (\(method))".utf8), cors: false)
        }
        return
    }

    var contentLength = 0
    for line in lines.dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
            contentLength = max(0, Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0)
        }
    }
    var body = Array(received[(headersLength! + headerEnd.count)...])
    if contentLength > body.count {
        guard let rest = readAll(client, count: contentLength - body.count) else { return }
        body += rest
    }
    body = Array(body.prefix(contentLength))

    // The path without its leading "/", and the query (as urllib.parse.urlparse splits them).
    var target = Substring(requestLine[1])
    if let hash = target.firstIndex(of: "#") { target = target[..<hash] }
    let query = target.firstIndex(of: "?").map { target[target.index(after: $0)...] } ?? ""
    let path = String(target[..<(target.firstIndex(of: "?") ?? target.endIndex)].dropFirst())

    if blacklistedPaths.contains(path) {
        respond(client, status: 400, contentType: "", body: [])
        return
    }
    if path == "serverVersion" || path.isEmpty {
        respond(client, status: 200, contentType: "application/json", body: Array("{\"version\": \(nativeMessagingVersion)}".utf8))
        return
    }

    let text = String(decoding: body, as: UTF8.self)
    guard let response = requests.send(action: path, params: parseQuery(query), body: text, client: client) else {
        // Or the client is gone, and this reaches nobody.
        respond(client, status: 504, contentType: "application/json", body: Array("\"Yomitan did not answer in time\"".utf8))
        return
    }
    guard let status = response["responseStatusCode"].flatMap({ Int(String(decoding: $0, as: UTF8.self)) }),
          let data = response["data"]
    else {
        errorLog("Unexpected reply from Yomitan: \(response.keys.sorted())")
        respond(client, status: 500, contentType: "application/json", body: [])
        return
    }
    respond(client, status: status, contentType: "application/json", body: Array(data))
}

func serve(requests: Requests) throws -> Never {
    let server = socket(AF_INET, SOCK_STREAM, 0)
    guard server >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var yes: Int32 = 1
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var socketAddress = sockaddr_in()
    socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    socketAddress.sin_family = sa_family_t(AF_INET)
    socketAddress.sin_port = port.bigEndian
    inet_pton(AF_INET, address, &socketAddress.sin_addr)
    // The instance stopped above may take a moment to let go of the port.
    let deadline = Date().addingTimeInterval(processStartupWait)
    while withUnsafePointer(to: &socketAddress, {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }) != 0 {
        guard errno == EADDRINUSE, Date() < deadline else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        usleep(100_000)
    }
    guard listen(server, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    while true {
        let client = accept(server, nil, nil)
        guard client >= 0 else { continue }
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread {
            handle(client, requests: requests)
            close(client)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
ensureSingleInstance()
let requests = Requests()
requests.start()
do {
    try serve(requests: requests)
} catch {
    errorLog("Couldn't serve http://\(address):\(port): \(error)")
    quit(1)
}
