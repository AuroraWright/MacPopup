// Draws the app icon (a pink あ in a speech bubble on a blue tile, after the trans flag's colors).
// usage: swift scripts/make-icon.swift Resources/AppIcon.icon
//        swift scripts/make-icon.swift ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// The .icon is Icon Composer's (build.sh compiles it with actool: macOS 26's Liquid Glass icon, and an .icns actool
// renders from it for older macOS): the tile's gradient as its fill, the bubble as a glass layer and あ above it, on a square
// the tile fills (the system shapes the tile and adds its shadow). The iOS one (a .png) is the tile alone, square and
// opaque, as iOS rounds the corners itself. The README's Resources/AppIcon.png is the .icon as macOS 26 shows it:
// ictool Resources/AppIcon.icon --export-image --output-file Resources/AppIcon.png --platform macOS --rendition Default
// --width 512 --height 512 --scale 1 (ictool is in Xcode's Icon Composer.app, Contents/Executables).
// あ is Noto Sans JP ExtraBold's outline (SIL Open Font License), in font units with y up.
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

// On the 1024 grid of macOS icons, top down: an 824 tile, which the pictures are cropped to.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let bubble = CGRect(x: 216, y: 226, width: 592, height: 476)
let tail = [CGPoint(x: 330, y: 640), CGPoint(x: 282, y: 812), CGPoint(x: 500, y: 690)]
let glyphHeight: CGFloat = 303

enum Part { case tile, bubble, glyph }

/// The tile, 1024 pixels square, with `parts` drawn: opaque with the tile, else transparent around what's drawn.
func draw(_ parts: Set<Part>) -> CGImage {
    let alpha = parts.contains(.tile) ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    // The grid top down, the tile filling the picture.
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1024 / tile.width, y: -1024 / tile.height)
    context.translateBy(x: -tile.minX, y: -tile.minY)
    if parts.contains(.tile) {
        let gradient = CGGradient(colorsSpace: nil, colors: [color(tileTop), color(tileBottom)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    }
    if parts.contains(.bubble) {
        drawBubble(in: context)
    }
    if parts.contains(.glyph) {
        drawGlyph(in: context)
    }
    return context.makeImage()!
}

let tileTop = 0x54b8fe, tileBottom = 0x238fe9

func drawBubble(in context: CGContext) {
    let radius = bubble.height / 2
    context.addPath(CGPath(roundedRect: bubble, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.addLines(between: tail)
    context.closePath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(14)
    context.setLineJoin(.round)
    context.drawPath(using: .fillStroke)
}

func drawGlyph(in context: CGContext) {
    // あ centered in the bubble.
    let path = glyphPath()
    let box = path.boundingBoxOfPath
    let size = glyphHeight / box.height
    context.translateBy(x: bubble.midX, y: bubble.midY)
    context.scaleBy(x: size, y: -size)
    context.translateBy(x: -box.midX, y: -box.midY)
    context.addPath(path)
    context.clip()
    // Top down; the glyph's y is up.
    let pink = CGGradient(colorsSpace: nil, colors: [color(0xf5a7b9), color(0xf096ad)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(pink, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
if output.pathExtension == "icon" {
    let assets = output.appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    writePNG(draw([.glyph]), to: assets.appendingPathComponent("glyph.png"))
    writePNG(draw([.bubble]), to: assets.appendingPathComponent("bubble.png"))
    func srgb(_ hex: Int) -> String {
        "srgb:" + [hex >> 16 & 0xff, hex >> 8 & 0xff, hex & 0xff].map { String(format: "%.5f", Double($0) / 255) }.joined(separator: ",") + ",1.00000"
    }
    // The groups top first: あ in one of its own without glass, which outlined it and, in the bubble's group, dimmed it.
    let document: [String: Any] = [
        "fill": [
            "linear-gradient": [srgb(tileTop), srgb(tileBottom)],
            "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
        ],
        "groups": [
            ["layers": [["image-name": "glyph.png", "name": "glyph", "glass": false]]],
            [
                "layers": [["image-name": "bubble.png", "name": "bubble", "glass": true]],
                "shadow": ["kind": "neutral", "opacity": 0.5],
                "translucency": ["enabled": true, "value": 0.5],
            ],
        ],
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: output.appendingPathComponent("icon.json"))
    print("wrote \(output.path)")
    exit(0)
}
guard output.pathExtension == "png" else {
    print("usage: swift scripts/make-icon.swift <.icon or .png>")
    exit(1)
}
writePNG(draw([.tile, .bubble, .glyph]), to: output)
print("wrote \(output.path)")
