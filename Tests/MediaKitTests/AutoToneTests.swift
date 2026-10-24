import CoreGraphics
import CoreImage
import XCTest
@testable import MediaKit

/// Auto tone as dials: what Core Image's auto-enhance sets shows on the editor's sliders and curve, and the user's
/// changes sit on top of it.
final class AutoToneTests: XCTestCase {
    /// A dark gradient so auto tone has something to lift.
    func gradient(w: Int = 320, h: Int = 200) -> CIImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1), CGColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return CIImage(cgImage: ctx.makeImage()!)
    }

    func testAutoToneBecomesDials() {
        let a = EditPipeline.autoAdjustments(gradient(), strength: 1)
        XCTAssertTrue(a.changesPixels, "auto tone sets something on a dark gradient")
        XCTAssertTrue(a.hasCurve || a.shadows != 0 || a.vibrance != 0 || a.exposure != 0)
        XCTAssertEqual(a.turns, 0)
        XCTAssertFalse(a.monochrome)
        let half = EditPipeline.autoAdjustments(gradient(), strength: 0.5)
        XCTAssertEqual(half.vibrance, a.vibrance / 2, accuracy: 1e-6)
        XCTAssertEqual(half.shadows, a.shadows / 2, accuracy: 1e-6)
        if a.hasCurve { XCTAssertEqual(half.tone[2], (a.tone[2] + 0.5) / 2, accuracy: 1e-6) }
    }

    func testUserChangesSitOnTopAndComeBackOff() {
        var auto = Adjustments()
        auto.shadows = 0.3; auto.vibrance = 0.2; auto.exposure = 0.4
        auto.tone = [0, 0.3, 0.55, 0.8, 1]
        var user = Adjustments()
        user.shadows = -0.1; user.contrast = 0.2; user.monochrome = true
        user.tone = [0.05, 0.25, 0.5, 0.78, 0.95]
        let shown = user.composed(over: auto)
        XCTAssertEqual(shown.shadows, 0.2, accuracy: 1e-9)
        XCTAssertEqual(shown.vibrance, 0.2, accuracy: 1e-9)
        XCTAssertEqual(shown.exposure, 0.4, accuracy: 1e-9)
        XCTAssertEqual(shown.contrast, 0.2, accuracy: 1e-9)
        XCTAssertTrue(shown.monochrome, "black & white is the user's")
        XCTAssertEqual(shown.tone[0], 0.05, accuracy: 1e-9)
        XCTAssertGreaterThan(shown.tone[2], 0.5, "the curve shown is the user's on top of auto's lift")
        // Back out of it: what the user set is recovered (the curve to within the five-point sampling).
        let back = shown.subtracting(auto)
        XCTAssertEqual(back.shadows, user.shadows, accuracy: 1e-9)
        XCTAssertEqual(back.contrast, user.contrast, accuracy: 1e-9)
        XCTAssertEqual(back.vibrance, 0, accuracy: 1e-9)
        for (b, u) in zip(back.tone, user.tone) { XCTAssertEqual(b, u, accuracy: 0.03) }
        // Nothing of the user's: the dials show exactly auto's values.
        let plain = Adjustments().composed(over: auto)
        XCTAssertEqual(plain.shadows, 0.3, accuracy: 1e-9)
        XCTAssertEqual(plain.tone, auto.tone)
        XCTAssertFalse(Adjustments().composed(over: auto).subtracting(auto).changesPixels)
        // Clamped at the dial's end.
        var hot = Adjustments(); hot.shadows = 0.9
        XCTAssertEqual(hot.composed(over: auto).shadows, 1, accuracy: 1e-9)
    }

    func testPipelineAppliesWhatIsShown() {
        let img = gradient()
        var r = EditRecipe()
        r.autoTone = true
        let auto = EditPipeline.autoAdjustments(img, strength: 1)
        var asDials = EditRecipe()
        asDials.look = auto
        let a = EditPipeline.tone(img, r), b = EditPipeline.tone(img, asDials)
        let ctx = CIContext()
        let pa = ctx.createCGImage(a, from: a.extent)!, pb = ctx.createCGImage(b, from: b.extent)!
        XCTAssertEqual(pa.width, pb.width)
        // Same pixels: auto tone is nothing more than those dials.
        func bytes(_ c: CGImage) -> [UInt8] { Array((c.dataProvider!.data! as Data).prefix(4096)) }
        XCTAssertEqual(bytes(pa), bytes(pb))
    }
}
