import CoreGraphics
import CoreImage
import CoreText
import FaceCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Renders a photo through an `EditRecipe`: auto tone -> face-aware crop -> resize -> watermark -> JPEG with metadata.
public enum EditPipeline {
    static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    public enum Failure: Error, LocalizedError {
        case unreadable(String), logo(String), write(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let p): "Can't read \(p)"
            case .logo(let p): "Can't read the logo \(p)"
            case .write(let p): "Can't write \(p)"
            }
        }
    }

    /// Writes the edited photo as JPEG to `dest`. `focus` nil: faces are detected on the fly when cropping. The photo's
    /// own crop (shape and placement edited by hand) wins over the recipe's.
    public static func render(_ url: URL, recipe: EditRecipe, focus: FocusHint?, people: [String] = [], to dest: URL) throws {
        let recipe = CropPlacements.shared.recipe(recipe, for: url)
        // One read per file (a network share would otherwise send it twice), then decode only as many pixels as the
        // output needs: a 1350 px Instagram crop doesn't need all 33 megapixels.
        guard let data = try? Data(contentsOf: url, options: .uncached),
              let src = CGImageSourceCreateWithData(data as CFData, ImageLoader.sourceOptions(for: url) as CFDictionary) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let focus = CropPlacements.shared.focus(for: url, given: focus)
        guard var image = decode(src, data: data, recipe: recipe, properties: props, zoom: focus?.magnification ?? 1, rect: focus?.rect) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let sourceSpace = image.colorSpace
        // Deep when the decoded pixels are (a 10-bit HEIC, a 16-bit TIFF): a RAW develops to 8 bits here, and a 16-bit
        // PNG of it took seconds to write at twice the size for nothing.
        let deep = (image.cgImage.map(\.bitsPerComponent) ?? props?[kCGImagePropertyDepth] as? Int ?? 8) > 8
        image = try apply(recipe, to: image, focus: focus)
        guard let cg = pixels(image, format: recipe.outputFormat, sourceSpace: sourceSpace, deep: deep) else {
            throw Failure.write(dest.lastPathComponent)
        }
        try writeImage(cg, to: dest, format: recipe.outputFormat, quality: recipe.jpegQuality, sourceProperties: props,
                       people: recipe.writePeopleNames ? people : [])
    }

    /// Final pixels. JPEG: 8-bit sRGB, as before. PNG: no alpha channel, the photo's own RGB colour space (Display P3
    /// stays P3), and 16 bits per channel when the original has more than 8 (10-bit HEIC, 16-bit TIFF).
    public static func pixels(_ image: CIImage, format: OutputFormat, sourceSpace: CGColorSpace? = nil, deep: Bool = false) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard format == .png else { return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb) }
        let space = sourceSpace.flatMap { $0.model == .rgb && $0.name != nil ? $0 : nil } ?? srgb
        let bits = deep ? 16 : 8
        let w = Int(image.extent.width), h = Int(image.extent.height)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        context.render(image, toBitmap: ctx.data!, rowBytes: ctx.bytesPerRow, bounds: image.extent,
                       format: deep ? .RGBA16 : .RGBA8, colorSpace: space)
        return ctx.makeImage()
    }

    /// Upright image at the resolution the recipe needs (full size when it keeps the original size). `zoom`: the
    /// photo's own crop zoom, which keeps a smaller part of it.
    static func decode(_ src: CGImageSource, data: Data, recipe: EditRecipe, properties p: [CFString: Any]?, zoom: Double = 1, rect: CGRect? = nil) -> CIImage? {
        var w = Double(p?[kCGImagePropertyPixelWidth] as? Int ?? 0), h = Double(p?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        if let o = p?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        if recipe.look.swapsSides { swap(&w, &h) }
        if let target = recipe.maxLongSide, w > 0, h > 0 {
            // Share of the long side the crop keeps (crops never upscale, so this is how much detail is needed).
            var keep = 1.0
            if let rect {
                keep = max(rect.width * w, rect.height * h) / max(w, h)
            } else if let a = recipe.aspect(for: CGSize(width: w, height: h)) {
                let cw = min(w, h * a.ratio), ch = min(h, w / a.ratio)
                keep = max(cw, ch) / max(w, h)
            }
            if rect == nil { keep /= max(1, zoom) }
            // Straightening trims up to about 15% (at 10°).
            let turn = recipe.straighten == true || recipe.rotation != nil ? 1 / 0.85 : 1
            let needed = Int((Double(target) / keep * 1.05 * turn).rounded(.up))
            if Double(needed) < max(w, h) * 0.9 {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: needed,
                                             kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return CIImage(cgImage: cg) }
            }
        }
        // A RAW file is developed here (seconds per photo, done only for full-size exports); Core Image can't read
        // its bytes directly.
        if ImageLoader.isRawSource(src), let long = [w, h].max(), long > 0 {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Int(long),
                                         kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { CIImage(cgImage: $0) }
        }
        return CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    /// The recipe applied to an image in memory (also used for video frames and previews): turned the right way up,
    /// healed, toned, levelled, cropped, resized, watermarked.
    ///
    /// `previewLongSide`: for previews, the cropped photo is scaled to exactly this long side (up or down) before the
    /// watermark goes on, so the watermark is drawn at the screen's resolution however far the preview is zoomed.
    public static func apply(_ recipe: EditRecipe, to input: CIImage, focus: FocusHint?, previewLongSide: Int? = nil) throws -> CIImage {
        // Healed first, on the photo as shot (where the strokes are kept).
        var (image, focus) = orient(Healing.apply(recipe.heal ?? [], to: input, amount: recipe.healAmount ?? 1), recipe.look, focus: focus)
        // Auto tone, the people's parts and the horizon are measured on a copy the size of the editor's preview, as
        // the preview measures them: on a whole 24-megapixel photo they took seconds each, for the same answer.
        let probe = analysisCopy(image)
        let auto = recipe.autoTone ? autoAdjustments(probe, strength: recipe.autoToneStrength) : nil
        let parts = recipe.retouch?.isActive == true ? BodyParts.find(in: probe) : nil
        image = tone(image, recipe, auto: auto, findParts: { _ in parts })
        if let degrees = rotation(recipe, probe) { (image, focus) = rotate(image, degrees: degrees, focus: focus) }
        let size = image.extent.size
        // Cropped to the export's shape, or, zoomed in by hand, to the photo's own shape.
        if let ratio = cropRatio(recipe, size: size, focus: focus) {
            var hint = focus
            // Nothing known about the faces (none given, or only a zoom set by hand): find them, so the zoomed crop
            // keeps the people in frame too. A crop drawn by hand needs none.
            if hint?.rect == nil, hint == nil || (hint!.hasNoFaces && hint!.center == nil) {
                hint = detectFaces(image).map { var d = $0; d.zoom = focus?.zoom; return d } ?? hint
            }
            let r = cropRect(imageSize: size, ratio: ratio, focus: hint)
            // Core Image is bottom-left origin.
            image = image.cropped(to: CGRect(x: image.extent.minX + r.minX, y: image.extent.minY + size.height - r.maxY,
                                             width: r.width, height: r.height))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if let long = previewLongSide ?? recipe.maxLongSide, long > 0 {
            let scale = Double(long) / Double(max(image.extent.width, image.extent.height))
            if scale < 1 || (previewLongSide != nil && scale > 1.001) {
                // Exact output size (e.g. 1080 x 1350): Lanczos leaves fractional edges that rounding would grow.
                let w = (image.extent.width * scale).rounded(), h = (image.extent.height * scale).rounded()
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                image = image.cropped(to: CGRect(x: image.extent.minX.rounded(), y: image.extent.minY.rounded(), width: w, height: h))
            }
        }
        if let wm = recipe.watermark { image = try watermark(image, spec: wm) }
        return image
    }

    /// Long side of the copy a photo is measured on (`analysisCopy`): the editor preview's.
    public static let analysisSide: CGFloat = 1600

    /// The image scaled down to `analysisSide` and rendered once, so each measurement reads that many pixels and
    /// not the whole photo again; small images as they are.
    static func analysisCopy(_ image: CIImage) -> CIImage {
        let e = image.extent, long = max(e.width, e.height)
        guard long > analysisSide * 1.2, e.width.isFinite else { return image }
        let k = analysisSide / long
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        guard let cg = context.createCGImage(small, from: small.extent) else { return image }
        return CIImage(cgImage: cg)
    }

    // MARK: - Tone

    /// The adjustments' light, colour and detail; with auto tone, on top of what auto tone sets for this photo
    /// (`autoAdjustments`), so the dials the editor shows are the ones applied.
    public static func tone(_ image: CIImage, _ recipe: EditRecipe) -> CIImage {
        tone(image, recipe, auto: recipe.autoTone ? autoAdjustments(image, strength: recipe.autoToneStrength) : nil)
    }

    /// As above with the auto tone's dials already measured (`autoAdjustments`), so a caller can show them.
    /// `levelled`: the image is already levelled by these degrees from a picture of this size (the editor's preview
    /// levels before toning), for the strokes painted on the masks to land where they were painted.
    /// `findParts`: how the people's parts are found (the editor's preview only has them for the photos it was asked
    /// to find them in).
    public static func tone(_ image: CIImage, _ recipe: EditRecipe, auto: Adjustments?, levelled: (degrees: Double, size: CGSize)? = nil,
                            findParts: (CIImage) -> BodyParts? = { BodyParts.find(in: $0) }) -> CIImage {
        let look = recipe.look.composed(over: auto)
        var out = look.changesPixels ? adjust(image, look) : image
        // The people's parts are found on the photo before toning (so moving a dial doesn't look for them again).
        if let r = recipe.retouch, r.isActive, let parts = findParts(image) {
            out = retouch(out, r, parts: parts, brush: placedBrush(recipe, levelled: levelled))
        }
        return out
    }

    /// The recipe's strokes, placed in the picture its masks are found on.
    public static func placedBrush(_ recipe: EditRecipe, levelled: (degrees: Double, size: CGSize)? = nil) -> [Retouch.Part: [MaskStroke]] {
        (recipe.brush ?? [:]).mapValues { MaskBrush.place($0, look: recipe.look, levelled: levelled?.degrees, size: levelled?.size ?? .zero) }
    }

    // MARK: - Retouch

    /// Skin smoothed, brightened and made fairer where face skin (and body skin) is, then each part's own dials
    /// where it is.
    /// `brush`: strokes painted by hand on the parts' masks, placed in this image.
    public static func retouch(_ image: CIImage, _ r: Retouch, parts: BodyParts, brush: [Retouch.Part: [MaskStroke]] = [:]) -> CIImage {
        let ext = image.extent
        let short = min(ext.width, ext.height)
        var out = image
        if r.retouchesSkin {
            let skin = partMask(.skin, r, parts: parts, extent: ext, brush: brush)
            out = beautify(out, r, short: short).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: skin])
        }
        for (part, look) in r.parts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where look.changesPixels {
            let mask = partMask(part, r, parts: parts, extent: ext, brush: brush)
            out = adjust(out, part: look).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
        }
        return out.cropped(to: ext)
    }

    /// A part's mask over a photo of this extent, shaped by its dials, then the strokes painted on it by hand (`brush`,
    /// each part's, placed in this image): what the part's dials change, and what Show Mask draws.
    /// The skin retouch's mask is the face skin mask, with the body skin mask too when `bodyToo`: the same ones, so
    /// shaping or painting them moves the retouch with them.
    public static func partMask(_ part: Retouch.Part, _ r: Retouch?, parts: BodyParts, extent: CGRect,
                                brush: [Retouch.Part: [MaskStroke]] = [:]) -> CIImage {
        guard part == .skin else {
            let shaped = shape(parts.mask(part.kind, extent: extent), r?.look(part) ?? PartLook(), short: min(extent.width, extent.height), extent: extent)
            return MaskBrush.apply(brush[part] ?? [], to: shaped, extent: extent)
        }
        var skin = partMask(.faceSkin, r, parts: parts, extent: extent, brush: brush)
        if r?.bodyToo ?? true {
            skin = skin.applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: partMask(.bodySkin, r, parts: parts, extent: extent, brush: brush)])
        }
        return MaskBrush.apply(brush[.skin] ?? [], to: skin, extent: extent)
    }

    /// A mask grown or shrunk, then its edge softened, by the part's dials (sized on the photo's short side).
    public static func shape(_ mask: CIImage, _ look: PartLook, short: CGFloat, extent: CGRect) -> CIImage {
        var m = mask.clampedToExtent()
        let grow = look.grow * Double(short) * 0.015
        if grow >= 0.5 { m = m.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]) }
        if grow <= -0.5 { m = m.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: -grow]) }
        let soft = look.softness * Double(short) * 0.008
        if soft >= 0.5 { m = m.applyingGaussianBlur(sigma: soft) }
        return m.cropped(to: extent)
    }

    /// The skin look over the whole picture (the mask keeps it to the skin): blotches and unevenness softened while
    /// fine texture stays (the band between a fine and a coarse blur taken out), brighter, fairer.
    static func beautify(_ image: CIImage, _ r: Retouch, short: CGFloat) -> CIImage {
        var out = image
        if r.smooth > 0 {
            let base = image.clampedToExtent()
            let k = r.smooth * 0.9
            // out = image − k·fine + k·coarse: the band between the two blurs (blemishes, uneven tone) goes, the finer
            // texture and the broad shading stay. Core Image works in floating point, so the negative layer adds up
            // exactly. The layers keep their alpha (Core Image premultiplies by it: at 0 they would add nothing), and
            // the sum's alpha is set back to one.
            func scaled(_ img: CIImage, _ f: Double) -> CIImage {
                img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
                                                                 "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
                                                                 "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0)])
            }
            let fine = scaled(base.applyingGaussianBlur(sigma: Double(short) * 0.0012), -k)
            let coarse = scaled(base.applyingGaussianBlur(sigma: Double(short) * 0.01), k)
            out = fine.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: out])
            out = coarse.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: out])
            out = out.settingAlphaOne(in: image.extent).cropped(to: image.extent)
        }
        if r.brighten > 0 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.brighten * 0.6]) }
        if r.whiten > 0 {
            // Fairer: less yellow and less colour, lighter mid-tones, a touch of pink.
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - r.whiten * 0.22, kCIInputBrightnessKey: 0])
            out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                          "inputTargetNeutral": CIVector(x: 6500 + r.whiten * 700, y: r.whiten * 18)])
            out = out.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 - r.whiten * 0.25])
        }
        return out
    }

    /// One part's dials, as the main ones do it.
    static func adjust(_ image: CIImage, part a: PartLook) -> CIImage {
        var out = image
        if a.exposure != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.contrast != 0 || a.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + a.contrast * 0.5, kCIInputSaturationKey: 1 + a.saturation])
        }
        if a.temperature != 0 || a.tint != 0 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                          "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 2500, y: a.tint * 60)])
        }
        if a.hue != 0 { out = out.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 3]) }
        return out
    }

    /// What Core Image's auto-enhance would do to this photo, as the editor's own dials: its tone curve, its
    /// shadow and highlight lift, its vibrance and exposure. (Its skin-tone balance has no dial and is left out.)
    /// `strength` scales it (1 = as Core Image would).
    public static func autoAdjustments(_ image: CIImage, strength: Double) -> Adjustments {
        var a = Adjustments()
        for f in image.autoAdjustmentFilters(options: [.redEye: false, .crop: false, .level: false]) {
            switch f.name {
            case "CIToneCurve":
                let pts = (0..<5).compactMap { f.value(forKey: "inputPoint\($0)") as? CIVector }.map { (Double($0.x), Double($0.y)) }.sorted { $0.0 < $1.0 }
                guard pts.count >= 2 else { break }
                // Its points usually sit at 0, ¼, ½, ¾ and 1; sampled there in any case.
                a.tone = Adjustments.straightCurve.map { x in
                    if x <= pts[0].0 { return pts[0].1 }
                    if x >= pts[pts.count - 1].0 { return pts[pts.count - 1].1 }
                    let i = pts.lastIndex { $0.0 <= x }!
                    let (x0, y0) = pts[i], (x1, y1) = pts[i + 1]
                    return x1 > x0 ? y0 + (y1 - y0) * (x - x0) / (x1 - x0) : y0
                }
            case "CIHighlightShadowAdjust":
                if let h = f.value(forKey: "inputHighlightAmount") as? NSNumber { a.highlights = ((h.doubleValue - 1) / 0.7).clamped(-1, 0) }
                if let s = f.value(forKey: "inputShadowAmount") as? NSNumber { a.shadows = s.doubleValue.clamped(-1, 1) }
            case "CIVibrance":
                if let v = f.value(forKey: kCIInputAmountKey) as? NSNumber { a.vibrance = v.doubleValue.clamped(-1, 1) }
            case "CIExposureAdjust":
                if let ev = f.value(forKey: kCIInputEVKey) as? NSNumber { a.exposure = ev.doubleValue.clamped(-2, 2) }
            default:
                break
            }
        }
        return strength >= 0.999 ? a : a.scaled(max(0, strength))
    }

    /// Flips and quarter turns, with the face rects turned along. The result's origin is zero.
    public static func orient(_ image: CIImage, _ a: Adjustments, focus: FocusHint?) -> (CIImage, FocusHint?) {
        guard a.changesOrientation else { return (image, focus) }
        var out = image
        if a.flipHorizontal { out = out.oriented(.upMirrored) }
        if a.flipVertical { out = out.oriented(.downMirrored) }
        for _ in 0..<((a.turns % 4 + 4) % 4) { out = out.oriented(.right) }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        guard var f = focus else { return (out, nil) }
        f.primary = f.primary.map(a.map)
        f.others = f.others.map(a.map)
        return (out, f)
    }

    /// Light, colour and detail, in the order editors apply them: exposure and tone, then colour, then sharpening and
    /// the vignette.
    public static func adjust(_ image: CIImage, _ a: Adjustments) -> CIImage {
        var out = image
        let ext = image.extent
        if a.exposure != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.highlights < 0 || a.shadows != 0 {
            out = out.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + max(-1, a.highlights) * 0.7,
                                                                             "inputShadowAmount": a.shadows, "inputRadius": 2.5])
        }
        if a.highlights > 0 {
            // Brighter highlights: the top of the curve lifted, the rest untouched.
            out = curve(out, [0, 0.25, 0.5, 0.75 + min(1, a.highlights) * 0.12, 1])
        }
        if a.whites != 0 || a.blacks != 0 {
            out = out.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": endsLUT(whites: a.whites, blacks: a.blacks), "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        if a.contrast != 0 || a.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + a.contrast * 0.5, kCIInputSaturationKey: 1 + a.saturation])
        }
        if a.hasCurve { out = curve(out, a.tone) }
        if let hsl = a.hsl, !hsl.isEmpty {
            out = out.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": hslCubeSize, "inputCubeData": hslCube(hsl), "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        if a.temperature != 0 || a.tint != 0 {
            // Warmer = the neutral point moved to a cooler light (6500 K daylight is "as shot").
            out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                          "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 2500, y: a.tint * 60)])
        }
        if a.vibrance != 0 { out = out.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: a.vibrance]) }
        if a.monochrome { out = out.applyingFilter("CIPhotoEffectMono") }
        let side = max(ext.width, ext.height)
        if a.clarity > 0 {
            // Local contrast: a wide, gentle unsharp mask.
            out = out.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: side / 100, kCIInputIntensityKey: a.clarity * 0.8])
        } else if a.clarity < 0 {
            // Less local contrast: part of the way to the same wide blur, a softer, hazier look.
            out = soften(out, radius: side / 100, amount: -a.clarity * 0.6, extent: ext)
        }
        if a.sharpness > 0 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness * 1.2, kCIInputRadiusKey: 1.5])
        } else if a.sharpness < 0 {
            // Softer: towards a fine blur, sized to the picture so the preview looks like the export.
            out = soften(out, radius: side / 1500, amount: -a.sharpness, extent: ext)
        }
        if a.vignette > 0 {
            out = out.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: a.vignette * 1.6, kCIInputRadiusKey: 1.6])
        }
        return out.cropped(to: ext)
    }

    /// The image `amount` (0…1) of the way to a Gaussian blur of `radius` pixels; edges clamped so they don't darken.
    static func soften(_ image: CIImage, radius: CGFloat, amount: Double, extent: CGRect) -> CIImage {
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: blurred, kCIInputTimeKey: min(1, amount)])
    }

    // MARK: Tone curve

    nonisolated(unsafe) static var curveCache: ([Double], Data)?

    /// The image through a tone curve: five outputs for the inputs 0, ¼, ½, ¾ and 1, joined by a monotone cubic
    /// (no overshoot between points), as a 256-step lookup. (CIToneCurveAdjust is not used: it returns an empty
    /// image on recent macOS.)
    public static func curve(_ image: CIImage, _ points: [Double]) -> CIImage {
        guard points.count == 5 else { return image }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": curveLUT(points), "inputCurvesDomain": CIVector(x: 0, y: 1), "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
    }

    /// 256 RGB triples of the curve.
    public static func curveLUT(_ points: [Double]) -> Data {
        hslLock.lock(); defer { hslLock.unlock() }
        if let c = curveCache, c.0 == points { return c.1 }
        var lut = [Float]()
        lut.reserveCapacity(256 * 3)
        for i in 0..<256 {
            let v = Float(min(1, max(0, curveValue(points, Double(i) / 255))))
            lut.append(v); lut.append(v); lut.append(v)
        }
        let data = lut.withUnsafeBufferPointer { Data(buffer: $0) }
        curveCache = (points, data)
        return data
    }

    nonisolated(unsafe) static var endsCache: (Double, Double, Data)?

    /// Whites and blacks: each end of the tones moved, the middle barely. Whites shifts tone x by 0.25·w·x³ (at 1
    /// white clips, at −1 the brightest come down a quarter), blacks by 0.2·b·(1−x)³; always rising, so no tones swap.
    public static func endsValue(_ x: Double, whites w: Double, blacks b: Double) -> Double {
        min(1, max(0, x + 0.25 * w * x * x * x + 0.2 * b * (1 - x) * (1 - x) * (1 - x)))
    }

    /// 256 RGB triples of `endsValue`.
    public static func endsLUT(whites: Double, blacks: Double) -> Data {
        hslLock.lock(); defer { hslLock.unlock() }
        if let c = endsCache, c.0 == whites, c.1 == blacks { return c.2 }
        var lut = [Float]()
        lut.reserveCapacity(256 * 3)
        for i in 0..<256 {
            let v = Float(endsValue(Double(i) / 255, whites: whites, blacks: blacks))
            lut.append(v); lut.append(v); lut.append(v)
        }
        let data = lut.withUnsafeBufferPointer { Data(buffer: $0) }
        endsCache = (whites, blacks, data)
        return data
    }

    /// Fritsch–Carlson monotone cubic interpolation of (i/4, points[i]) at `x`.
    public static func curveValue(_ y: [Double], _ x: Double) -> Double {
        let n = y.count, h = 1.0 / Double(n - 1)
        var d = [Double](repeating: 0, count: n - 1), m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { d[i] = (y[i + 1] - y[i]) / h }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        let i = min(max(Int(x / h), 0), n - 2)
        let t = (x - Double(i) * h) / h, t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * y[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * y[i + 1] + (t3 - t2) * h * m[i + 1]
    }

    // MARK: HSL

    static let hslCubeSize = 32
    nonisolated(unsafe) static var hslCubeCache: (HSLAdjust, Data)?
    static let hslLock = NSLock()

    /// A colour cube that turns, saturates and lightens each colour band as asked: every colour of the cube goes
    /// through HSV, its band weights (a triangle between neighbouring bands), the shifts, and back. Grey is left
    /// alone, and the nearly grey nearly so.
    public static func hslCube(_ a: HSLAdjust) -> Data {
        hslLock.lock(); defer { hslLock.unlock() }
        if let c = hslCubeCache, c.0 == a { return c.1 }
        let n = hslCubeSize
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        let centres = HSLAdjust.hues
        var i = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let rf = Double(r) / Double(n - 1), gf = Double(g) / Double(n - 1), bf = Double(b) / Double(n - 1)
            var (h, s, v) = hsv(rf, gf, bf)
            if s > 0.001 && v > 0.001 {
                // Band weights: 1 at a band's hue, 0 at its neighbours'.
                var shift = 0.0, sat = 0.0, lum = 0.0
                for k in 0..<8 {
                    let c0 = centres[k], prev = centres[(k + 7) % 8], next = centres[(k + 1) % 8]
                    let left = ((c0 - prev) + 360).truncatingRemainder(dividingBy: 360), right = ((next - c0) + 360).truncatingRemainder(dividingBy: 360)
                    var d = h - c0
                    if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                    let w = d < 0 ? max(0, 1 + d / left) : max(0, 1 - d / right)
                    shift += w * a.hue[k] * 30
                    sat += w * a.saturation[k]
                    lum += w * a.luminance[k]
                }
                // Nearly grey colours are barely touched, so skies and skin don't tear at the edges.
                let k = min(1, s * 2.5)
                h = (h + shift * k + 360).truncatingRemainder(dividingBy: 360)
                s = min(1, max(0, s * (1 + sat * k)))
                v = min(1, max(0, v * (1 + lum * 0.6 * k)))
            }
            let (ro, go, bo) = rgb(h, s, v)
            cube[i] = Float(ro); cube[i + 1] = Float(go); cube[i + 2] = Float(bo); cube[i + 3] = 1
            i += 4
        } } }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        hslCubeCache = (a, data)
        return data
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
            if h < 0 { h += 360 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double) = switch Int(h / 60) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    // MARK: - Straighten

    /// How far the photo is turned off level, in degrees counter-clockwise, when it looks like a slip: 0.3°–10°,
    /// measured on its long straight lines (see TiltEstimator). Bigger tilts are taken as meant. Vision's horizon
    /// request isn't used: it reports a confident tilt for most level photos taken indoors.
    public static func horizonTilt(_ image: CIImage) -> Double? {
        guard let degrees = TiltEstimator.tilt(image) else { return nil }
        return abs(degrees) >= 0.3 && abs(degrees) <= 10 ? degrees : nil
    }

    /// The turn a recipe asks for, in degrees counter-clockwise: the photo's own, else the one that levels its horizon.
    public static func rotation(_ recipe: EditRecipe, _ image: CIImage) -> Double? {
        if let r = recipe.rotation { return abs(r) < 0.01 ? nil : r }
        return recipe.straighten == true ? horizonTilt(image).map { -$0 } : nil
    }

    /// Share of each side left after turning a w x h photo by `degrees` and trimming to the largest frame of the same
    /// shape that has no empty corners.
    public static func rotatedScale(_ size: CGSize, degrees: Double) -> Double {
        let t = degrees * .pi / 180, c = abs(cos(t)), s = abs(sin(t)), w = size.width, h = size.height
        return min(w / (w * c + h * s), h / (w * s + h * c))
    }

    /// Turned `degrees` counter-clockwise about its centre and trimmed to the largest frame of the same shape inside,
    /// so no empty corners show. Face rects (normalized, top-left origin) turn with it.
    public static func rotate(_ image: CIImage, degrees: Double, focus: FocusHint?) -> (CIImage, FocusHint?) {
        let ext = image.extent, w = ext.width, h = ext.height, t = degrees * .pi / 180
        let k = rotatedScale(ext.size, degrees: degrees)
        let W = (w * k).rounded(.down), H = (h * k).rounded(.down)
        let turn = CGAffineTransform(translationX: -ext.midX, y: -ext.midY)
            .concatenating(CGAffineTransform(rotationAngle: t))
            .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))
        // Clamped first, so the edges don't fade into the transparent area outside.
        let out = image.clampedToExtent().transformed(by: turn).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        func map(_ r: CGRect) -> CGRect {
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            let turned = corners.map { p -> CGPoint in
                let dx = (p.x - 0.5) * w, dy = (0.5 - p.y) * h  // from the centre, y up
                let x = dx * cos(t) - dy * sin(t), y = dx * sin(t) + dy * cos(t)
                return CGPoint(x: (x + W / 2) / W, y: (H / 2 - y) / H)
            }
            let minX = max(0, turned.map(\.x).min()!), maxX = min(1, turned.map(\.x).max()!)
            let minY = max(0, turned.map(\.y).min()!), maxY = min(1, turned.map(\.y).max()!)
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
        guard var f = focus else { return (out, nil) }
        f.primary = f.primary.map(map)
        f.others = f.others.map(map)
        return (out, f)
    }

    // MARK: - Crop

    /// Width / height of the crop a photo of this size gets: the recipe's shape, else (zoomed in by hand) its own;
    /// nil when it isn't cropped at all.
    public static func cropRatio(_ recipe: EditRecipe, size: CGSize, focus: FocusHint?) -> Double? {
        if let r = focus?.rect, r.width > 0, r.height > 0, size.height > 0 { return (r.width * size.width) / (r.height * size.height) }
        if let a = recipe.aspect(for: size) { return a.ratio }
        guard (focus?.magnification ?? 1) > 1, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// Largest rect of the given aspect ratio that fits (1/zoom of it when zoomed in by hand), placed so the main face
    /// sits a little above centre (headroom), with everyone else in the shot in frame too: faces at least half the main
    /// face's height (smaller ones are people in the background), nearest first, as many as fit. Top-left origin, pixels.
    public static func cropRect(imageSize: CGSize, ratio: Double, focus: FocusHint?) -> CGRect {
        let W = imageSize.width, H = imageSize.height
        if let r = focus?.rect {
            // Drawn by hand: as drawn, kept inside the photo and at least a few pixels.
            let w = min(max(r.width * W, 4), W), h = min(max(r.height * H, 4), H)
            let x = min(max(r.minX * W, 0), W - w), y = min(max(r.minY * H, 0), H - h)
            return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded()).intersection(CGRect(origin: .zero, size: imageSize))
        }
        var cw = W, ch = W / ratio
        if ch > H { ch = H; cw = H * ratio }
        let zoom = focus?.magnification ?? 1
        cw /= zoom; ch /= zoom
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H) }
        if let c = focus?.center {
            let x = min(max(c.x * W - cw / 2, 0), W - cw), y = min(max(c.y * H - ch / 2, 0), H - ch)
            return CGRect(x: x.rounded(), y: y.rounded(), width: cw.rounded(), height: ch.rounded())
                .intersection(CGRect(origin: .zero, size: imageSize))
        }
        let others = (focus?.others ?? []).map(px)
        var target = focus?.primary.map(px) ?? others.max { $0.height < $1.height }
        if let main = target {
            func distance(_ r: CGRect) -> CGFloat { hypot(r.midX - main.midX, r.midY - main.midY) }
            for r in others.filter({ $0.height >= main.height * 0.5 }).sorted(by: { distance($0) < distance($1) }) {
                let group = target!.union(r)
                if group.width <= cw * 0.9 && group.height <= ch * 0.8 { target = group }
            }
        }
        guard let t = target else {
            return CGRect(x: ((W - cw) / 2).rounded(), y: ((H - ch) / 2).rounded(), width: cw.rounded(), height: ch.rounded())
                .intersection(CGRect(origin: .zero, size: imageSize))
        }
        // Eyes roughly on the upper third: put the face centre at 40% of the crop height.
        let x = min(max(t.midX - cw / 2, 0), W - cw)
        let y = min(max(t.midY - ch * 0.40, 0), H - ch)
        return CGRect(x: x.rounded(), y: y.rounded(), width: cw.rounded(), height: ch.rounded())
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Faces (or, without faces, the most eye-catching region) for crops of images not in the library.
    public static func detectFaces(_ image: CIImage) -> FocusHint? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([faces])
        func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
        let rects = (faces.results ?? []).map { topLeft($0.boundingBox) }.sorted { $0.width * $0.height > $1.width * $1.height }
        if let first = rects.first { return FocusHint(primary: first, others: Array(rects.dropFirst())) }
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([saliency])
        if let box = (saliency.results?.first?.salientObjects ?? []).first?.boundingBox { return FocusHint(primary: topLeft(box)) }
        return nil
    }

    // MARK: - Watermark

    static let logoCache = NSCache<NSString, CIImage>()

    /// The logo, text or banner, then the text drawn as well (`extraText`). Text on the banner's edge keeps its
    /// margin from the banner, not from the photo's edge, so it sits beside the banner instead of on it.
    public static func watermark(_ image: CIImage, spec: WatermarkSpec) throws -> CIImage {
        var out = try mark(image, spec: spec)
        if let t = spec.shownExtraText {
            var inset = (top: CGFloat(0), bottom: CGFloat(0))
            if spec.isBanner && spec.hasMark {
                let ext = image.extent
                let band = max(ext.width, ext.height) * (spec.bannerHeight ?? WatermarkSpec.defaultBannerHeight) + min(ext.width, ext.height) * spec.margin
                switch WatermarkSpec.Position.allCases.firstIndex(of: spec.position)! / 3 {
                case 0: inset.top = band
                case 2: inset.bottom = band
                default: break
                }
            }
            out = try mark(out, spec: t.spec, inset: inset)
        }
        return out
    }

    /// One mark; `inset` moves the top and bottom rows in from those edges (past a banner there).
    static func mark(_ image: CIImage, spec: WatermarkSpec, inset: (top: CGFloat, bottom: CGFloat) = (0, 0)) throws -> CIImage {
        guard spec.hasMark else { return image }
        let ext = image.extent
        let path = spec.logoPath(for: ext.size)
        let font = spec.font ?? WatermarkSpec.defaultFont
        let logo = try spec.isText ? cachedMark("text|\(spec.textColor?.rawValue ?? "")|\(font)|\(spec.text!)", path) {
            textMark(spec.text!, color: spec.textColor ?? .white, font: font)
        }
            : loadLogo(path)
        let short = min(ext.width, ext.height), long = max(ext.width, ext.height)
        var mark: CIImage
        if spec.isBanner {
            // Exactly the same height on every photo shape, whatever the banner was made for: banners are made wider than
            // any photo, with their text and logos in a safe zone in the middle, and the sides are trimmed (cropped(to:)
            // below). One too narrow to cover the width is stretched sideways to cover it; the height never changes.
            let s = long * (spec.bannerHeight ?? WatermarkSpec.defaultBannerHeight) / logo.extent.height
            mark = logo.transformed(by: CGAffineTransform(scaleX: max(s, ext.width / logo.extent.width), y: s))
        } else {
            // Sized on the shorter side, so it looks the same either way round.
            let s = short * spec.size / logo.extent.width
            mark = logo.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        mark = mark.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: spec.opacity)])
        let m = short * spec.margin, w = mark.extent.width, h = mark.extent.height
        let xs: [CGFloat] = spec.isBanner ? Array(repeating: (ext.width - w) / 2, count: 3) : [m, (ext.width - w) / 2, ext.width - w - m]
        let ys: [CGFloat] = [ext.height - h - m - inset.top, (ext.height - h) / 2, m + inset.bottom]  // top, middle, bottom (bottom-left origin)
        let idx = WatermarkSpec.Position.allCases.firstIndex(of: spec.position)!
        let pos = CGPoint(x: xs[idx % 3], y: ys[idx / 3])
        mark = mark.transformed(by: CGAffineTransform(translationX: ext.minX + pos.x - mark.extent.minX, y: ext.minY + pos.y - mark.extent.minY))
        return mark.composited(over: image).cropped(to: ext)
    }

    static func loadLogo(_ path: String) throws -> CIImage {
        try cachedMark(path, path) { CIImage(contentsOf: URL(fileURLWithPath: path, isDirectory: false)) }
    }

    static func cachedMark(_ key: String, _ path: String, make: () -> CIImage?) throws -> CIImage {
        if let l = logoCache.object(forKey: key as NSString) { return l }
        guard let l = make(), l.extent.width > 0, l.extent.height > 0 else { throw Failure.logo(path) }
        logoCache.setObject(l, forKey: key as NSString)
        return l
    }

    /// Text drawn large with a soft shadow (legible on light and dark areas), then scaled like a logo.
    static func textMark(_ text: String, color: WatermarkSpec.TextColor, font name: String = WatermarkSpec.defaultFont) -> CIImage? {
        let fontSize: CGFloat = 160
        // A font no longer installed falls back to Core Text's choice for the name (Helvetica), not a failure.
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        let white = color == .white
        let attr = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: white ? 1 : 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = fontSize * 0.25
        guard width > 0, let ctx = CGContext(data: nil, width: Int((width + 2 * pad).rounded(.up)), height: Int((ascent + descent + 2 * pad).rounded(.up)),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.03), blur: fontSize * 0.12, color: CGColor(gray: white ? 0 : 1, alpha: 0.45))
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    // MARK: - Encode

    public static func writeImage(_ image: CGImage, to dest: URL, format: OutputFormat = .jpeg, quality: Double,
                                  sourceProperties: [CFString: Any]?, people: [String]) throws {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.write(dest.lastPathComponent)
        }
        // Keep EXIF/GPS/IPTC from the original, but the pixels are already upright and resized.
        var props = sourceProperties ?? [:]
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] { props[k] = nil }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = nil; props[kCGImagePropertyTIFFDictionary] = tiff }
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        // One filter for every row, not ImageIO's pick per row: half the time on a 24-megapixel photo, and smaller.
        if format == .png { props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_UP] }
        props[kCGImagePropertyOrientation] = 1
        if !people.isEmpty {
            var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            iptc[kCGImagePropertyIPTCKeywords] = Array(Set((iptc[kCGImagePropertyIPTCKeywords] as? [String] ?? []) + people))
            props[kCGImagePropertyIPTCDictionary] = iptc
        }
        if !people.isEmpty, let meta = Metadata.peopleMetadata(people) {
            CGImageDestinationAddImageAndMetadata(d, image, meta, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(d, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(d) else { try? FileManager.default.removeItem(at: tmp); throw Failure.write(dest.lastPathComponent) }
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

extension Retouch.Part {
    /// The mask this part is drawn with.
    public var kind: BodyParts.Kind {
        switch self {
        case .faceSkin, .skin: .faceSkin
        case .bodySkin: .bodySkin
        case .lips: .lips
        case .clothes: .clothes
        }
    }
}
