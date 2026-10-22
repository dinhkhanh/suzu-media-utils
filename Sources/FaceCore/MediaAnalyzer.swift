import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A detected face, aligned for embedding, with a small preview for the UI.
public struct AnalyzedFace {
    public var face: DetectedFace
    /// Video timestamp in seconds; nil for photos.
    public var time: Double?
    /// 112x112 RGBA8 ArcFace crop; nil when landmarks were missing.
    public var aligned: [UInt8]?
    public var preview: CGImage?
    /// Variance of the Laplacian on the aligned crop (higher = sharper); nil without an aligned crop.
    public var sharpness: Double?
}

public struct AnalyzedMedia {
    /// Size of the image (or video frame) the face coordinates refer to.
    public var width = 0
    public var height = 0
    public var duration: Double?
    public var framesSampled: Int?
    public var faces: [AnalyzedFace] = []
    /// EXIF capture time (photos) or recording date (videos).
    public var takenAt: Date?
    /// Vision image feature print of the whole photo, for finding near-identical shots (bursts).
    public var featurePrint: [Float]?
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
        out.takenAt = ImageLoader.captureDate(src)
        // No feature print here: it would cost ~45% of ingest speed. Bursts get theirs in an idle-time pass.
        return out
    }

    /// Feature print from the small preview embedded in the file (only the start of the file is read), falling
    /// back to a quick 1/8-scale decode. For burst detection, which only compares near-identical frames.
    public static func quickFeaturePrint(_ url: URL) -> [Float]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return featurePrint(thumb)
    }

    /// Whole-image feature print (Vision, runs on the Neural Engine).
    public static func featurePrint(_ image: CGImage) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let fp = req.results?.first, fp.elementType == .float else { return nil }
        return fp.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Variance of a 3x3 Laplacian over the grey 112x112 aligned crop: a standard focus measure.
    public static func sharpness(_ rgba: [UInt8], side: Int = FaceAligner.side) -> Double {
        var grey = [Double](repeating: 0, count: side * side)
        for i in 0..<(side * side) {
            grey[i] = 0.299 * Double(rgba[i * 4]) + 0.587 * Double(rgba[i * 4 + 1]) + 0.114 * Double(rgba[i * 4 + 2])
        }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let c = y * side + x
                let l = grey[c - 1] + grey[c + 1] + grey[c - side] + grey[c + side] - 4 * grey[c]
                sum += l; sumSq += l * l; n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    public static func analyzeVideo(_ url: URL, interval: Double) throws -> AnalyzedMedia {
        let (duration, frames) = try VideoSampler.framesSync(url, interval: interval, maxPixel: detectSize)
        var out = AnalyzedMedia(duration: duration, framesSampled: frames.count)
        out.takenAt = VideoSampler.recordingDate(url)
        for frame in frames {
            out.width = frame.image.width
            out.height = frame.image.height
            out.faces += try faces(in: frame.image, time: frame.time)
        }
        return out
    }

    static func faces(in image: CGImage, time: Double?) throws -> [AnalyzedFace] {
        try FaceDetector.detect(image).map { f in
            let aligned = f.points.map { FaceAligner.align(image, points: $0.map(\.cg)) }
            return AnalyzedFace(
                face: f, time: time, aligned: aligned,
                preview: FaceAligner.preview(image, rect: f.rect, side: previewSize),
                sharpness: aligned.map { sharpness($0) })
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
