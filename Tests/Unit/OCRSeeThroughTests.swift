// Floating windows over a whole display (OCRController.isSeeThrough): an overlay such as a screen dimmer, drawn in a
// see-through color, isn't a window to read; a player kept on top in full screen, drawn opaque, is, also with a clear
// strip (a bar it draws see-through).
import CoreGraphics
import Testing
@testable import MacPopup

/// A 64×40 image filled with `alpha` black, with its top `opaqueRows` rows opaque white.
private func image(alpha: CGFloat, opaqueRows: Int = 0) -> CGImage {
    let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: alpha))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 40 - opaqueRows, width: 64, height: opaqueRows))
    return context.makeImage()!
}

@Test func seeThrough() {
    #expect(OCRController.isSeeThrough(image(alpha: 0.1)))
    #expect(OCRController.isSeeThrough(image(alpha: 0.6)))
    #expect(OCRController.isSeeThrough(image(alpha: 0)))
    #expect(OCRController.isSeeThrough(image(alpha: 0.1, opaqueRows: 12)))
    #expect(!OCRController.isSeeThrough(image(alpha: 1)))
    #expect(!OCRController.isSeeThrough(image(alpha: 0, opaqueRows: 30)))
}
