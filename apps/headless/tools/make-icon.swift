// Renders the full-bleed Headless app icon: a cream H over the product's wave palette.
// Usage: swift tools/make-icon.swift <output.iconset>

import Cocoa

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

private let artFrame = NSRect(x: 0, y: 0, width: 1024, height: 1024)
private let sourceSize: CGFloat = 512

private func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

private func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    let scale = artFrame.width / sourceSize
    return NSPoint(x: artFrame.minX + x * scale, y: artFrame.maxY - y * scale)
}

private func drawWaveArtwork() {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    color(0x853953).setFill()
    artFrame.fill()

    let middle = NSBezierPath()
    middle.move(to: point(0, 184))
    middle.line(to: point(67, 199))
    middle.curve(
        to: point(108, 190),
        controlPoint1: point(84, 202),
        controlPoint2: point(92, 199)
    )
    middle.line(to: point(233, 116))
    middle.curve(
        to: point(279, 120),
        controlPoint1: point(249, 108),
        controlPoint2: point(263, 111)
    )
    middle.line(to: point(410, 199))
    middle.curve(
        to: point(440, 196),
        controlPoint1: point(420, 203),
        controlPoint2: point(428, 200)
    )
    middle.line(to: point(512, 182))
    middle.line(to: point(512, 365))
    middle.line(to: point(439, 377))
    middle.curve(
        to: point(407, 373),
        controlPoint1: point(425, 380),
        controlPoint2: point(417, 378)
    )
    middle.line(to: point(279, 326))
    middle.curve(
        to: point(234, 326),
        controlPoint1: point(260, 318),
        controlPoint2: point(251, 318)
    )
    middle.line(to: point(105, 374))
    middle.curve(
        to: point(68, 377),
        controlPoint1: point(92, 379),
        controlPoint2: point(83, 380)
    )
    middle.line(to: point(0, 365))
    middle.close()
    color(0x0F3040).setFill()
    middle.fill()

    let top = NSBezierPath()
    top.move(to: point(0, 0))
    top.line(to: point(512, 0))
    top.line(to: point(512, 182))
    top.line(to: point(440, 196))
    top.curve(
        to: point(410, 199),
        controlPoint1: point(428, 200),
        controlPoint2: point(420, 203)
    )
    top.line(to: point(279, 120))
    top.curve(
        to: point(233, 116),
        controlPoint1: point(263, 111),
        controlPoint2: point(249, 108)
    )
    top.line(to: point(108, 190))
    top.curve(
        to: point(67, 199),
        controlPoint1: point(92, 199),
        controlPoint2: point(84, 202)
    )
    top.line(to: point(0, 184))
    top.close()
    color(0x2C5745).setFill()
    top.fill()

    let monogram = NSBezierPath()
    monogram.move(to: point(81, 63))
    monogram.curve(
        to: point(168, 95),
        controlPoint1: point(114, 63),
        controlPoint2: point(145, 72)
    )
    monogram.curve(
        to: point(181, 158),
        controlPoint1: point(180, 105),
        controlPoint2: point(178, 131)
    )
    monogram.curve(
        to: point(244, 228),
        controlPoint1: point(185, 199),
        controlPoint2: point(207, 226)
    )
    monogram.curve(
        to: point(318, 157),
        controlPoint1: point(282, 230),
        controlPoint2: point(309, 198)
    )
    monogram.line(to: point(319, 63))
    monogram.curve(
        to: point(409, 94),
        controlPoint1: point(357, 62),
        controlPoint2: point(388, 71)
    )
    monogram.curve(
        to: point(418, 145),
        controlPoint1: point(418, 104),
        controlPoint2: point(418, 124)
    )
    monogram.line(to: point(418, 382))
    monogram.curve(
        to: point(426, 455),
        controlPoint1: point(418, 410),
        controlPoint2: point(420, 438)
    )
    monogram.curve(
        to: point(329, 460),
        controlPoint1: point(391, 474),
        controlPoint2: point(350, 479)
    )
    monogram.curve(
        to: point(320, 389),
        controlPoint1: point(317, 449),
        controlPoint2: point(320, 420)
    )
    monogram.curve(
        to: point(251, 321),
        controlPoint1: point(320, 351),
        controlPoint2: point(291, 321)
    )
    monogram.curve(
        to: point(180, 389),
        controlPoint1: point(211, 321),
        controlPoint2: point(180, 350)
    )
    monogram.curve(
        to: point(181, 454),
        controlPoint1: point(180, 420),
        controlPoint2: point(185, 448)
    )
    monogram.curve(
        to: point(120, 473),
        controlPoint1: point(159, 468),
        controlPoint2: point(139, 476)
    )
    monogram.curve(
        to: point(82, 415),
        controlPoint1: point(94, 469),
        controlPoint2: point(82, 445)
    )
    monogram.line(to: point(81, 63))
    monogram.close()
    color(0xFBF7EF).setFill()
    monogram.fill()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true

    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(px) / 1024)
    scale.concat()
    drawWaveArtwork()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    try render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("iconset written to \(outDir)")
