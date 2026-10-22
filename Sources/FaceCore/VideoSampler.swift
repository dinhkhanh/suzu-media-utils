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

    // The synchronous functions below use AVFoundation's callback APIs, never Swift concurrency. Waiting on a Task
    // from code that is itself on Swift's cooperative pool deadlocks once every pool thread is waiting (a grid of
    // video thumbnails did exactly that and froze search); callbacks don't need the pool, so these are safe anywhere.

    /// Upright frames every `interval` seconds, long side capped at `maxPixel`, via AVFoundation. A loose time
    /// tolerance lets the decoder return the nearest cheap frame instead of decoding forward from a keyframe.
    static func avFrames(_ url: URL, interval: Double, maxPixel: Int) throws -> (duration: Double, frames: [Frame]) {
        let asset = AVURLAsset(url: url)
        let duration = try loadDuration(asset)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        let times = stride(from: min(interval / 2, duration / 2), to: duration, by: interval)
            .map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        guard !times.isEmpty else { return (duration, []) }
        let lock = NSLock()
        let sem = DispatchSemaphore(value: 0)
        var out: [Frame] = []
        var remaining = times.count
        gen.generateCGImagesAsynchronously(forTimes: times) { _, image, actual, result, _ in
            lock.lock()
            if result == .succeeded, let image { out.append(Frame(time: actual.seconds, image: image)) }
            remaining -= 1
            let finished = remaining == 0
            lock.unlock()
            if finished { sem.signal() }
        }
        sem.wait()
        return (duration, out.sorted { $0.time < $1.time })
    }

    /// Frames for worker threads. Falls back to ffmpeg when AVFoundation can't decode the file.
    public static func framesSync(_ url: URL, interval: Double, maxPixel: Int) throws -> (duration: Double, frames: [Frame]) {
        let result = Result { try avFrames(url, interval: interval, maxPixel: maxPixel) }
        if case .success(let r) = result, !r.frames.isEmpty { return r }
        if FFmpeg.isAvailable { return try FFmpeg.frames(url, interval: interval, maxPixel: maxPixel) }
        if case .success(let r) = result, r.duration > 0 { throw Unsupported() }
        return try result.get()
    }

    static func load(_ object: AVAsynchronousKeyValueLoading, _ key: String) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        object.loadValuesAsynchronously(forKeys: [key]) { sem.signal() }
        sem.wait()
        var error: NSError?
        return object.statusOfValue(forKey: key, error: &error) == .loaded
    }

    static func loadDuration(_ asset: AVURLAsset) throws -> Double {
        guard load(asset, "duration"), let t = (asset.value(forKey: "duration") as? NSValue)?.timeValue else { throw Unsupported() }
        return t.seconds.isFinite ? t.seconds : 0
    }

    /// Duration in seconds via AVFoundation; 0 when it can't read the file.
    public static func duration(_ url: URL) -> Double { (try? loadDuration(AVURLAsset(url: url))) ?? 0 }

    /// Recording date from the file's metadata, else its modification date.
    public static func recordingDate(_ url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        var date: Date?
        if load(asset, "creationDate"), let item = asset.value(forKey: "creationDate") as? AVMetadataItem, load(item, "dateValue") {
            date = item.value(forKey: "dateValue") as? Date
        }
        return date ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    /// One upright frame near `time`, via AVFoundation or ffmpeg.
    public static func frameSync(_ url: URL, at time: Double, maxPixel: Int) -> CGImage? {
        let gen = generator(url, maxPixel: maxPixel)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var image: CGImage?
        gen.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { cg, _, _ in
            image = cg
            sem.signal()
        }
        sem.wait()
        return image ?? FFmpeg.frame(url, at: time, maxPixel: maxPixel)
    }

    /// One upright frame near `time` via AVFoundation, for async callers (nil when it can't decode the file).
    public static func frame(_ url: URL, at time: Double, maxPixel: Int) async -> CGImage? {
        try? await generator(url, maxPixel: maxPixel).image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    static func generator(_ url: URL, maxPixel: Int) -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return gen
    }
}
