import AVKit
import FaceCore
import FaceLibrary
import ImageIO
import SwiftUI

/// Files to cull, in the order they were shown, and the one to start at.
struct CullRequest: Codable, Hashable {
    var ids: [Int64]
    var start: Int64?
    var title: String
}

/// Culling, full screen: one photo at a time with the keys photographers know from Lightroom (← → to move, 0-5
/// stars, 6-9 labels, P pick, X reject, U unflag). Faces are boxed and named, with their crops at full resolution
/// under the photo to check focus and eyes; Z zooms to 100% on a face. Marks are saved as they're made.
struct CullWindow: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    let request: CullRequest?
    @State private var files: [ProjectFile] = []
    @State private var index = 0
    /// Screen-sized images of the current photo and its neighbours.
    @State private var images: [Int64: NSImage] = [:]
    @State private var faces: [MediaFace] = []
    /// The current photo at full resolution, and its faces cut out of it.
    @State private var full: CGImage?
    @State private var crops: [Int64: NSImage] = [:]
    /// The face shown at 100% instead of the whole photo.
    @State private var zoom: MediaFace?
    @State private var player: AVPlayer?
    @AppStorage("cull.info") private var showInfo = true
    @AppStorage("cull.advance") private var autoAdvance = true
    @Environment(\.displayScale) private var displayScale

    var current: ProjectFile? { files.indices.contains(index) ? files[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            if let f = current { topBar(f) }
            stage.frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInfo, current?.kind == .photo, !crops.isEmpty { faceStrip }
            filmstrip
            Text("← →  move    0–5  stars    6–9  labels    P  pick    X  reject    U  unflag    Z  zoom to face    I  faces    Esc  close")
                .font(.caption).foregroundStyle(.tertiary).padding(.bottom, 6)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .navigationTitle("Cull · \(request?.title ?? "")")
        .onWindowKeys(key)
        .background(FullScreenOnOpen())
        .task(id: request) { await load() }
        .task(id: current?.id) { await show() }
        .onDisappear { player?.pause() }
    }

    func topBar(_ f: ProjectFile) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.headline).lineLimit(1)
                Text(([("\(index + 1) of \(files.count)")]
                      + [f.takenAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) }, f.people.isEmpty ? nil : f.people.joined(separator: ", ")]
                        .compactMap { $0 })
                    .joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) { HintLabels(file: f) }.font(.caption)
            Spacer(minLength: 10)
            StarsView(rating: f.rating, size: 17) { apply(.rating($0)) }
            HStack(spacing: 6) {
                ForEach(ColorLabel.allCases, id: \.self) { l in
                    Circle().fill(l.color).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: f.label == l ? 2 : 0))
                        .opacity(f.label == nil || f.label == l ? 1 : 0.45)
                        .onTapGesture { apply(.label(f.label == l ? nil : l)) }
                        .help(l.key.map { "\(l.title) (\($0))" } ?? l.title)
                }
            }
            Button { apply(.flag(f.flag == .pick ? .none : .pick)) } label: {
                Image(systemName: f.flag == .pick ? "flag.fill" : "flag")
            }
            .help("Pick (P)")
            Button { apply(.flag(f.flag == .reject ? .none : .reject)) } label: {
                Image(systemName: f.flag == .reject ? "xmark.circle.fill" : "xmark.circle")
            }
            .help("Reject (X)")
            Divider().frame(height: 18)
            Toggle("Auto-advance", isOn: $autoAdvance).toggleStyle(.checkbox)
                .help("Go to the next photo after rating, picking or rejecting")
            Menu {
                let hinted = files.filter { ($0.eyesClosed || $0.soft) && $0.flag == .none }
                Button("Reject \(hinted.count) Shot\(hinted.count == 1 ? "" : "s") with Closed Eyes or Soft Focus") { reject(hinted) }
                    .disabled(hinted.isEmpty)
                Toggle("Show Faces & Names (I)", isOn: $showInfo)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden).fixedSize()
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Full screen")
            Button("Done") { dismiss() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder var stage: some View {
        if let f = current {
            Group {
                if f.kind == .video {
                    if let player { VideoPlayer(player: player) }
                } else if let zoom, let full {
                    zoomed(full, on: zoom)
                } else if let image = images[f.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay { if showInfo { faceBoxes } }
                } else {
                    ProgressView()
                }
            }
            .opacity(f.flag == .reject ? 0.45 : 1)
            .padding(12)
            .overlay(alignment: .topLeading) {
                if f.flag != .none {
                    Text(f.flag == .pick ? "PICK" : "REJECTED")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(f.flag == .pick ? Color.green : Color.red, in: Capsule())
                        .padding(20)
                }
            }
        } else {
            ProgressView()
        }
    }

    /// Boxes around the faces with their names; red when the eyes are closed or the face is soft. Click to zoom.
    var faceBoxes: some View {
        GeometryReader { g in
            ForEach(faces.filter { $0.box.width >= 0.015 }) { face in
                let r = CGRect(x: face.box.minX * g.size.width, y: face.box.minY * g.size.height,
                               width: face.box.width * g.size.width, height: face.box.height * g.size.height)
                let bad = Self.eyesClosed(face) || Self.soft(face)
                Rectangle()
                    .stroke(bad ? Color.red : Color.white.opacity(0.8), lineWidth: 1.5)
                    .contentShape(Rectangle())
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .onTapGesture { zoom = face }
                if let name = face.name {
                    Text(name)
                        .font(.caption)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .position(x: r.midX, y: r.maxY + 11)
                }
            }
        }
    }

    /// The photo at 100% (one image pixel per screen pixel) around a face.
    func zoomed(_ image: CGImage, on face: MediaFace) -> some View {
        GeometryReader { g in
            let w = min(CGFloat(image.width), g.size.width * displayScale), h = min(CGFloat(image.height), g.size.height * displayScale)
            let cx = face.box.midX * CGFloat(image.width), cy = face.box.midY * CGFloat(image.height)
            let rect = CGRect(x: min(max(0, cx - w / 2), CGFloat(image.width) - w), y: min(max(0, cy - h / 2), CGFloat(image.height) - h), width: w, height: h)
            if let crop = image.cropping(to: rect.integral) {
                Image(nsImage: NSImage(cgImage: crop, size: CGSize(width: CGFloat(crop.width) / displayScale, height: CGFloat(crop.height) / displayScale)))
                    .frame(width: g.size.width, height: g.size.height)
                    .onTapGesture { zoom = nil }
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("100%  ·  Z or click to see the whole photo").font(.caption).padding(6)
                .background(.black.opacity(0.6), in: Capsule()).padding(20)
        }
    }

    /// Each face cut out of the full-resolution photo, with its name and warnings; click to zoom to it.
    var faceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(faces.filter { crops[$0.id] != nil }) { face in
                    VStack(spacing: 3) {
                        Image(nsImage: crops[face.id]!)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(zoom == face ? Color.accentColor : .clear, lineWidth: 2))
                        HStack(spacing: 4) {
                            Text(face.name ?? "Unnamed").lineLimit(1)
                            if Self.eyesClosed(face) { Image(systemName: "eye.slash").foregroundStyle(.orange).help("Eyes closed") }
                            if Self.soft(face) { Image(systemName: "camera.metering.unknown").foregroundStyle(.orange).help("Soft focus") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .onTapGesture { zoom = zoom == face ? nil : face }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .frame(height: 134)
    }

    var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(files.indices, id: \.self) { i in
                        FileThumbnail(file: files[i], side: 58, badges: false)
                            .opacity(files[i].flag == .reject ? 0.35 : 1)
                            .overlay(alignment: .bottom) {
                                if files[i].rating > 0 { Text(String(repeating: "★", count: files[i].rating)).font(.system(size: 7)).foregroundStyle(.yellow) }
                            }
                            .overlay(alignment: .topTrailing) { FlagBadge(flag: files[i].flag == .pick ? .pick : .none, size: 8, onImage: true).padding(2) }
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == index ? Color.accentColor : .clear, lineWidth: 2))
                            .id(i)
                            .onTapGesture { index = i }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 70)
            .onChange(of: index) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) } }
            .onChange(of: files.count) { proxy.scrollTo(index, anchor: .center) }
        }
    }

    // MARK: - Keys and marks

    func key(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case KeyCode.left: step(-1); return true
        case KeyCode.right: step(1); return true
        case KeyCode.home: index = 0; return true
        case KeyCode.end: index = max(0, files.count - 1); return true
        case KeyCode.escape:
            if zoom != nil { zoom = nil } else { dismiss() }
            return true
        case KeyCode.space:
            guard let player else { return false }
            if player.timeControlStatus == .playing { player.pause() } else { player.play() }
            return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "z":
            guard full != nil else { return false }
            zoom = zoom == nil ? faces.first : nil
        case "i":
            showInfo.toggle()
        default:
            guard let f = current, let change = MarkChange.forKey(e, current: [f]) else { return false }
            apply(change)
        }
        return true
    }

    func step(_ d: Int) {
        index = min(max(0, index + d), max(0, files.count - 1))
    }

    func apply(_ change: MarkChange) {
        guard let f = current else { return }
        files[index].apply(change)
        model.mark([f.id], change)
        if autoAdvance, case .label = change {} else if autoAdvance { step(1) }
    }

    func reject(_ list: [ProjectFile]) {
        let ids = Set(list.map(\.id))
        for i in files.indices where ids.contains(files[i].id) { files[i].flag = .reject }
        model.mark(Array(ids), .flag(.reject))
    }

    // MARK: - Loading

    func load() async {
        guard let request else { return }
        // A window restored at launch can open before the library.
        while model.store == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        guard let store = model.store else { return }
        let list = await Task.detached(priority: .userInitiated) {
            (try? store.db.read { db in try ProjectFiles.list(db, project: nil, ids: request.ids) }) ?? []
        }.value
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        files = request.ids.compactMap { byId[$0] }
        index = request.start.flatMap { s in files.firstIndex { $0.id == s } } ?? 0
    }

    /// The current file: screen-sized first, then its faces and full-resolution crops, then the neighbours ahead.
    func show() async {
        guard let f = current, let store = model.store else { return }
        zoom = nil; faces = []; crops = [:]; full = nil
        player?.pause()
        player = f.kind == .video ? AVPlayer(url: f.url) : nil
        if f.kind == .photo {
            if images[f.id] == nil, let cg = await Self.decode(f.url, maxPixel: 2400) { images[f.id] = NSImage(cgImage: cg, size: .zero) }
            guard !Task.isCancelled else { return }
            faces = (try? await store.db.read { db in try ProjectFiles.faces(db, mediaId: f.id) }) ?? []
            if let cg = await Self.decode(f.url, maxPixel: nil), !Task.isCancelled {
                full = cg
                crops = Self.crops(of: faces, in: cg)
            }
        }
        // Keep the neighbours ready, and only them.
        let near = Set((max(0, index - 2)...min(files.count - 1, index + 2)).map { files[$0].id })
        images = images.filter { near.contains($0.key) }
        for i in [index + 1, index - 1, index + 2] where files.indices.contains(i) && files[i].kind == .photo && images[files[i].id] == nil {
            guard !Task.isCancelled else { return }
            if let cg = await Self.decode(files[i].url, maxPixel: 2400) { images[files[i].id] = NSImage(cgImage: cg, size: .zero) }
        }
    }

    /// The photo upright, its long side at most `maxPixel` (nil: full resolution).
    nonisolated static func decode(_ url: URL, maxPixel: Int?) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { ImageLoader.decode(url, maxPixel: maxPixel) }.value
    }

    /// Faces big enough to judge, cut out with some room around them.
    static func crops(of faces: [MediaFace], in image: CGImage) -> [Int64: NSImage] {
        var out: [Int64: NSImage] = [:]
        let size = CGSize(width: image.width, height: image.height)
        for face in faces.prefix(12) where face.box.width >= 0.02 {
            let r = CGRect(x: face.box.minX * size.width, y: face.box.minY * size.height, width: face.box.width * size.width, height: face.box.height * size.height)
                .insetBy(dx: -face.box.width * size.width * 0.35, dy: -face.box.height * size.height * 0.35)
                .intersection(CGRect(origin: .zero, size: size)).integral
            if let crop = image.cropping(to: r) { out[face.id] = NSImage(cgImage: crop, size: .zero) }
        }
        return out
    }

    static func eyesClosed(_ f: MediaFace) -> Bool { f.eyesOpen.map { $0 < ProjectFiles.eyesClosedBelow } ?? false }
    static func soft(_ f: MediaFace) -> Bool { f.sharpness.map { $0 < ProjectFiles.softBelow } ?? false }
}

/// Puts the window in full screen when it opens.
private struct FullScreenOnOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Opener() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Opener: NSView {
        private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            window.backgroundColor = .black
            DispatchQueue.main.async {
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }
}
