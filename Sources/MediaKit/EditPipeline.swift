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
        guard var image = decode(src, data: data, recipe: recipe, properties: props) else { throw Failure.unreadable(url.lastPathComponent) }
        let sourceSpace = image.colorSpace
        image = try apply(recipe, to: image, focus: CropPlacements.shared.focus(for: url, given: focus))
        let deep = (props?[kCGImagePropertyDepth] as? Int ?? 8) > 8
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

    /// Upright image at the resolution the recipe needs (full size when it keeps the original size).
    static func decode(_ src: CGImageSource, data: Data, recipe: EditRecipe, properties p: [CFString: Any]?) -> CIImage? {
        var w = Double(p?[kCGImagePropertyPixelWidth] as? Int ?? 0), h = Double(p?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        if let o = p?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        if let target = recipe.maxLongSide, w > 0, h > 0 {
            // Share of the long side the crop keeps (crops never upscale, so this is how much detail is needed).
            var keep = 1.0
            if let a = recipe.aspect(for: CGSize(width: w, height: h)) {
                let cw = min(w, h * a.ratio), ch = min(h, w / a.ratio)
                keep = max(cw, ch) / max(w, h)
            }
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

    /// The recipe applied to an image in memory (also used for video frames and previews).
    public static func apply(_ recipe: EditRecipe, to input: CIImage, focus: FocusHint?) throws -> CIImage {
        var image = input, focus = focus
        if recipe.autoTone { image = autoTone(image, strength: recipe.autoToneStrength) }
        if let degrees = rotation(recipe, image) { (image, focus) = rotate(image, degrees: degrees, focus: focus) }
        if let aspect = recipe.aspect(for: image.extent.size) {
            let size = image.extent.size
            let hint = focus ?? detectFaces(image)
            let r = cropRect(imageSize: size, ratio: aspect.ratio, focus: hint)
            // Core Image is bottom-left origin.
            image = image.cropped(to: CGRect(x: image.extent.minX + r.minX, y: image.extent.minY + size.height - r.maxY,
                                             width: r.width, height: r.height))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if let long = recipe.maxLongSide, long > 0 {
            let scale = Double(long) / Double(max(image.extent.width, image.extent.height))
            if scale < 1 {
                // Exact output size (e.g. 1080 x 1350): Lanczos leaves fractional edges that rounding would grow.
                let w = (image.extent.width * scale).rounded(), h = (image.extent.height * scale).rounded()
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                image = image.cropped(to: CGRect(x: image.extent.minX.rounded(), y: image.extent.minY.rounded(), width: w, height: h))
            }
        }
        if let wm = recipe.watermark { image = try watermark(image, spec: wm) }
        return image
    }

    // MARK: - Auto tone

    public static func autoTone(_ image: CIImage, strength: Double) -> CIImage {
        var out = image
        for f in image.autoAdjustmentFilters(options: [.redEye: false, .crop: false, .level: false]) {
            f.setValue(out, forKey: kCIInputImageKey)
            if let o = f.outputImage { out = o }
        }
        out = out.cropped(to: image.extent)
        guard strength < 0.999 else { return out }
        return out.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputImageKey: image, kCIInputTimeKey: max(0, strength)])
            .cropped(to: image.extent)
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

    /// Largest rect of the given aspect ratio that fits, placed so the main face sits a little above centre
    /// (headroom), with everyone else in the shot in frame too: faces at least half the main face's height (smaller ones
    /// are people in the background), nearest first, as many as fit. Top-left origin, pixels.
    public static func cropRect(imageSize: CGSize, ratio: Double, focus: FocusHint?) -> CGRect {
        let W = imageSize.width, H = imageSize.height
        var cw = W, ch = W / ratio
        if ch > H { ch = H; cw = H * ratio }
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

    public static func watermark(_ image: CIImage, spec: WatermarkSpec) throws -> CIImage {
        guard !spec.isEmpty else { return image }
        let ext = image.extent
        let path = spec.logoPath(for: ext.size)
        let logo = try spec.isText ? cachedMark("text|\(spec.textColor?.rawValue ?? "")|\(spec.text!)", path) { textMark(spec.text!, color: spec.textColor ?? .white) }
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
        let ys: [CGFloat] = [ext.height - h - m, (ext.height - h) / 2, m]  // top, middle, bottom (bottom-left origin)
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
    static func textMark(_ text: String, color: WatermarkSpec.TextColor) -> CIImage? {
        let fontSize: CGFloat = 160
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
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
