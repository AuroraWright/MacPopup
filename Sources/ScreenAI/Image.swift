import Accelerate
import Foundation

/// 8-bit gray image, rows packed (stride == width).
struct GrayImage {
    var width = 0, height = 0
    var data: [UInt8] = []

    init() {}

    init(width: Int, height: Int, data: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.data = data ?? [UInt8](repeating: 0, count: width * height)
    }

    /// visionkit ImageConversion: gray = (77 R + 150 G + 29 B + 128) >> 8; alpha is ignored. `rgba` rows are
    /// `bytesPerRow` apart.
    init(rgba: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        self.width = width
        self.height = height
        guard width > 0 && height > 0 else { return }
        // Every byte is written below.
        data = [UInt8](unsafeUninitializedCapacity: width * height) { _, count in count = width * height }
        data.withUnsafeMutableBytes { out in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: rgba), height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: bytesPerRow)
            var dst = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width)
            // Integer weights over a divisor of 256, with the rounding term before the shift: the same bytes.
            let weights: [Int16] = [77, 150, 29, 0]
            vImageMatrixMultiply_ARGB8888ToPlanar8(&src, &dst, weights, 256, nil, 128, vImage_Flags(kvImageNoFlags))
        }
    }

    /// Copies `rows` runs of `count` bytes from `src` (starting at `srcStart`, `srcStride` apart) into `dst`
    /// (starting at `dstStart`, `dstStride` apart).
    static func copyRows(_ src: [UInt8], _ srcStart: Int, _ srcStride: Int, _ dst: inout [UInt8], _ dstStart: Int,
                         _ dstStride: Int, count: Int, rows: Int) {
        guard count > 0 else { return }
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                for y in 0..<rows {
                    (d.baseAddress! + dstStart + y * dstStride).update(from: s.baseAddress! + srcStart + y * srcStride, count: count)
                }
            }
        }
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { data[y * width + x] }
        set { data[y * width + x] = newValue }
    }
}
