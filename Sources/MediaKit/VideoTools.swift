import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import FaceCore
import Foundation
import ImageIO

/// Clips, highlight reels, proxies, contact sheets and stills from videos.
public enum VideoTools {
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// Merges face sample times (1 per second) into on-screen segments, padded so clips don't start mid-word.
    public static func segments(times: [Double], duration: Double, gap: Double = 2.5, pad: Double = 1.0, minLength: Double = 1.5) -> [Segment] {
        var out: [Segment] = []
        for t in times.sorted() {
            if let last = out.last, t - last.end <= gap { out[out.count - 1].end = t } else { out.append(Segment(start: t, end: t)) }
        }
        return out.map { Segment(start: max(0, $0.start - pad), end: min(duration > 0 ? duration : .infinity, $0.end + pad)) }
            .filter { $0.duration >= minLength }
    }

    static func needsFFmpeg(_ url: URL) -> Bool { !["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) }

    /// One segment without re-encoding (cuts land on the nearest keyframes).
    public static func exportClip(_ url: URL, segment: Segment, to dest: URL) async throws {
        if needsFFmpeg(url) {
            guard let ff = FFmpeg.ffmpegPath else { throw VideoSampler.Unsupported() }
            _ = try FFmpeg.run(ff, ["-v", "error", "-nostdin", "-y", "-ss", String(segment.start), "-to", String(segment.end),
                                    "-i", url.path, "-c", "copy", dest.path])
            return
        }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
        session.timeRange = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600),
                                        end: CMTime(seconds: segment.end, preferredTimescale: 600))
        try? FileManager.default.removeItem(at: dest)
        try await session.export(to: dest, as: dest.pathExtension.lowercased() == "mov" ? .mov : .mp4)
    }

    /// Several segments from several videos joined into one re-encoded HEVC movie.
    public static func exportReel(_ parts: [(url: URL, segment: Segment)], to dest: URL) async throws {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileWriteUnknown) }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var transformSet = false
        for p in parts where !needsFFmpeg(p.url) {
            let asset = AVURLAsset(url: p.url)
            let range = CMTimeRange(start: CMTime(seconds: p.segment.start, preferredTimescale: 600),
                                    end: CMTime(seconds: p.segment.end, preferredTimescale: 600))
            guard let sv = try await asset.loadTracks(withMediaType: .video).first else { continue }
            try vTrack.insertTimeRange(range, of: sv, at: cursor)
            if !transformSet { vTrack.preferredTransform = try await sv.load(.preferredTransform); transformSet = true }
            if let sa = try await asset.loadTracks(withMediaType: .audio).first { try? aTrack?.insertTimeRange(range, of: sa, at: cursor) }
            cursor = cursor + range.duration
        }
        guard cursor > .zero, let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: dest)
        try await session.export(to: dest, as: .mov)
    }

    /// A smaller copy for quick review and editing (720p H.264; ffmpeg for formats AVFoundation can't read).
    public static func proxy(_ url: URL, to dest: URL) async throws {
        if needsFFmpeg(url) {
            guard let ff = FFmpeg.ffmpegPath else { throw VideoSampler.Unsupported() }
            _ = try FFmpeg.run(ff, ["-v", "error", "-nostdin", "-y", "-i", url.path, "-vf", "scale=-2:720", "-c:v", "h264_videotoolbox",
                                    "-b:v", "5M", "-c:a", "aac", dest.path])
            return
        }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPreset1280x720) else { throw CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: dest)
        try await session.export(to: dest, as: .mp4)
    }

    /// A grid of evenly spaced frames with timestamps: a one-page overview of a clip.
    public static func contactSheet(_ url: URL, columns: Int = 4, rows: Int = 4, width: Int = 2000, to dest: URL) throws {
        let duration = FFmpeg.duration(url) ?? avDuration(url)
        guard duration > 0 else { throw VideoSampler.Unsupported() }
        let n = columns * rows
        let cellW = width / columns
        let frames: [(Double, CGImage?)] = (0..<n).map { i in
            let t = duration * (Double(i) + 0.5) / Double(n)
            return (t, VideoSampler.frameSync(url, at: t, maxPixel: cellW * 2))
        }
        let aspect = frames.compactMap(\.1).first.map { Double($0.height) / Double($0.width) } ?? 9.0 / 16
        let cellH = Int(Double(cellW) * aspect)
        let header = 70
        let H = header + rows * cellH
        let ctx = CGContext(data: nil, width: width, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: H))
        drawText(ctx, "\(url.lastPathComponent)  ·  \(timecode(duration))", at: CGPoint(x: 20, y: H - 46), size: 28, color: CGColor(gray: 1, alpha: 1))
        for (i, (t, img)) in frames.enumerated() {
            let x = (i % columns) * cellW, y = H - header - (i / columns + 1) * cellH
            let rect = CGRect(x: x + 2, y: y + 2, width: cellW - 4, height: cellH - 4)
            if let img { ctx.draw(img, in: rect) }
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 110, height: 32))
            drawText(ctx, timecode(t), at: CGPoint(x: rect.minX + 10, y: rect.minY + 8), size: 20, color: CGColor(gray: 1, alpha: 1))
        }
        ImageLoader.writeJPEG(ctx.makeImage()!, to: dest, quality: 0.85)
    }

    /// A still frame through an edit recipe (auto tone, crop, watermark…).
    public static func still(_ url: URL, at time: Double, recipe: EditRecipe, focus: FocusHint?, people: [String], to dest: URL) throws {
        guard let frame = VideoSampler.frameSync(url, at: time, maxPixel: 4000) else { throw VideoSampler.Unsupported() }
        let image = try EditPipeline.apply(recipe, to: CIImage(cgImage: frame), focus: focus)
        guard let cg = EditPipeline.context.createCGImage(image, from: image.extent) else { throw CocoaError(.fileWriteUnknown) }
        try EditPipeline.writeJPEG(cg, to: dest, quality: recipe.jpegQuality, sourceProperties: nil, people: recipe.writePeopleNames ? people : [])
    }

    static func avDuration(_ url: URL) -> Double {
        let sem = DispatchSemaphore(value: 0)
        var d = 0.0
        Task { d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0; sem.signal() }
        sem.wait()
        return d
    }

    public static func timecode(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func drawText(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font,
                                                                  .init(kCTForegroundColorAttributeName as String): color])
        ctx.textPosition = p
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    }
}
