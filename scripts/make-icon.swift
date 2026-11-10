// Draws the app icon (a pink あ in a speech bubble on a blue tile, after the trans flag's colors) and writes it as an .icns.
// usage: swift scripts/make-icon.swift Resources/AppIcon.icns
//        swift scripts/make-icon.swift ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// Drawn on the 1024 grid of macOS icons (an 824 tile with its shadow); 16 and 32 px get a bigger tile, bubble and あ,
// without the shadow. The iOS one (a .png) is the tile alone, square and opaque, as iOS rounds the corners itself. あ is Noto Sans JP ExtraBold's outline (SIL Open Font License), in font units with y up.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let glyph = "M503 808Q498 793 495 779Q492 765 489 753Q479 705 470.5 645Q462 585 457 521Q452 457 452 397Q452 314 460.5 247.5Q469 181 484 125Q499 69 515 18L388 -19Q373 26 359.5 88.5Q346 151 337 224Q328 297 328 373Q328 422 331 472Q334 522 338.5 570.5Q343 619 348 664.5Q353 710 357 748Q359 763 360 780.5Q361 798 360 812ZM320 702Q417 702 500 705.5Q583 709 659.5 719Q736 729 815 748L816 621Q766 612 703 604.5Q640 597 572 592Q504 587 438 584.5Q372 582 316 582Q288 582 255 583.5Q222 585 190 586.5Q158 588 134 589L130 715Q148 713 180.5 709.5Q213 706 250 704Q287 702 320 702ZM756 547Q752 538 745.5 520Q739 502 733 483.5Q727 465 723 454Q695 364 653.5 290.5Q612 217 564.5 162.5Q517 108 471 74Q422 38 357.5 9.5Q293 -19 225 -19Q188 -19 156.5 -3.5Q125 12 105.5 46Q86 80 86 132Q86 186 108 238.5Q130 291 169.5 338.5Q209 386 261 422.5Q313 459 374 481Q423 498 482.5 509Q542 520 600 520Q694 520 768 486.5Q842 453 886 392.5Q930 332 930 252Q930 199 913.5 147.5Q897 96 858.5 53Q820 10 757 -22Q694 -54 600 -68L527 48Q625 59 683 92Q741 125 767 169.5Q793 214 793 258Q793 300 770 333.5Q747 367 702 387.5Q657 408 591 408Q522 408 468.5 392.5Q415 377 379 360Q331 337 294 302Q257 267 236.5 229.5Q216 192 216 162Q216 139 226 127Q236 115 259 115Q295 115 341.5 139.5Q388 164 433 207Q485 255 530 321Q575 387 604 486Q608 497 611 514.5Q614 532 617 550Q620 568 621 579Z"

func glyphPath() -> CGPath {
    let path = CGMutablePath()
    let scanner = Scanner(string: glyph)
    func point() -> CGPoint { CGPoint(x: scanner.scanDouble()!, y: scanner.scanDouble()!) }
    while let command = scanner.scanCharacter() {
        switch command {
        case "M": path.move(to: point())
        case "L": path.addLine(to: point())
        case "Q": let control = point(); path.addQuadCurve(to: point(), control: control)
        case "Z": path.closeSubpath()
        default: fatalError("unknown path command \(command)")
        }
    }
    return path
}

func color(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

struct Layout {
    var tile: CGRect, tileRadius: CGFloat, shadow: Bool
    var bubble: CGRect, tail: [CGPoint], glyphHeight: CGFloat
}

let large = Layout(tile: CGRect(x: 100, y: 100, width: 824, height: 824), tileRadius: 185, shadow: true,
                   bubble: CGRect(x: 216, y: 226, width: 592, height: 476),
                   tail: [CGPoint(x: 330, y: 640), CGPoint(x: 282, y: 812), CGPoint(x: 500, y: 690)], glyphHeight: 303)
let small = Layout(tile: CGRect(x: 56, y: 56, width: 912, height: 912), tileRadius: 205, shadow: false,
                   bubble: CGRect(x: 160, y: 176, width: 704, height: 560),
                   tail: [CGPoint(x: 300, y: 680), CGPoint(x: 250, y: 880), CGPoint(x: 520, y: 730)], glyphHeight: 380)

func draw(pixels: Int, iOS: Bool = false) -> CGImage {
    var layout = pixels <= 32 ? small : large
    let alpha = iOS ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    // The 1024 grid, top down.
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    if iOS {
        // The tile fills the picture.
        context.scaleBy(x: 1024 / layout.tile.width, y: 1024 / layout.tile.height)
        context.translateBy(x: -layout.tile.minX, y: -layout.tile.minY)
        layout.tileRadius = 0
        layout.shadow = false
    }

    let tile = CGPath(roundedRect: layout.tile, cornerWidth: layout.tileRadius, cornerHeight: layout.tileRadius, transform: nil)
    if layout.shadow {
        context.saveGState()
        // CG shadow offsets ignore the flip and the scale: down 10 and blurred 24 on the grid.
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(tile)
        context.setFillColor(color(0x238fe9))
        context.fillPath()
        context.restoreGState()
    }
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0x54b8fe), color(0x238fe9)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: layout.tile.minY), end: CGPoint(x: 0, y: layout.tile.maxY), options: [])
    context.restoreGState()

    let radius = layout.bubble.height / 2
    context.addPath(CGPath(roundedRect: layout.bubble, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.addLines(between: layout.tail)
    context.closePath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(14)
    context.setLineJoin(.round)
    context.drawPath(using: .fillStroke)

    // あ centered in the bubble.
    let path = glyphPath()
    let box = path.boundingBoxOfPath
    let size = layout.glyphHeight / box.height
    context.translateBy(x: layout.bubble.midX, y: layout.bubble.midY)
    context.scaleBy(x: size, y: -size)
    context.translateBy(x: -box.midX, y: -box.midY)
    context.addPath(path)
    context.clip()
    // Top down; the glyph's y is up.
    let pink = CGGradient(colorsSpace: nil, colors: [color(0xf5a7b9), color(0xf096ad)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(pink, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
if output.pathExtension == "png" {
    writePNG(draw(pixels: 1024, iOS: true), to: output)
    print("wrote \(output.path)")
    exit(0)
}
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        writePNG(draw(pixels: points * factor), to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote \(output.path), from \(iconset.path)" : "iconutil failed")
exit(iconutil.terminationStatus)
