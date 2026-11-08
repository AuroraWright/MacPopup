import Foundation

/// The sentence audio and screenshot of a line from a video player (iina-plugin/), taken from the video file by the
/// ffmpeg in Contents/Helpers (scripts/build-ffmpeg.sh): the line's time range as AAC in .m4a, and one frame.
enum MediaClip {
    static func audio(file: String, stream: Int, start: Double, end: Double) async throws -> Data {
        try checkFile(file, stream: stream)
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 600 else {
            throw BridgeError("Invalid audio range")
        }
        return try await run(extension: "m4a", what: "cut the audio") { output in
            [
                "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", end - start),
                // "file:" so that a name with a colon isn't taken for a protocol.
                "-i", "file:" + file,
                "-map", "0:\(stream)", "-vn", "-sn", "-dn",
                "-c:a", "aac", "-b:a", "128k", "-ac", "2",
                "-f", "ipod", output,
            ]
        }
    }

    /// The frame shown at `time`, without subtitles, at the video's size (non-square pixels made square).
    /// - Parameter quality: JPEG quality, 0–100.
    static func frame(file: String, stream: Int, time: Double, png: Bool, quality: Double) async throws -> Data {
        try checkFile(file, stream: stream)
        guard time.isFinite, time >= 0 else { throw BridgeError("Invalid time") }
        // ffmpeg's JPEG quality scale goes from 2 (best) to 31.
        let scale = Int((2 + (100 - min(100, max(0, quality))) * 29 / 100).rounded())
        return try await run(extension: png ? "png" : "jpg", what: "take the screenshot") { output in
            [
                "-ss", String(format: "%.3f", time),
                "-i", "file:" + file,
                "-map", "0:\(stream)", "-an", "-sn", "-dn", "-frames:v", "1",
                "-vf", "scale=trunc(iw*sar/2)*2:ih",
            ] + (png ? [] : ["-q:v", "\(scale)"]) + ["-f", "image2", output]
        }
    }

    private static func checkFile(_ file: String, stream: Int) throws {
        var isDirectory: ObjCBool = false
        guard file.hasPrefix("/"), FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BridgeError("No video file at \(file)")
        }
        guard (0...999).contains(stream) else { throw BridgeError("Invalid stream") }
    }

    /// Runs ffmpeg with the arguments for an output file, and returns the file.
    private static func run(extension: String, what: String, arguments: (String) -> [String]) async throws -> Data {
        let ffmpeg = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            throw BridgeError("This build of MacPopup has no ffmpeg (see scripts/build.sh)")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("macpopup-clip-\(UUID().uuidString).\(`extension`)")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"] + arguments(output.path)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError("ffmpeg couldn’t \(what): \(message.isEmpty ? "status \(status)" : message)")
        }
        return try Data(contentsOf: output)
    }
}
