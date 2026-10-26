import CoreImage
@testable import MediaKit
import XCTest

final class MaskBrushTests: XCTestCase {
    func testStrokesLandWhereTheyWerePaintedWhateverTheTurnAndLevel() {
        var look = Adjustments()
        look.turns = 1; look.flipHorizontal = true
        let size = CGSize(width: 3000, height: 2000), p = CGPoint(x: 0.3, y: 0.7)
        for degrees in [nil, 4.5, -7.0] {
            let placed = MaskBrush.place([MaskStroke(points: [p], radius: 0.05, softness: 0, erase: false)], look: look, levelled: degrees, size: size)[0]
            let back = MaskBrush.unplace(placed.points[0], look: look, levelled: degrees, size: size)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-4)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-4)
        }
        // A quarter turn clockwise: the left edge of the photo as shot becomes its top.
        var turn = Adjustments(); turn.turns = 1
        let top = MaskBrush.place([MaskStroke(points: [CGPoint(x: 0, y: 0.5)], radius: 0.05, softness: 0, erase: false)], look: turn)[0].points[0]
        XCTAssertEqual(top.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(top.y, 0, accuracy: 1e-9)
    }

    func testLevellingMatchesThePipelinesTurn() {
        // A face rect turned by EditPipeline.rotate and a stroke's point placed by the brush agree.
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let p = CGPoint(x: 0.25, y: 0.4)
        let (_, f) = EditPipeline.rotate(image, degrees: 6, focus: FocusHint(primary: CGRect(origin: p, size: .zero)))
        let placed = MaskBrush.level(p, degrees: 6, size: image.extent.size)
        XCTAssertEqual(f!.primary!.minX, placed.x, accuracy: 1e-9)
        XCTAssertEqual(f!.primary!.minY, placed.y, accuracy: 1e-9)
    }

    func testPaintingAddsThenErasesInOrder() {
        let add = MaskStroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], radius: 0.1, softness: 0, erase: false)
        let erase = MaskStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1, softness: 0, erase: true)
        let (keep, added) = MaskBrush.paint([add, erase], width: 100, height: 100)
        func at(_ v: [Float]?, _ x: Int, _ y: Int) -> Float { v![y * 100 + x] }
        XCTAssertEqual(at(added, 30, 50), 1)
        XCTAssertEqual(at(added, 50, 50), 0, "erased after it was added")
        XCTAssertEqual(at(keep, 50, 50), 0)
        XCTAssertEqual(at(keep, 30, 50), 1)
        XCTAssertEqual(at(added, 50, 10), 0, "outside the stroke")
        // A soft edge fades out between the brush's middle and its rim.
        let (_, soft) = MaskBrush.paint([MaskStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.2, softness: 1, erase: false)], width: 100, height: 100)
        XCTAssertGreaterThan(at(soft, 50, 50), 0.95)
        XCTAssertGreaterThan(at(soft, 60, 50), 0.2)
        XCTAssertLessThan(at(soft, 60, 50), 0.8)
        XCTAssertEqual(at(soft, 75, 50), 0)
    }

    func testMaskPaintedByHand() {
        let ext = CGRect(x: 0, y: 0, width: 200, height: 100)
        let empty = CIImage(color: .black).cropped(to: ext)
        let out = MaskBrush.apply([MaskStroke(points: [CGPoint(x: 0.25, y: 0.5)], radius: 0.2, softness: 0, erase: false)], to: empty, extent: ext)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext()
        func grey(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
            ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return px[0]
        }
        XCTAssertGreaterThan(grey(50, 50), 240)
        XCTAssertLessThan(grey(150, 50), 10)
    }

    func testAStrokeNearTheTopLandsNearTheTop() {
        // Points are top-left origin; Core Image counts rows from the bottom.
        let ext = CGRect(x: 0, y: 0, width: 200, height: 100)
        let empty = CIImage(color: .black).cropped(to: ext)
        let out = MaskBrush.apply([MaskStroke(points: [CGPoint(x: 0.5, y: 0.2)], radius: 0.1, softness: 0, erase: false)], to: empty, extent: ext)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext()
        func grey(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
            ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return px[0]
        }
        XCTAssertGreaterThan(grey(100, 80), 240, "painted 20% from the top")
        XCTAssertLessThan(grey(100, 20), 10, "nothing 20% from the bottom")
    }
}

final class SmoothSkinTests: XCTestCase {
    /// Smooth skin takes out blotches (the band between its two blurs) without changing the overall tone.
    func testSmoothingEvensOutBlotches() {
        let w = 1000, h = 800
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v: UInt8 = (x / 10 + y / 10) % 2 == 0 ? 150 : 110
                let i = (y * w + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v
            }
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let img = CIImage(bitmapData: Data(px), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: srgb)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        func stats(_ i: CIImage) -> (mean: Double, spread: Double, alpha: UInt8) {
            var b = [UInt8](repeating: 0, count: 200 * 200 * 4)
            ctx.render(i, toBitmap: &b, rowBytes: 800, bounds: CGRect(x: 400, y: 300, width: 200, height: 200), format: .RGBA8, colorSpace: srgb)
            let g = stride(from: 0, to: b.count, by: 4).map { Double(b[$0]) }
            let m = g.reduce(0, +) / Double(g.count)
            return (m, (g.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(g.count)).squareRoot(), b[3])
        }
        var r = Retouch()
        r.smooth = 1
        let before = stats(img), after = stats(EditPipeline.beautify(img, r, short: 800))
        XCTAssertLessThan(after.spread, before.spread * 0.6, "the blotches are evened out")
        XCTAssertEqual(after.mean, before.mean, accuracy: 4)
        XCTAssertEqual(after.alpha, 255)
    }
}
