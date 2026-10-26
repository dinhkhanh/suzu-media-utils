import CoreImage
@testable import MediaKit
import XCTest

final class HealingTests: XCTestCase {
    let w = 400, h = 300
    let ctx = CIContext(options: [.cacheIntermediates: false])
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Skin-like: a gentle shading from left to right, fine grain, and a dark spot (or line) drawn by `blemish`.
    func skin(_ blemish: (Int, Int) -> Bool) -> CIImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt64 = 7
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let grain = Double(Int(seed >> 59)) - 16  // -16…15
                let base = 170 + Double(x) / Double(w) * 40 + grain * 0.6
                let v = blemish(x, y) ? base - 90 : base
                let i = (y * w + x) * 4
                px[i] = UInt8(max(0, min(255, v))); px[i + 1] = UInt8(max(0, min(255, v * 0.8))); px[i + 2] = UInt8(max(0, min(255, v * 0.7)))
            }
        }
        return CIImage(bitmapData: Data(px), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: srgb)
    }

    /// The red channel of a box (top-left origin): its mean and spread.
    func stats(_ img: CIImage, _ box: CGRect) -> (mean: Double, spread: Double) {
        var b = [UInt8](repeating: 0, count: Int(box.width * box.height) * 4)
        ctx.render(img, toBitmap: &b, rowBytes: Int(box.width) * 4,
                   bounds: CGRect(x: box.minX, y: CGFloat(h) - box.maxY, width: box.width, height: box.height), format: .RGBA8, colorSpace: srgb)
        let r = stride(from: 0, to: b.count, by: 4).map { Double(b[$0]) }
        let m = r.reduce(0, +) / Double(r.count)
        return (m, (r.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(r.count)).squareRoot())
    }

    func testAMoleIsHealedFromTheSkinAroundIt() {
        let image = skin { x, y in (x - 200) * (x - 200) + (y - 150) * (y - 150) < 100 }
        let spot = CGRect(x: 194, y: 144, width: 12, height: 12)
        XCTAssertLessThan(stats(image, spot).mean, 120)
        let healed = Healing.apply([HealStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.06, softness: 0.3)], to: image)
        let after = stats(healed, spot), around = stats(image, CGRect(x: 194, y: 120, width: 12, height: 12))
        XCTAssertEqual(after.mean, around.mean, accuracy: 6, "the spot takes the skin's tone")
        XCTAssertGreaterThan(after.spread, around.spread * 0.5, "and keeps its grain (not smeared flat)")
        // Nothing else changes.
        XCTAssertEqual(stats(healed, CGRect(x: 10, y: 10, width: 40, height: 40)).mean, stats(image, CGRect(x: 10, y: 10, width: 40, height: 40)).mean, accuracy: 0.01)
    }

    func testALineIsHealedAlongItsLength() {
        // A long line, as a wrinkle: healed a piece at a time.
        let image = skin { x, y in abs(y - 150) <= 2 && x > 60 && x < 340 }
        let stroke = HealStroke(points: [CGPoint(x: 0.13, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.87, y: 0.5)], radius: 0.025, softness: 0.2)
        let healed = Healing.apply([stroke], to: image)
        for x in stride(from: 80, through: 320, by: 40) {
            let line = stats(healed, CGRect(x: x, y: 148, width: 8, height: 5)), near = stats(image, CGRect(x: x, y: 130, width: 8, height: 5))
            XCTAssertEqual(line.mean, near.mean, accuracy: 8, "healed at x \(x)")
        }
    }

    func testAPickedSourceIsUsed() {
        // Healed from a spot picked by hand, the spot is copied over: the source is the one picked, even if worse.
        let image = skin { x, y in (x - 100) * (x - 100) + (y - 150) * (y - 150) < 16 }
        let stroke = HealStroke(points: [CGPoint(x: 0.75, y: 0.5)], radius: 0.03, softness: 0, source: CGVector(dx: -0.5, dy: 0))
        let healed = Healing.apply([stroke], to: image)
        let spot = stats(healed, CGRect(x: 297, y: 147, width: 6, height: 6)).mean, before = stats(image, CGRect(x: 297, y: 147, width: 6, height: 6)).mean
        XCTAssertLessThan(spot, before - 40)
    }

    func testLinesAreCutIntoPieces() {
        let p = Healing.pieces([(0, 0), (100, 0)], length: 30)
        XCTAssertEqual(p.count, 3, "30, 30, then 40 (the short end joins the last)")
        XCTAssertEqual(p[0].last!.0, 30, accuracy: 1e-9)
        XCTAssertEqual(p[1].first!.0, 30, accuracy: 1e-9)
        XCTAssertEqual(p.last!.last!.0, 100, accuracy: 1e-9)
        XCTAssertEqual(Healing.pieces([(5, 5)], length: 30).count, 1)
    }

    func testHealedStrokesAreKeptForThePreview() {
        let image = skin { x, y in (x - 200) * (x - 200) + (y - 150) * (y - 150) < 100 }
        let one = HealStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.06, softness: 0.3)
        let two = HealStroke(points: [CGPoint(x: 0.2, y: 0.2)], radius: 0.03, softness: 0.3)
        let a = Healing.apply([one], to: image, key: "test")
        let b = Healing.apply([one, two], to: image, key: "test")
        let fresh = Healing.apply([one, two], to: image)
        let spot = CGRect(x: 194, y: 144, width: 12, height: 12)
        XCTAssertEqual(stats(a, spot).mean, stats(b, spot).mean, accuracy: 0.01)
        XCTAssertEqual(stats(b, spot).mean, stats(fresh, spot).mean, accuracy: 0.01)
    }

    func testTheSameSourceIsFoundAtEveryResolution() {
        // A spot by an edge (light skin left, dark right), as the preview sees it at one zoom and the export at
        // another: both heal it from along the edge nearby (a near tie, up or down, may go either way).
        func scene(_ k: Int) -> ([SIMD4<Float>], Int, Int) {
            let w = 400 * k, h = 300 * k
            var px = [SIMD4<Float>](repeating: .zero, count: w * h)
            var seed: UInt64 = 3
            for y in 0..<h {
                for x in 0..<w {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let fx = Double(x) / Double(k), fy = Double(y) / Double(k)
                    var v = fx < 220 + fy * 0.2 ? 0.75 : 0.3
                    if (fx - 248) * (fx - 248) + (fy - 150) * (fy - 150) < 25 { v -= 0.2 }
                    v += Double(Int(seed >> 60) - 8) * 0.004
                    px[y * w + x] = SIMD4(Float(v), Float(v * 0.85), Float(v * 0.75), 1)
                }
            }
            return (px, w, h)
        }
        var shifts: [(Double, Double)] = []
        for k in [1, 3] {
            let (px, w, h) = scene(k)
            let r = 0.04 * Double(h)
            var m = [Float](repeating: 0, count: w * h)
            let box = MaskBrush.cover([(248 * Double(k), 150 * Double(k))], radius: r, softness: 0.3, width: w, height: h, into: &m)!
            let s = Healing.findSource(px, w: w, h: h, mask: m, box: box, r: r)!
            shifts.append((Double(s.0) / Double(w), Double(s.1) / Double(h)))
        }
        for (dx, dy) in shifts {
            // Along the edge (not across it, which would carry the dark side over), and near.
            XCTAssertGreaterThan(abs(dy) * 300, abs(dx) * 400 * 2)
            XCTAssertLessThan(hypot(dx * 400, dy * 300), 0.04 * 300 * 4.5)
        }
    }
}
