// Draws the SuZu Media Utils app icon and writes Resources/AppIcon.icns (+ a 1024 px PNG).
// usage: swift tools/make_icon.swift
import AppKit
import CoreGraphics

func draw(_ ctx: CGContext, _ S: CGFloat) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                             CGFloat(hex & 255) / 255, a])!
    }
    let k = S / 1024
    // macOS icon grid: 824 pt rounded square centred on a 1024 canvas, with a soft drop shadow.
    let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: color(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0xE0405E)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0xFF9A3C), color(0xF2454F), color(0xB81E7A)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // Gloss on the upper half.
    let gloss = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])

    let c = CGPoint(x: 512 * k, y: 530 * k)
    // Lens: thick white ring.
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(46 * k)
    ctx.strokeEllipse(in: CGRect(x: c.x - 270 * k, y: c.y - 270 * k, width: 540 * k, height: 540 * k))

    // Face: head and shoulders, clipped to the lens.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 232 * k, y: c.y - 232 * k, width: 464 * k, height: 464 * k)); ctx.clip()
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: c.x - 92 * k, y: c.y - 10 * k, width: 184 * k, height: 196 * k))
    ctx.fillEllipse(in: CGRect(x: c.x - 200 * k, y: c.y - 330 * k, width: 400 * k, height: 320 * k))
    ctx.restoreGState()

    // Play badge for video, bottom right.
    let b = CGPoint(x: 735 * k, y: 300 * k), r = 112 * k
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 16 * k, color: color(0x000000, 0.3))
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: b.x - r, y: b.y - r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
    ctx.move(to: CGPoint(x: b.x - 34 * k, y: b.y + 52 * k))
    ctx.addLine(to: CGPoint(x: b.x + 58 * k, y: b.y))
    ctx.addLine(to: CGPoint(x: b.x - 34 * k, y: b.y - 52 * k))
    ctx.closePath()
    ctx.setFillColor(color(0xE23B5A)); ctx.fillPath()
    ctx.restoreGState()
}

func png(_ size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, CGFloat(size))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
