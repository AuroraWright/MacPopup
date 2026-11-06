import CoreGraphics
import CoreVideo
import Foundation
import os

/// The screen frame the broadcast extension (Broadcast/) hands to the app for continuous mode: the App Group's
/// frame.bin, replaced whole for each frame, and a Darwin notification. A 64-byte header (little-endian UInt32s:
/// magic, pixel format, width, height, orientation, plane count, then each plane's bytes per row and height, and the
/// frame's number as a UInt64 at 56), then the planes' bytes.
enum SharedFrame {
    static let notification = "local.macpopup.ios.frame"
    /// Posted when a broadcast starts and finishes.
    static let startedNotification = "local.macpopup.ios.broadcast-started"
    static let finishedNotification = "local.macpopup.ios.broadcast-finished"
    static let magic: UInt32 = 0x3146_504D  // "MPF1"
    static let headerSize = 64

    static var url: URL? { AppGroup.folder?.appendingPathComponent("frame.bin") }

    /// Settings the app and the extension share.
    static let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    /// The seconds between the frames the extension compares.
    static let intervalKey = "continuousInterval"
    static var interval: Double {
        let value = defaults.double(forKey: intervalKey)
        return value > 0 ? value : 0.5
    }

    /// When the broadcast extension last said it's running (it removes it when the broadcast finishes).
    static let broadcastAliveKey = "broadcastAlive"

    /// The share of an area's pixels, in percent, that must change clearly for a frame to differ (as MacPopup's OCR
    /// mode's ocrChangeThreshold).
    static let changeThresholdKey = "continuousChangeThreshold"
    static var changeThreshold: Double {
        let value = defaults.double(forKey: changeThresholdKey)
        return value > 0 ? value : 0.3
    }
    /// A broadcast is running: the extension said so in the last 30 s (it does every 10 s while frames come).
    static var isBroadcasting: Bool {
        Date().timeIntervalSince1970 - defaults.double(forKey: broadcastAliveKey) < 30
    }

    static let areasKey = "continuousAreas"
    /// The parts of the screen to watch and read; none means the whole screen.
    static var areas: [ScreenArea] {
        get { defaults.data(forKey: areasKey).flatMap { try? JSONDecoder().decode([ScreenArea].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: areasKey) }
    }

    struct Header {
        var pixelFormat: OSType
        var width: Int
        var height: Int
        /// CGImagePropertyOrientation's raw value: how the frame is turned from the way the screen shows it.
        var orientation: UInt32
        var planes: [(bytesPerRow: Int, height: Int)]
        var number: UInt64

        var data: Data {
            var data = Data(count: SharedFrame.headerSize)
            func put(_ value: UInt32, at offset: Int) {
                withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
            }
            put(SharedFrame.magic, at: 0)
            put(pixelFormat, at: 4)
            put(UInt32(width), at: 8)
            put(UInt32(height), at: 12)
            put(orientation, at: 16)
            put(UInt32(planes.count), at: 20)
            for (index, plane) in planes.prefix(2).enumerated() {
                put(UInt32(plane.bytesPerRow), at: 24 + index * 8)
                put(UInt32(plane.height), at: 28 + index * 8)
            }
            withUnsafeBytes(of: number.littleEndian) { data.replaceSubrange(56..<64, with: $0) }
            return data
        }

        init(pixelFormat: OSType, width: Int, height: Int, orientation: UInt32, planes: [(bytesPerRow: Int, height: Int)], number: UInt64) {
            self.pixelFormat = pixelFormat
            self.width = width
            self.height = height
            self.orientation = orientation
            self.planes = planes
            self.number = number
        }

        init?(_ data: Data) {
            guard data.count >= SharedFrame.headerSize else { return nil }
            func get(_ offset: Int) -> UInt32 {
                data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            }
            guard get(0) == SharedFrame.magic else { return nil }
            pixelFormat = get(4)
            width = Int(get(8))
            height = Int(get(12))
            orientation = get(16)
            planes = (0..<min(Int(get(20)), 2)).map { (Int(get(24 + $0 * 8)), Int(get(28 + $0 * 8))) }
            number = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 56, as: UInt64.self)) }
            guard data.count >= SharedFrame.headerSize + planes.reduce(0, { $0 + $1.bytesPerRow * $1.height }) else { return nil }
        }
    }

    /// Posts a Darwin notification: by default, that a frame is ready.
    static func announce(_ name: String = notification) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }
}

/// A part of the screen continuous mode watches and reads, drawn by the user on a captured frame: normalized to the
/// screen as shown (origin at the top left). It applies only while the screen is turned the way it was drawn.
struct ScreenArea: Codable, Equatable, Identifiable {
    var id = UUID()
    var rect: CGRect
    var landscape: Bool

    /// The areas for a screen shown at this size.
    static func matching(_ areas: [ScreenArea], width: Int, height: Int) -> [ScreenArea] {
        areas.filter { $0.landscape == (width > height) }
    }

    /// The area in a frame's pixels, which are turned from the screen by the orientation (CGImagePropertyOrientation's
    /// raw value; mirrored ones aren't sent).
    func pixels(inFrameOf width: Int, height: Int, orientation: UInt32) -> CGRect {
        // A point on the screen (x, y) in the frame (u, v), all normalized.
        let toFrame: (CGPoint) -> CGPoint = switch orientation {
        case 3: { CGPoint(x: 1 - $0.x, y: 1 - $0.y) }  // down
        case 6: { CGPoint(x: $0.y, y: 1 - $0.x) }  // right: the frame's top row is the screen's right side
        case 8: { CGPoint(x: 1 - $0.y, y: $0.x) }  // left: the frame's top row is the screen's left side
        default: { $0 }
        }
        let a = toFrame(CGPoint(x: rect.minX, y: rect.minY)), b = toFrame(CGPoint(x: rect.maxX, y: rect.maxY))
        let normalized = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return CGRect(
            x: normalized.minX * CGFloat(width), y: normalized.minY * CGFloat(height),
            width: normalized.width * CGFloat(width), height: normalized.height * CGFloat(height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// The process's memory use, as iOS counts it against its limit.
enum Memory {
    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak))) : (0, 0)
    }

    /// What the process can still use before iOS ends it.
    static func available() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
