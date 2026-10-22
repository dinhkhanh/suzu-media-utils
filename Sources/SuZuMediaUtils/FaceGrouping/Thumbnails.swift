import AppKit
import FaceCore
import QuickLookThumbnailing
import SwiftUI

/// In-memory cache for face crops (small files written by the processor) and file thumbnails.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    private let videoSlots = AsyncLimiter(4)

    init() { cache.countLimit = 4000 }

    func face(_ id: Int64, store: URL) -> NSImage? {
        let key = "f\(id)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let img = NSImage(contentsOf: store.appendingPathComponent("\(id).jpg")) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Photo thumbnail via Quick Look; for videos, the frame at `time` (where the person is).
    func media(_ url: URL, time: Double?, side: CGFloat) async -> NSImage? {
        let key = "\(url.path)#\(time ?? -1)#\(Int(side))" as NSString
        if let img = cache.object(forKey: key) { return img }
        var image: NSImage?
        if let time {
            // A grid can ask for hundreds of video frames at once: decode a few at a time, and skip cells that
            // scrolled away (their task is cancelled) instead of decoding frames nobody will see.
            await videoSlots.acquire()
            defer { Task { await videoSlots.release() } }
            guard !Task.isCancelled else { return nil }
            var cg = await VideoSampler.frame(url, at: time, maxPixel: Int(side * 2))
            if cg == nil, FFmpeg.isAvailable, !Task.isCancelled {
                cg = await Task.detached(priority: .utility) { FFmpeg.frame(url, at: time, maxPixel: Int(side * 2)) }.value
            }
            image = cg.map { NSImage(cgImage: $0, size: .zero) }
        } else {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                                                   representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// At most `limit` holders at a time; others wait their turn without blocking a thread.
actor AsyncLimiter {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ limit: Int) { free = limit }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

struct FaceImage: View {
    @EnvironmentObject var model: FaceGroupingModel
    let faceId: Int64?
    var side: CGFloat = 96

    var body: some View {
        Group {
            if let id = faceId, let dir = model.store?.facesDirectory, let img = Thumbnails.shared.face(id, store: dir) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.square").resizable().foregroundStyle(.tertiary).padding(side / 5)
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

struct MediaThumbnail: View {
    let item: PersonMedia
    var side: CGFloat = 180
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
            if item.kind == .video {
                // Play button in the middle, timestamp of the person's best frame in the corner.
                Image(systemName: "play.circle.fill")
                    .font(.system(size: side * 0.24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let t = item.time {
                    Text(Self.timecode(t))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item.id) {
            image = await Thumbnails.shared.media(item.url, time: item.kind == .video ? (item.time ?? 0) : nil, side: side)
        }
    }

    static func timecode(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
