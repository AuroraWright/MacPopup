// The Yomitan API's native messaging host (yomitan_api.py from github.com/yomidevs/yomitan-api) in Swift, so it
// runs without Python. Settings → Scanning → Install copies it to where the API's installer copies yomitan_api.py
// on macOS (next to the browser's native messaging manifest), as yomitan_api.
//
// The browser starts it when Yomitan's "Enable Yomitan API" is on. It serves http://127.0.0.1:19633 and passes each
// POST to Yomitan over stdin and stdout ({action, params, body} out, {responseStatusCode, data} back), one at a time.
// Unlike the script, it quits when the browser closes its stdin.
import Darwin
import Foundation

let address = "127.0.0.1"
/// YOMITAN_API_PORT: another port (for test runs).
let port = ProcessInfo.processInfo.environment["YOMITAN_API_PORT"].flatMap(UInt16.init) ?? 19633
let processStartupWait: TimeInterval = 5
let nativeMessagingVersion = 1
let blacklistedPaths: Set = ["favicon.ico"]
let invalidMethods: Set = ["GET", "HEAD", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"]

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

/// The browser's replies, read as they come so the host quits when the browser closes stdin.
final class Replies {
    private let condition = NSCondition()
    private var queue: [[UInt8]] = []

    func start() {
        Thread.detachNewThread {
            while let message = getMessage() {
                self.condition.lock()
                self.queue.append(message)
                self.condition.signal()
                self.condition.unlock()
            }
            quit(0)
        }
    }

    func next() -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty { condition.wait() }
        return queue.removeFirst()
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
    431: "Request Header Fields Too Large", 500: "Internal Server Error", 501: "Not Implemented",
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

func handle(_ client: Int32, replies: Replies) {
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

    sendMessage(["action": path, "params": parseQuery(query), "body": String(decoding: body, as: UTF8.self)])
    let reply = replies.next()
    guard let response = members(of: reply), let status = response["responseStatusCode"].flatMap({ Int(String(decoding: $0, as: UTF8.self)) }),
          let data = response["data"]
    else {
        errorLog("Unexpected reply from Yomitan: \(String(decoding: reply.prefix(1000), as: UTF8.self))")
        respond(client, status: 500, contentType: "application/json", body: [])
        return
    }
    respond(client, status: status, contentType: "application/json", body: Array(data))
}

func serve(replies: Replies) throws -> Never {
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

    // Requests are handled one at a time, as Yomitan's replies come back in order.
    while true {
        let client = accept(server, nil, nil)
        guard client >= 0 else { continue }
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        handle(client, replies: replies)
        close(client)
    }
}

signal(SIGPIPE, SIG_IGN)
ensureSingleInstance()
let replies = Replies()
replies.start()
do {
    try serve(replies: replies)
} catch {
    errorLog("Couldn't serve http://\(address):\(port): \(error)")
    quit(1)
}
