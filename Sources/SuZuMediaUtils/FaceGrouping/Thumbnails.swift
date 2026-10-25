import AppKit
import FaceCore
import FaceLibrary
import GRDB
import QuickLookThumbnailing
import SwiftUI

/// In-memory cache for face crops (small files written by the processor) and file thumbnails.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    private let videoSlots = AsyncLimiter(4)

    init() { cache.countLimit = 4000 }

    func cachedFace(_ id: Int64) -> NSImage? { cache.object(forKey: "f\(id)" as NSString) }

    func face(_ id: Int64, store: URL) -> NSImage? {
        let key = "f\(id)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let img = NSImage(contentsOf: store.appendingPathComponent("\(id).jpg")) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// The library, for its thumbnail files (set when it opens).
    var store: LibraryStore?
    private let diskSlots = AsyncLimiter(6)

    /// A file's thumbnail, the way the Finder shows one: from memory, else from the library's thumbnail file
    /// (made when the file was processed, or by the idle-time pass), else made now and kept. For videos with a
    /// `time`, the frame there (where the person is); the file's own thumbnail is the frame a moment in.
    ///
    /// A file given without its library id (the editor's strip and grid) is looked up by path, so a library file
    /// shows its thumbnail file (local, milliseconds) instead of being read off the NAS and decoded again. A still
    /// thumbnail is kept once for every size it is shown at (the library's is 400 px).
    func media(_ url: URL, id: Int64? = nil, time: Double?, side: CGFloat) async -> NSImage? {
        let still = "\(url.path)#still" as NSString
        if time == nil, let img = cache.object(forKey: still) { return img }
        let key = "\(url.path)#\(time ?? -1)#\(Int(side))" as NSString
        if let img = cache.object(forKey: key) { return img }
        var id = id
        if id == nil, time == nil, let store {
            let path = url.path
            id = await Task.detached(priority: .userInitiated) {
                try? store.db.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(duplicateOf, id) FROM media WHERE path = ?", arguments: [path]) }
            }.value ?? nil
        }
        var image: NSImage?
        let wantsFrame = time != nil && !(time == 0 && id != nil)
        if let id, let store, !wantsFrame {
            // The library's thumbnail: a small local file, read off the main thread, a few at a time.
            await diskSlots.acquire()
            defer { Task { await self.diskSlots.release() } }
            guard !Task.isCancelled else { return nil }
            let thumb = store.thumbnailURL(id)
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: thumb) }.value
            if image == nil, !Task.isCancelled {
                // Not made yet (an older library, a file that just arrived): the camera's own thumbnail at once
                // (a few KB read, no decode); the idle-time pass makes and keeps the proper one.
                let made = await Task.detached(priority: .userInitiated) { MediaAnalyzer.thumbnail(url, quick: true) }.value
                image = made.map { NSImage(cgImage: $0, size: .zero) }
            }
        } else if let time {
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
            // A file outside the library (a tool given files): a reduced decode, not Quick Look's full one.
            await diskSlots.acquire()
            defer { Task { await self.diskSlots.release() } }
            guard !Task.isCancelled else { return nil }
            let made = await Task.detached(priority: .userInitiated) { MediaAnalyzer.displayThumbnail(url, maxPixel: max(400, Int(side * 2))) }.value
            image = made.map { NSImage(cgImage: $0, size: .zero) }
        }
        if let image {
            cache.setObject(image, forKey: key)
            // The library's thumbnail serves every size; so does a decode at the usual 400 px.
            if time == nil, id != nil || side <= 200 { cache.setObject(image, forKey: still) }
        }
        return image
    }

    /// A face sharp enough to check (the crops are small): the crop's framing cut from the original photo or video
    /// frame, with the file it is in and where in a video. Kept, so stepping back to a face is instant.
    func closeUp(_ faceId: Int64, side: Int) async -> (image: NSImage?, path: String, time: Double?)? {
        guard let store else { return nil }
        let found = await Task.detached(priority: .userInitiated) { () -> (path: String, box: CGRect, time: Double?)? in
            let row = try? store.db.read { db in
                try Row.fetchOne(db, sql: "SELECT m.path, f.x, f.y, f.w, f.h, f.time FROM face f JOIN media m ON m.id = f.mediaId WHERE f.id = ?",
                                 arguments: [faceId])
            }
            guard let row = row ?? nil else { return nil }
            let x: Double = row["x"], y: Double = row["y"], w: Double = row["w"], h: Double = row["h"]
            return (row["path"], CGRect(x: x, y: y, width: w, height: h), row["time"])
        }.value
        guard let (path, box, time) = found else { return nil }
        let key = "c\(faceId)#\(side)" as NSString
        if let img = cache.object(forKey: key) { return (img, path, time) }
        let made = await Task.detached(priority: .userInitiated) {
            MediaAnalyzer.faceContext(URL(fileURLWithPath: path, isDirectory: false), box: box, time: time, maxSide: side, pad: 0.35)
        }.value
        let image = made.map { NSImage(cgImage: $0, size: .zero) }
        if let image { cache.setObject(image, forKey: key) }
        return (image, path, time)
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
    @State private var loaded: NSImage?

    /// A crop already in memory draws at once; one that isn't is read off the main thread, so a grid of hundreds
    /// of people scrolls without waiting on the disk for each tile.
    var cached: NSImage? {
        guard let id = faceId else { return nil }
        return Thumbnails.shared.cachedFace(id)
    }

    var body: some View {
        Group {
            if let img = cached ?? loaded {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.square").resizable().foregroundStyle(.tertiary).padding(side / 5)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: faceId) {
            loaded = nil
            guard let id = faceId, cached == nil, let dir = model.store?.facesDirectory else { return }
            let img = await Task.detached(priority: .userInitiated) { Thumbnails.shared.face(id, store: dir) }.value
            if !Task.isCancelled { loaded = img }
        }
    }
}

extension Set {
    /// A click in a grid: ⌘-click adds or removes, ⇧-click selects everything from the selection to this one (in
    /// `order`, the grid's order; ⇧⌘-click adds that range), a plain click selects just this one.
    mutating func click(_ e: Element, in order: [Element] = []) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), order.contains(e) {
            if !mods.contains(.command), let range = rangeExtended(to: e, in: order) { self = Set(order[range]) } else { extend(to: e, in: order) }
        } else if mods.contains(.command) || mods.contains(.shift) {
            if contains(e) { remove(e) } else { insert(e) }
        } else {
            self = [e]
        }
    }

    /// Adds the stretch of `order` between the selection and `e`: from the first selected item when `e` is inside or
    /// after the selection, up to the last selected one when it comes before. Just `e` when nothing is selected.
    mutating func extend(to e: Element, in order: [Element]) {
        guard let range = rangeExtended(to: e, in: order) else { insert(e); return }
        formUnion(order[range])
    }

    func rangeExtended(to e: Element, in order: [Element]) -> ClosedRange<Int>? {
        guard let i = order.firstIndex(of: e) else { return nil }
        let picked = order.indices.filter { contains(order[$0]) }
        guard let lo = picked.min(), let hi = picked.max() else { return i...i }
        return i < lo ? i...hi : lo...i
    }
}

extension View {
    /// A click in a grid that shows at once, and a double-click. Every click runs `click` (the second of a
    /// double-click too, so a tick-on-click grid ends where it started); the second also runs `double`. Not
    /// `onTapGesture(count: 2)` beside a plain tap: SwiftUI then holds every click until the double-click time has
    /// passed, and the selection ring came late.
    func onClick(_ click: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        onTapGesture {
            click()
            if (NSApp.currentEvent?.clickCount ?? 1) == 2 { double() }
        }
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
            image = await Thumbnails.shared.media(item.url, id: item.id, time: item.kind == .video ? (item.time ?? 0) : nil, side: side)
        }
    }

    static func timecode(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
