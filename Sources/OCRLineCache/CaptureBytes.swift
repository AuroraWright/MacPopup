import CoreGraphics

extension CGImage {
    /// `body` with the image's bytes and row length, when it's laid out as ScreenCaptureKit's captures are (8-bit BGRA,
    /// alpha premultiplied or none, little-endian, in an RGB color space): the engines take their pixels from those bytes
    /// instead of drawing the image. Nil for other images.
    public func withCaptureBytes<R>(_ body: (UnsafePointer<UInt8>, _ bytesPerRow: Int) throws -> R) rethrows -> R? {
        guard bitsPerComponent == 8, colorSpace?.model == .rgb, alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst,
              bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little else { return nil }
        return try withPixelBytes(body)
    }

    /// `body` with the bytes of a 32-bit-per-pixel image and their row length, nil if it has none (or too few).
    public func withPixelBytes<R>(_ body: (UnsafePointer<UInt8>, _ bytesPerRow: Int) throws -> R) rethrows -> R? {
        guard bitsPerPixel == 32, let data = dataProvider?.data, let pixels = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= bytesPerRow * (height - 1) + 4 * width else { return nil }
        return try withExtendedLifetime(data) { try body(pixels, bytesPerRow) }
    }
}
