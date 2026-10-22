import AVFoundation
import CoreGraphics
import Foundation

public enum VideoSampler {
    public static let extensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "3gp", "wmv", "flv", "mts", "m2ts"]

    /// No frame could be decoded by AVFoundation (e.g. AV1 on M1/M2, WebM) and ffmpeg is not installed.
    public struct Unsupported: Error, CustomStringConvertible, LocalizedError {
        public init() {}
        public var description: String { "unsupported video format — install ffmpeg (brew install ffmpeg) to read it" }
        public var errorDescription: String? { description }
    }

    public struct Frame {
        public var time: Double
        public var image: CGImage
    }

    /// Upright frames every `interval` seconds, long side capped at `maxPixel`. A loose time tolerance lets
    /// the decoder return the nearest cheap frame instead of decoding forward from a keyframe to an exact time.
    public static func frames(_ url: URL, interval: Double, maxPixel: Int) async throws -> (duration: Double, frames: [Frame]) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        let times = stride(from: min(interval / 2, duration / 2), to: duration, by: interval)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }
        var out: [Frame] = []
        for await result in gen.images(for: times) {
            if case .success(_, let image, let actual) = result {
                out.append(Frame(time: actual.seconds, image: image))
            }
        }
        return (duration, out)
    }

    /// Synchronous wrapper for worker threads. Falls back to ffmpeg when AVFoundation can't decode the file.
    public static func framesSync(_ url: URL, interval: Double, maxPixel: Int) throws -> (duration: Double, frames: [Frame]) {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(duration: Double, frames: [Frame]), Error>!
        Task {
            do { result = .success(try await frames(url, interval: interval, maxPixel: maxPixel)) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        if case .success(let r) = result, !r.frames.isEmpty { return r }
        if FFmpeg.isAvailable { return try FFmpeg.frames(url, interval: interval, maxPixel: maxPixel) }
        if case .success(let r) = result, r.duration > 0 { throw Unsupported() }
        return try result.get()
    }

    /// One upright frame near `time`, via AVFoundation or ffmpeg.
    public static func frameSync(_ url: URL, at time: Double, maxPixel: Int) -> CGImage? {
        let sem = DispatchSemaphore(value: 0)
        var image: CGImage?
        Task {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            image = try? await gen.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            sem.signal()
        }
        sem.wait()
        return image ?? FFmpeg.frame(url, at: time, maxPixel: maxPixel)
    }
}
