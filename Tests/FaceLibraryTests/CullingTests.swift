import CoreGraphics
import Foundation
import XCTest
@testable import FaceCore
@testable import FaceLibrary

/// Skipping similar and blurry shots before an export.
final class CullingTests: XCTestCase {
    func shot(_ name: String, at t: Double? = nil, print p: [Float]? = nil, faceSharpness: Double? = nil, blur: Double? = nil,
              score: Double? = nil, folder: String = "/e") -> ShotCuller.Measure {
        ShotCuller.Measure(url: URL(fileURLWithPath: "\(folder)/\(name)"), takenAt: t.map(Date.init(timeIntervalSince1970:)),
                           featurePrint: p, blur: blur, faceSharpness: faceSharpness, faceScore: score)
    }

    func testBlurIndexRisesWhenTheFrameIsBlurred() {
        // A checkerboard with a little grain, then the same frame through 5x5 and 9x9 box blurs.
        let w = 200, h = 160
        var sharp = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { sharp[y * w + x] = ((x / 10 + y / 10) % 2 == 0 ? 200 : 40) + Float((x * 7 + y * 13) % 11) - 5 } }
        func box(_ r: Int) -> [Float] {
            var out = sharp
            for y in r..<(h - r) { for x in r..<(w - r) {
                var s: Float = 0
                for dy in -r...r { for dx in -r...r { s += sharp[(y + dy) * w + x + dx] } }
                out[y * w + x] = s / Float((2 * r + 1) * (2 * r + 1))
            } }
            return out
        }
        let a = ShotCuller.blurIndex(sharp, width: w, height: h), b = ShotCuller.blurIndex(box(2), width: w, height: h),
            c = ShotCuller.blurIndex(box(4), width: w, height: h)
        XCTAssertLessThan(a, 0.3, "crisp frame reads sharp: \(a)")
        XCTAssertGreaterThan(b, a + 0.2, "a 5x5 blur reads much softer: \(b)")
        XCTAssertGreaterThan(c, ShotCuller.blurryFrameAbove, "a 9x9 blur counts as blurry: \(c)")
    }

    func testBlurryUsesTheMainFaceFirst() {
        XCTAssertTrue(ShotCuller.isBlurry(shot("a", faceSharpness: 30)))
        XCTAssertFalse(ShotCuller.isBlurry(shot("b", faceSharpness: 300, blur: 0.9)), "a sharp face decides, whatever the background")
        XCTAssertTrue(ShotCuller.isBlurry(shot("c", blur: 0.7)), "no usable face: the frame decides")
        XCTAssertFalse(ShotCuller.isBlurry(shot("d", blur: 0.3)))
        XCTAssertFalse(ShotCuller.isBlurry(shot("e")), "unreadable: never skipped")
    }

    func testSimilarShotsGroupByTimeAndLookAndKeepTheBest() {
        let p1: [Float] = [1, 0, 0], p1b: [Float] = [0.9, 0.2, 0], p2: [Float] = [0, 1, 0]
        let shots = [
            shot("1.jpg", at: 100, print: p1, faceSharpness: 100, score: 0.5),
            shot("2.jpg", at: 101, print: p1b, faceSharpness: 300, score: 0.9),   // same burst as 1, better
            shot("3.jpg", at: 101.5, print: p2, faceSharpness: 200, score: 0.7),  // looks different
            shot("4.jpg", at: 130, print: p1, faceSharpness: 200, score: 0.6),    // same look, half a minute later
            shot("5.jpg", at: 131, print: p1b, faceSharpness: 100, score: 0.4),   // burst with 4
        ]
        let groups = ShotCuller.similarGroups(shots)
        XCTAssertEqual(groups, [[0, 1], [3, 4]])
        let culled = ShotCuller.cull(shots, similar: true, blurry: false)
        XCTAssertEqual(culled, [0: .similar(to: shots[1].url), 4: .similar(to: shots[3].url)])
    }

    func testWithoutCaptureTimesNeighboursInAFolderGroupByLook() {
        let p: [Float] = [1, 0]
        let shots = [shot("IMG_1.jpg", print: p), shot("IMG_2.jpg", print: p), shot("IMG_3.jpg", print: [0, 1]), shot("IMG_4.jpg", print: p, folder: "/f")]
        XCTAssertEqual(ShotCuller.similarGroups(shots), [[0, 1]], "no times: neighbours in the same folder only")
    }

    func testBlurryShotsGoFirstSoAGroupKeepsASharpOne() {
        let p: [Float] = [1, 0]
        let shots = [shot("1.jpg", at: 1, print: p, faceSharpness: 20, score: 0.9), shot("2.jpg", at: 2, print: p, faceSharpness: 200, score: 0.5)]
        XCTAssertEqual(ShotCuller.cull(shots, similar: true, blurry: true), [0: .blurry])
        XCTAssertEqual(ShotCuller.cull(shots, similar: true, blurry: false), [1: .similar(to: shots[0].url)], "without the blur check the score wins")
    }

    func testMeasureReadsAPhotoFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.jpg")
        let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<40 {
            ctx.setFillColor(CGColor(gray: i % 2 == 0 ? 0.1 : 0.9, alpha: 1))
            ctx.fill(CGRect(x: i * 16, y: 0, width: 16, height: 480))
        }
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
        let m = ShotCuller.measure(url, faces: true)
        XCTAssertNotNil(m.featurePrint)
        XCTAssertNotNil(m.blur)
        XCTAssertLessThan(m.blur!, ShotCuller.blurryFrameAbove, "hard stripes are crisp")
        XCTAssertNil(m.faceSharpness, "no face in stripes")
        XCTAssertFalse(ShotCuller.isBlurry(m))
        let missing = ShotCuller.measure(dir.appendingPathComponent("none.jpg"), faces: true)
        XCTAssertNil(missing.blur)
        XCTAssertFalse(ShotCuller.isBlurry(missing))
    }
}
