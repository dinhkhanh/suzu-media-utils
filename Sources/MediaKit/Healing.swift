import CoreGraphics
import CoreImage
import Foundation

/// A stroke of the healing brush on one photo: what it covers (a blemish, a mole, freckles, a line) is filled from
/// skin nearby, that skin's texture kept and its light and colour matched to the skin around the stroke, as
/// Photoshop's healing brushes do. Kept with the photo's own edits (CropPlacements).
public struct HealStroke: Codable, Sendable, Hashable {
    /// Along the stroke: normalized, top-left origin, in the photo as shot (upright, before its own turns and
    /// levelling), as a MaskStroke's.
    public var points: [CGPoint]
    /// The brush's radius, as a share of the photo's short side.
    public var radius: Double
    /// The brush's edge: 0 hard, 1 fading out from the centre.
    public var softness: Double
    /// Where it heals from, picked by hand: the shift from the stroke to its source (normalized, as `points`). nil:
    /// the brush finds clean skin nearby itself (content-aware).
    public var source: CGVector?

    public init(points: [CGPoint], radius: Double, softness: Double, source: CGVector? = nil) {
        // Rounded, so a photo with many strokes keeps a small record.
        self.points = points.map { CGPoint(x: ($0.x * 10000).rounded() / 10000, y: ($0.y * 10000).rounded() / 10000) }
        self.radius = radius
        self.softness = softness
        self.source = source.map { CGVector(dx: ($0.dx * 10000).rounded() / 10000, dy: ($0.dy * 10000).rounded() / 10000) }
    }
}

/// The healing brush. Each stroke (in pieces, when it is long) is filled from a source of the same shape nearby:
/// the one whose surroundings match the stroke's best and which holds no blemish of its own, unless one was picked
/// by hand. The source's texture is copied in and its light and colour corrected by the membrane (Laplace's
/// equation) between the two's differences at the stroke's rim, so it meets the skin around without a seam.
public enum Healing {
    static let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (strokes: [HealStroke], patches: [CIImage?])] = [:]
    nonisolated(unsafe) private static var cacheOrder: [String] = []

    /// `image` with the strokes healed, in order (each from what the ones before left). `key` names the picture (its
    /// file and size) for the preview, which draws the same strokes again for every dial moved: the strokes healed
    /// before are kept, and only new ones are healed.
    public static func apply(_ strokes: [HealStroke], to image: CIImage, key: String? = nil) -> CIImage {
        let ext = image.extent
        guard !strokes.isEmpty, ext.width >= 8, ext.height >= 8, ext.width.isFinite, ext.height.isFinite else { return image }
        var patches: [CIImage?] = []
        if let key, let hit = cacheLock.withLock({ cache[key] }) {
            // The strokes they have in common, from the first.
            patches = Array(hit.patches.prefix(zip(hit.strokes, strokes).prefix { $0 == $1 }.count))
        }
        var out = image
        for case let p? in patches { out = p.composited(over: out) }
        for s in strokes.dropFirst(patches.count) {
            let p = heal(s, in: out)
            patches.append(p)
            if let p { out = p.composited(over: out) }
        }
        if let key {
            cacheLock.withLock {
                if cache[key] == nil { cacheOrder.append(key) }
                cache[key] = (strokes, patches)
                while cacheOrder.count > 6 { cache[cacheOrder.removeFirst()] = nil }
            }
        }
        return out.cropped(to: ext)
    }

    /// How far from a piece of a stroke its source is looked for.
    static func reach(_ r: Double) -> Double { max(8, r * 4.5) }

    /// One stroke healed in `image`: the pixels it changes (opaque where it covers, clear elsewhere), or nil.
    static func heal(_ s: HealStroke, in image: CIImage) -> CIImage? {
        let ext = image.extent
        let W = Int(ext.width.rounded(.down)), H = Int(ext.height.rounded(.down))
        let r = max(1, s.radius * Double(min(W, H)))
        let pts = s.points.map { (Double($0.x) * Double(W), Double($0.y) * Double(H)) }
        guard !pts.isEmpty else { return nil }
        let shift = s.source.map { (Int(($0.dx * Double(W)).rounded()), Int(($0.dy * Double(H)).rounded())) }
        // The pixels read: the stroke, and around it as far as its source may be.
        let margin = r + 4 + (shift.map { Double(max(abs($0.0), abs($0.1))) } ?? reach(r) + r * 0.5)
        let rx = max(0, Int((pts.map(\.0).min()! - margin).rounded(.down))), rx1 = min(W, Int((pts.map(\.0).max()! + margin).rounded(.up)))
        let ry = max(0, Int((pts.map(\.1).min()! - margin).rounded(.down))), ry1 = min(H, Int((pts.map(\.1).max()! + margin).rounded(.up)))
        let w = rx1 - rx, h = ry1 - ry
        guard w > 2, h > 2 else { return nil }
        // Rows from the top, as a bitmap's (Core Image puts the first row at the top).
        let bounds = CGRect(x: ext.minX + CGFloat(rx), y: ext.minY + CGFloat(H - ry1), width: CGFloat(w), height: CGFloat(h))
        var px = [SIMD4<Float>](repeating: .zero, count: w * h)
        px.withUnsafeMutableBytes { EditPipeline.context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: space) }
        let local = pts.map { ($0.0 - Double(rx), $0.1 - Double(ry)) }
        var all = [Float](repeating: 0, count: w * h)
        guard MaskBrush.cover(local, radius: r, softness: s.softness, width: w, height: h, into: &all) != nil else { return nil }

        // A long stroke (a line) is healed a piece at a time, each from a source of its own; a source picked by hand
        // serves the whole stroke.
        for piece in shift == nil ? pieces(local, length: r * 5) : [local] {
            var m = [Float](repeating: 0, count: w * h)
            guard let box = MaskBrush.cover(piece, radius: r, softness: s.softness, width: w, height: h, into: &m),
                  let from = shift ?? findSource(px, w: w, h: h, mask: m, box: box, r: r) else { continue }
            blend(&px, w: w, h: h, mask: m, box: box, shift: from)
        }
        // Only what the stroke covers goes back.
        for i in 0..<(w * h) { if all[i] > 0 { px[i].w = 1 } else { px[i] = .zero } }
        let data = px.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    /// A line cut into pieces about `length` long (a short end joins the piece before).
    static func pieces(_ pts: [(Double, Double)], length: Double) -> [[(Double, Double)]] {
        guard pts.count > 1, length > 0 else { return [pts] }
        var out: [[(Double, Double)]] = [], cur = [pts[0]], run = 0.0
        for i in 1..<pts.count {
            var a = pts[i - 1]
            let b = pts[i]
            var seg = hypot(b.0 - a.0, b.1 - a.1)
            while seg > 0, run + seg >= length {
                let t = (length - run) / seg
                let c = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
                cur.append(c)
                out.append(cur)
                cur = [c]
                a = c
                seg = hypot(b.0 - a.0, b.1 - a.1)
                run = 0
            }
            run += seg
            cur.append(b)
        }
        if out.isEmpty || run > length * 0.5 { out.append(cur) } else { out[out.count - 1].append(contentsOf: cur.dropFirst()) }
        return out
    }

    // MARK: - The source

    /// The brush's radius in the cells of the grid the source is looked for on, whatever the picture's size: the
    /// preview at any zoom and the export (each its own resolution) see the same grid, so they pick the same source.
    static let searchRadius = 12.0

    /// The shift (in pixels) to the best source for what `m` covers within `box`, looked for on a grid where the
    /// brush is `searchRadius` cells: its rim matching the stroke's (texture and tone), its inside clean (no spots
    /// or lines), and near. nil when none fits in the picture.
    static func findSource(_ px: [SIMD4<Float>], w: Int, h: Int, mask m: [Float], box: (Int, Int, Int, Int), r: Double) -> (Int, Int)? {
        // Pixels per cell (below one for a small brush: cells then repeat pixels).
        let f = r / searchRadius, rc = searchRadius
        let ring = max(2, Int((rc * 0.35).rounded()))
        let pad = Int((reach(r) + Double(ring + 1) * f).rounded(.up))
        let x0 = max(0, box.0 - pad), y0 = max(0, box.2 - pad)
        let cw = Int(Double(min(w - 1, box.1 + pad) - x0 + 1) / f), ch = Int(Double(min(h - 1, box.3 + pad) - y0 + 1) / f)
        guard cw > 2, ch > 2 else { return nil }
        let n = cw * ch
        // The pixels a cell covers, along one side.
        func span(_ c: Int, _ origin: Int, _ limit: Int) -> Range<Int> {
            let a = min(limit - 1, origin + Int(Double(c) * f)), b = min(limit, origin + Int(Double(c + 1) * f))
            return a..<max(a + 1, b)
        }
        // Each cell's colour, and whether it is in the stroke.
        var col = [SIMD4<Float>](repeating: .zero, count: n), hole = [Bool](repeating: false, count: n)
        for cy in 0..<ch {
            let ys = span(cy, y0, h)
            for cx in 0..<cw {
                let xs = span(cx, x0, w)
                var sum = SIMD4<Float>.zero, inside = false
                for y in ys {
                    for x in xs {
                        sum += px[y * w + x]
                        if m[y * w + x] > 0 { inside = true }
                    }
                }
                col[cy * cw + cx] = sum / Float(ys.count * xs.count)
                hole[cy * cw + cx] = inside
            }
        }
        // The rim: cells just outside the stroke.
        var rim = [Bool](repeating: false, count: n)
        for cy in 0..<ch {
            for cx in 0..<cw where hole[cy * cw + cx] {
                for dy in -ring...ring {
                    for dx in -ring...ring where dx * dx + dy * dy <= ring * ring {
                        let x = cx + dx, y = cy + dy
                        if x >= 0, x < cw, y >= 0, y < ch, !hole[y * cw + x] { rim[y * cw + x] = true }
                    }
                }
            }
        }
        // Detail: lightness less its local average (spots, lines and edges stand out; broad shading doesn't).
        let b = max(1, Int(rc * 0.5))
        var sat = [Float](repeating: 0, count: (cw + 1) * (ch + 1))
        for y in 0..<ch {
            var row: Float = 0
            for x in 0..<cw {
                let c = col[y * cw + x]
                row += (c.x + c.y + c.z) / 3
                sat[(y + 1) * (cw + 1) + x + 1] = sat[y * (cw + 1) + x + 1] + row
            }
        }
        var detail = [Float](repeating: 0, count: n)
        for y in 0..<ch {
            for x in 0..<cw {
                let lx = max(0, x - b), hx = min(cw, x + b + 1), ly = max(0, y - b), hy = min(ch, y + b + 1)
                let s = sat[hy * (cw + 1) + hx] - sat[ly * (cw + 1) + hx] - sat[hy * (cw + 1) + lx] + sat[ly * (cw + 1) + lx]
                let c = col[y * cw + x], d = (c.x + c.y + c.z) / 3 - s / Float((hx - lx) * (hy - ly))
                detail[y * cw + x] = d * d
            }
        }
        var holeCells: [Int] = [], rimCells: [Int] = []
        var bx0 = cw, bx1 = -1, by0 = ch, by1 = -1
        for i in 0..<n where hole[i] || rim[i] {
            if hole[i] { holeCells.append(i) } else { rimCells.append(i) }
            bx0 = min(bx0, i % cw); bx1 = max(bx1, i % cw); by0 = min(by0, i / cw); by1 = max(by1, i / cw)
        }
        guard !holeCells.isEmpty, !rimCells.isEmpty else { return nil }
        let reachC = Int((reach(r) / f).rounded())

        func cost(_ ox: Int, _ oy: Int) -> Float? {
            guard bx0 + ox >= 0, bx1 + ox < cw, by0 + oy >= 0, by1 + oy < ch else { return nil }
            let o = oy * cw + ox
            var sum = SIMD4<Float>.zero, sq: Float = 0, e: Float = 0
            for p in rimCells {
                let q = p + o
                if hole[q] { return nil }
                let d = col[q] - col[p]
                sum += d
                sq += (d * d).sum()
            }
            for p in holeCells {
                let q = p + o
                if hole[q] { return nil }
                e += detail[q]
            }
            let nr = Float(rimCells.count), mean = sum / nr
            // The rims' texture apart from their tone (the blend makes up a difference in tone), the tone a little.
            let rimCost = sq / nr - (mean * mean).sum() + 0.25 * (mean * mean).sum()
            let far = Float((Double(ox * ox + oy * oy)).squareRoot() / rc)
            return (rimCost + 3 * e / Float(holeCells.count)) * (1 + 0.08 * far) + 1e-7 * far
        }

        var best: (Int, Int, Float)?
        for oy in stride(from: -reachC, through: reachC, by: 2) {
            for ox in stride(from: -reachC, through: reachC, by: 2) where ox * ox + oy * oy <= reachC * reachC {
                if let c = cost(ox, oy), c < best?.2 ?? .infinity { best = (ox, oy, c) }
            }
        }
        guard var found = best else { return nil }
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                if let c = cost(found.0 + dx, found.1 + dy), c < found.2 { found = (found.0 + dx, found.1 + dy, c) }
            }
        }
        return (Int((Double(found.0) * f).rounded()), Int((Double(found.1) * f).rounded()))
    }

    // MARK: - The blend

    /// What `m` covers (within `box`) filled from `shift` away: the source's pixels, corrected by the membrane between
    /// the differences at the rim, then faded into the photo by the brush's edge.
    static func blend(_ px: inout [SIMD4<Float>], w: Int, h: Int, mask m: [Float], box: (Int, Int, Int, Int), shift: (Int, Int)) {
        let x0 = max(0, box.0 - 1), x1 = min(w - 1, box.1 + 1), y0 = max(0, box.2 - 1), y1 = min(h - 1, box.3 + 1)
        let ww = x1 - x0 + 1, wh = y1 - y0 + 1
        func source(_ x: Int, _ y: Int) -> SIMD4<Float> { px[min(h - 1, max(0, y + shift.1)) * w + min(w - 1, max(0, x + shift.0))] }
        // 2 inside the stroke, 1 its rim (where the difference is known), 0 neither.
        var state = [UInt8](repeating: 0, count: ww * wh)
        var diff = [SIMD4<Float>](repeating: .zero, count: ww * wh)
        for y in y0...y1 { for x in x0...x1 where m[y * w + x] > 0 { state[(y - y0) * ww + x - x0] = 2 } }
        for y in 0..<wh {
            for x in 0..<ww where state[y * ww + x] == 2 {
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < ww && ny >= 0 && ny < wh {
                    let j = ny * ww + nx
                    if state[j] == 0 {
                        state[j] = 1
                        diff[j] = px[(ny + y0) * w + nx + x0] - source(nx + x0, ny + y0)
                    }
                }
            }
        }
        membrane(&diff, state, w: ww, h: wh)
        var healed: [(Int, SIMD4<Float>)] = []
        for y in 0..<wh {
            for x in 0..<ww where state[y * ww + x] == 2 {
                let i = (y + y0) * w + x + x0, a = m[i]
                var v = (source(x + x0, y + y0) + diff[y * ww + x]) * a + px[i] * (1 - a)
                v.w = 1
                healed.append((i, v))
            }
        }
        for (i, v) in healed { px[i] = v }
    }

    /// The values inside (`state` 2) set to the membrane stretched over the known ones (`state` 1): smooth, and meeting
    /// them at the rim. A pull-push guess first, then over-relaxed toward Laplace's equation.
    static func membrane(_ v: inout [SIMD4<Float>], _ state: [UInt8], w: Int, h: Int) {
        // Pull: averages of the known values, halving the size until one cell is left.
        var levels: [(v: [SIMD4<Float>], wt: [Float], w: Int, h: Int)] = []
        levels.append((v, state.map { $0 == 1 ? 1 : 0 }, w, h))
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let f = levels.last!, nw = (f.w + 1) / 2, nh = (f.h + 1) / 2
            var nv = [SIMD4<Float>](repeating: .zero, count: nw * nh), nwt = [Float](repeating: 0, count: nw * nh)
            for y in 0..<f.h {
                for x in 0..<f.w {
                    let i = y * f.w + x, j = (y / 2) * nw + x / 2
                    nv[j] += f.v[i] * f.wt[i]
                    nwt[j] += f.wt[i]
                }
            }
            for j in 0..<(nw * nh) where nwt[j] > 0 { nv[j] /= nwt[j]; nwt[j] = min(1, nwt[j]) }
            levels.append((nv, nwt, nw, nh))
        }
        // Push: what a level doesn't know, from the coarser one (bilinear).
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let c = levels[l + 1]
            var f = levels[l]
            for y in 0..<f.h {
                for x in 0..<f.w {
                    let i = y * f.w + x, a = f.wt[i]
                    guard a < 1 else { continue }
                    let cx = min(Double(c.w - 1), max(0, (Double(x) + 0.5) / 2 - 0.5)), cy = min(Double(c.h - 1), max(0, (Double(y) + 0.5) / 2 - 0.5))
                    let ix = Int(cx), iy = Int(cy), jx = min(c.w - 1, ix + 1), jy = min(c.h - 1, iy + 1)
                    let tx = Float(cx - Double(ix)), ty = Float(cy - Double(iy))
                    let top = c.v[iy * c.w + ix] * (1 - tx) + c.v[iy * c.w + jx] * tx
                    let bottom = c.v[jy * c.w + ix] * (1 - tx) + c.v[jy * c.w + jx] * tx
                    f.v[i] = f.v[i] * a + (top * (1 - ty) + bottom * ty) * (1 - a)
                }
            }
            levels[l].v = f.v
        }
        var inside: [Int32] = [], around: [SIMD4<Int32>] = []
        for i in 0..<(w * h) where state[i] == 2 {
            v[i] = levels[0].v[i]
            let x = i % w, y = i / w
            inside.append(Int32(i))
            // Neighbours off the picture's edge are left out (-1).
            around.append(SIMD4(x > 0 ? Int32(i - 1) : -1, x < w - 1 ? Int32(i + 1) : -1, y > 0 ? Int32(i - w) : -1, y < h - 1 ? Int32(i + w) : -1))
        }
        guard !inside.isEmpty else { return }
        let span = Double(max(w, h))
        let omega = Float(min(1.95, max(1, 2 / (1 + sin(.pi / max(2, span))))))
        let iterations = min(400, max(20, Int(span)))
        v.withUnsafeMutableBufferPointer { b in
            for _ in 0..<iterations {
                for (i, nb) in zip(inside, around) {
                    var sum = SIMD4<Float>.zero, count: Float = 0
                    if nb.x >= 0 { sum += b[Int(nb.x)]; count += 1 }
                    if nb.y >= 0 { sum += b[Int(nb.y)]; count += 1 }
                    if nb.z >= 0 { sum += b[Int(nb.z)]; count += 1 }
                    if nb.w >= 0 { sum += b[Int(nb.w)]; count += 1 }
                    guard count > 0 else { continue }
                    b[Int(i)] += (sum / count - b[Int(i)]) * omega
                }
            }
        }
    }
}
