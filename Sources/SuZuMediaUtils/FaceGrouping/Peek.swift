import AppKit
import AVKit
import FaceCore
import SwiftUI

/// Space in a grid or list, as Quick Look in the Finder: a look at the tile under the mouse (else the one clicked
/// last, else the first selected), and space again closes it, in a popover: `FacePeek` for faces, `MediaPeek` for
/// photos and videos. Which tile is pointed at lives here, outside SwiftUI's state, so moving the mouse over a grid
/// redraws nothing.
final class Peek<ID: Hashable> {
    private var hovered: ID?
    var clicked: ID?

    func hover(_ id: ID, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    /// The tile space opens, of those in `order` (the grid's).
    func target(selection: Set<ID>, order: [ID]) -> ID? {
        if let hovered, order.contains(hovered) { return hovered }
        if let clicked, order.contains(clicked) { return clicked }
        return order.first { selection.contains($0) }
    }

    /// Space opens and closes `open`; while it is open, ← → step to the tile before or after and esc closes it.
    /// True when the key was used.
    func key(_ e: NSEvent, open: inout PeekState<ID>?, selection: Set<ID>, order: [ID]) -> Bool {
        switch e.keyCode {
        case KeyCode.space:
            if open != nil { open = nil; return true }
            guard let t = target(selection: selection, order: order) else { return false }
            open = PeekState(anchor: t, current: t)
            return true
        case KeyCode.escape:
            guard open != nil else { return false }
            open = nil
            return true
        case KeyCode.left, KeyCode.right:
            guard let o = open, let i = order.firstIndex(of: o.current) else { return false }
            let j = i + (e.keyCode == KeyCode.left ? -1 : 1)
            if order.indices.contains(j) {
                open?.current = order[j]
                // Space next opens where the stepping ended, not the tile the mouse was left on.
                clicked = order[j]
                hovered = nil
            }
            return true
        default:
            return false
        }
    }
}

/// What space has open: the tile the popover hangs from, and the one shown in it. ← → step the shown one along the
/// grid while the popover stays put, as Quick Look's window does (a popover moved to the next tile each time would
/// close and open again, and quick steps lose it).
struct PeekState<ID: Hashable>: Equatable {
    var anchor: ID
    var current: ID
}

extension View {
    /// The popover `Peek` opens from this tile, with `content` for the tile shown in it. Its keys go to `keys` too:
    /// the popover can be the key window, and space there closes it.
    func peekPopover<ID: Hashable, Content: View>(_ id: ID, open: Binding<PeekState<ID>?>, keys: @escaping (NSEvent) -> Bool,
                                                  @ViewBuilder content: @escaping (ID) -> Content) -> some View {
        popover(isPresented: Binding(get: { open.wrappedValue?.anchor == id }, set: { if !$0, open.wrappedValue?.anchor == id { open.wrappedValue = nil } }),
                arrowEdge: .trailing) {
            if let current = open.wrappedValue?.current { content(current).onWindowKeys(keys) }
        }
    }
}

/// A face big enough to check: the small crop at once, then the same framing cut sharp from the original photo or
/// video frame, and the file it is in under it.
struct FacePeek: View {
    let faceId: Int64?
    var title: String?
    @State private var sharp: NSImage?
    @State private var file = " "
    static let side: CGFloat = 360

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let img = sharp ?? faceId.flatMap(Thumbnails.shared.cachedFace) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.crop.square").resizable().foregroundStyle(.tertiary).padding(Self.side / 5)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if let title { Text(title).font(.headline).lineLimit(1) }
            Text(file).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: Self.side)
        .padding(12)
        .task(id: faceId) {
            sharp = nil
            guard let faceId, let found = await Thumbnails.shared.closeUp(faceId, side: Int(Self.side * 2)) else { return }
            guard !Task.isCancelled else { return }
            sharp = found.image
            file = URL(fileURLWithPath: found.path, isDirectory: false).lastPathComponent
                + (found.time.map { " at " + MediaThumbnail.timecode($0) } ?? "")
        }
    }
}

/// A photo or video big enough to check: the thumbnail at once, then a sharper decode; a video plays. Edit opens a
/// photo in Edit & Export, Copy Path copies the full path (Quick Look's own window can't have these buttons).
struct MediaPeek: View {
    let url: URL
    /// The library's id for the file, so its thumbnail shows at once.
    var mediaId: Int64?
    /// For a video, where to start (where the person is).
    var time: Double?
    /// The person's face in the photo, so Edit & Export keeps them in frame.
    var faceId: Int64?
    @Environment(\.openWindow) private var openWindow
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    static let box = CGSize(width: 640, height: 480)

    var isVideo: Bool { MediaAnalyzer.isVideo(url) }

    /// The picture's size, fitted in `box` (the box itself until there is a picture).
    var size: CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return Self.box }
        let scale = min(Self.box.width / image.size.width, Self.box.height / image.size.height)
        return CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(width: isVideo ? Self.box.width : size.width, height: isVideo ? Self.box.height * 0.75 : size.height)
            .background(Color.black.opacity(player == nil ? 0 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Text(url.lastPathComponent + (isVideo ? time.map { " at " + MediaThumbnail.timecode($0) } ?? "" : ""))
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                CopyPathButton(path: url.path, what: isVideo ? "video" : "photo")
                if !isVideo {
                    Button {
                        openWindow.edit([url.path], faces: faceId.map { [url.path: $0] } ?? [:])
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Open in Edit & Export")
                }
            }
        }
        .frame(width: Self.box.width)
        .padding(12)
        .task(id: url) {
            player?.pause()
            player = nil
            image = nil
            if isVideo {
                let p = AVPlayer(url: url)
                if let time { await p.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
                guard !Task.isCancelled else { return }
                player = p
                p.play()
                return
            }
            image = await Thumbnails.shared.media(url, id: mediaId, time: nil, side: 176)
            let sharp = await Task.detached(priority: .userInitiated) { [url] in MediaAnalyzer.displayThumbnail(url, maxPixel: 1600) }.value
            if let sharp, !Task.isCancelled { image = NSImage(cgImage: sharp, size: .zero) }
        }
        .onDisappear { player?.pause() }
    }
}
