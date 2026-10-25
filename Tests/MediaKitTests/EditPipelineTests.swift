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

    func testZoomShrinksTheCropAndCropsToThePhotosOwnShapeWithoutAPreset() throws {
        // Zoomed in twice about a hand-placed centre: half of each side.
        let placed = FocusHint(primary: nil, center: CGPoint(x: 0.5, y: 0.5), zoom: 2)
        XCTAssertEqual(EditPipeline.cropRect(imageSize: CGSize(width: 6000, height: 4000), ratio: 1.5, focus: placed),
                       CGRect(x: 1500, y: 1000, width: 3000, height: 2000))
        // Without a preset, only a zoomed photo is cropped, to its own shape; a preset's shape still wins.
        var recipe = EditRecipe()
        let size = CGSize(width: 6000, height: 4000)
        XCTAssertNil(EditPipeline.cropRatio(recipe, size: size, focus: FocusHint(primary: nil, center: CGPoint(x: 0.5, y: 0.5))))
        XCTAssertNil(EditPipeline.cropRatio(recipe, size: size, focus: nil))
        XCTAssertEqual(EditPipeline.cropRatio(recipe, size: size, focus: placed), 1.5)
        recipe.aspect = .square
        XCTAssertEqual(EditPipeline.cropRatio(recipe, size: size, focus: placed), 1)
        // Only zoomed: the faces place the smaller crop, with headroom, inside the photo.
        let faces = FocusHint(primary: CGRect(x: 0.7, y: 0.2, width: 0.05, height: 0.08), zoom: 2)
        let f = EditPipeline.cropRect(imageSize: size, ratio: 1.5, focus: faces)
        XCTAssertEqual(f.size, CGSize(width: 3000, height: 2000))
        XCTAssertEqual(f.midX, 4350, accuracy: 1)
        XCTAssertEqual(f.minY, 160, accuracy: 1)
        // Through the pipeline, a zoomed photo without a preset comes out half as big in its own shape.
        let out = try EditPipeline.apply(EditRecipe(), to: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 2000)), focus: placed)
        XCTAssertEqual(out.extent.size, CGSize(width: 1500, height: 1000))
    }

    func testZoomIsClampedAndTheLargestCropMeansNone() {
        XCTAssertNil(CropPlacements.clamp(nil))
        XCTAssertNil(CropPlacements.clamp(1))
        XCTAssertNil(CropPlacements.clamp(0.5))
        XCTAssertEqual(CropPlacements.clamp(1.234), 1.23)
        XCTAssertEqual(CropPlacements.clamp(9), CropPlacements.maxZoom)
    }

    func testRenderHonoursThePhotosOwnZoomAndDecodesOnlyWhatItNeeds() throws {
        let photo = try makeJPEG("zoomed.jpg", w: 3000, h: 2000)
        CropPlacements.shared.set(zoom: 2, center: CGPoint(x: 0.5, y: 0.5), for: photo)
        defer { CropPlacements.shared.resetPlacement(for: photo) }
        XCTAssertEqual(CropPlacements.shared.zoom(for: photo), 2)
        var recipe = EditRecipe()
        recipe.maxLongSide = 1000
        let out = tmp.appendingPathComponent("zoomed-out.jpg")
        try EditPipeline.render(photo, recipe: recipe, focus: nil, to: out)
        let s = size(out)
        XCTAssertEqual(s.width, 1000)
        XCTAssertEqual(s.height, 667, accuracy: 1)
        // Full size: the middle half of each side.
        recipe.maxLongSide = nil
        try EditPipeline.render(photo, recipe: recipe, focus: nil, to: out)
        XCTAssertEqual(size(out), CGSize(width: 1500, height: 1000))
        // Back to the largest crop: untouched.
        CropPlacements.shared.resetPlacement(for: photo)
        try EditPipeline.render(photo, recipe: recipe, focus: nil, to: out)
        XCTAssertEqual(size(out), CGSize(width: 3000, height: 2000))
    }

    func testAdjustmentsChangeThePixelsAndEmptyOnesDoNothing() throws {
        let photo = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        /// The mean red level (0–1) of the image as a JPEG would have it.
        func gray(_ img: CIImage) -> Double {
            let cg = EditPipeline.pixels(img, format: .jpeg)!
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Double(ctx.data!.assumingMemoryBound(to: UInt8.self)[0]) / 255
        }
        var a = Adjustments()
        XCTAssertTrue(a.isEmpty)
        XCTAssertEqual(gray(EditPipeline.adjust(photo, a)), gray(photo), accuracy: 0.01)
        a.exposure = 1
        XCTAssertFalse(a.isEmpty)
        XCTAssertGreaterThan(gray(EditPipeline.adjust(photo, a)), gray(photo) + 0.08, "a stop up is brighter")
        a = Adjustments(); a.exposure = -1
        XCTAssertLessThan(gray(EditPipeline.adjust(photo, a)), gray(photo) - 0.05)
        var r = EditRecipe()
        XCTAssertTrue(r.isPassthrough)
        r.look.vibrance = 0.5
        XCTAssertFalse(r.isPassthrough)
        r.look = Adjustments()
        XCTAssertNil(r.adjustments, "an empty look is stored as none")
        // Old saved recipes have no adjustments; new ones may lack keys added later.
        let old = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"autoTone":false,"autoToneStrength":1,"jpegQuality":0.9,"writePeopleNames":true}"#.utf8))
        XCTAssertTrue(old.look.isEmpty)
        let partial = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"contrast":0.5}"#.utf8))
        XCTAssertEqual(partial.contrast, 0.5); XCTAssertEqual(partial.turns, 0)
    }

    func testOrientationTurnsThePhotoAndItsFaces() throws {
        let wide = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        var a = Adjustments()
        a.turns = 1
        let face = FocusHint(primary: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3))
        let (turned, f) = EditPipeline.orient(wide, a, focus: face)
        XCTAssertEqual(turned.extent, CGRect(x: 0, y: 0, width: 200, height: 300), "a quarter turn swaps the sides, origin at zero")
        // Top-left of a landscape photo turned clockwise ends up top-right.
        let p = try XCTUnwrap(f?.primary)
        XCTAssertEqual(p.minX, 1 - 0.2 - 0.3, accuracy: 0.001)
        XCTAssertEqual(p.minY, 0.1, accuracy: 0.001)
        XCTAssertEqual(p.size, CGSize(width: 0.3, height: 0.2))
        a.turns = 4
        XCTAssertFalse(a.changesOrientation, "four turns is none")
        a.turns = 0; a.flipHorizontal = true
        XCTAssertEqual(a.map(CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3)).minX, 0.7, accuracy: 0.001)
        var r = EditRecipe()
        r.look.turns = 1
        let out = try EditPipeline.apply(r, to: wide, focus: nil)
        XCTAssertEqual(out.extent.size, CGSize(width: 200, height: 300))
    }

    func testACropDrawnByHandIsUsedAsDrawn() throws {
        let photo = try makeJPEG("drawn.jpg", w: 3000, h: 2000)
        CropPlacements.shared.set(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25), for: photo)
        defer { CropPlacements.shared.resetPlacement(for: photo) }
        XCTAssertNotNil(CropPlacements.shared.rect(for: photo))
        XCTAssertTrue(CropPlacements.shared.edit(for: photo)!.cropEdited)
        let size = CGSize(width: 3000, height: 2000)
        let focus = CropPlacements.shared.focus(for: photo, given: nil)
        XCTAssertEqual(try XCTUnwrap(EditPipeline.cropRatio(EditRecipe(), size: size, focus: focus)), 3, accuracy: 0.001, "its own shape, whatever the export's")
        var square = EditRecipe(); square.aspect = .square
        XCTAssertEqual(try XCTUnwrap(EditPipeline.cropRatio(square, size: size, focus: focus)), 3, accuracy: 0.001)
        XCTAssertEqual(EditPipeline.cropRect(imageSize: size, ratio: 3, focus: focus), CGRect(x: 300, y: 400, width: 1500, height: 500))
        let out = tmp.appendingPathComponent("drawn-out.jpg")
        try EditPipeline.render(photo, recipe: square, focus: nil, to: out)
        XCTAssertEqual(self.size(out), CGSize(width: 1500, height: 500))
        // Resized exports decode only what the drawn crop needs, and still come out right.
        var small = EditRecipe(); small.maxLongSide = 600
        try EditPipeline.render(photo, recipe: small, focus: nil, to: out)
        XCTAssertEqual(self.size(out), CGSize(width: 600, height: 200))
        // A zoom set afterwards replaces the drawn crop.
        CropPlacements.shared.set(zoom: 2, for: photo)
        XCTAssertNil(CropPlacements.shared.rect(for: photo))
    }

    func testPreviewScaleDrawsTheWatermarkAtScreenSize() throws {
        let small = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        var r = EditRecipe()
        r.watermark = WatermarkSpec(text: "SuZu")
        let out = try EditPipeline.apply(r, to: small, focus: nil, previewLongSide: 1200)
        XCTAssertEqual(out.extent.size, CGSize(width: 1200, height: 800), "scaled up to the screen before the watermark goes on")
        let plain = try EditPipeline.apply(r, to: small, focus: nil)
        XCTAssertEqual(plain.extent.size, CGSize(width: 300, height: 200), "exports never upscale")
    }

    func testToneCurveAndHSLTouchOnlyWhatTheyShould() throws {
        func mean(_ img: CIImage, _ what: String = #function) throws -> [Double] {
            let cg = try XCTUnwrap(EditPipeline.pixels(img, format: .jpeg), "no pixels for \(what): \(img.extent)")
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return [Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255]
        }
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        var a = Adjustments()
        a.tone = [0, 0.25, 0.7, 0.75, 1]
        XCTAssertTrue(a.hasCurve)
        XCTAssertGreaterThan(try mean(EditPipeline.adjust(grey, a), "curve")[0], try mean(grey, "grey")[0] + 0.1, "the middle of the curve lifted brightens a mid grey")
        a.tone = Adjustments.straightCurve
        XCTAssertNil(a.curve, "the straight line is no curve")
        // HSL: red less saturated leaves blue and grey alone.
        let red = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let blue = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        var h = HSLAdjust()
        h.saturation[0] = -1
        a = Adjustments(); a.colours = h
        XCTAssertFalse(a.isEmpty)
        let r = try mean(EditPipeline.adjust(red, a), "hsl red"), b = try mean(EditPipeline.adjust(blue, a), "hsl blue"), g = try mean(EditPipeline.adjust(grey, a), "hsl grey")
        XCTAssertLessThan(r[0] - r[1], 0.15, "red drained of colour")
        XCTAssertGreaterThan(b[2] - b[0], 0.5, "blue untouched")
        XCTAssertEqual(g[0], try mean(grey)[0], accuracy: 0.02, "grey untouched")
        // Hue: red turned towards orange gains green.
        h = HSLAdjust(); h.hue[0] = 1
        a.colours = h
        XCTAssertGreaterThan(try mean(EditPipeline.adjust(red, a), "hue")[1], try mean(red, "red")[1] + 0.1)
        // Round trips and old data.
        let (hh, ss, vv) = EditPipeline.hsv(0.8, 0.2, 0.2)
        let back = EditPipeline.rgb(hh, ss, vv)
        XCTAssertEqual(back.0, 0.8, accuracy: 0.001); XCTAssertEqual(back.1, 0.2, accuracy: 0.001)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"curve":[0,0.25,0.5,0.75,1],"hsl":{"hue":[1,2]}}"#.utf8))
        XCTAssertNil(decoded.curve, "a straight saved curve is none"); XCTAssertNil(decoded.hsl, "a malformed HSL is none")
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
        var r = EditRecipe()
        r.autoTone = true
        let out = EditPipeline.tone(input, r)
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
        XCTAssertNil(r.watermark!.extraText)
    }

    func testTextIsDrawnAsWellAsABanner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("banner-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bar = dir.appendingPathComponent("bar.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1400, height: 50)), to: bar,
                                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var spec = WatermarkSpec(banner: bar.path)
        spec.bannerHeight = 0.1
        spec.extraText = WatermarkSpec.TextMark(text: "© SuZu Media", position: .topLeft)
        spec.extraText?.opacity = 1
        let canvas = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
        func peak(_ image: CIImage, _ r: CGRect) -> Double {
            let f = image.cropped(to: r).applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(f, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(px[0]) / 255
        }
        let out = try EditPipeline.watermark(canvas, spec: spec)
        XCTAssertGreaterThan(peak(out, CGRect(x: 0, y: 0, width: 1200, height: 100)), 0.9)     // the banner along the bottom
        XCTAssertGreaterThan(peak(out, CGRect(x: 0, y: 600, width: 500, height: 200)), 0.9)    // the text, top left
        XCTAssertLessThan(peak(out, CGRect(x: 700, y: 300, width: 500, height: 500)), 0.3)     // nothing else
        // Text alone (no banner chosen yet) is still drawn; a text watermark ignores text "as well".
        var textOnly = WatermarkSpec(logoPath: "")
        textOnly.extraText = spec.extraText
        XCTAssertFalse(textOnly.isEmpty)
        XCTAssertGreaterThan(peak(try EditPipeline.watermark(canvas, spec: textOnly), CGRect(x: 0, y: 600, width: 500, height: 200)), 0.9)
        var text = WatermarkSpec(text: "SuZu")
        text.position = .bottomRight
        text.extraText = spec.extraText
        XCTAssertLessThan(peak(try EditPipeline.watermark(canvas, spec: text), CGRect(x: 0, y: 600, width: 500, height: 200)), 0.3)
    }

    func testTextAsWellIsKeptWhileOffAndTakesATextPreset() throws {
        var preset = WatermarkSpec(text: "Ảnh: SuZu")
        preset.position = .topLeft; preset.size = 0.18; preset.opacity = 0.7; preset.margin = 0.02
        preset.textColor = .black; preset.font = "Courier"; preset.presetId = "p1"
        var mark = WatermarkSpec.TextMark(preset)
        XCTAssertTrue(mark.sameLook(as: preset))
        XCTAssertEqual(mark.presetId, "p1")
        XCTAssertEqual(mark.spec.font, "Courier")
        XCTAssertEqual(mark.spec.position, .topLeft)
        mark.off = true
        XCTAssertFalse(mark.isShown)
        XCTAssertTrue(mark.sameLook(as: preset), "turning it off doesn't change its look")
        var spec = WatermarkSpec(logoPath: "")
        spec.extraText = mark
        XCTAssertTrue(spec.isEmpty, "off: nothing to draw")
        XCTAssertNil(spec.shownExtraText)
        spec.extraText?.off = nil
        XCTAssertEqual(spec.shownExtraText?.text, "Ảnh: SuZu")
        mark.size = 0.3
        XCTAssertFalse(mark.sameLook(as: preset))
    }

    func testTextWatermarkUsesItsFont() throws {
        // The same words are wider in Courier than in the default face, and each font's mark is kept apart.
        let plain = try XCTUnwrap(EditPipeline.textMark("SuZu Media", color: .white))
        let courier = try XCTUnwrap(EditPipeline.textMark("SuZu Media", color: .white, font: "Courier"))
        XCTAssertGreaterThan(courier.extent.width, plain.extent.width * 1.05)
        // Drawn on a photo one after the other, each comes out in its own font (not the first one's, from the cache).
        let canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        var a = WatermarkSpec(text: "SuZu Media")
        a.opacity = 1
        var b = a
        b.font = "Courier"
        func pixels(_ spec: WatermarkSpec) throws -> [UInt8] {
            var px = [UInt8](repeating: 0, count: 600 * 400 * 4)
            CIContext().render(try EditPipeline.watermark(canvas, spec: spec), toBitmap: &px, rowBytes: 600 * 4,
                               bounds: canvas.extent, format: .RGBA8, colorSpace: nil)
            return px
        }
        XCTAssertNotEqual(try pixels(a), try pixels(b))
    }

    func testTextOnTheBannersEdgeKeepsItsMarginFromTheBanner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("banner-margin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bar = dir.appendingPathComponent("red.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1400, height: 50)), to: bar,
                                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // A red banner 120 px high along the bottom of 1200 x 800; white text bottom-left, its own margin 20 px.
        var spec = WatermarkSpec(banner: bar.path)
        spec.bannerHeight = 0.1
        spec.extraText = WatermarkSpec.TextMark(text: "© SuZu Media", position: .bottomLeft)
        spec.extraText?.opacity = 1
        spec.extraText?.margin = 20.0 / 800
        let canvas = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let out = try EditPipeline.watermark(canvas, spec: spec)
        func green(_ r: CGRect) -> Double {
            let f = out.cropped(to: r).applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(f, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(px[1]) / 255
        }
        XCTAssertLessThan(green(CGRect(x: 0, y: 0, width: 1200, height: 138)), 0.3)          // banner and the 20 px above it: no text
        XCTAssertGreaterThan(green(CGRect(x: 0, y: 140, width: 500, height: 120)), 0.9)      // the text, just above that
        // Text on another edge is measured from the photo's edge as usual.
        spec.extraText?.position = .topLeft
        let top = try EditPipeline.watermark(canvas, spec: spec)
        let r = CGRect(x: 0, y: 660, width: 500, height: 120)
        let f = top.cropped(to: r).applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(f, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        XCTAssertGreaterThan(Double(px[1]) / 255, 0.9)
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
