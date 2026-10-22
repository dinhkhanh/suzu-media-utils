import CoreGraphics
import Foundation
import ImageIO

/// Fallback decoder for videos AVFoundation can't open (AV1 on M1/M2, WebM, MKV, AVI…). Uses an ffmpeg binary
/// installed with Homebrew; nothing is bundled.
public enum FFmpeg {
    public static let ffmpegPath: String? = find("ffmpeg")
    public static let ffprobePath: String? = find("ffprobe")
    public static var isAvailable: Bool { ffmpegPath != nil }

    static func find(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a tool and returns stdout; throws with stderr on failure.
    public static func run(_ path: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "FFmpeg", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errData, as: UTF8.self)
                              .trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return data
    }

    public static func duration(_ url: URL) -> Double? {
        guard let probe = ffprobePath,
              let out = try? run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        else { return nil }
        return Double(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One upright frame every `interval` seconds, long side at most `maxPixel`.
    public static func frames(_ url: URL, interval: Double, maxPixel: Int) throws -> (duration: Double, frames: [VideoSampler.Frame]) {
        guard let ffmpeg = ffmpegPath else { throw VideoSampler.Unsupported() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fg-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scale = "scale='if(gt(iw,ih),min(\(maxPixel),iw),-2)':'if(gt(iw,ih),-2,min(\(maxPixel),ih))'"
        _ = try run(ffmpeg, ["-v", "error", "-nostdin", "-i", url.path,
                             "-vf", "fps=1/\(interval),\(scale)", "-q:v", "3", dir.appendingPathComponent("%06d.jpg").path])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }.sorted()
        let frames: [VideoSampler.Frame] = files.enumerated().compactMap { i, name in
            // Decode now: a lazily decoded CGImage would read its file after the temp folder is gone.
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            return VideoSampler.Frame(time: Double(i) * interval, image: img)
        }
        return (duration(url) ?? Double(frames.count) * interval, frames)
    }

    /// A single frame near `time` (thumbnails, crops).
    public static func frame(_ url: URL, at time: Double, maxPixel: Int) -> CGImage? {
        guard let ffmpeg = ffmpegPath else { return nil }
        let scale = "scale='if(gt(iw,ih),min(\(maxPixel),iw),-2)':'if(gt(iw,ih),-2,min(\(maxPixel),ih))'"
        guard let data = try? run(ffmpeg, ["-v", "error", "-nostdin", "-ss", String(format: "%.2f", time), "-i", url.path,
                                           "-frames:v", "1", "-vf", scale, "-f", "image2pipe", "-vcodec", "mjpeg", "-"]),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
