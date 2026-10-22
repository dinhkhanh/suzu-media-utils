import CoreGraphics
import Foundation

public enum FaceAligner {
    public static let side = 112
    /// InsightFace ArcFace 112x112 reference points.
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares similarity transform (rotation, uniform scale, translation) mapping `src` onto `dst`.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        let n = Double(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var num_a = 0.0, num_b = 0.0, den = 0.0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            num_a += sx * dx + sy * dy
            num_b += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        let a = num_a / den, b = num_b / den
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: md.x - (a * ms.x - b * ms.y), ty: md.y - (b * ms.x + a * ms.y))
    }

    /// Warps the face into a 112x112 RGBA8 crop. `points` are in `image` pixel coordinates, top-left origin.
    public static func align(_ image: CGImage, points: [CGPoint]) -> [UInt8] {
        render(image, side: side, transform: similarity(from: points, to: template))
    }

    /// Square crop around `rect` (top-left origin), padded by `pad`, resized to `side`.
    public static func preview(_ image: CGImage, rect: CGRect, side: Int, pad: Double = 0.35) -> CGImage? {
        let s = max(rect.width, rect.height) * (1 + 2 * pad)
        let scale = Double(side) / s
        let t = CGAffineTransform(translationX: -(rect.midX - s / 2), y: -(rect.midY - s / 2))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let px = render(image, side: side, transform: t)
        return makeImage(px, side: side)
    }

    static func render(_ full: CGImage, side: Int, transform full_t: CGAffineTransform) -> [UInt8] {
        // Draw only the source region that lands in the output; CG otherwise resamples the whole image per face.
        let region = CGRect(x: 0, y: 0, width: side, height: side).applying(full_t.inverted())
            .insetBy(dx: -2, dy: -2).integral
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        var image = full, transform = full_t
        if !region.isNull, let cropped = full.cropping(to: region) {
            image = cropped
            transform = CGAffineTransform(translationX: region.minX, y: region.minY).concatenating(full_t)
        }
        var px = [UInt8](repeating: 0, count: side * side * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            // Top-left origin user space, then image pixel space, then undo CG's bottom-up image drawing.
            ctx.translateBy(x: 0, y: CGFloat(side))
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(transform)
            ctx.translateBy(x: 0, y: CGFloat(image.height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return px
    }

    public static func makeImage(_ px: [UInt8], side: Int) -> CGImage? {
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
