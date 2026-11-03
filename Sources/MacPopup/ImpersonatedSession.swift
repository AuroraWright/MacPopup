import CurlImpersonate
import Foundation

/// HTTP requests that look like Chrome's, down to its TLS and HTTP/2 fingerprints (libcurl-impersonate, see
/// CurlImpersonate.h), as owocr makes Google Lens' and Bing's with curl_cffi: depending on the network, Bing refuses
/// others. A session keeps its cookies and connections between requests, which it makes one at a time.
final class ImpersonatedSession: @unchecked Sendable {
    /// What owocr's "chrome" stands for (curl_cffi 0.14).
    static let target = "chrome142"

    struct Response {
        var status: Int
        /// The Location header, as sent.
        var location: String?
        var body: Data
    }

    /// A part of a multipart form.
    struct Part {
        var name: String
        var contentType: String? = nil
        var data: Data
    }

    private let session: OpaquePointer
    private let queue = DispatchQueue(label: "ImpersonatedSession")

    init() throws {
        try Self.loadLibrary()
        guard let session = MPCurlSessionCreate() else { throw BridgeError("Couldn’t start libcurl-impersonate") }
        self.session = session
    }

    deinit {
        MPCurlSessionFree(session)
    }

    private static func loadLibrary() throws {
        let path = Bundle.main.privateFrameworksURL?.appendingPathComponent("libcurl-impersonate.4.dylib").path ?? ""
        var error = [CChar](repeating: 0, count: 512)
        guard MPCurlLoad(path, &error, error.count) == 0 else {
            let reason = String(cString: error)
            throw BridgeError(
                FileManager.default.fileExists(atPath: path)
                    ? "Couldn’t load libcurl-impersonate: \(reason)"
                    : "libcurl-impersonate isn’t in MacPopup.app: scripts/build.sh downloads it"
            )
        }
    }

    /// POSTs `body`, or a multipart form of `parts`, with Chrome's headers and `headers` (which replace those of the same
    /// name), without following redirects. Cancelling the task stops the request.
    func post(_ url: String, headers: [(String, String)], body: Data = Data(), parts: [Part] = [], timeout: Int = 20) async throws -> Response {
        let cancelled = ManagedAtomicFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancelled.isSet else { return continuation.resume(throwing: CancellationError()) }
                    continuation.resume(with: Result {
                        try Self.perform(session, url: url, headers: headers.map { "\($0): \($1)" }, body: body, parts: parts, timeout: timeout)
                    })
                }
            }
        } onCancel: { [self] in
            cancelled.set()
            MPCurlSessionCancel(session)
        }
    }

    private static func perform(
        _ session: OpaquePointer, url: String, headers: [String], body: Data, parts: [Part], timeout: Int
    ) throws -> Response {
        // C strings and bytes that stay put during the call.
        var allocations: [UnsafeMutableRawPointer] = []
        defer { allocations.forEach { free($0) } }
        func copy(_ string: String) -> UnsafePointer<CChar> {
            let pointer = strdup(string)!
            allocations.append(pointer)
            return UnsafePointer(pointer)
        }
        func copy(_ data: Data) -> UnsafeRawPointer? {
            guard !data.isEmpty, let pointer = malloc(data.count) else { return nil }
            allocations.append(pointer)
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
            return UnsafeRawPointer(pointer)
        }
        let headerPointers: [UnsafePointer<CChar>] = headers.map(copy)
        let cParts = parts.map { MPCurlPart(name: copy($0.name), contentType: $0.contentType.map(copy), data: copy($0.data), length: $0.data.count) }
        let bodyPointer = copy(body)
        var response = MPCurlResponse()
        defer { MPCurlResponseFree(&response) }
        let code = headerPointers.withUnsafeBufferPointer { headerBuffer in
            cParts.withUnsafeBufferPointer { partBuffer in
                MPCurlSessionPost(
                    session, url, target, headerBuffer.baseAddress, headerBuffer.count, bodyPointer, body.count,
                    partBuffer.baseAddress, partBuffer.count, timeout, &response
                )
            }
        }
        guard code == 0 else {
            switch code {
            case 28: throw URLError(.timedOut)  // CURLE_OPERATION_TIMEDOUT
            case 42: throw CancellationError()  // CURLE_ABORTED_BY_CALLBACK
            default:
                let message = withUnsafeBytes(of: response.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                throw BridgeError(message.isEmpty ? "curl error \(code)" : message)
            }
        }
        return Response(
            status: response.status,
            location: response.location.map { String(cString: $0) },
            body: response.body.map { Data(bytes: $0, count: response.bodyLength) } ?? Data()
        )
    }
}

/// Set once, read from any thread.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
