import CoreGraphics
import CoreImage
import Foundation

/// How far a photo is turned off level, measured on its long vertical lines: pillars, door frames, the edges of
/// banners and screens, which stay vertical in a level photo whatever the perspective (give or take a degree when the
/// camera points up or down). Horizontal lines slope with perspective, so they aren't used. Says nothing unless many
/// lines agree: turning a level photo is worse than leaving a tilted one. Checked on event photos turned by ±3°.
enum TiltEstimator {
    /// Long side of the copy measured.
    static let side = 640
    /// Tilts looked for, in degrees either way.
    static let range = 12.0
    static let step = 0.1

    struct Line { var angle: Double; var votes: Int }

    /// Degrees counter-clockwise the photo is turned (the horizon tilt), or nil when the lines don't say.
    static func tilt(_ image: CIImage) -> Double? {
        guard let (gray, w, h) = grayscale(image) else { return nil }
        return agreed(verticals(gray, w, h), minLines: 6, spread: 1.2)
    }

    /// The vote-weighted median angle when enough lines agree around it (most of the votes, and `minLines` lines;
    /// a few lines that happen to line up are folds, stripes or a slanted structure).
    static func agreed(_ lines: [Line], minLines: Int, spread: Double) -> Double? {
        guard lines.count >= minLines else { return nil }
        let sorted = lines.sorted { $0.angle < $1.angle }
        let total = sorted.reduce(0) { $0 + $1.votes }
        var acc = 0, median = sorted[0].angle
        for l in sorted { acc += l.votes; if acc * 2 >= total { median = l.angle; break } }
        let near = lines.filter { abs($0.angle - median) <= spread }
        guard near.count >= minLines, near.reduce(0, { $0 + $1.votes }) * 5 >= total * 3 else { return nil }
        let w = near.reduce(0.0) { $0 + Double($1.votes) }
        return near.reduce(0.0) { $0 + $1.angle * Double($1.votes) } / w
    }

    static func grayscale(_ image: CIImage) -> ([Float], Int, Int)? {
        let ext = image.extent
        guard ext.width > 8, ext.height > 8 else { return nil }
        let s = Double(side) / max(ext.width, ext.height)
        let small = image.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY).concatenating(CGAffineTransform(scaleX: s, y: s)))
        // Whole pixels only: a half-covered last column would read as a long vertical line.
        let w = Int(small.extent.width.rounded(.down)), h = Int(small.extent.height.rounded(.down))
        var px = [UInt8](repeating: 0, count: w * h)
        CIContext(options: [.useSoftwareRenderer: false]).render(small, toBitmap: &px, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                                                 format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        return (px.map(Float.init), w, h)
    }

    /// Long straight lines near vertical (Hough transform on strong edges). Angles are in degrees counter-clockwise
    /// from upright, as the photo would have to be turned back clockwise.
    static func verticals(_ g: [Float], _ w: Int, _ h: Int) -> [Line] {
        // Sobel gradients; the strongest 10% of edges vote.
        var gx = [Float](repeating: 0, count: w * h), gy = gx, mag = gx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let a = g[i - w - 1], b = g[i - w], c = g[i - w + 1], d = g[i - 1], f = g[i + 1], p = g[i + w - 1], q = g[i + w], r = g[i + w + 1]
                gx[i] = (c + 2 * f + r) - (a + 2 * d + p)
                gy[i] = (p + 2 * q + r) - (a + 2 * b + c)
                mag[i] = (gx[i] * gx[i] + gy[i] * gy[i]).squareRoot()
            }
        }
        let threshold = max(60, mag.sorted()[Int(Double(mag.count) * 0.9)])
        let angles = Int(range / step) * 2 + 1
        // Rows are top-down here, so a line leaning right at the top (photo turned clockwise) gets a negative
        // angle: the sign is flipped at the end to measure counter-clockwise.
        let maxRho = w + h, bins = 2 * maxRho + 1
        var acc = [Int32](repeating: 0, count: angles * bins)
        let cosT = (0..<angles).map { cos((Double($0) * step - range) * .pi / 180) }
        let sinT = (0..<angles).map { sin((Double($0) * step - range) * .pi / 180) }
        // Not the photo's own border (nor the soft edge a turn leaves).
        let m = 4
        for y in m..<(h - m) {
            for x in m..<(w - m) {
                let i = y * w + x
                guard mag[i] >= threshold else { continue }
                // The edge's normal, folded to -90°…90°: near 0° for a vertical edge.
                var n = atan2(Double(gy[i]), Double(gx[i])) * 180 / .pi
                if n > 90 { n -= 180 } else if n < -90 { n += 180 }
                guard abs(n) <= range + 2 else { continue }
                // Votes only near the edge's own direction (±2°), which keeps texture from adding up.
                let lo = max(0, Int(((n - 2) + range) / step)), hi = min(angles - 1, Int(((n + 2) + range) / step))
                guard lo <= hi else { continue }
                let fx = Double(x), fy = Double(y)
                for k in lo...hi {
                    let rho = fx * cosT[k] + fy * sinT[k]
                    acc[k * bins + Int(rho.rounded()) + maxRho] += 1
                }
            }
        }
        // Peaks: lines at least a tenth of the photo long, one per neighbourhood (±1°, ±4 px).
        let minVotes = Int32(Double(h) / 10)
        var found: [(k: Int, rho: Int, votes: Int32)] = []
        for k in 0..<angles {
            for rho in 0..<bins where acc[k * bins + rho] >= minVotes {
                found.append((k, rho, acc[k * bins + rho]))
            }
        }
        found.sort { $0.votes > $1.votes }
        var kept: [(k: Int, rho: Int, votes: Int32)] = []
        for f in found where kept.count < 20 {
            if kept.contains(where: { abs($0.k - f.k) <= 10 && abs($0.rho - f.rho) <= 4 }) { continue }
            kept.append(f)
        }
        // Each line's angle: the centre of its peak (a straight line scores almost as well 0.1° either side, so the
        // single best bin would wobble).
        return kept.map { p in
            var sum = 0.0, weight = 0.0
            for k in max(0, p.k - 8)...min(angles - 1, p.k + 8) {
                let best = (max(0, p.rho - 2)...min(bins - 1, p.rho + 2)).map { acc[k * bins + $0] }.max()!
                let v = Double(best) - Double(p.votes) * 0.8
                if v > 0 { sum += Double(k) * v; weight += v }
            }
            let k = weight > 0 ? sum / weight : Double(p.k)
            return Line(angle: -(k * step - range), votes: Int(p.votes))
        }
    }
}
