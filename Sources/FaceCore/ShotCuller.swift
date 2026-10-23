import CoreGraphics
import Foundation
import ImageIO

/// Culling before an export: which photos are blurry, and which are near-identical shots of which only the best
/// is worth keeping. Works on plain files; the library fills in what it already knows (see `Selection.measures`).
public enum ShotCuller {
    /// What the culling looks at in one photo.
    public struct Measure: Sendable {
        public var url: URL
        public var takenAt: Date?
        /// Vision feature print of the whole frame (same as the library's burst detection).
        public var featurePrint: [Float]?
        /// Blur of the whole frame, 0 crisp to 1 smeared (`blurIndex`); nil when the file could not be read.
        public var blur: Double?
        /// Sharpness of the main face (variance of the Laplacian on the aligned crop, as the library stores it);
        /// nil when there is no face at least `minFaceWidth` of the frame wide.
        public var faceSharpness: Double?
        /// Best-shot score of the main face when the library knows it (ranks a group's shots).
        public var faceScore: Double?

        public init(url: URL, takenAt: Date? = nil, featurePrint: [Float]? = nil, blur: Double? = nil,
                    faceSharpness: Double? = nil, faceScore: Double? = nil) {
            self.url = url; self.takenAt = takenAt; self.featurePrint = featurePrint; self.blur = blur
            self.faceSharpness = faceSharpness; self.faceScore = faceScore
        }
    }

    /// Why a photo was left out.
    public enum Reason: Sendable, Hashable {
        case blurry
        /// A near-identical shot of `best`, which is kept instead.
        case similar(to: URL)
    }

    /// Face sharpness below which the main face counts as soft; ~40 is blurry, ~1000 crisp (the Files browser's
    /// "soft" hint uses the same line).
    public static let softFaceBelow = 60.0
    /// Faces narrower than this share of the frame (crowds, background) don't decide the photo.
    public static let minFaceWidth = 0.04
    /// Whole-frame blur index above which a photo without a usable face counts as blurry. Measured on the 1500 px
    /// detection decode, 1,046 sharp library photos read 0.18–0.52 (median 0.31; event photos at most 0.47). A
    /// 5×5 box blur at that size (a visibly missed focus at full size) moves them to 0.56–0.73 and a 9×9 one past
    /// 0.72. Set so a sharp photo is never skipped.
    public static let blurryFrameAbove = 0.58
    /// Same gap and feature-print distance as the library's burst detection.
    public static let maxGap = 2.0
    public static let maxDistance: Float = 0.48

    // MARK: Measuring

    /// Reads one photo. `faces`: also detect faces for the main face's sharpness (the slow part, ~a tenth of a
    /// second per photo); without it only the frame's blur is known. The capture time falls back to the file's
    /// modification time, as the library's does.
    public static func measure(_ url: URL, faces: Bool) -> Measure {
        var m = Measure(url: url)
        guard let (src, _) = try? ImageLoader.source(url) else { return m }
        m.takenAt = ImageLoader.captureDate(src)
            ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        m.featurePrint = MediaAnalyzer.quickFeaturePrint(url)
        // One decode at the detection size serves both the blur index and the faces.
        guard let image = ImageLoader.decode(src, maxPixel: MediaAnalyzer.detectSize) else { return m }
        m.blur = blurIndex(image)
        if faces, let found = try? MediaAnalyzer.faces(in: image, time: nil) {
            let minWidth = Double(image.width) * minFaceWidth
            if let main = found.filter({ $0.face.w >= minWidth }).max(by: { $0.face.w * $0.face.h < $1.face.w * $1.face.h }) {
                m.faceSharpness = main.sharpness
            }
        }
        return m
    }

    /// No-reference blur estimate (Crete et al.): how much of the image's edge contrast a strong blur still takes
    /// away, over both directions together. 0 = every edge is crisp, 1 = blurring changes nothing because it is
    /// already smeared.
    public static func blurIndex(_ image: CGImage) -> Double? {
        let w = image.width, h = image.height
        guard w > 12, h > 12 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let g = bytes.map { Float($0) }
        return blurIndex(g, width: w, height: h)
    }

    static func blurIndex(_ g: [Float], width w: Int, height h: Int) -> Double {
        // 9-tap box blurs, one per direction.
        var bh = g, bv = g
        for y in 0..<h {
            for x in 4..<(w - 4) {
                var s: Float = 0
                for k in -4...4 { s += g[y * w + x + k] }
                bh[y * w + x] = s / 9
            }
        }
        for y in 4..<(h - 4) {
            for x in 0..<w {
                var s: Float = 0
                for k in -4...4 { s += g[(y + k) * w + x] }
                bv[y * w + x] = s / 9
            }
        }
        var edgesH = 0.0, lostH = 0.0, edgesV = 0.0, lostV = 0.0
        for y in 5..<(h - 5) {
            for x in 5..<(w - 5) {
                let i = y * w + x
                let dh = abs(g[i] - g[i - 1]), dv = abs(g[i] - g[i - w])
                edgesH += Double(dh); lostH += Double(max(0, dh - abs(bh[i] - bh[i - 1])))
                edgesV += Double(dv); lostV += Double(max(0, dv - abs(bv[i] - bv[i - w])))
            }
        }
        let edges = edgesH + edgesV
        return edges > 0 ? (edges - lostH - lostV) / edges : 1
    }

    // MARK: Deciding

    /// The main face is soft; or, without a usable face, the whole frame is smeared.
    public static func isBlurry(_ m: Measure) -> Bool {
        if let s = m.faceSharpness { return s < softFaceBelow }
        if let b = m.blur { return b > blurryFrameAbove }
        return false
    }

    /// Near-identical shots: taken within `maxGap` seconds of each other (or next to each other in the same folder
    /// when capture times are missing) and looking the same. Each group is in shooting order, two or more photos.
    public static func similarGroups(_ shots: [Measure], maxGap: Double = maxGap, maxDistance: Float = maxDistance) -> [[Int]] {
        let order = shots.indices.sorted { a, b in
            let fa = shots[a].url.deletingLastPathComponent().path, fb = shots[b].url.deletingLastPathComponent().path
            if fa != fb { return fa < fb }
            if let ta = shots[a].takenAt, let tb = shots[b].takenAt, ta != tb { return ta < tb }
            return shots[a].url.lastPathComponent.localizedStandardCompare(shots[b].url.lastPathComponent) == .orderedAscending
        }
        var groups: [[Int]] = []
        for i in order {
            if let prev = groups.last?.last, follows(shots[i], shots[prev], maxGap: maxGap, maxDistance: maxDistance) {
                groups[groups.count - 1].append(i)
            } else {
                groups.append([i])
            }
        }
        return groups.filter { $0.count > 1 }
    }

    static func follows(_ s: Measure, _ prev: Measure, maxGap: Double, maxDistance: Float) -> Bool {
        guard let a = s.featurePrint, let b = prev.featurePrint, distance(a, b) <= maxDistance else { return false }
        if let t = s.takenAt, let p = prev.takenAt { return abs(t.timeIntervalSince(p)) <= maxGap }
        return s.url.deletingLastPathComponent() == prev.url.deletingLastPathComponent()
    }

    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { let d = a[i] - b[i]; s += d * d }
        return s.squareRoot()
    }

    /// Which of a group's shots to keep: the library's best-shot score, else the sharpest face, else the crispest
    /// frame, else the first.
    public static func best(of group: [Int], in shots: [Measure]) -> Int {
        func key(_ i: Int) -> (Double, Double, Double) {
            let m = shots[i]
            return (m.faceScore ?? -1, m.faceSharpness ?? -1, m.blur.map { 1 - $0 } ?? -1)
        }
        return group.max { key($0) < key($1) } ?? group[0]
    }

    /// Everything to leave out: blurry shots first (when asked), then all but the best of each group of similar
    /// shots among the rest. Keys are the photos' indexes in `shots`.
    public static func cull(_ shots: [Measure], similar: Bool, blurry: Bool) -> [Int: Reason] {
        var out: [Int: Reason] = [:]
        if blurry { for i in shots.indices where isBlurry(shots[i]) { out[i] = .blurry } }
        if similar {
            let kept = shots.indices.filter { out[$0] == nil }
            for group in similarGroups(kept.map { shots[$0] }) {
                let best = best(of: group, in: kept.map { shots[$0] })
                for i in group where i != best { out[kept[i]] = .similar(to: shots[kept[best]].url) }
            }
        }
        return out
    }
}
