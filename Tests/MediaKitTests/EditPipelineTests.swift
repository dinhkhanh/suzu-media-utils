import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import MediaKit

final class EditPipelineTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// A JPEG with a gradient so auto tone has something to do.
    func makeJPEG(_ name: String, w: Int, h: Int, dark: Bool = true) throws -> URL {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1), CGColor(red: dark ? 0.3 : 0.9, green: 0.25, blue: 0.2, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        let url = tmp.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
        return url
    }

    func size(_ url: URL) -> CGSize {
        let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
        return CGSize(width: p[kCGImagePropertyPixelWidth] as! Int, height: p[kCGImagePropertyPixelHeight] as! Int)
    }

    func testCropKeepsFaceWithHeadroomAndStaysInside() {
        // Landscape 6000x4000, face near the right edge, crop to 4:5.
        let r = EditPipeline.cropRect(imageSize: CGSize(width: 6000, height: 4000), ratio: 0.8,
                                      focus: FocusHint(primary: CGRect(x: 0.85, y: 0.2, width: 0.08, height: 0.12)))
        XCTAssertEqual(r.width / r.height, 0.8, accuracy: 0.01)
        XCTAssertEqual(r.height, 4000)
        XCTAssertEqual(r.maxX, 6000, "pushed against the edge, never outside")
        XCTAssertTrue(r.contains(CGPoint(x: 0.89 * 6000, y: 0.26 * 4000)), "face inside the crop")
    }

    func testCropFitsGroupWhenPossible() {
        let r = EditPipeline.cropRect(imageSize: CGSize(width: 6000, height: 4000), ratio: 1,
                                      focus: FocusHint(primary: CGRect(x: 0.30, y: 0.3, width: 0.06, height: 0.09),
                                                       others: [CGRect(x: 0.55, y: 0.32, width: 0.06, height: 0.09)]))
        XCTAssertLessThanOrEqual(r.minX, 0.30 * 6000)
        XCTAssertGreaterThanOrEqual(r.maxX, 0.61 * 6000)
    }

    func testRenderCropsResizesWatermarksAndTagsPeople() throws {
        let photo = try makeJPEG("p.jpg", w: 3000, h: 2000)
        let logo = try makeJPEG("logo.jpg", w: 400, h: 120, dark: false)
        var recipe = EditRecipe()
        recipe.autoTone = true
        recipe.aspect = .portrait
        recipe.maxLongSide = 1350
        recipe.watermark = WatermarkSpec(logoPath: logo.path)
        let out = tmp.appendingPathComponent("out.jpg")
        try EditPipeline.render(photo, recipe: recipe, focus: FocusHint(primary: CGRect(x: 0.5, y: 0.3, width: 0.1, height: 0.15)),
                                people: ["Mỹ Tâm", "Sơn Tùng M-TP"], to: out)
        let s = size(out)
        XCTAssertEqual(s.height, 1350)
        XCTAssertEqual(s.width, 1080, accuracy: 1)
        XCTAssertEqual(Set(Metadata.people(in: out)), ["Mỹ Tâm", "Sơn Tùng M-TP"])
    }

    func testAutoToneBrightensADarkImage() throws {
        let photo = try makeJPEG("dark.jpg", w: 800, h: 600)
        let input = CIImage(contentsOf: photo)!
        let out = EditPipeline.autoTone(input, strength: 1)
        func mean(_ i: CIImage) -> Double {
            let avg = i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: i.extent)])
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(px[0]) + Double(px[1]) + Double(px[2])
        }
        XCTAssertGreaterThan(mean(out), mean(input))
    }

    func testWritePeopleInPlaceKeepsPixelsAndMerges() throws {
        let photo = try makeJPEG("tag.jpg", w: 640, h: 480)
        let before = size(photo)
        XCTAssertTrue(try Metadata.writePeople(["An"], to: photo))
        XCTAssertTrue(try Metadata.writePeople(["Bình", "An"], to: photo))
        XCTAssertEqual(Metadata.people(in: photo), ["An", "Bình"])
        XCTAssertEqual(size(photo), before)
    }
}
