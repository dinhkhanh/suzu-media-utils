import CoreGraphics
import CoreImage
import FaceCore
import Foundation
import ImageIO
import MediaKit
import Vision

// facescan scan <folder> --out <dir> [--workers 8] [--detect 1500] [--hires 0|3000] [--models ArcFaceR50,SFace]
//                        [--models-dir models/compiled] [--limit N]
// facescan cluster <dir> [--model ArcFaceR50] [--threshold 0.45] [--min-size 40] [--min-quality 0.3] [--sweep]

func usage() -> Never {
    print("""
    usage:
      facescan scan <folder> --out <dir> [--workers 8] [--detect 1500] [--hires 0|3000] [--models ArcFaceR50,SFace]
                             [--models-dir models/compiled] [--limit N]
      facescan cluster <dir> [--model ArcFaceR50] [--threshold 0.45] [--min-size 40] [--min-quality 0.3] [--sweep]
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }
let command = args.removeFirst()
let target = URL(fileURLWithPath: args.removeFirst())
var opts: [String: String] = [:]
var flags: Set<String> = []
while let a = args.first {
    args.removeFirst()
    guard a.hasPrefix("--") else { usage() }
    let key = String(a.dropFirst(2))
    if let v = args.first, !v.hasPrefix("--") { opts[key] = v; args.removeFirst() } else { flags.insert(key) }
}

func now() -> Double { Date().timeIntervalSinceReferenceDate }
func fmt(_ v: Double, _ p: Int = 1) -> String { String(format: "%.\(p)f", v) }

switch command {
case "render":
    // facescan render <photo> --out x.jpg [--aspect 4:5] [--tone] [--straighten] [--logo logo.png] [--banner wide.png [--banner-portrait tall.png]] [--long 1350]
    var r = EditRecipe()
    r.autoTone = flags.contains("tone")
    r.straighten = flags.contains("straighten") ? true : nil
    r.aspect = opts["aspect"].flatMap(AspectPreset.init(rawValue:))
    r.maxLongSide = opts["long"].flatMap(Int.init)
    r.watermark = opts["logo"].map(WatermarkSpec.init(logoPath:)) ?? opts["banner"].map { WatermarkSpec(banner: $0, portrait: opts["banner-portrait"]) }
    try! EditPipeline.render(target, recipe: r, focus: nil, to: URL(fileURLWithPath: opts["out"]!))
    print("ok")
case "tilt":
    // facescan tilt <folder> [--test] : the tilt straightening would correct, per photo (blank: left alone). --test
    // also turns each photo 3° each way and prints how far off the estimates are.
    let files = (FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        .filter { ImageLoader.extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    for f in files.prefix(Int(opts["limit"] ?? "200")!) {
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
        let image = CIImage(cgImage: cg), base = EditPipeline.horizonTilt(image)
        var line = [base.map { fmt($0) + "°" } ?? "", f.lastPathComponent]
        if flags.contains("test") {
            for turn in [3.0, -3.0] {
                let est = EditPipeline.horizonTilt(EditPipeline.rotate(image, degrees: turn, focus: nil).0)
                line.append(est.map { "\(fmt(turn, 0)): err \(fmt($0 - (base ?? 0) - turn, 2))" } ?? "\(fmt(turn, 0)): none")
            }
        }
        print(line.joined(separator: "\t"))
    }
case "mask":
    // facescan mask <photo> --out x.jpg [--part faceSkin] [--soft 0.3] [--face] [--plain] [--model BodyParts.mlmodelc]
    //               [--long 1600] : the photo with a part's mask (as the retouch uses it) in red over it, to see where
    //               it reaches; --face: only the biggest face, close up; --plain: the mask alone.
    BodyParts.modelURL = opts["model"].map(URL.init(fileURLWithPath:))
    guard let src = CGImageSourceCreateWithURL(target as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: Int(opts["long"] ?? "1600")!,
                                                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { exit(1) }
    let image = CIImage(cgImage: cg)
    let part = Retouch.Part(rawValue: opts["part"] ?? "faceSkin")!
    let t0 = now()
    guard let parts = BodyParts.find(in: image) else { print("nobody"); exit(1) }
    print("found in \(fmt(now() - t0, 2))s, by model: \(parts.byModel)")
    var retouch = Retouch()
    var look = PartLook()
    if let soft = opts["soft"].flatMap(Double.init) { look.softness = soft }
    retouch.setLook(look, for: part)
    let mask = EditPipeline.partMask(part, retouch, parts: parts, extent: image.extent)
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: image.extent)
    let tinted = red.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: image])
        .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: 0.5])
    var out = flags.contains("plain") ? mask
        : tinted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
    if flags.contains("face") {
        // Only the biggest face and a little around it, to see its edge up close.
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: image).perform([req])
        if let b = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox {
            let e = image.extent
            let r = CGRect(x: b.minX * e.width, y: b.minY * e.height, width: b.width * e.width, height: b.height * e.height)
            out = out.cropped(to: r.insetBy(dx: -r.width * 0.45, dy: -r.height * 0.45))
        }
    }
    try! CIContext().writeJPEGRepresentation(of: out, to: URL(fileURLWithPath: opts["out"]!), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("ok")
case "sheet":
    try! VideoTools.contactSheet(target, to: URL(fileURLWithPath: opts["out"]!))
    print("ok")
case "crop":
    // facescan crop <file> --box x,y,w,h [--time t] --out file.jpg : the crop a recognition service would receive.
    let b = opts["box"]!.split(separator: ",").map { Double($0)! }
    let data = MediaAnalyzer.faceContextJPEG(target, box: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]),
                                             time: opts["time"].flatMap(Double.init))!
    try! data.write(to: URL(fileURLWithPath: opts["out"]!))
    print("\(data.count) bytes")
case "scan": scan()
case "cluster": cluster()
default: usage()
}

// MARK: - scan

func scan() {
    let out = URL(fileURLWithPath: opts["out"] ?? "runs/\(target.lastPathComponent)")
    let workers = Int(opts["workers"] ?? "8")!
    let detectSize = Int(opts["detect"] ?? "1500")!
    // Off by default: Phase 0 showed no clustering gain from cutting small faces out of a 3000 px decode.
    let hires = Int(opts["hires"] ?? "0")!
    let videoInterval = Double(opts["video-interval"] ?? "1")!
    let modelNames = (opts["models"] ?? "ArcFaceR50,SFace").split(separator: ",").map(String.init)
    let modelsDir = URL(fileURLWithPath: opts["models-dir"] ?? "models/compiled")
    try! FileManager.default.createDirectory(at: out.appendingPathComponent("crops"), withIntermediateDirectories: true)

    var t0 = now()
    var files = ImageLoader.enumerate(target)
    if let l = opts["limit"].flatMap(Int.init) { files = Array(files.prefix(l)) }
    let tEnum = now() - t0
    print("\(files.count) images under \(target.path) (enumerated in \(fmt(tEnum, 2)) s)")

    struct PhotoOut {
        var photo: ScannedPhoto
        var faces: [ScannedFace] = []
        var aligned: [[UInt8]] = []
        var previews: [CGImage] = []
        var tRead = 0.0, tDetect = 0.0, tAlign = 0.0
    }
    var results = [PhotoOut?](repeating: nil, count: files.count)
    let lock = NSLock()
    var next = 0
    var done = 0

    t0 = now()
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        while true {
            lock.lock(); let i = next; next += 1; lock.unlock()
            if i >= files.count { return }
            var r = PhotoOut(photo: ScannedPhoto(path: files[i].path, bytes: 0, longSide: 0, detectWidth: 0, detectHeight: 0))
            autoreleasepool {
                do {
                    if VideoSampler.extensions.contains(files[i].pathExtension.lowercased()) {
                        try scanVideo(files[i], index: i, into: &r)
                        return
                    }
                    var t = now()
                    let (src, bytes) = try ImageLoader.source(files[i])
                    r.photo.bytes = bytes
                    r.photo.longSide = ImageLoader.pixelLongSide(src)
                    r.tRead = now() - t

                    t = now()
                    guard let thumb = ImageLoader.decode(src, maxPixel: detectSize) else { throw CocoaError(.fileReadCorruptFile) }
                    r.photo.detectWidth = thumb.width
                    r.photo.detectHeight = thumb.height
                    let faces = try FaceDetector.detect(thumb)
                    r.tDetect = now() - t

                    t = now()
                    // Small faces are cut from a larger decode so the 112 px crop is not upsampled from mush.
                    var hi: CGImage?
                    let thumbLong = max(thumb.width, thumb.height)
                    if hires > 0, r.photo.longSide > thumbLong, faces.contains(where: { $0.points != nil && $0.w < 112 }) {
                        // Prefer an exact 1/2 or 1/4 JPEG DCT scale at or above the requested size.
                        let target = [r.photo.longSide / 4, r.photo.longSide / 2].first { $0 >= hires } ?? r.photo.longSide
                        hi = ImageLoader.decode(src, maxPixel: target)
                    }
                    for f in faces {
                        var sf = ScannedFace(photo: i, face: f)
                        if let pts = f.points {
                            let useHi = hi != nil && f.w < 112
                            let img = useHi ? hi! : thumb
                            let k = Double(img.width) / Double(thumb.width)
                            r.aligned.append(FaceAligner.align(img, points: pts.map { CGPoint(x: $0.x * k, y: $0.y * k) }))
                            sf.alignedFrom = max(img.width, img.height)
                            let rect = f.rect.applying(CGAffineTransform(scaleX: k, y: k))
                            if let p = FaceAligner.preview(img, rect: rect, side: 128) { r.previews.append(p) }
                        }
                        r.faces.append(sf)
                    }
                    r.tAlign = now() - t
                } catch {
                    r.photo.error = "\(error)"
                }
            }
            lock.lock()
            results[i] = r
            done += 1
            if done % 100 == 0 { print("  \(done)/\(files.count)") }
            lock.unlock()
        }
    }
    let tDetectStage = now() - t0

    // Videos: sample frames, detect and align on each. Every sampled face is kept; the cluster step collapses
    // repeats of one person within a video.
    func scanVideo(_ url: URL, index i: Int, into r: inout PhotoOut) throws {
        var t = now()
        let (duration, frames) = try VideoSampler.framesSync(url, interval: videoInterval, maxPixel: detectSize)
        r.photo.bytes = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if frames.isEmpty && duration > 0 { throw VideoSampler.Unsupported() }
        r.photo.duration = duration
        r.photo.framesSampled = frames.count
        r.tRead = now() - t
        for frame in frames {
            t = now()
            let faces = try FaceDetector.detect(frame.image)
            r.photo.detectWidth = frame.image.width
            r.photo.detectHeight = frame.image.height
            r.photo.longSide = max(frame.image.width, frame.image.height)
            r.tDetect += now() - t
            t = now()
            for f in faces {
                var sf = ScannedFace(photo: i, face: f, time: frame.time)
                if let pts = f.points {
                    r.aligned.append(FaceAligner.align(frame.image, points: pts.map(\.cg)))
                    sf.alignedFrom = r.photo.longSide
                    if let p = FaceAligner.preview(frame.image, rect: f.rect, side: 128) { r.previews.append(p) }
                }
                r.faces.append(sf)
            }
            r.tAlign += now() - t
        }
    }

    var photos: [ScannedPhoto] = []
    var faces: [ScannedFace] = []
    var aligned: [[UInt8]] = []
    var previews: [CGImage] = []
    var sumRead = 0.0, sumDetect = 0.0, sumAlign = 0.0, bytes = 0
    for r in results.compactMap({ $0 }) {
        photos.append(r.photo)
        faces += r.faces
        aligned += r.aligned
        previews += r.previews
        sumRead += r.tRead; sumDetect += r.tDetect; sumAlign += r.tAlign
        bytes += r.photo.bytes
    }
    let errors = photos.filter { $0.error != nil }
    print("""
    detect stage: \(fmt(tDetectStage, 2)) s wall, \(fmt(Double(files.count) / tDetectStage)) photos/s, \
    \(fmt(Double(bytes) / 1e6 / tDetectStage)) MB/s, \(workers) workers
      per photo (cpu-avg): read \(fmt(sumRead / Double(files.count) * 1000, 0)) ms, \
    decode+detect \(fmt(sumDetect / Double(files.count) * 1000, 0)) ms, \
    align \(fmt(sumAlign / Double(files.count) * 1000, 0)) ms
      \(faces.count) faces, \(aligned.count) aligned, \(errors.count) errors
      videos: \(photos.filter(\.isVideo).count), \(fmt(photos.compactMap(\.duration).reduce(0, +))) s of footage, \
    \(photos.compactMap(\.framesSampled).reduce(0, +)) frames sampled
    """)
    for e in errors.prefix(5) { print("  error: \(e.path): \(e.error!)") }

    for (i, p) in previews.enumerated() {
        ImageLoader.writeJPEG(p, to: out.appendingPathComponent("crops/\(i).jpg"))
    }
    if flags.contains("save-aligned") {
        try! FileManager.default.createDirectory(at: out.appendingPathComponent("aligned"), withIntermediateDirectories: true)
        for (i, a) in aligned.enumerated() {
            if let img = FaceAligner.makeImage(a, side: FaceAligner.side) {
                ImageLoader.writeJPEG(img, to: out.appendingPathComponent("aligned/\(i).jpg"))
            }
        }
    }

    var timings: [String: Double] = ["enumerate": tEnum, "detectStage": tDetectStage]
    var dims: [String: Int] = [:]
    for name in modelNames {
        let url = modelsDir.appendingPathComponent("\(name).mlmodelc")
        do {
            var t = now()
            let embedder = try Embedder(name: name, compiledModel: url)
            let tLoad = now() - t
            _ = try embedder.embed(Array(aligned.prefix(32)))  // warm up
            t = now()
            let emb = try embedder.embed(aligned)
            let tEmbed = now() - t
            dims[name] = emb.first?.count ?? 0
            try ScanResult.saveEmbeddings(emb, model: name, dir: out)
            timings["embed_\(name)"] = tEmbed
            print("embed \(name): \(aligned.count) faces in \(fmt(tEmbed, 2)) s = \(fmt(Double(aligned.count) / tEmbed)) faces/s (load \(fmt(tLoad, 2)) s)")
            if flags.contains("flip") {
                // Mirrored crops as a second "model", so test-time flip averaging can be scored offline.
                let side = FaceAligner.side
                let mirrored = aligned.map { c -> [UInt8] in
                    var m = c
                    for y in 0..<side { for x in 0..<side { for k in 0..<4 { m[(y * side + x) * 4 + k] = c[(y * side + side - 1 - x) * 4 + k] } } }
                    return m
                }
                t = now()
                let embF = try embedder.embed(mirrored)
                dims["\(name)_flip"] = embF.first?.count ?? 0
                try ScanResult.saveEmbeddings(embF, model: "\(name)_flip", dir: out)
                print("embed \(name) flipped: \(fmt(now() - t, 2)) s")
            }
        } catch {
            print("embed \(name) failed: \(error)")
        }
    }

    let result = ScanResult(root: target.path, photos: photos, faces: faces, models: dims, timings: timings)
    try! result.save(out)
    print("wrote \(out.path)")
}

// MARK: - cluster

func cluster() {
    let dir = target
    let scan = try! ScanResult.load(dir)
    let model = opts["model"] ?? "ArcFaceR50"
    let minSize = Double(opts["min-size"] ?? "40")!
    let minQuality = Float(opts["min-quality"] ?? "0.3")!
    let emb = try! scan.loadEmbeddings(model: model, dir: dir)

    // Row index of each aligned face in the embedding file == its crop index.
    let alignedFaces = scan.faces.filter { $0.alignedFrom != nil }
    precondition(alignedFaces.count == emb.count, "embedding rows \(emb.count) != aligned faces \(alignedFaces.count)")
    let keep = alignedFaces.indices.filter {
        alignedFaces[$0].face.w >= minSize && (alignedFaces[$0].face.quality ?? 0) >= minQuality
    }
    let x = keep.map { emb[$0] }
    print("\(model): \(keep.count) of \(emb.count) faces pass min-size \(Int(minSize)) px, min-quality \(minQuality)")

    var t = now()
    let sim = Clustering.similarityMatrix(x)
    print("similarity matrix \(keep.count)x\(keep.count) in \(fmt((now() - t) * 1000, 0)) ms")

    func summary(_ labels: [Int]) -> (groups: Int, inGroups: Int, pairs: Int, singles: Int, largest: Int) {
        var counts: [Int: Int] = [:]
        for l in labels { counts[l, default: 0] += 1 }
        let sizes = counts.values
        return (sizes.filter { $0 >= 3 }.count, sizes.filter { $0 >= 3 }.reduce(0, +),
                sizes.filter { $0 == 2 }.count, sizes.filter { $0 == 1 }.count, sizes.max() ?? 0)
    }

    if flags.contains("sweep") {
        print("threshold  groups(>=3)  faces-in-groups  pairs  singles  largest")
        for th in stride(from: Float(0.25), through: 0.701, by: 0.05) {
            let s = summary(Clustering.averageLinkage(similarity: sim, count: keep.count, threshold: th))
            print(String(format: "  %.2f     %6d       %6d (%3.0f%%)  %5d  %6d  %6d", th, s.groups, s.inGroups,
                         100 * Double(s.inGroups) / Double(keep.count), s.pairs, s.singles, s.largest))
        }
    }

    let threshold = Float(opts["threshold"] ?? "0.45")!
    t = now()
    let labels = Clustering.averageLinkage(similarity: sim, count: keep.count, threshold: threshold)
    let tCluster = now() - t
    let s = summary(labels)
    print("threshold \(threshold): \(s.groups) groups with \(s.inGroups) faces, \(s.pairs) pairs, \(s.singles) singles, largest \(s.largest) (\(fmt(tCluster * 1000, 0)) ms)")

    // Report: one row per group, best-quality faces first.
    var groups: [Int: [Int]] = [:]
    for (row, l) in labels.enumerated() { groups[l, default: []].append(row) }
    let ordered = groups.sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
    let reportDir = dir.appendingPathComponent("report_\(model)_\(String(format: "%.2f", threshold))")
    try! FileManager.default.createDirectory(at: reportDir.appendingPathComponent("montage"), withIntermediateDirectories: true)

    var html = """
    <!doctype html><meta charset="utf-8"><title>\(model) @ \(threshold)</title>
    <style>body{font:13px -apple-system;margin:16px;background:#111;color:#ddd}h2{font-size:14px;margin:18px 0 6px}
    img{width:96px;height:96px;margin:1px;border-radius:4px}</style>
    <h1>\(model), threshold \(threshold), \(keep.count) faces</h1>
    <p>\(s.groups) groups (>=3 faces) holding \(s.inGroups) faces; \(s.pairs) pairs; \(s.singles) singles.</p>

    """
    var singles: [Int] = []
    var overview: [Int] = []  // best 3 faces per group, -1 pads
    for (gi, (_, rows)) in ordered.enumerated() {
        if rows.count < 3 { singles += rows; continue }
        let sorted = rows.sorted { (alignedFaces[keep[$0]].face.quality ?? 0) > (alignedFaces[keep[$1]].face.quality ?? 0) }
        overview += sorted.prefix(3).map { keep[$0] } + Array(repeating: -1, count: 3 - min(3, sorted.count))
        html += "<h2>Group \(gi + 1) — \(rows.count) faces</h2>\n"
        for r in sorted {
            let f = alignedFaces[keep[r]]
            let name = (scan.photos[f.photo].path as NSString).lastPathComponent
            html += "<img src=\"../crops/\(keep[r]).jpg\" title=\"\(name) q=\(fmt(Double(f.face.quality ?? 0), 2)) w=\(Int(f.face.w))\">"
        }
        html += "\n"
        writeMontage(sorted.prefix(60).map { keep[$0] }, to: reportDir.appendingPathComponent(String(format: "montage/group_%03d.jpg", gi + 1)))
    }
    html += "<h2>Unassigned (pairs and singles) — \(singles.count) faces</h2>\n"
    for r in singles { html += "<img src=\"../crops/\(keep[r]).jpg\">" }
    try! html.write(to: reportDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    writeMontage(singles.prefix(120).map { keep[$0] }, to: reportDir.appendingPathComponent("montage/unassigned.jpg"))
    // 4 groups per row, 40 groups per sheet.
    for (k, start) in stride(from: 0, to: overview.count, by: 120).enumerated() {
        writeMontage(Array(overview[start..<min(start + 120, overview.count)]),
                     to: reportDir.appendingPathComponent("montage/overview_\(k + 1).jpg"))
    }
    print("wrote \(reportDir.path)/index.html")

    func writeMontage(_ crops: [Int], to url: URL) {
        let tile = 96, cols = 12
        let rows = (crops.count + cols - 1) / cols
        guard rows > 0, let ctx = CGContext(
            data: nil, width: cols * tile, height: rows * tile, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: cols * tile, height: rows * tile))
        for (k, c) in crops.enumerated() where c >= 0 {
            let u = dir.appendingPathComponent("crops/\(c).jpg") as CFURL
            guard let src = CGImageSourceCreateWithURL(u, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            ctx.draw(img, in: CGRect(x: (k % cols) * tile, y: (rows - 1 - k / cols) * tile, width: tile, height: tile))
        }
        if let img = ctx.makeImage() { ImageLoader.writeJPEG(img, to: url) }
    }
}
