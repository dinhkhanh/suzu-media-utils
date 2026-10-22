import CoreGraphics
import Foundation
import ImageIO

/// A detected face, aligned for embedding, with a small preview for the UI.
public struct AnalyzedFace {
    public var face: DetectedFace
    /// Video timestamp in seconds; nil for photos.
    public var time: Double?
    /// 112x112 RGBA8 ArcFace crop; nil when landmarks were missing.
    public var aligned: [UInt8]?
    public var preview: CGImage?
}

public struct AnalyzedMedia {
    /// Size of the image (or video frame) the face coordinates refer to.
    public var width = 0
    public var height = 0
    public var duration: Double?
    public var framesSampled: Int?
    public var faces: [AnalyzedFace] = []
}

public enum MediaAnalyzer {
    public static let detectSize = 1500
    public static let previewSize = 160

    public static func isVideo(_ url: URL) -> Bool {
        VideoSampler.extensions.contains(url.pathExtension.lowercased())
    }

    public static func analyze(_ url: URL, videoInterval: Double = 1) throws -> AnalyzedMedia {
        isVideo(url) ? try analyzeVideo(url, interval: videoInterval) : try analyzePhoto(url)
    }

    public static func analyzePhoto(_ url: URL) throws -> AnalyzedMedia {
        let (src, _) = try ImageLoader.source(url)
        guard let image = ImageLoader.decode(src, maxPixel: detectSize) else { throw CocoaError(.fileReadCorruptFile) }
        var out = AnalyzedMedia(width: image.width, height: image.height)
        out.faces = try faces(in: image, time: nil)
        return out
    }

    public static func analyzeVideo(_ url: URL, interval: Double) throws -> AnalyzedMedia {
        let (duration, frames) = try VideoSampler.framesSync(url, interval: interval, maxPixel: detectSize)
        var out = AnalyzedMedia(duration: duration, framesSampled: frames.count)
        for frame in frames {
            out.width = frame.image.width
            out.height = frame.image.height
            out.faces += try faces(in: frame.image, time: frame.time)
        }
        return out
    }

    static func faces(in image: CGImage, time: Double?) throws -> [AnalyzedFace] {
        try FaceDetector.detect(image).map { f in
            AnalyzedFace(
                face: f, time: time,
                aligned: f.points.map { FaceAligner.align(image, points: $0.map(\.cg)) },
                preview: FaceAligner.preview(image, rect: f.rect, side: previewSize))
        }
    }
}

extension MediaAnalyzer {
    /// JPEG of the area around one face, cut from a sharp decode of the original (not the small preview), for
    /// sending to a recognition service. `box` is normalized, top-left origin; `time` selects the video frame.
    public static func faceContextJPEG(_ url: URL, box: CGRect, time: Double?, maxSide: Int = 640) -> Data? {
        let image: CGImage?
        if isVideo(url) {
            image = VideoSampler.frameSync(url, at: time ?? 0, maxPixel: 3000)
        } else if let (src, _) = try? ImageLoader.source(url) {
            image = ImageLoader.decode(src, maxPixel: min(3000, max(1, ImageLoader.pixelLongSide(src))))
        } else {
            image = nil
        }
        guard let image else { return nil }
        let W = Double(image.width), H = Double(image.height)
        let face = CGRect(x: box.minX * W, y: box.minY * H, width: box.width * W, height: box.height * H)
        // Head and shoulders: a square 2.2x the face box, centred on the face.
        let out = min(maxSide, max(80, Int(max(face.width, face.height) * 2.2)))
        guard let crop = FaceAligner.preview(image, rect: face, side: out, pad: 0.6) else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, crop, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dst)
        return data as Data
    }
}
