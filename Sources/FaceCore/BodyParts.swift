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
    var details: [(rect: CGRect, width: Int, height: Int, planes: [[Float]])]
    /// Found by the model (else by Vision).
    public let byModel: Bool
    /// Eyes and brows (outlines, normalized, top-left origin): their hairs (and the eyes) are kept out of face skin
    /// when it is refined, so smoothing it leaves lashes and brows sharp while the skin around them is retouched.
    var features: [(outline: [CGPoint], brow: Bool)] = []
    /// Parts found again for the faces the model missed (heavy make-up or a smoothed, doll-like photo can leave a
    /// face and its neck empty), each laid over these around its `regions` (normalized, top-left origin): the model's
    /// again with the photo smaller, in place of these (`replace`); Apple Vision's face and body skin and lips,
    /// wherever they find more.
    var fallbacks: [(parts: BodyParts, regions: [CGRect], replace: Bool)] = []
    /// The masks fitted to the photo's own edges (`refine`): the whole photo first, then the faces' closer looks,
    /// each over its rect (normalized, top-left origin) at width x height, with one byte plane (rows from the top)
    /// per kind the editor changes (face skin, body skin, lips, clothes), kept only over the box where it isn't empty. Empty: drawn from the planes as found.
    var layers: [(rect: CGRect, width: Int, height: Int, planes: [Kind: (box: CGRect, bytes: [UInt8])])] = []

    init(width: Int, height: Int, planes: [[Float]], details: [(rect: CGRect, width: Int, height: Int, planes: [[Float]])] = [], byModel: Bool) {
        self.width = width; self.height = height; self.planes = planes; self.details = details; self.byModel = byModel
    }

    /// The share of the photo a kind covers (for tests and logs).
    public func coverage(_ kind: Kind) -> Double { planes[kind.rawValue].reduce(0) { $0 + Double($1) } / Double(max(1, width * height)) }

    // MARK: - Masks for drawing

    /// A kind's mask over a photo of `extent` (Core Image: bottom-left origin), white where the part is, with the
    /// faces' closer looks laid over it.
    public func mask(_ kind: Kind, extent: CGRect) -> CIImage {
        guard let first = layers.first, first.planes[kind] != nil else { return coarse(kind, extent: extent) }
        var out: CIImage?
        for l in layers {
            guard let p = l.planes[kind] else { continue }
            let r = Self.place(l.rect, in: extent)
            let patch = Self.image(bytes: p.bytes, box: p.box, width: l.width, height: l.height, into: r)
            out = out.map { Self.overlay(patch, over: $0, rect: r) } ?? patch
        }
        return (out ?? coarse(kind, extent: extent)).cropped(to: extent)
    }

    /// A kind's mask as the model (or Vision) gave it, faces' closer looks included: soft and coarse at its edges.
    func coarse(_ kind: Kind, extent: CGRect) -> CIImage {
        var out = Self.image(planes[kind.rawValue], width: width, height: height, into: extent)
        for d in details {
            let r = Self.place(d.rect, in: extent)
            out = Self.overlay(Self.image(d.planes[kind.rawValue], width: d.width, height: d.height, into: r), over: out, rect: r)
        }
        for fb in fallbacks where fb.replace || [.faceSkin, .bodySkin, .lips].contains(kind) {
            // Only around the missed faces, soft-edged.
            var around = CIImage(color: .black).cropped(to: extent)
            for n in fb.regions {
                let r = Self.place(n, in: extent)
                around = CIImage(color: .white).cropped(to: r).applyingGaussianBlur(sigma: Double(min(r.width, r.height)) * 0.08)
                    .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: around])
            }
            let other = fb.parts.coarse(kind, extent: extent)
            out = fb.replace
                ? other.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: around])
                : other.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: around])
                    .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: out])
        }
        return out.cropped(to: extent)
    }

    /// A top-left normalized rect as a Core Image rect in `extent`.
    static func place(_ n: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + n.minX * extent.width, y: extent.minY + (1 - n.maxY) * extent.height,
               width: n.width * extent.width, height: n.height * extent.height)
    }

    /// A closer look over the mask under it, faded in from its edges, so no seam shows where it ends.
    static func overlay(_ patch: CIImage, over base: CIImage, rect r: CGRect) -> CIImage {
        let fade = CIImage(color: .white).cropped(to: r.insetBy(dx: r.width * 0.12, dy: r.height * 0.12))
            .applyingGaussianBlur(sigma: Double(min(r.width, r.height)) * 0.06).cropped(to: r)
        return patch.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: fade])
    }

    /// A refined plane (bytes over `box`, in a width x height layer, rows from the top) stretched over `rect`;
    /// black in the rest of it.
    static func image(bytes: [UInt8], box: CGRect, width: Int, height: Int, into rect: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: rect)
        guard box.width > 0, box.height > 0 else { return black }
        var bytes = bytes
        let data = Data(bytes: &bytes, count: bytes.count)
        let small = CIImage(bitmapData: data, bytesPerRow: Int(box.width), size: box.size, format: .L8, colorSpace: nil)
        let sx = rect.width / CGFloat(width), sy = rect.height / CGFloat(height)
        // The box counts rows from the top; Core Image from the bottom.
        let at = CGPoint(x: rect.minX + box.minX * sx, y: rect.minY + (CGFloat(height) - box.maxY) * sy)
        // Its border pixels are (all but) empty, so stretched without clamping nothing leaks past them.
        let patch = small.samplingLinear().transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: at.x, y: at.y)))
        return patch.composited(over: black).cropped(to: rect)
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
    /// other dials). Nil when nobody is found. `key`: which picture this is, when the caller knows (its file and how
    /// it is turned), so the same one at another size (the preview zoomed in, from a bigger decode) is not looked at
    /// again: the parts are kept in the picture's own proportions, whatever its size, and pixels alone can't tell
    /// it apart from the next shot of a burst at one size and from itself at another.
    public static func find(in image: CIImage, key given: String? = nil) -> BodyParts? {
        guard let key = given.map({ "file|\($0)" }) ?? fingerprint(image) else { return nil }
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let found = (try? fromModel(image)) ?? fromVision(image)
        if let found, found.byModel { found.fillMissedFaces(in: image) }
        found?.features = eyesAndBrows(in: image)
        found?.refine(with: image)
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
    static let predicting = NSLock()

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
        // One prediction at a time: Core ML aborted the app (a Metal assertion) when two exports' photos ran the
        // model at once. The GPU runs one anyway; the result is read out before the next may start.
        predicting.lock()
        defer { predicting.unlock() }
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
    static func eyesAndBrows(in image: CIImage) -> [(outline: [CGPoint], brow: Bool)] {
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(ciImage: image).perform([req])
        var out: [(outline: [CGPoint], brow: Bool)] = []
        for f in req.results ?? [] {
            guard let lm = f.landmarks else { continue }
            for (region, brow) in [(lm.leftEye, false), (lm.rightEye, false), (lm.leftEyebrow, true), (lm.rightEyebrow, true)] {
                guard let region else { continue }
                // Landmark points are in the face box, bottom-left origin.
                out.append((region.normalizedPoints.map { p in
                    CGPoint(x: f.boundingBox.minX + p.x * f.boundingBox.width, y: 1 - (f.boundingBox.minY + p.y * f.boundingBox.height))
                }, brow))
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

    /// Faces the model left (mostly) without face skin are looked at again (`fallbacks`), with the neck and
    /// shoulders below: by the model with the photo smaller (it can miss a face at one size and find it at
    /// another), and those still missed by Vision. Their closer looks, missed too, are dropped.
    func fillMissedFaces(in image: CIImage) {
        let faces = Self.faces(in: image)
        var missed = missed(faces)
        guard !missed.isEmpty else { return }
        details.removeAll { d in missed.contains { d.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) } }
        func around(_ f: CGRect) -> CGRect {
            CGRect(x: f.minX - f.width * 0.6, y: f.minY - f.height * 0.3, width: f.width * 2.2, height: f.height * 3.3)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if let model = try? Self.loadModel(),
           let (w, h, planes) = try? Self.cover(image, scale: min(1, CGFloat(Self.tileH) / image.extent.height) * 0.6, model: model) {
            let again = BodyParts(width: w, height: h, planes: planes, byModel: true)
            let still = again.missed(missed)
            let found = missed.filter { !still.contains($0) }
            if !found.isEmpty { fallbacks.append((again, found.map(around), true)) }
            missed = still
        }
        if !missed.isEmpty, let vision = Self.fromVision(image) { fallbacks.append((vision, missed.map(around), false)) }
    }

    /// The faces (normalized, top-left origin) these parts leave (mostly) without face skin.
    func missed(_ faces: [CGRect]) -> [CGRect] {
        guard !faces.isEmpty else { return [] }
        // Face skin, small: enough to tell a face found from one missed. Rows from the top.
        let k = 512 / CGFloat(max(width, height))
        let w = max(1, Int(CGFloat(width) * k)), h = max(1, Int(CGFloat(height) * k))
        var p = [Float](repeating: 0, count: w * h)
        Self.context.render(coarse(.faceSkin, extent: CGRect(x: 0, y: 0, width: w, height: h)), toBitmap: &p, rowBytes: w * 4,
                            bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Lf, colorSpace: nil)
        // The mean over a part of a face's box (fractions of it).
        func mean(_ f: CGRect, _ xs: (CGFloat, CGFloat), _ ys: (CGFloat, CGFloat)) -> Float? {
            let x0 = Int((f.minX + f.width * xs.0) * CGFloat(w)), x1 = Int((f.minX + f.width * xs.1) * CGFloat(w))
            let y0 = Int((f.minY + f.height * ys.0) * CGFloat(h)), y1 = Int((f.minY + f.height * ys.1) * CGFloat(h))
            var sum: Float = 0, n: Float = 0
            for y in max(0, y0)...max(0, min(h - 1, y1)) { for x in max(0, x0)...max(0, min(w - 1, x1)) { sum += p[y * w + x]; n += 1 } }
            return n >= 2 ? sum / n : nil
        }
        return faces.filter { f in
            // Its cheeks and its chin: skin when the face is found (the far cheek at least half, turned away); a
            // missed face may still have its nose or the skin under its eyes, or lose only its jaw.
            guard let left = mean(f, (0.15, 0.35), (0.5, 0.75)), let right = mean(f, (0.65, 0.85), (0.5, 0.75)) else { return false }
            let chin = mean(f, (0.35, 0.65), (0.88, 0.98)) ?? 1
            return (left + right) / 2 < 0.5 || chin < 0.5
        }
    }

    // MARK: - Fitting them to the photo

    /// Fits the masks to the photo (`layers`): the model sees the photo small, so its edges are a few of the photo's
    /// pixels off and spill onto hair and background. Each is redrawn, in more detail than the model had: along its
    /// edge each pixel goes with the side whose colour it has, then a guided filter mattes it onto the photo's own
    /// edges; then the eyes, lashes and brow hairs are taken out of face skin, leaving the skin between and around
    /// them in.
    func refine(with image: CIImage) {
        let e = image.extent
        guard e.width >= 16, e.height >= 16 else { return }
        // The whole photo at 2048 on the long side, then each closer look at twice its own detail (never more than
        // the photo has).
        let s = min(1, 2048 / max(e.width, e.height))
        var regions: [(rect: CGRect, scale: CGFloat, step: Double, detail: Int?)] = [(CGRect(x: 0, y: 0, width: 1, height: 1), s, Double(e.height * s) / Double(height), nil)]
        for (i, d) in details.enumerated() {
            let ds = min(1, CGFloat(d.width) * 2 / (d.rect.width * e.width))
            regions.append((d.rect, ds, Double(d.rect.height * e.height * ds) / Double(d.height), i))
        }
        var out: [(rect: CGRect, width: Int, height: Int, planes: [Kind: (box: CGRect, bytes: [UInt8])])] = []
        for region in regions {
            let px = Self.place(region.rect, in: e)
            let gw = max(4, Int((px.width * region.scale).rounded())), gh = max(4, Int((px.height * region.scale).rounded()))
            let layerRect = CGRect(x: 0, y: 0, width: gw, height: gh)
            // The photo there, as the guide: r, g, b planes 0…1, rows from the top.
            let guideImage = image.cropped(to: px).transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY)
                .concatenating(CGAffineTransform(scaleX: CGFloat(gw) / px.width, y: CGFloat(gh) / px.height)))
            var rgba = [UInt8](repeating: 0, count: gw * gh * 4)
            Self.context.render(guideImage.clampedToExtent(), toBitmap: &rgba, rowBytes: gw * 4, bounds: layerRect, format: .RGBA8,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let guide = (0..<3).map { c in (0..<(gw * gh)).map { Float(rgba[$0 * 4 + c]) / 255 } }
            // About two and a half of the model's pixels either way: as far as its edges are off.
            let radius = max(2, Int((region.step * 2.5).rounded()))
            // This region's features, in its pixels.
            let feats = features.map { f in
                (f.outline.map { CGPoint(x: ($0.x - region.rect.minX) / region.rect.width * CGFloat(gw),
                                         y: ($0.y - region.rect.minY) / region.rect.height * CGFloat(gh)) }, f.brow)
            }.filter { f in f.0.contains { layerRect.insetBy(dx: -20, dy: -20).contains($0) } }
            func found(_ kind: Kind) -> [Float] {
                let coarse = region.detail.map { Self.image(details[$0].planes[kind.rawValue], width: details[$0].width, height: details[$0].height, into: layerRect) }
                    ?? self.coarse(kind, extent: layerRect)
                var p = [Float](repeating: 0, count: gw * gh)
                Self.context.render(coarse, toBitmap: &p, rowBytes: gw * 4, bounds: layerRect, format: .Lf, colorSpace: nil)
                return p
            }
            // Decided by colour along the edge, then matted onto the photo's edges (a strand of hair, a soft jaw) in a
            // smaller window; what is left faint on either side (a glow over hair or a collar, a dip on skin) is
            // pushed to none or all.
            func fitted(_ p: [Float]) -> [Float] {
                var q = Self.snap(guide: guide, input: p, width: gw, height: gh, radius: radius)
                q = Self.guidedFilter(guide: guide, input: q, width: gw, height: gh, radius: max(2, radius / 2), eps: 0.001)
                for i in q.indices { let t = max(0, min(1, (q[i] - 0.12) / 0.76)); q[i] = t * t * (3 - 2 * t) }
                return q
            }
            var planes: [Kind: (box: CGRect, bytes: [UInt8])] = [:]
            let done = NSLock()
            // Skin, lips and clothes side by side.
            DispatchQueue.concurrentPerform(iterations: 3) { job in
                var fit: [Kind: (box: CGRect, bytes: [UInt8])] = [:]
                if job == 0 {
                    // Face and body skin meet on skin (neck and chest): fitted as one, so no seam opens between them,
                    // then shared out as the model has them, each taking all of the skin where it has at least half
                    // of it (so the two together, as the retouch takes them, are the whole skin).
                    let face = found(.faceSkin), body = found(.bodySkin)
                    let skin = fitted(zip(face, body).map { min(1, $0 + $1) })
                    let share = Self.boxMean(zip(face, body).map { $0 + $1 > 0.02 ? $0 / ($0 + $1) : 0 }, width: gw, height: gh, radius: max(1, radius / 2))
                    var faceSkin = zip(skin, share).map { $0 * min(1, 2 * $1) }
                    Self.cutFeatures(feats, from: &faceSkin, guide: guide, width: gw, height: gh)
                    fit[.faceSkin] = Self.packed(faceSkin, width: gw, height: gh)
                    fit[.bodySkin] = Self.packed(zip(skin, share).map { $0 * min(1, 2 * (1 - $1)) }, width: gw, height: gh)
                } else {
                    let kind: Kind = job == 1 ? .lips : .clothes
                    fit[kind] = Self.packed(fitted(found(kind)), width: gw, height: gh)
                }
                done.lock(); planes.merge(fit) { a, _ in a }; done.unlock()
            }
            out.append((region.rect, gw, gh, planes))
        }
        layers = out
    }

    /// A plane as bytes, kept only over the box where it isn't empty (and a pixel around it).
    static func packed(_ q: [Float], width w: Int, height h: Int) -> (box: CGRect, bytes: [UInt8]) {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where q[y * w + x] > 0.004 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 >= 0 else { return (.zero, []) }
        x0 = max(0, x0 - 1); y0 = max(0, y0 - 1); x1 = min(w - 1, x1 + 1); y1 = min(h - 1, y1 + 1)
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var bytes = [UInt8](repeating: 0, count: bw * bh)
        for y in 0..<bh { for x in 0..<bw { bytes[y * bw + x] = UInt8((max(0, min(1, q[(y0 + y) * w + x0 + x])) * 255).rounded()) } }
        return (CGRect(x: x0, y: y0, width: bw, height: bh), bytes)
    }

    /// Along a mask's edge (within `radius` of it, where the model may be wrong), each pixel goes with the side whose
    /// colour it is nearer: the colours of what is surely in and surely out, nearby. Where the two sides look alike
    /// (skin against a skin-coloured wall), the mask is left as it was.
    static func snap(guide: [[Float]], input p: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where p[y * w + x] > 0.004 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        var out = p
        guard x1 >= 0 else { return out }
        x0 = max(0, x0 - 3 * r); y0 = max(0, y0 - 3 * r); x1 = min(w - 1, x1 + 3 * r); y1 = min(h - 1, y1 + 3 * r)
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1, n = bw * bh
        func crop(_ a: [Float]) -> [Float] {
            var c = [Float](repeating: 0, count: n)
            for y in 0..<bh { for x in 0..<bw { c[y * bw + x] = a[(y0 + y) * w + x0 + x] } }
            return c
        }
        let I = guide.map(crop), P = crop(p)
        // Surely in: all in, as far as the model can be off; surely out, likewise.
        let near = boxMean(P, width: bw, height: bh, radius: r)
        let sureIn = near.map { $0 > 0.97 ? Float(1) : 0 }, sureOut = near.map { $0 < 0.03 ? Float(1) : 0 }
        // Their colours nearby (in a wider window, so both sides are in it).
        func colours(_ core: [Float]) -> (count: [Float], rgb: [[Float]]) {
            (boxMean(core, width: bw, height: bh, radius: 2 * r),
             I.map { c in boxMean(zip(c, core).map { $0 * $1 }, width: bw, height: bh, radius: 2 * r) })
        }
        let inside = colours(sureIn), outside = colours(sureOut)
        for y in 0..<bh {
            for x in 0..<bw {
                let i = y * bw + x
                guard sureIn[i] == 0, sureOut[i] == 0, inside.count[i] > 0.02, outside.count[i] > 0.02 else { continue }
                var dIn: Float = 0, dOut: Float = 0, apart: Float = 0
                for c in 0..<3 {
                    let a = inside.rgb[c][i] / inside.count[i], b = outside.rgb[c][i] / outside.count[i], v = I[c][i]
                    dIn += (v - a) * (v - a); dOut += (v - b) * (v - b); apart += (a - b) * (a - b)
                }
                // In by how much nearer it is to the inside's colour; trusted as far as the two sides differ.
                let t = dOut / (dIn + dOut + 1e-6)
                let trust = max(0, min(1, (apart - 0.003) / 0.017))
                out[(y0 + y) * w + x0 + x] = trust * t + (1 - trust) * P[i]
            }
        }
        return out
    }

    /// He, Sun and Tang's guided filter with a colour guide: in every window the mask is fitted as a linear mix of
    /// the photo's r, g and b, so where the photo has an edge (skin against hair or background) the mask's edge
    /// moves onto it, and where it has none the mask stays smooth. `eps` is how much colour change counts as an
    /// edge (as a variance, colours 0…1). Worked out only over the box the mask reaches (and a window around it).
    static func guidedFilter(guide: [[Float]], input p: [Float], width w: Int, height h: Int, radius r: Int, eps: Float) -> [Float] {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where p[y * w + x] > 0.004 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        var out = [Float](repeating: 0, count: w * h)
        guard x1 >= 0 else { return out }
        x0 = max(0, x0 - 2 * r); y0 = max(0, y0 - 2 * r); x1 = min(w - 1, x1 + 2 * r); y1 = min(h - 1, y1 + 2 * r)
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1, n = bw * bh
        func crop(_ a: [Float]) -> [Float] {
            var c = [Float](repeating: 0, count: n)
            for y in 0..<bh { for x in 0..<bw { c[y * bw + x] = a[(y0 + y) * w + x0 + x] } }
            return c
        }
        let I = guide.map(crop), P = crop(p)
        func mean(_ a: [Float]) -> [Float] { boxMean(a, width: bw, height: bh, radius: r) }
        func product(_ a: [Float], _ b: [Float]) -> [Float] { var c = [Float](repeating: 0, count: n); vDSP_vmul(a, 1, b, 1, &c, 1, vDSP_Length(n)); return c }
        let mI = I.map(mean), mP = mean(P)
        let mIP = I.map { mean(product($0, P)) }
        // Second moments of the guide: rr, rg, rb, gg, gb, bb.
        let pairs = [(0, 0), (0, 1), (0, 2), (1, 1), (1, 2), (2, 2)]
        let mII = pairs.map { mean(product(I[$0.0], I[$0.1])) }
        var a = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3), b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let mr = mI[0][i], mg = mI[1][i], mb = mI[2][i], mp = mP[i]
            // Covariance of the guide (plus eps) and of guide with mask.
            let srr = mII[0][i] - mr * mr + eps, srg = mII[1][i] - mr * mg, srb = mII[2][i] - mr * mb
            let sgg = mII[3][i] - mg * mg + eps, sgb = mII[4][i] - mg * mb, sbb = mII[5][i] - mb * mb + eps
            let cr = mIP[0][i] - mr * mp, cg = mIP[1][i] - mg * mp, cb = mIP[2][i] - mb * mp
            // The 3 x 3 inverse by cofactors.
            let c00 = sgg * sbb - sgb * sgb, c01 = srb * sgb - srg * sbb, c02 = srg * sgb - srb * sgg
            let c11 = srr * sbb - srb * srb, c12 = srb * srg - srr * sgb, c22 = srr * sgg - srg * srg
            let det = srr * c00 + srg * c01 + srb * c02
            guard abs(det) > 1e-12 else { b[i] = mp; continue }
            let ar = (c00 * cr + c01 * cg + c02 * cb) / det
            let ag = (c01 * cr + c11 * cg + c12 * cb) / det
            let ab = (c02 * cr + c12 * cg + c22 * cb) / det
            a[0][i] = ar; a[1][i] = ag; a[2][i] = ab
            b[i] = mp - ar * mr - ag * mg - ab * mb
        }
        let ma = a.map(mean), mb = mean(b)
        for y in 0..<bh {
            for x in 0..<bw {
                let i = y * bw + x
                let q = ma[0][i] * I[0][i] + ma[1][i] * I[1][i] + ma[2][i] * I[2][i] + mb[i]
                out[(y0 + y) * w + x0 + x] = max(0, min(1, q))
            }
        }
        return out
    }

    /// The mean over a (2r+1)-square window around each pixel (fewer at the borders), by running sums.
    static func boxMean(_ a: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var rows = [Float](repeating: 0, count: w * h), out = rows
        a.withUnsafeBufferPointer { src in
            rows.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let o = y * w
                    var sum: Float = 0
                    for x in 0...min(r, w - 1) { sum += src[o + x] }
                    for x in 0..<w {
                        let lo = max(0, x - r), hi = min(w - 1, x + r)
                        dst[o + x] = sum / Float(hi - lo + 1)
                        if x + r + 1 < w { sum += src[o + x + r + 1] }
                        if x - r >= 0 { sum -= src[o + x - r] }
                    }
                }
            }
        }
        rows.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var sum = [Float](repeating: 0, count: w)
                for y in 0...min(r, h - 1) { for x in 0..<w { sum[x] += src[y * w + x] } }
                for y in 0..<h {
                    let lo = max(0, y - r), hi = min(h - 1, y + r), k = 1 / Float(hi - lo + 1)
                    for x in 0..<w { dst[y * w + x] = sum[x] * k }
                    if y + r + 1 < h { for x in 0..<w { sum[x] += src[(y + r + 1) * w + x] } }
                    if y - r >= 0 { for x in 0..<w { sum[x] -= src[(y - r) * w + x] } }
                }
            }
        }
        return out
    }

    /// Eyes, lashes and brow hairs out of a face-skin plane (features in its pixels, top-left origin). The eyes
    /// themselves go by their outlines; around them and over the brows, only what is clearly darker than the skin
    /// nearby (hairs, lashes, liner) goes, so the skin between and around the hairs is still retouched, and an
    /// outline a little off costs nothing.
    static func cutFeatures(_ feats: [([CGPoint], Bool)], from q: inout [Float], guide: [[Float]], width w: Int, height h: Int) {
        guard !feats.isEmpty else { return }
        // The eyes, a touch beyond their outlines, soft-edged.
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(gray: 0, alpha: 1); ctx.setStrokeColor(gray: 0, alpha: 1); ctx.setLineJoin(.round)
            for (outline, brow) in feats where !brow && outline.count > 2 {
                // The context counts rows from the bottom.
                let pts = outline.map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) }
                let xs = pts.map(\.x)
                ctx.setLineWidth(max(1.5, (xs.max()! - xs.min()!) * 0.08))
                ctx.addLines(between: pts); ctx.closePath()
                ctx.drawPath(using: .fillStroke)
            }
            let holes = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
            var eyes = (0..<(w * h)).map { Float(holes[$0]) / 255 }
            eyes = boxMean(boxMean(eyes, width: w, height: h, radius: 1), width: w, height: h, radius: 1)
            for i in 0..<(w * h) { q[i] *= eyes[i] }
        }
        func luma(_ i: Int) -> Float { 0.299 * guide[0][i] + 0.587 * guide[1][i] + 0.114 * guide[2][i] }
        for (outline, brow) in feats where outline.count > 1 {
            let xs = outline.map(\.x), ys = outline.map(\.y)
            let fw = max(2, xs.max()! - xs.min()!), fh = ys.max()! - ys.min()!
            // An ellipse around it: brows reach further up and down (their outline may sit off the hairs), eyes take
            // in their lashes and liner.
            let c = CGPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2)
            let rx = fw * (brow ? 0.62 : 0.68), ry = fh / 2 + fw * (brow ? 0.22 : 0.2)
            let bx0 = max(0, Int(c.x - rx)), bx1 = min(w - 1, Int(c.x + rx)), by0 = max(0, Int(c.y - ry)), by1 = min(h - 1, Int(c.y + ry))
            guard bx1 > bx0, by1 > by0 else { continue }
            func weight(_ x: Int, _ y: Int) -> Float {
                let dx = (CGFloat(x) - c.x) / rx, dy = (CGFloat(y) - c.y) / ry
                let d = Float((dx * dx + dy * dy).squareRoot())
                // Full inside 70% of the way out, none at the ellipse.
                let t = max(0, min(1, (1 - d) / 0.3))
                return t * t * (3 - 2 * t)
            }
            // The skin's lightness there: the lighter part of what is still skin (hairs are the darker part).
            var skin: [Float] = []
            for y in by0...by1 { for x in bx0...bx1 where weight(x, y) > 0 && q[y * w + x] > 0.5 { skin.append(luma(y * w + x)) } }
            guard skin.count >= 8 else { continue }
            skin.sort()
            let ref = max(0.05, skin[Int(Float(skin.count - 1) * 0.7)])
            for y in by0...by1 {
                for x in bx0...bx1 {
                    let wgt = weight(x, y)
                    guard wgt > 0 else { continue }
                    let i = y * w + x
                    // How much darker than the skin: under 18% is shading (or dark circles, which want retouching);
                    // past 38%, hair.
                    let t = max(0, min(1, ((ref - luma(i)) / ref - 0.18) / 0.2))
                    q[i] *= 1 - wgt * t * t * (3 - 2 * t)
                }
            }
        }
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
            // Hair over the face (its colour far from the skin's) is left out; refining fits the edge to it.
            faceSkin[i] = faceArea[i] * max(near, 0.1) * max(inPerson, faceArea[i])
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
