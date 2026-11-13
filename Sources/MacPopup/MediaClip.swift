import Foundation

/// The sentence audio and screenshot of a line from a video player (iina-plugin/), cut by the ffmpeg in
/// Contents/Helpers (scripts/build-ffmpeg.sh): the line's time range as AAC in .m4a, and one frame.
enum MediaClip {
    /// Where a line's video or audio is read from (see iina-plugin/main.js).
    enum Source {
        case file(String, stream: Int)
        /// An http(s) stream, with the player's request headers ("Name: value") and http proxy.
        case url(URL, stream: Int, headers: [String], proxy: URL?)
        /// DASH fragments, which the plugin at `socket` lists for a time range of the window with `key`.
        case fragments(key: String, socket: URL)
        /// Only in the player's cache: the plugin at `socket` dumps a time range of the window with `key` into a
        /// file first, whose first audio and video streams are the ones playing.
        case cache(key: String, socket: URL)

        init(_ body: [String: Any], socket: String?) throws {
            let stream = (body["stream"] as? NSNumber)?.intValue
            if let file = body["file"] as? String, let stream {
                guard (0...999).contains(stream) else { throw AppError("Invalid stream") }
                self = .file(file, stream: stream)
            } else if let string = body["url"] as? String, let stream {
                guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased()),
                      (0...999).contains(stream)
                else { throw AppError("Invalid stream URL") }
                self = .url(url, stream: stream, headers: Self.headers(body["headers"]), proxy: Self.proxy(body["proxy"]))
            } else if let key = body["fragments"] as? String {
                self = .fragments(key: key, socket: try Self.localSocket(socket))
            } else if let key = body["cache"] as? String {
                self = .cache(key: key, socket: try Self.localSocket(socket))
            } else {
                throw AppError("Invalid source")
            }
        }

        /// The player's request headers, without line breaks inside one (they'd add headers of their own).
        static func headers(_ value: Any?) -> [String] {
            (value as? [String] ?? []).filter { !$0.contains("\r") && !$0.contains("\n") && $0.contains(":") }
        }

        /// The player's http proxy ("http://host:port"), if any.
        static func proxy(_ value: Any?) -> URL? {
            guard let url = (value as? String).flatMap(URL.init(string:)), url.scheme?.lowercased() == "http",
                  url.host != nil
            else { return nil }
            return url
        }

        /// Only the plugin on this Mac is asked for the line.
        private static func localSocket(_ socket: String?) throws -> URL {
            guard let socket = socket.flatMap(URL.init(string:)), socket.scheme == "ws",
                  ["127.0.0.1", "localhost", "::1"].contains(socket.host ?? "")
            else { throw AppError("No local WebSocket to ask the player for the line") }
            return socket
        }
    }

    static func audio(_ source: Source, start: Double, end: Double) async throws -> Data {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 600 else {
            throw AppError("Invalid audio range")
        }
        let output = ["-vn", "-sn", "-dn", "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-f", "ipod"]
        if let (part, offset) = try await playerPart(source, type: "audio", start: start, end: end) {
            defer { try? FileManager.default.removeItem(at: part) }
            return try await run(extension: "m4a", what: "cut the audio") { file in
                ["-ss", time(start - offset), "-t", time(end - start), "-i", "file:" + part.path, "-map", "0:a:0"]
                    + output + [file]
            }
        }
        return try await run(extension: "m4a", what: "cut the audio") { file in
            ["-ss", time(start), "-t", time(end - start)] + (try input(source)) + output + [file]
        }
    }

    /// The frame shown at `time`, without subtitles, at the video's size (non-square pixels made square).
    /// - Parameter quality: JPEG quality, 0–100.
    static func frame(_ source: Source, time seconds: Double, png: Bool, quality: Double) async throws -> Data {
        guard seconds.isFinite, seconds >= 0 else { throw AppError("Invalid time") }
        // ffmpeg's JPEG quality scale goes from 2 (best) to 31.
        let scale = Int((2 + (100 - min(100, max(0, quality))) * 29 / 100).rounded())
        let output = ["-an", "-sn", "-dn", "-frames:v", "1", "-vf", "scale=trunc(iw*sar/2)*2:ih"]
            + (png ? [] : ["-q:v", "\(scale)"]) + ["-f", "image2"]
        // A little around the frame (for a dump, its audio places it).
        if let (part, offset) = try await playerPart(source, type: "video", start: max(0, seconds - 0.5), end: seconds + 0.5) {
            defer { try? FileManager.default.removeItem(at: part) }
            return try await run(extension: png ? "png" : "jpg", what: "take the screenshot") { file in
                ["-ss", time(max(0, seconds - offset)), "-i", "file:" + part.path, "-map", "0:v:0"] + output + [file]
            }
        }
        return try await run(extension: png ? "png" : "jpg", what: "take the screenshot") { file in
            ["-ss", time(seconds)] + (try input(source)) + output + [file]
        }
    }

    private static func time(_ seconds: Double) -> String { String(format: "%.3f", seconds) }

    /// For a source that the player is asked for, a file with the time range and the time it starts at (the caller
    /// deletes the file); nil for one that ffmpeg reads itself.
    private static func playerPart(_ source: Source, type: String, start: Double, end: Double) async throws -> (URL, Double)? {
        switch source {
        case .fragments(let key, let socket):
            return try await Player.fragments(key: key, type: type, socket: socket, start: start, end: end)
        case .cache(let key, let socket):
            let dump = try await Player.dump(key: key, socket: socket, start: start, end: end)
            do {
                return (dump, try await dumpOffset(dump, end: end))
            } catch {
                try? FileManager.default.removeItem(at: dump)
                throw error
            }
        case .file, .url:
            return nil
        }
    }

    /// ffmpeg's input options for a file or stream, with its stream mapped.
    private static func input(_ source: Source) throws -> [String] {
        switch source {
        case .file(let file, let stream):
            var isDirectory: ObjCBool = false
            guard file.hasPrefix("/"), FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw AppError("No video file at \(file)")
            }
            // "file:" so that a name with a colon isn't taken for a protocol.
            return ["-i", "file:" + file, "-map", "0:\(stream)"]
        case .url(let url, let stream, let headers, let proxy):
            // Only network protocols (an HLS playlist could name local files), and no waiting forever (µs).
            return ["-protocol_whitelist", "http,https,tcp,tls,crypto,httpproxy", "-rw_timeout", "20000000"]
                + (headers.isEmpty ? [] : ["-headers", headers.map { $0 + "\r\n" }.joined()])
                + (proxy.map { ["-http_proxy", $0.absoluteString] } ?? [])
                + ["-i", url.absoluteString, "-map", "0:\(stream)"]
        case .fragments, .cache:
            throw AppError("The player’s part is read from its file")
        }
    }

    /// Where a dump from the player's cache starts in the stream's time. mpv starts it at the keyframe before the
    /// range, with its times from 0, and ends its audio at the range's end: so the end, less the audio's length (to
    /// about one audio packet).
    private static func dumpOffset(_ dump: URL, end: Double) async throws -> Double {
        let progress = try await ffmpeg([
            "-i", "file:" + dump.path, "-map", "0:a:0", "-c", "copy", "-f", "null", "-", "-progress", "pipe:1",
        ], what: "read the player’s cache")
        let length = progress.split(separator: "\n").compactMap { line -> Double? in
            guard line.hasPrefix("out_time_us=") else { return nil }
            return Double(line.dropFirst("out_time_us=".count)).map { $0 / 1_000_000 }
        }.last
        guard let length, length > 0 else { throw AppError("The player’s cache had no audio to place the line by") }
        return end - length
    }

    /// Runs ffmpeg with the arguments for an output file, and returns the file.
    private static func run(extension: String, what: String, arguments: (String) throws -> [String]) async throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("macpopup-clip-\(UUID().uuidString).\(`extension`)")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await ffmpeg(try arguments(output.path), what: what)
        guard let data = try? Data(contentsOf: output), !data.isEmpty else { throw AppError("ffmpeg couldn’t \(what)") }
        return data
    }

    /// Runs ffmpeg and returns what it wrote to its standard output.
    private static func ffmpeg(_ arguments: [String], what: String) async throws -> String {
        let ffmpeg = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            throw AppError("This build of MacPopup has no ffmpeg (see scripts/build.sh)")
        }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"] + arguments
        let errors = Pipe()
        let output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        // Read while it runs, so that a full pipe doesn't stop it.
        async let outputData = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? output.fileHandleForWriting.close()
                try? errors.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
        let (standardOutput, standardError) = await (outputData, errorData)
        guard status == 0 else {
            let message = String(data: standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AppError("ffmpeg couldn’t \(what): \(message.isEmpty ? "status \(status)" : message)")
        }
        return String(data: standardOutput, encoding: .utf8) ?? ""
    }
}

/// What MacPopup asks the IINA plugin over its WebSocket for (iina-plugin/global.js): a time range of a player
/// window's DASH fragments, or a dump of it from the player's cache.
private enum Player {
    /// The init segment and the fragments that the time range is in, downloaded into one file in the temporary
    /// folder with the player's headers and proxy, and the time the file starts at.
    static func fragments(key: String, type: String, socket: URL, start: Double, end: Double) async throws -> (URL, Double) {
        let id = UUID().uuidString
        let reply = try await ask(["fragments": ["id": id, "key": key, "type": type, "start": start, "end": end]], id: id, socket: socket)
        let http = { (url: URL) in ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
        let parts = reply["parts"] as? [[String: Any]] ?? []
        let urls = parts.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
        guard let initSegment = (reply["init"] as? String).flatMap(URL.init(string:)), http(initSegment),
              !parts.isEmpty, parts.count <= 500, urls.count == parts.count, urls.allSatisfy(http),
              let first = (parts[0]["start"] as? NSNumber)?.doubleValue
        else { throw AppError("IINA sent no fragments") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        // The player's own Cookie header.
        configuration.httpShouldSetCookies = false
        if let proxy = MediaClip.Source.proxy(reply["proxy"]), let host = proxy.host {
            guard proxy.user == nil else { throw AppError("A proxy with a password isn’t supported for DASH") }
            let port = proxy.port ?? 80
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true, kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port, kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host, kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let headers = MediaClip.Source.headers(reply["headers"]).map { header in
            let colon = header.firstIndex(of: ":")!
            return (String(header[..<colon]), header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macpopup-fragments-\(id).mp4")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file)
        else { throw AppError("Couldn’t save the video’s fragments") }
        defer { try? handle.close() }
        do {
            for url in [initSegment] + urls {
                var request = URLRequest(url: url)
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                let (data, response) = try await session.data(for: request)
                guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                    throw AppError("The video’s server refused a fragment")
                }
                try handle.write(contentsOf: data)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return (file, first)
    }

    /// The time range dumped from the window's cache into a file in the temporary folder.
    static func dump(key: String, socket: URL, start: Double, end: Double) async throws -> URL {
        let id = UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macpopup-dump-\(id).mkv")
        let reply = try await ask(["dump": ["id": id, "key": key, "start": start, "end": end, "file": file.path]], id: id, socket: socket)
        guard reply["file"] as? String == file.path else { throw AppError("IINA sent another file") }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            try? FileManager.default.removeItem(at: file)
            throw AppError("IINA couldn’t dump the line from its cache")
        }
        return file
    }

    /// Sends a request and returns the plugin's reply to it.
    private static func ask(_ request: [String: Any], id: String, socket: URL) async throws -> [String: Any] {
        let task = URLSession.shared.webSocketTask(with: socket)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await task.send(.string(String(data: JSONSerialization.data(withJSONObject: request), encoding: .utf8)!))

        let reply: [String: Any] = try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                // The plugin also sends its lines on this connection.
                while true {
                    let data: Data
                    switch try await task.receive() {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    if let reply = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reply"] as? [String: Any],
                       reply["id"] as? String == id {
                        return reply
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw AppError("IINA didn’t answer (is the player window still open?)")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        if let error = reply["error"] as? String { throw AppError(error) }
        return reply
    }
}
