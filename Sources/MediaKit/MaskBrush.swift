import CoreGraphics
import CoreImage
import Foundation

/// A stroke painted by hand on one part's mask (see Retouch.Part) of one photo: it adds to the mask or takes away
/// from it. Kept with the photo's own edits (CropPlacements), each part's strokes apart.
public struct MaskStroke: Codable, Sendable, Hashable {
    /// Along the stroke: normalized, top-left origin, in the photo as shot (upright, before its own turns and
    /// levelling), so a stroke stays where it was painted whatever the photo is turned or levelled by later.
    public var points: [CGPoint]
    /// The brush's radius, as a share of the photo's short side.
    public var radius: Double
    /// The brush's edge: 0 hard, 1 fading out from the centre.
    public var softness: Double
    /// Takes away from the mask instead of adding to it.
    public var erase: Bool

    public init(points: [CGPoint], radius: Double, softness: Double, erase: Bool) {
        // Rounded, so a photo with many strokes keeps a small record.
        self.points = points.map { CGPoint(x: ($0.x * 10000).rounded() / 10000, y: ($0.y * 10000).rounded() / 10000) }
        self.radius = radius
        self.softness = softness
        self.erase = erase
    }
}

public enum MaskBrush {
    // MARK: - Where a stroke goes

    /// The strokes placed in the picture the masks are found on: the photo turned and flipped by `look`, then (as in
    /// the editor's preview) levelled by `degrees`, `size` being its size before levelling.
    public static func place(_ strokes: [MaskStroke], look: Adjustments, levelled degrees: Double? = nil, size: CGSize = .zero) -> [MaskStroke] {
        strokes.map { s in
            var s = s
            s.points = s.points.map { p in
                let o = turned(p, look)
                guard let degrees, abs(degrees) >= 0.01, size.width > 0, size.height > 0 else { return o }
                return level(o, degrees: degrees, size: size)
            }
            if let degrees, abs(degrees) >= 0.01, size.width > 0 { s.radius /= EditPipeline.rotatedScale(size, degrees: degrees) }
            return s
        }
    }

    /// Back from that picture to the photo as shot: for strokes painted on the preview.
    public static func unplace(_ p: CGPoint, look: Adjustments, levelled degrees: Double? = nil, size: CGSize = .zero) -> CGPoint {
        var o = p
        if let degrees, abs(degrees) >= 0.01, size.width > 0, size.height > 0 { o = unlevel(o, degrees: degrees, size: size) }
        return unturned(o, look)
    }

    /// As `Adjustments.map` for a point: flipped, then turned a quarter clockwise at a time.
    static func turned(_ p: CGPoint, _ a: Adjustments) -> CGPoint { a.map(CGRect(origin: p, size: .zero)).origin }

    static func unturned(_ p: CGPoint, _ a: Adjustments) -> CGPoint {
        var x = p.x, y = p.y
        for _ in 0..<((a.turns % 4 + 4) % 4) { (x, y) = (y, 1 - x) }  // a quarter turn anticlockwise
        if a.flipVertical { y = 1 - y }
        if a.flipHorizontal { x = 1 - x }
        return CGPoint(x: x, y: y)
    }

    /// As EditPipeline.rotate turns a point of a `size` picture (counter-clockwise, trimmed to the frame inside).
    static func level(_ p: CGPoint, degrees: Double, size: CGSize) -> CGPoint {
        let (w, h, W, H) = frames(size, degrees), t = degrees * .pi / 180
        let dx = (p.x - 0.5) * w, dy = (0.5 - p.y) * h  // from the centre, y up
        let x = dx * cos(t) - dy * sin(t), y = dx * sin(t) + dy * cos(t)
        return CGPoint(x: (x + W / 2) / W, y: (H / 2 - y) / H)
    }

    static func unlevel(_ q: CGPoint, degrees: Double, size: CGSize) -> CGPoint {
        let (w, h, W, H) = frames(size, degrees), t = degrees * .pi / 180
        let x = q.x * W - W / 2, y = H / 2 - q.y * H
        let dx = x * cos(t) + y * sin(t), dy = -x * sin(t) + y * cos(t)
        return CGPoint(x: dx / w + 0.5, y: 0.5 - dy / h)
    }

    private static func frames(_ size: CGSize, _ degrees: Double) -> (Double, Double, Double, Double) {
        let k = EditPipeline.rotatedScale(size, degrees: degrees)
        return (size.width, size.height, (size.width * k).rounded(.down), (size.height * k).rounded(.down))
    }

    // MARK: - Painting

    /// Long side the strokes are painted at; scaled up smoothly to the picture's size.
    static let paintSide = 1600

    /// `mask` with the strokes painted over it, in order: what a stroke covers is added (or, erasing, taken away),
    /// fading out at its edge.
    public static func apply(_ strokes: [MaskStroke], to mask: CIImage, extent: CGRect) -> CIImage {
        guard !strokes.isEmpty, extent.width >= 1, extent.height >= 1, let (keep, added) = layers(strokes, size: extent.size) else { return mask }
        // Painting in order comes down to max(mask × keep, added) (an erase scales both, an addition raises `added`).
        let place = { (img: CIImage) -> CIImage in
            img.samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: extent.width / img.extent.width, y: extent.height / img.extent.height)
                    .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
                .clampedToExtent().cropped(to: extent)
        }
        var out = mask
        if let keep { out = place(keep).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: out]) }
        if let added { out = place(added).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: out]) }
        return out.cropped(to: extent)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (CIImage?, CIImage?)] = [:]
    nonisolated(unsafe) private static var cacheOrder: [String] = []

    /// The strokes as two grey pictures: how much of the mask is kept (nil: all of it) and what is added (nil:
    /// nothing). Kept for the last few photos, as the preview draws the same strokes again for every dial moved.
    static func layers(_ strokes: [MaskStroke], size: CGSize) -> (CIImage?, CIImage?)? {
        let key = "\(strokes.hashValue)|\(Int(size.width))x\(Int(size.height))"
        if let hit = cacheLock.withLock({ cache[key] }) { return hit }
        let s = min(1, Double(paintSide) / max(size.width, size.height))
        let w = max(1, Int((size.width * s).rounded())), h = max(1, Int((size.height * s).rounded()))
        let (keep, added) = paint(strokes, width: w, height: h)
        func image(_ v: [Float]?) -> CIImage? {
            guard let v else { return nil }
            let bytes = v.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
            // Rows from the top, as a bitmap's: Core Image puts the first row at the top itself (flipping them here
            // too painted every stroke upside down).
            return CIImage(bitmapData: Data(bytes), bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8, colorSpace: nil)
        }
        let out = (image(keep), image(added))
        cacheLock.withLock {
            if cache[key] == nil { cacheOrder.append(key) }
            cache[key] = out
            while cacheOrder.count > 8 { cache[cacheOrder.removeFirst()] = nil }
        }
        return out
    }

    /// Paints the strokes on a `width` × `height` grid (top-left origin): keep (nil when nothing is erased) and
    /// added (nil when nothing is added), 0…1.
    static func paint(_ strokes: [MaskStroke], width w: Int, height h: Int) -> ([Float]?, [Float]?) {
        var keep: [Float]?, added: [Float]?
        let short = Double(min(w, h))
        var cover = [Float](repeating: 0, count: w * h)
        for stroke in strokes where !stroke.points.isEmpty {
            // One stroke's cover: the brush's dab at every point along it, the strongest where they overlap.
            let r = max(0.5, stroke.radius * short)
            let inner = r * (1 - min(1, max(0, stroke.softness)))
            let pts = stroke.points.map { (Double($0.x) * Double(w), Double($0.y) * Double(h)) }
            var x0 = w, x1 = -1, y0 = h, y1 = -1
            let segments = pts.count == 1 ? [(pts[0], pts[0])] : Array(zip(pts, pts.dropFirst()))
            for (a, b) in segments {
                let lx = max(0, Int((min(a.0, b.0) - r).rounded(.down))), hx = min(w - 1, Int((max(a.0, b.0) + r).rounded(.up)))
                let ly = max(0, Int((min(a.1, b.1) - r).rounded(.down))), hy = min(h - 1, Int((max(a.1, b.1) + r).rounded(.up)))
                guard lx <= hx, ly <= hy else { continue }
                x0 = min(x0, lx); x1 = max(x1, hx); y0 = min(y0, ly); y1 = max(y1, hy)
                let ex = b.0 - a.0, ey = b.1 - a.1, len2 = ex * ex + ey * ey
                for y in ly...hy {
                    let py = Double(y) + 0.5
                    for x in lx...hx {
                        let px = Double(x) + 0.5
                        // Distance to the segment.
                        let t = len2 > 0 ? min(1, max(0, ((px - a.0) * ex + (py - a.1) * ey) / len2)) : 0
                        let dx = px - (a.0 + t * ex), dy = py - (a.1 + t * ey)
                        let d = (dx * dx + dy * dy).squareRoot()
                        guard d < r else { continue }
                        var v = 1.0
                        if d > inner {
                            let u = (r - d) / max(0.5, r - inner)
                            v = u * u * (3 - 2 * u)
                        }
                        let i = y * w + x
                        if Float(v) > cover[i] { cover[i] = Float(v) }
                    }
                }
            }
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let i = y * w + x, c = cover[i]
                    guard c > 0 else { continue }
                    cover[i] = 0
                    if stroke.erase {
                        if keep == nil { keep = [Float](repeating: 1, count: w * h) }
                        keep![i] *= 1 - c
                        if added != nil { added![i] *= 1 - c }
                    } else {
                        if added == nil { added = [Float](repeating: 0, count: w * h) }
                        added![i] = max(added![i], c)
                    }
                }
            }
        }
        return (keep, added)
    }
}
