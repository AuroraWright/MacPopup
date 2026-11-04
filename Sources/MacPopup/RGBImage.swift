import CoreGraphics
import CoreML

/// An image's pixels as 8-bit RGB(A), for the models' inputs (meikiocr's and PP-OCRv6_manga's).
struct RGBImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        let (width, height) = (image.width, image.height)
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    private init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The pixels of `rect` (whole pixels, within the image), turned 90° counterclockwise if `rotated` (as OpenCV's
    /// ROTATE_90_COUNTERCLOCKWISE: the top row becomes the left column, read from the bottom up).
    func cropped(_ rect: CGRect, rotated: Bool = false) -> RGBImage {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), cropWidth = Int(rect.width), cropHeight = Int(rect.height)
        var out = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { out in
                for y in 0..<cropHeight {
                    for x in 0..<cropWidth {
                        let from = ((y0 + y) * width + x0 + x) * 4
                        // Rotated, the crop's pixel (x, y) goes to column y, row (cropWidth - 1 - x).
                        let to = rotated ? ((cropWidth - 1 - x) * cropHeight + y) * 4 : (y * cropWidth + x) * 4
                        for channel in 0..<4 { out[to + channel] = source[from + channel] }
                    }
                }
            }
        }
        return rotated
            ? RGBImage(width: cropHeight, height: cropWidth, pixels: out)
            : RGBImage(width: cropWidth, height: cropHeight, pixels: out)
    }

    /// Resizes the part `source` (in pixels) to `width` x `height` (bilinear, like OpenCV's INTER_LINEAR) into the top
    /// left of `array` ([1, 3, H, W] floats, channels in OpenCV's order: blue, green, red); the rest is zero. Each value
    /// is (pixel / 255 - mean) / deviation, with the channel's `mean` and `deviation` (in that order too), the resized
    /// pixel rounded first if `rounded` (as OpenCV's resizing of 8-bit images has them).
    func write(
        _ source: CGRect, into array: MLMultiArray, width: Int, height: Int,
        mean: [Float] = [0, 0, 0], deviation: [Float] = [1, 1, 1], rounded: Bool = false
    ) {
        let arrayHeight = array.shape[2].intValue, arrayWidth = array.shape[3].intValue
        let plane = arrayHeight * arrayWidth
        let sourceX = Int(source.minX), sourceY = Int(source.minY)
        let sourceWidth = max(1, Int(source.width)), sourceHeight = max(1, Int(source.height))
        let scaleX = Double(sourceWidth) / Double(width), scaleY = Double(sourceHeight) / Double(height)
        // Each output column's two source columns and the weight of the second.
        let columns = (0..<min(width, arrayWidth)).map { x -> (Int, Int, Float) in
            let position = max((Double(x) + 0.5) * scaleX - 0.5, 0)
            let left = min(Int(position), sourceWidth - 1)
            return (sourceX + left, sourceX + min(left + 1, sourceWidth - 1), Float(position - Double(left)))
        }
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { output, _ in
            output.initialize(repeating: 0)
            pixels.withUnsafeBufferPointer { pixels in
                for y in 0..<min(height, arrayHeight) {
                    let position = max((Double(y) + 0.5) * scaleY - 0.5, 0)
                    let top = min(Int(position), sourceHeight - 1)
                    let row0 = (sourceY + top) * self.width * 4
                    let row1 = (sourceY + min(top + 1, sourceHeight - 1)) * self.width * 4
                    let wy = Float(position - Double(top))
                    for (x, (left, right, wx)) in columns.enumerated() {
                        for channel in 0..<3 {
                            // RGBA in, BGR out.
                            let p00 = Float(pixels[row0 + left * 4 + channel]), p01 = Float(pixels[row0 + right * 4 + channel])
                            let p10 = Float(pixels[row1 + left * 4 + channel]), p11 = Float(pixels[row1 + right * 4 + channel])
                            var value = (p00 * (1 - wx) + p01 * wx) * (1 - wy) + (p10 * (1 - wx) + p11 * wx) * wy
                            if rounded { value = value.rounded() }
                            output[(2 - channel) * plane + y * arrayWidth + x] = (value / 255 - mean[2 - channel]) / deviation[2 - channel]
                        }
                    }
                }
            }
        }
    }
}
