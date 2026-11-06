import CoreGraphics
import Foundation
import ImageIO
import OCREngines
import UniformTypeIdentifiers

/// Online text recognition (Settings → OCR Mode → Cloud recognition (second pass)), with the requests owocr makes: Google
/// Lens (as Chrome's Lens overlay sends them) and Bing's visual search, both as Chrome (see ImpersonatedSession). Both
/// find the language by themselves. A request often takes a second or more, so OCR mode only uses them for a final
/// reading (see OCRController.finishReading).
enum CloudOCR: String {
    case googleLens
    case bing

    var name: String {
        switch self {
        case .googleLens: "Google Lens"
        case .bing: "Bing"
        }
    }

    /// The lines of `image`, boxes normalized to it.
    func recognize(_ image: CGImage, language: String) async throws -> [RecognizedLine] {
        do {
            switch self {
            case .googleLens: return try await GoogleLens.recognize(image, language: language)
            case .bing: return try await Bing.recognize(image)
            }
        } catch let error as URLError where error.code == .timedOut {
            throw BridgeError("\(name): the request timed out")
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BridgeError("\(name): \(error.localizedDescription)")
        }
    }

    /// Each engine's session (Bing's second request needs the cookies of its first), made when it's first used.
    fileprivate var session: ImpersonatedSession {
        get throws {
            try Self.sessionsLock.withLock {
                if let session = Self.sessions[self] { return session }
                let session = try ImpersonatedSession()
                Self.sessions[self] = session
                return session
            }
        }
    }

    private nonisolated(unsafe) static var sessions: [CloudOCR: ImpersonatedSession] = [:]
    private static let sessionsLock = NSLock()

    /// A response other than the expected one.
    fileprivate func failure(_ response: ImpersonatedSession.Response, expected: Int) -> BridgeError {
        BridgeError(response.status == expected ? "\(name): unexpected response" : "\(name): the server answered \(response.status)")
    }
}

// MARK: Google Lens

private enum GoogleLens {
    /// Chrome's key for the Lens overlay (as owocr uses it).
    static let apiKey = "AIzaSyDr2UxVnv_U85AbhhY8XSHSIavUW0DC-sY"
    static let maxPixels = 3_000_000

    static func recognize(_ image: CGImage, language: String) async throws -> [RecognizedLine] {
        var image = image
        if image.width * image.height > maxPixels {
            let aspect = Double(image.width) / Double(image.height)
            let width = Int((Double(maxPixels) * aspect).squareRoot())
            image = try resized(image, width: width, height: Int(Double(width) / aspect))
        }
        let png = try encoded(image, as: .png)
        let response = try await CloudOCR.googleLens.session.post(
            "https://lensfrontend-pa.googleapis.com/v1/crupload",
            headers: [
                ("Host", "lensfrontend-pa.googleapis.com"), ("Connection", "keep-alive"), ("Content-Type", "application/x-protobuf"),
                ("X-Goog-Api-Key", apiKey), ("Sec-Fetch-Mode", "no-cors"), ("Sec-Fetch-Dest", "empty"),
            ],
            body: Data(requestBody(png: png, width: image.width, height: image.height, language: language))
        )
        guard response.status == 200 else { throw CloudOCR.googleLens.failure(response, expected: 200) }
        return try lines(ProtoMessage([UInt8](response.body)[...]), width: image.width, height: image.height)
    }

    /// A LensOverlayServerRequest with an objects request for the image.
    static func requestBody(png: Data, width: Int, height: Int, language: String) -> [UInt8] {
        var request = ProtoWriter()
        request.message(1) { objects in  // objects_request
            objects.message(1) { context in  // request_context
                context.message(3) { id in  // request_id
                    id.varint(1, UInt64.random(in: 0...UInt64.max))  // uuid
                    id.bytes(4, (0..<16).map { _ in UInt8.random(in: 0...255) })  // analytics_id
                    id.message(6) { _ in }  // routing_info
                }
                context.message(4) { client in  // client_context
                    client.varint(1, 3)  // platform: PLATFORM_WEB
                    client.varint(2, 4)  // surface: SURFACE_CHROMIUM
                    client.message(4) { locale in  // locale_context
                        locale.string(1, language)
                        locale.string(2, "Asia/Tokyo")
                    }
                    client.message(17) { filters in  // client_filters
                        filters.message(1) { $0.varint(1, 7) }  // filter: AUTO_FILTER
                    }
                }
            }
            objects.message(3) { data in  // image_data
                data.message(1) { $0.bytes(1, [UInt8](png)) }  // payload.image_bytes
                data.message(3) { metadata in  // image_metadata
                    metadata.varint(1, UInt64(width))
                    metadata.varint(2, UInt64(height))
                }
            }
        }
        return request.data
    }

    /// The text layout of a LensOverlayServerResponse: its paragraphs' lines, with their words.
    static func lines(_ response: ProtoMessage, width: Int, height: Int) throws -> [RecognizedLine] {
        if response.message(1) != nil, response.message(2) == nil { throw BridgeError("Google Lens: the server returned an error") }
        let layout = response.message(2)?.message(3)?.message(1)  // objects_response.text.text_layout
        var lines: [RecognizedLine] = []
        for paragraph in layout?.messages(1) ?? [] {
            for line in paragraph.messages(2) {
                var text = ""
                var words: [(text: String, box: CGRect)] = []
                for word in line.messages(1) {
                    let plain = word.string(2) ?? ""
                    text += plain + (word.string(3) ?? "")
                    if let box = word.message(4)?.message(1) { words.append((plain, bounds(box, width: width, height: height))) }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let box = line.message(2)?.message(1).map { bounds($0, width: width, height: height) }
                    ?? words.map(\.box).reduce(CGRect.null) { $0.union($1) }
                lines.append(RecognizedLine(text: text, box: box, words: words))
            }
        }
        return lines
    }

    /// A CenterRotatedBox's bounds, normalized to the image (as its coordinates are, unless it says they're pixels).
    static func bounds(_ box: ProtoMessage, width: Int, height: Int) -> CGRect {
        let (w, h) = (CGFloat(width), CGFloat(height))
        let isPixels = box.number(6) == 2  // coordinate_type: IMAGE
        let scaleX = isPixels ? 1 : w, scaleY = isPixels ? 1 : h
        let center = CGPoint(x: CGFloat(box.float(1) ?? 0) * scaleX, y: CGFloat(box.float(2) ?? 0) * scaleY)
        let size = CGSize(width: CGFloat(box.float(3) ?? 0) * scaleX, height: CGFloat(box.float(4) ?? 0) * scaleY)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        let rotated = rect.applying(
            CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: CGFloat(box.float(5) ?? 0))
                .translatedBy(x: -center.x, y: -center.y)
        )
        return CGRect(x: rotated.minX / w, y: rotated.minY / h, width: rotated.width / w, height: rotated.height / h)
    }
}

// MARK: Bing

private enum Bing {
    static let minSide = 50
    static let maxSide = 4000
    static let maxBytes = 767_772

    static func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        let (upload, host) = try await uploaded(try encodedForUpload(image))
        guard let token = URLComponents(string: upload)?.queryItems?.first(where: { $0.name == "insightsToken" })?.value else {
            throw BridgeError("Bing: no token for the image")
        }
        let knowledge: [String: Any] = [
            "imageInfo": ["imageInsightsToken": token, "source": "Url"],
            "knowledgeRequest": ["invokedSkills": ["OCR"], "index": 1],
        ]
        let response = try await CloudOCR.bing.session.post(
            "https://\(host)/images/api/custom/knowledge",
            headers: [("Origin", "https://www.bing.com"), ("Referer", "https://www.bing.com/images/search?view=detailV2&insightstoken=\(token)")],
            parts: [.init(name: "knowledgeRequest", contentType: "application/json", data: try JSONSerialization.data(withJSONObject: knowledge))]
        )
        guard response.status == 200, let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw CloudOCR.bing.failure(response, expected: 200)
        }
        return lines(json)
    }

    /// Uploads the image: the search page it redirects to (with the image's token), and the host that answered.
    static func uploaded(_ image: Data) async throws -> (location: String, host: String) {
        var url = URL(string: "https://www.bing.com/images/search?view=detailv2&iss=sbiupload")!
        // Bing may redirect to another host first.
        for _ in 0..<2 {
            let response = try await CloudOCR.bing.session.post(
                url.absoluteString,
                headers: [("Origin", "https://www.bing.com")],
                parts: [.init(name: "imgurl", data: Data()), .init(name: "cbir", data: Data("sbi".utf8)), .init(name: "imageBin", data: image.base64EncodedData())]
            )
            guard response.status == 302, let location = response.location else { throw CloudOCR.bing.failure(response, expected: 302) }
            guard location.hasPrefix("https://"), let next = URL(string: location) else { return (location, url.host ?? "www.bing.com") }
            url = next
        }
        throw BridgeError("Bing: too many redirects")
    }

    /// PNG (or JPEG when that's too big), at most `maxBytes`, `minSide` to `maxSide` pixels a side.
    static func encodedForUpload(_ image: CGImage) throws -> Data {
        var image = image
        let (width, height) = (Double(image.width), Double(image.height))
        if image.width < minSide || image.height < minSide {
            let factor = max(Double(minSide) / width, Double(minSide) / height)
            image = try resized(image, width: Int(width * factor), height: Int(height * factor))
        }
        if image.width > maxSide || image.height > maxSide {
            let factor = min(Double(maxSide) / Double(image.width), Double(maxSide) / Double(image.height))
            image = try resized(image, width: Int(Double(image.width) * factor), height: Int(Double(image.height) * factor))
        }
        let png = try encoded(image, as: .png)
        if png.count <= maxBytes { return png }
        let factor = max(image.width, image.height) > 2000 ? 0.6 : 0.75
        let smaller = try resized(image, width: Int(Double(image.width) * factor), height: Int(Double(image.height) * factor))
        let smallerPNG = try encoded(smaller, as: .png)
        if smallerPNG.count <= maxBytes { return smallerPNG }
        for candidate in [image, smaller] {
            for quality in stride(from: 0.8, through: 0.6, by: -0.05) {
                let jpeg = try encoded(candidate, as: .jpeg, quality: quality)
                if jpeg.count <= maxBytes { return jpeg }
            }
        }
        throw BridgeError("Bing: the image is too big")
    }

    /// The text recognition action's regions' lines (boxes are normalized to the image).
    static func lines(_ response: [String: Any]) -> [RecognizedLine] {
        let tag = (response["tags"] as? [[String: Any]] ?? []).first { $0["displayName"] as? String == "##TextRecognition" }
        let action = (tag?["actions"] as? [[String: Any]] ?? []).first { $0["_type"] as? String == "ImageKnowledge/TextRecognitionAction" }
        let regions = (action?["data"] as? [String: Any])?["regions"] as? [[String: Any]] ?? []
        return regions.flatMap { region in
            (region["lines"] as? [[String: Any]] ?? []).compactMap { line -> RecognizedLine? in
                guard let text = line["text"] as? String, !text.isEmpty, let box = bounds(line["boundingBox"]) else { return nil }
                let words = (line["words"] as? [[String: Any]] ?? []).compactMap { word -> (text: String, box: CGRect)? in
                    guard let text = word["text"] as? String, let box = bounds(word["boundingBox"]) else { return nil }
                    return (text, box)
                }
                return RecognizedLine(text: text, box: box, words: words)
            }
        }
    }

    /// The bounds of a quadrilateral (topLeft, topRight, bottomRight, bottomLeft).
    static func bounds(_ quad: Any?) -> CGRect? {
        guard let quad = quad as? [String: Any] else { return nil }
        let points = ["topLeft", "topRight", "bottomRight", "bottomLeft"].compactMap { corner -> CGPoint? in
            guard let point = quad[corner] as? [String: Any], let x = point["x"] as? Double, let y = point["y"] as? Double else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard points.count == 4 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

// MARK: Images

private func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    guard width > 0, height > 0,
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          )
    else { throw BridgeError("Couldn’t resize the image") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let resized = context.makeImage() else { throw BridgeError("Couldn’t resize the image") }
    return resized
}

private func encoded(_ image: CGImage, as type: UTType, quality: Double? = nil) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        throw BridgeError("Couldn’t encode the image")
    }
    let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, options)
    guard CGImageDestinationFinalize(destination) else { throw BridgeError("Couldn’t encode the image") }
    return data as Data
}

// MARK: Protocol Buffers

/// Protocol Buffers' wire format, as far as the Lens request needs it (proto3: zero values are left out).
private struct ProtoWriter {
    private(set) var data: [UInt8] = []

    private mutating func append(varint value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        append(varint: UInt64(field << 3))
        append(varint: value)
    }

    mutating func bytes(_ field: Int, _ value: [UInt8]) {
        append(varint: UInt64(field << 3 | 2))
        append(varint: UInt64(value.count))
        data += value
    }

    mutating func string(_ field: Int, _ value: String) {
        if !value.isEmpty { bytes(field, Array(value.utf8)) }
    }

    /// A message field, present even when empty.
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var message = ProtoWriter()
        build(&message)
        bytes(field, message.data)
    }
}

/// A decoded message: each field's values in order, varints and fixed-size numbers as their bits, the rest as bytes.
private struct ProtoMessage {
    enum Value {
        case number(UInt64)
        case bytes(ArraySlice<UInt8>)
    }

    private var fields: [Int: [Value]] = [:]

    init(_ data: ArraySlice<UInt8>) throws {
        var index = data.startIndex
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex, shift < 64 {
                let byte = data[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            throw BridgeError("Google Lens: malformed response")
        }
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, data.endIndex - index >= count else { throw BridgeError("Google Lens: malformed response") }
            defer { index += count }
            return data[index..<(index + count)]
        }
        func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        while index < data.endIndex {
            let key = try varint()
            let value: Value
            switch key & 7 {
            case 0: value = .number(try varint())
            case 1: value = .number(littleEndian(try take(8)))
            case 2: value = .bytes(try take(Int(try varint())))
            case 5: value = .number(littleEndian(try take(4)))
            default: throw BridgeError("Google Lens: malformed response")
            }
            fields[Int(key >> 3), default: []].append(value)
        }
    }

    func messages(_ field: Int) -> [ProtoMessage] {
        (fields[field] ?? []).compactMap { value in
            if case let .bytes(bytes) = value { try? ProtoMessage(bytes) } else { nil }
        }
    }

    func message(_ field: Int) -> ProtoMessage? {
        messages(field).last
    }

    func string(_ field: Int) -> String? {
        guard case let .bytes(bytes) = fields[field]?.last else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    func number(_ field: Int) -> UInt64? {
        guard case let .number(value) = fields[field]?.last else { return nil }
        return value
    }

    func float(_ field: Int) -> Float? {
        number(field).map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
    }
}
