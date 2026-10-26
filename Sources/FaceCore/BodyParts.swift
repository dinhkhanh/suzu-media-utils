import Accelerate
import CoreImage
import CoreML
import Foundation
import Vision

/// The parts of the people in a photo as soft masks: face skin, body skin, lips, clothes, hair. Found by Sapiens
/// (Meta's body-part segmentation, converted by tools/convert_sapiens.py) when the app has the model; else, or when
/// it fails, by Apple Vision (`fromVision`): lips and face skin from face landmarks, body skin and clothes from the
/// person mask and the faces' skin colours.
///
/// The model sees 576 x 768 (portrait): a photo is scaled to 768 high (never enlarged: blown up, a small picture
/// isn't recognised) and covered by overlapping tiles of that shape, blended where they meet. Faces too small there
/// for their lips get a closer pass each, when the photo has at least twice the detail for them (never enlarged).
public final class BodyParts: @unchecked Sendable {
    public enum Kind: Int, CaseIterable, Sendable { case faceSkin, bodySkin, lips, clothes, hair }

    /// The compiled model (BodyParts.mlmodelc); set by the app at launch. Nil: Vision only.
    nonisolated(unsafe) public static var modelURL: URL?

    /// Mask size: the planes cover the whole photo at this resolution.
    public let width: Int, height: Int
    /// One plane per kind, rows from the top, 0…1.
    let planes: [[Float]]
    /// Closer looks at faces: each over its rect (normalized, top-left origin), same kinds.
    let details: [(rect: CGRect, width: Int, height: Int, planes: [[Float]])]
    /// Found by the model (else by Vision).
    public let byModel: Bool
    /// Eyes and brows (outlines, normalized, top-left origin): kept out of face skin, so smoothing it leaves lashes
    /// and brows sharp.
    var features: [[CGPoint]] = []

    init(width: Int, height: Int, planes: [[Float]], details: [(rect: CGRect, width: Int, height: Int, planes: [[Float]])] = [], byModel: Bool) {
        self.width = width; self.height = height; self.planes = planes; self.details = details; self.byModel = byModel
    }

    /// The share of the photo a kind covers (for tests and logs).
    public func coverage(_ kind: Kind) -> Double { planes[kind.rawValue].reduce(0) { $0 + Double($1) } / Double(max(1, width * height)) }

    // MARK: - Masks for drawing

    /// A kind's mask over a photo of `extent` (Core Image: bottom-left origin), white where the part is, with the
    /// faces' closer looks laid over it.
    public func mask(_ kind: Kind, extent: CGRect) -> CIImage {
        var out = Self.image(planes[kind.rawValue], width: width, height: height, into: extent)
        for d in details {
            // Top-left normalized rect → Core Image rect in the extent.
            let r = CGRect(x: extent.minX + d.rect.minX * extent.width, y: extent.minY + (1 - d.rect.maxY) * extent.height,
                           width: d.rect.width * extent.width, height: d.rect.height * extent.height)
            let patch = Self.image(d.planes[kind.rawValue], width: d.width, height: d.height, into: r)
            // Faded in from its edges, so no seam shows where the closer look ends.
            let fade = CIImage(color: .white).cropped(to: r.insetBy(dx: r.width * 0.12, dy: r.height * 0.12))
                .applyingGaussianBlur(sigma: Double(min(r.width, r.height)) * 0.06).cropped(to: r)
            out = patch.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: fade])
        }
        if kind == .faceSkin, let holes = featureMask(extent: extent) {
            out = out.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: holes])
        }
        return out.cropped(to: extent)
    }

    /// White everywhere but the eyes and brows (a little wider than their outlines, soft-edged).
    func featureMask(extent: CGRect) -> CIImage? {
        guard !features.isEmpty else { return nil }
        let scale = min(1, 1600 / max(extent.width, extent.height))
        let w = max(1, Int(extent.width * scale)), h = max(1, Int(extent.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        for outline in features where outline.count > 2 {
            // Bottom-left origin in the context; outlines are top-left normalized.
            let pts = outline.map { CGPoint(x: $0.x * CGFloat(w), y: (1 - $0.y) * CGFloat(h)) }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            ctx.setLineWidth(max(2, (max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)) * 0.35))
            ctx.setLineJoin(.round)
            ctx.addLines(between: pts); ctx.closePath()
            ctx.drawPath(using: .fillStroke)
        }
        guard let cg = ctx.makeImage() else { return nil }
        let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
        return img.clampedToExtent().applyingGaussianBlur(sigma: 1.5 / scale).cropped(to: extent)
    }

    static func image(_ plane: [Float], width: Int, height: Int, into rect: CGRect) -> CIImage {
        // Faint guesses (a printed graphic taken for a sleeve) count as nothing; sure ones as all: a smooth ramp
        // from 0.25 to 0.75. The edge's softness is the dials' (`PartLook.softness`).
        var bytes = plane.map { p -> UInt8 in
            let t = max(0, min(1, (p - 0.25) / 0.5))
            return UInt8((t * t * (3 - 2 * t) * 255).rounded())
        }
        let data = Data(bytes: &bytes, count: bytes.count)
        let small = CIImage(bitmapData: data, bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
        let sx = rect.width / CGFloat(width), sy = rect.height / CGFloat(height)
        return small.samplingLinear().transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            .clampedToExtent().cropped(to: rect)
    }

    // MARK: - Finding them

    nonisolated(unsafe) static var model: MLModel?
    nonisolated(unsafe) static var modelFailed = false
    static let lock = NSLock()
    nonisolated(unsafe) static var cache: [String: BodyParts] = [:]
    nonisolated(unsafe) static var cacheOrder: [String] = []
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])

    /// The parts in this photo, from the cache when the same picture was looked at before (a preview redrawn with
    /// other dials). Nil when nobody is found.
    public static func find(in image: CIImage) -> BodyParts? {
        guard let key = fingerprint(image) else { return nil }
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let found = (try? fromModel(image)) ?? fromVision(image)
        found?.features = eyesAndBrows(in: image)
        lock.lock()
        defer { lock.unlock() }
        if let found {
            cache[key] = found
            cacheOrder.append(key)
            if cacheOrder.count > 24 { cache[cacheOrder.removeFirst()] = nil }
        }
        return found
    }

    /// Which picture this is, whatever its size: a 16 x 16 grey thumbnail plus the shape.
    static func fingerprint(_ image: CIImage) -> String? {
        let e = image.extent
        guard e.width >= 16, e.height >= 16, e.width.isFinite else { return nil }
        let small = image.transformed(by: CGAffineTransform(scaleX: 16 / e.width, y: 16 / e.height).translatedBy(x: -e.minX, y: -e.minY))
        var px = [UInt8](repeating: 0, count: 16 * 16 * 4)
        context.render(small, toBitmap: &px, rowBytes: 64, bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBA8, colorSpace: nil)
        // Coarse levels, so a quick decode and a full one of the same photo agree.
        let grey = stride(from: 0, to: px.count, by: 4).map { String(format: "%x", (Int(px[$0]) + Int(px[$0 + 1]) + Int(px[$0 + 2])) / 48) }.joined()
        return "\(Int((e.width / e.height) * 100))|\(grey)"
    }

    /// Switches to the model at `url` (just downloaded): the next photos use it, and parts found without it are
    /// found again.
    public static func use(modelAt url: URL) {
        lock.lock(); defer { lock.unlock() }
        modelURL = url
        model = nil
        modelFailed = false
        cache = [:]
        cacheOrder = []
    }

    static func loadModel() throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let model { return model }
        guard !modelFailed, let url = modelURL else { throw CocoaError(.fileNoSuchFile) }
        do {
            let cfg = MLModelConfiguration()
            // The GPU: as fast as anything here, and ready at once (the Neural Engine takes minutes to prepare it).
            cfg.computeUnits = .cpuAndGPU
            let m = try MLModel(contentsOf: url, configuration: cfg)
            model = m
            return m
        } catch {
            modelFailed = true
            throw error
        }
    }

    static let tileW = 576, tileH = 768, outW = 288, outH = 384

    /// The model over the whole photo, then a closer pass on faces too small there for their lips.
    static func fromModel(_ image: CIImage) throws -> BodyParts {
        let model = try loadModel()
        let e = image.extent
        let s = min(1, CGFloat(tileH) / e.height)
        let (w, h, planes) = try cover(image, scale: s, model: model)
        var details: [(rect: CGRect, width: Int, height: Int, planes: [[Float]])] = []
        for face in faces(in: image) where face.height * e.height * s < 190 {
            // Only with more detail than the pass above had: a small picture enlarged is worse, not better.
            let cropScale = min(1, CGFloat(tileH) / (face.height * 4 * e.height))
            guard cropScale >= 2 * s else { continue }
            // Head and shoulders, in the model's shape, around a face that was under ~190 px tall in the pass above.
            var r = CGRect(x: face.midX - face.height * 1.5 * e.height / e.width, y: face.midY - face.height * 1.6,
                           width: face.height * 3 * e.height / e.width, height: face.height * 4)
            r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard r.width > 0.01, r.height > 0.01 else { continue }
            let crop = image.cropped(to: CGRect(x: e.minX + r.minX * e.width, y: e.minY + (1 - r.maxY) * e.height,
                                                width: r.width * e.width, height: r.height * e.height))
            let (cw, ch, cp) = try cover(crop, scale: cropScale, model: model)
            details.append((r, cw, ch, cp))
            if details.count >= 12 { break }
        }
        return BodyParts(width: w, height: h, planes: planes, details: details, byModel: true)
    }

    /// The image scaled by `scale` (to at most 768 high) under tiles of 576 x 768: one, centred and padded, when it
    /// is narrower; overlapping ones when wider. Returns planes at the model's half resolution over the image.
    static func cover(_ image: CIImage, scale s: CGFloat, model: MLModel) throws -> (Int, Int, [[Float]]) {
        let e = image.extent
        let sw = max(2, Int((e.width * s).rounded())), sh = max(2, min(tileH, Int((e.height * s).rounded())))
        // Rows of padding above the picture in a tile; Core Image counts from the bottom, so it sits at y = bottom.
        let top = (tileH - sh) / 2, bottom = tileH - top - sh
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(sw) / e.width, y: CGFloat(sh) / e.height)))
        let kinds = Kind.allCases.count
        let ow = sw / 2, oh = sh / 2
        var sum = [[Float]](repeating: [Float](repeating: 0, count: ow * oh), count: kinds)
        var weight = [Float](repeating: 0, count: ow * oh)
        // Tile x offsets in scaled pixels (negative: a narrow picture centred in one tile).
        let offsets: [Int]
        if sw <= tileW {
            offsets = [-(tileW - sw) / 2]
        } else {
            let n = Int((Double(sw - tileW) / 450).rounded(.up)) + 1
            offsets = (0..<n).map { Int((Double(sw - tileW) * Double($0) / Double(n - 1)).rounded()) }
        }
        for x0 in offsets {
            let out = try predict(scaled, x: x0, y: bottom, model: model)
            for oy in 0..<outH {
                let gy = oy - top / 2
                guard gy >= 0, gy < oh else { continue }
                for ox in 0..<outW {
                    let gx = x0 / 2 + ox
                    guard gx >= 0, gx < ow else { continue }
                    // Tiles weigh less towards their sides, so the overlaps blend instead of meeting at a seam.
                    let wgt = offsets.count == 1 ? 1 : max(0.02, Float(min(ox, outW - 1 - ox)) / Float(outW / 2))
                    let i = gy * ow + gx, o = oy * outW + ox
                    for k in 0..<kinds { sum[k][i] += out[k][o] * wgt }
                    weight[i] += wgt
                }
            }
        }
        for k in 0..<kinds { for i in 0..<(ow * oh) where weight[i] > 0 { sum[k][i] /= weight[i] } }
        return (ow, oh, sum)
    }

    /// One 576 x 768 tile: the scaled picture moved left by `x` and up by `y` (outside it: grey). Planes 288 x 384,
    /// rows from the top.
    static func predict(_ scaled: CIImage, x: Int, y: Int, model: MLModel) throws -> [[Float]] {
        let tile = scaled.transformed(by: CGAffineTransform(translationX: CGFloat(-x), y: CGFloat(y)))
            .composited(over: CIImage(color: CIColor(red: 0.47, green: 0.46, blue: 0.4)))
        var px = [UInt8](repeating: 0, count: tileW * tileH * 4)
        // Rendered rows run from the top, as the model wants them.
        context.render(tile, toBitmap: &px, rowBytes: tileW * 4, bounds: CGRect(x: 0, y: 0, width: tileW, height: tileH),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let plane = tileW * tileH
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: tileH), NSNumber(value: tileW)], dataType: .float32)
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        px.withUnsafeBufferPointer { src in
            // Every 4th byte from R, G and B into its plane, as floats.
            for c in 0..<3 {
                vDSP_vfltu8(src.baseAddress! + c, 4, ptr + c * plane, 1, vDSP_Length(plane))
            }
        }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let masks = result.featureValue(for: "masks")?.multiArrayValue else { throw CocoaError(.coderReadCorrupt) }
        let n = outW * outH
        let st = masks.strides.map(\.intValue)
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: Kind.allCases.count)
        for k in 0..<out.count {
            out[k].withUnsafeMutableBufferPointer { dst in
                for row in 0..<outH {
                    let at = k * st[1] + row * st[2]
                    switch masks.dataType {
                    case .float16:
                        let p = masks.dataPointer.bindMemory(to: Float16.self, capacity: masks.count)
                        for col in 0..<outW { dst[row * outW + col] = Float(p[at + col * st[3]]) }
                    default:
                        let p = masks.dataPointer.bindMemory(to: Float.self, capacity: masks.count)
                        if st[3] == 1 {
                            (dst.baseAddress! + row * outW).update(from: p + at, count: outW)
                        } else {
                            for col in 0..<outW { dst[row * outW + col] = p[at + col * st[3]] }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Every face's eyes and brows (normalized, top-left origin), from Apple Vision's face landmarks.
    static func eyesAndBrows(in image: CIImage) -> [[CGPoint]] {
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(ciImage: image).perform([req])
        var out: [[CGPoint]] = []
        for f in req.results ?? [] {
            guard let lm = f.landmarks else { continue }
            for region in [lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow] {
                guard let region else { continue }
                // Landmark points are in the face box, bottom-left origin.
                out.append(region.normalizedPoints.map { p in
                    CGPoint(x: f.boundingBox.minX + p.x * f.boundingBox.width, y: 1 - (f.boundingBox.minY + p.y * f.boundingBox.height))
                })
            }
        }
        return out
    }

    /// Faces (normalized, top-left origin), biggest first.
    static func faces(in image: CIImage) -> [CGRect] {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: image).perform([req])
        return (req.results ?? []).map { o in
            CGRect(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY, width: o.boundingBox.width, height: o.boundingBox.height)
        }.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    // MARK: - Without the model

    /// Apple Vision's view: the people (person mask), their faces' outlines (face skin without eyes, brows and mouth;
    /// lips), and body skin as the person where the colour is the faces' skin colour; clothes are the rest of the person.
    static func fromVision(_ image: CIImage) -> BodyParts? {
        let e = image.extent
        let w = 384, h = max(1, Int((CGFloat(w) * e.height / e.width).rounded()))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // Person mask.
        let personReq = VNGeneratePersonSegmentationRequest()
        personReq.qualityLevel = .accurate
        let landmarks = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(ciImage: image).perform([personReq, landmarks])
        guard let buffer = personReq.results?.first?.pixelBuffer else { return nil }
        let person = sample(buffer, width: w, height: h)
        // Face and lips outlines, drawn at mask size.
        let faceObs = landmarks.results ?? []
        guard let faceCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let lipCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        func path(_ region: VNFaceLandmarkRegion2D?, _ face: VNFaceObservation) -> CGPath? {
            guard let pts = region?.pointsInImage(imageSize: CGSize(width: w, height: h)), pts.count > 2 else { return nil }
            let p = CGMutablePath()
            p.addLines(between: pts)
            p.closeSubpath()
            return p
        }
        for f in faceObs {
            guard let lm = f.landmarks else { continue }
            // The face: its box as an ellipse (Vision's contour stops at the brows), less eyes, brows and mouth.
            let b = f.boundingBox
            faceCtx.setFillColor(gray: 1, alpha: 1)
            faceCtx.fillEllipse(in: CGRect(x: b.minX * CGFloat(w), y: b.minY * CGFloat(h) - b.height * CGFloat(h) * 0.05,
                                           width: b.width * CGFloat(w), height: b.height * CGFloat(h) * 1.15))
            faceCtx.setFillColor(gray: 0, alpha: 1)
            for r in [lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow, lm.outerLips] { if let p = path(r, f) { faceCtx.addPath(p); faceCtx.fillPath() } }
            lipCtx.setFillColor(gray: 1, alpha: 1)
            if let p = path(lm.outerLips, f) { lipCtx.addPath(p); lipCtx.fillPath() }
            lipCtx.setFillColor(gray: 0, alpha: 1)
            if let p = path(lm.innerLips, f) { lipCtx.addPath(p); lipCtx.fillPath() }
        }
        // A bitmap context's memory runs from the top row, like the planes.
        func plane(_ ctx: CGContext) -> [Float] {
            let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
            return (0..<(w * h)).map { i in Float(p[i]) / 255 }
        }
        let faceArea = plane(faceCtx), lips = plane(lipCtx)
        // The faces' skin colour (chroma), to find the rest of the skin.
        var cb = 0.0, cr = 0.0, n = 0.0
        func chroma(_ i: Int) -> (Double, Double) {
            let p = i * 4
            let r = Double(px[p]), g = Double(px[p + 1]), b = Double(px[p + 2])
            return (-0.169 * r - 0.331 * g + 0.5 * b, 0.5 * r - 0.419 * g - 0.081 * b)
        }
        for i in 0..<(w * h) where faceArea[i] > 0.5 && lips[i] < 0.5 {
            let c = chroma(i)
            cb += c.0; cr += c.1; n += 1
        }
        let skinColour: (Double, Double)? = n > 20 ? (cb / n, cr / n) : nil
        var faceSkin = [Float](repeating: 0, count: w * h), bodySkin = faceSkin, clothes = faceSkin, hair = faceSkin
        for i in 0..<(w * h) {
            let inPerson = person[i]
            let c = chroma(i)
            let near: Float
            if let s = skinColour {
                let d = ((c.0 - s.0) * (c.0 - s.0) + (c.1 - s.1) * (c.1 - s.1)).squareRoot()
                near = Float(max(0, min(1, (22 - d) / 10)))
            } else {
                // No face to learn from: a broad skin range.
                near = (c.1 > 8 && c.1 < 45 && c.0 > -40 && c.0 < 5) ? 1 : 0
            }
            faceSkin[i] = faceArea[i] * max(near, 0.5) * max(inPerson, faceArea[i])
            let skin = inPerson * near * (1 - faceArea[i]) * (1 - lips[i])
            bodySkin[i] = skin
            clothes[i] = max(0, inPerson - skin - faceArea[i] - lips[i])
        }
        return BodyParts(width: w, height: h, planes: [faceSkin, bodySkin, lips, clothes, hair], byModel: false)
    }

    /// A one-channel Vision mask resampled to w x h, rows from the top, 0…1.
    static func sample(_ buffer: CVPixelBuffer, width w: Int, height h: Int) -> [Float] {
        let ci = CIImage(cvPixelBuffer: buffer)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ci.extent.width, y: CGFloat(h) / ci.extent.height))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
        return (0..<(w * h)).map { i in Float(px[i * 4]) / 255 }
    }
}
