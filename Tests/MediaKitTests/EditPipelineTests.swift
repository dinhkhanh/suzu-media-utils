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

    func testCropKeepsBothPeopleButNotTheBackground() {
        // Two people side by side; a small face far right is someone in the background. 4:5 crop of a landscape photo.
        let r = EditPipeline.cropRect(imageSize: CGSize(width: 6000, height: 4000), ratio: 0.8,
                                      focus: FocusHint(primary: CGRect(x: 0.25, y: 0.25, width: 0.07, height: 0.1),
                                                       others: [CGRect(x: 0.55, y: 0.22, width: 0.07, height: 0.1),
                                                                CGRect(x: 0.92, y: 0.3, width: 0.02, height: 0.03)]))
        XCTAssertLessThanOrEqual(r.minX, 0.25 * 6000)
        XCTAssertGreaterThanOrEqual(r.maxX, 0.62 * 6000)
        XCTAssertLessThan(r.maxX, 0.92 * 6000)
        // The pair is centred, not the main person: the gap either side of them is about equal.
        XCTAssertEqual(0.25 * 6000 - r.minX, r.maxX - 0.62 * 6000, accuracy: 60)
    }

    func testCropByOrientationPicksTheShapePerPhoto() throws {
        var r = EditRecipe()
        r.cropByOrientation = true
        r.portraitAspect = .portrait
        r.aspect = .landscape
        XCTAssertTrue(r.crops)
        func out(_ w: CGFloat, _ h: CGFloat) throws -> CGSize {
            try EditPipeline.apply(r, to: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)), focus: FocusHint(primary: nil)).extent.size
        }
        XCTAssertEqual(try out(1200, 1800), CGSize(width: 1200, height: 1500))  // portrait -> 4:5
        XCTAssertEqual(try out(1800, 1200), CGSize(width: 1800, height: 1013))  // landscape -> 16:9
        XCTAssertEqual(try out(1000, 1000), CGSize(width: 1000, height: 563))   // square counts as landscape
        // Portraits keep their frame when only landscapes are cropped.
        r.portraitAspect = nil
        XCTAssertEqual(try out(1200, 1800), CGSize(width: 1200, height: 1800))
        XCTAssertEqual(r.cropDescription, "original portraits, 16:9 landscapes")
        // Old saved recipes: one crop for every photo.
        var old = EditRecipe()
        old.aspect = .portrait
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.aspect(for: CGSize(width: 1800, height: 1200)), .portrait)
    }

    func testCropPlacedByHandWinsAndStaysInside() {
        let faces = FocusHint(primary: CGRect(x: 0.1, y: 0.25, width: 0.07, height: 0.1))
        var placed = faces
        placed.center = CGPoint(x: 0.6, y: 0.5)
        let r = EditPipeline.cropRect(imageSize: CGSize(width: 6000, height: 4000), ratio: 0.8, focus: placed)
        XCTAssertEqual(r.midX, 3600, accuracy: 1)
        placed.center = CGPoint(x: 0.99, y: 0.5)
        XCTAssertEqual(EditPipeline.cropRect(imageSize: CGSize(width: 6000, height: 4000), ratio: 0.8, focus: placed).maxX, 6000)
    }

    func testCropAddsPeopleNearestFirstWhenNotAllFit() {
        // Main person in the middle, one neighbour close by, another at the far edge: the crop can't hold all three.
        let r = EditPipeline.cropRect(imageSize: CGSize(width: 6000, height: 4000), ratio: 0.8,
                                      focus: FocusHint(primary: CGRect(x: 0.45, y: 0.25, width: 0.07, height: 0.1),
                                                       others: [CGRect(x: 0.02, y: 0.25, width: 0.07, height: 0.1),
                                                                CGRect(x: 0.62, y: 0.25, width: 0.07, height: 0.1)]))
        XCTAssertLessThanOrEqual(r.minX, 0.45 * 6000)
        XCTAssertGreaterThanOrEqual(r.maxX, 0.69 * 6000)
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

final class WatermarkTests: XCTestCase {
    func testTextWatermarkIsDrawnWhereAsked() throws {
        let canvas = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
        var spec = WatermarkSpec(text: "© SuZu Media")
        spec.position = .topLeft
        spec.opacity = 1
        let out = try EditPipeline.watermark(canvas, spec: spec)
        // Brightest pixel of each half: the white text sits in the top-left, the bottom-right stays dark.
        func peak(_ r: CGRect) -> Double {
            let ctx = CIContext()
            let f = out.cropped(to: r).applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(f, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(px[0]) / 255
        }
        XCTAssertGreaterThan(peak(CGRect(x: 0, y: 400, width: 600, height: 400)), 0.9)  // Core Image: y up, so top = high y
        XCTAssertLessThan(peak(CGRect(x: 600, y: 0, width: 600, height: 400)), 0.3)
    }

    func testEmptyWatermarkLeavesThePhotoAlone() throws {
        let canvas = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(try EditPipeline.watermark(canvas, spec: WatermarkSpec(logoPath: "")).extent, canvas.extent)
    }

    func testBannerKeepsItsHeightAndTrimsItsSides() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Landscape banner white, portrait banner red, both wider than they need to be.
        func bar(_ name: String, _ color: CIColor, width: CGFloat) throws -> String {
            let url = dir.appendingPathComponent(name)
            let img = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: 50))
            try CIContext().writePNGRepresentation(of: img, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return url.path
        }
        var spec = WatermarkSpec(banner: try bar("wide.png", .white, width: 600), portrait: try bar("tall.png", .red, width: 400))
        spec.bannerHeight = 0.1
        func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> (Double, Double) {
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return (Double(px[0]) / 255, Double(px[1]) / 255)
        }
        let dark = CIColor(red: 0.1, green: 0.1, blue: 0.1)
        // Landscape 1200 x 800: a 120 px white bar along the whole bottom edge, nothing above it.
        let wide = try EditPipeline.watermark(CIImage(color: dark).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800)), spec: spec)
        for x: CGFloat in [1, 600, 1198] { XCTAssertGreaterThan(pixel(wide, x, 5).1, 0.9) }
        XCTAssertGreaterThan(pixel(wide, 600, 115).1, 0.9)
        XCTAssertLessThan(pixel(wide, 600, 125).1, 0.2)
        // Portrait 800 x 1200 (same long side): the red banner across the width, as high as the landscape one.
        // Both are 120 px high, unstretched, centred, with the sides trimmed.
        let tall = try EditPipeline.watermark(CIImage(color: dark).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1200)), spec: spec)
        for x: CGFloat in [1, 798] { XCTAssertGreaterThan(pixel(tall, x, 5).0, 0.9) }
        let p = pixel(tall, 400, 115)
        XCTAssertGreaterThan(p.0, 0.9); XCTAssertLessThan(p.1, 0.2)
        XCTAssertLessThan(pixel(tall, 400, 125).0, 0.2)
        // A banner too narrow to cover the photo is stretched sideways and keeps its height: 300 x 50 on 1200 x 800.
        var short = WatermarkSpec(banner: try bar("narrow.png", .white, width: 300))
        short.bannerHeight = 0.1
        let narrow = try EditPipeline.watermark(CIImage(color: dark).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800)), spec: short)
        for x: CGFloat in [1, 1198] { XCTAssertGreaterThan(pixel(narrow, x, 115).1, 0.9) }
        XCTAssertLessThan(pixel(narrow, 600, 125).1, 0.2)
        // Without a portrait banner, portrait photos use the landscape one.
        var one = spec
        one.portraitLogoPath = nil
        let fallback = try EditPipeline.watermark(CIImage(color: dark).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1200)), spec: one)
        XCTAssertGreaterThan(pixel(fallback, 400, 5).1, 0.9)
    }

    func testOldSavedRecipesStillDecode() throws {
        let json = #"{"autoTone":true,"autoToneStrength":0.8,"jpegQuality":0.9,"writePeopleNames":true,"watermark":{"logoPath":"/a.png","position":"bottomRight","size":0.22,"opacity":0.9,"margin":0.035}}"#
        let r = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        XCTAssertEqual(r.watermark?.logoPath, "/a.png")
        XCTAssertFalse(r.watermark!.isText)
    }
}

final class PNGExportTests: XCTestCase {
    func testPNGIsLosslessOpaqueAndTagged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 16-bit source: the PNG keeps 16 bits per channel.
        let src = dir.appendingPathComponent("deep.tiff")
        let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 16, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let d = CGImageDestinationCreateWithURL(src as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))

        var recipe = EditRecipe()
        recipe.format = .png
        recipe.aspect = .square
        recipe.maxLongSide = 600
        let out = dir.appendingPathComponent("out.\(recipe.fileExtension)")
        try EditPipeline.render(src, recipe: recipe, focus: nil, people: ["Mỹ Tâm"], to: out)

        let isrc = CGImageSourceCreateWithURL(out as CFURL, nil)!
        XCTAssertEqual(CGImageSourceGetType(isrc) as String?, "public.png")
        let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil)!
        XCTAssertEqual(img.width, 600)
        XCTAssertEqual(img.height, 600)
        XCTAssertEqual(img.bitsPerComponent, 16)
        XCTAssertFalse([.first, .last, .premultipliedFirst, .premultipliedLast].contains(img.alphaInfo), "no alpha channel")
        XCTAssertEqual(img.colorSpace?.name as String?, CGColorSpace.displayP3 as String, "keeps the photo's colour space")
        XCTAssertEqual(Metadata.people(in: out), ["Mỹ Tâm"])
    }
}

final class StraightenTests: XCTestCase {
    /// A wall with pillars and door frames (long vertical lines), turned by `degrees` (counter-clockwise).
    func scene(tilt degrees: Double) -> CIImage {
        var wall = CIImage(color: CIColor(red: 0.8, green: 0.78, blue: 0.72)).cropped(to: CGRect(x: -2000, y: -2000, width: 6000, height: 5000))
        for (i, x) in stride(from: -400.0, through: 1600, by: 110).enumerated() {
            let shade = i % 2 == 0 ? 0.25 : 0.45
            wall = CIImage(color: CIColor(red: shade, green: shade, blue: shade + 0.05))
                .cropped(to: CGRect(x: x, y: -1500, width: 18 + Double(i % 3) * 8, height: 4000)).composited(over: wall)
        }
        let t = degrees * .pi / 180
        return wall
            .transformed(by: CGAffineTransform(translationX: -600, y: -400).concatenating(CGAffineTransform(rotationAngle: t))
                .concatenating(CGAffineTransform(translationX: 600, y: 400)))
            .cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    func testFindsTheTiltAndLevelsIt() throws {
        let tilted = scene(tilt: 5)
        let tilt = try XCTUnwrap(EditPipeline.horizonTilt(tilted))
        XCTAssertEqual(tilt, 5, accuracy: 1)
        var r = EditRecipe()
        r.straighten = true
        XCTAssertEqual(try XCTUnwrap(EditPipeline.rotation(r, tilted)), -5, accuracy: 1)
        // Levelled: no tilt left (or too little to count), smaller (trimmed corners), same shape.
        let level = try EditPipeline.apply(r, to: tilted, focus: nil)
        XCTAssertLessThan(abs(EditPipeline.horizonTilt(level) ?? 0), 1)
        XCTAssertEqual(level.extent.width / level.extent.height, 1.5, accuracy: 0.01)
        XCTAssertLessThan(level.extent.width, 1200)
        // A level photo is left alone, and the photo's own setting wins.
        XCTAssertNil(EditPipeline.rotation(r, scene(tilt: 0)))
        r.rotation = 0
        XCTAssertNil(EditPipeline.rotation(r, tilted))
    }

    func testFacesTurnWithThePhoto() {
        // A face right of centre stays right of centre after a small turn, and inside the frame.
        let (_, f) = EditPipeline.rotate(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800)), degrees: 3,
                                         focus: FocusHint(primary: CGRect(x: 0.7, y: 0.4, width: 0.1, height: 0.15)))
        let p = f!.primary!
        XCTAssertEqual(p.midX, 0.75, accuracy: 0.05)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(p))
    }
}
