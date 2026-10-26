import AppKit
import FaceLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Find by a photo: drop one, paste one (⌘V) or choose one; each face in it lists the people it looks most like (a
/// click opens that person) and how many photos and videos it is in (Show All lists them). The photo is only looked
/// at, never added to the library.
struct PhotoLookupSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    /// Opens a person's page (the sheet closes first).
    let open: (Int64) -> Void
    /// Opens the files a face is in (the sheet closes first).
    let showFiles: (FaceFilesRoute) -> Void
    @State private var url: URL?
    @State private var image: NSImage?
    @State private var result: PhotoLookup?
    @State private var looking = false
    @State private var error: String?
    @State private var face = 0
    @State private var dropping = false
    /// The files each face (by index) is in, as found so far.
    @State private var files: [Int: [FaceMatch]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Find by Photo").font(.title2.bold())
                Spacer()
                Button("Paste") { paste() }.keyboardShortcut("v")
                Button("Choose Photo…") { choose() }
            }
            Group {
                if let image { content(image) } else { dropZone }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { drop($0) }
            HStack {
                if let error { Text(error).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 780, height: 560)
    }

    var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(dropping ? Color.accent : Color.secondary.opacity(0.4))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "person.fill.viewfinder").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Drop a photo here, paste one (⌘V), or choose one").foregroundStyle(.secondary)
                    Text("Every face in it is matched against the people in the library, and the photos and videos it is in are found.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
    }

    @ViewBuilder
    func content(_ image: NSImage) -> some View {
        HStack(alignment: .top, spacing: 18) {
            photo(image).frame(width: 300)
            VStack(alignment: .leading, spacing: 12) {
                if looking {
                    HStack { ProgressView().controlSize(.small); Text("Looking for faces…").foregroundStyle(.secondary) }
                } else if let result {
                    if result.faces.isEmpty {
                        ContentUnavailableView("No faces in this photo", systemImage: "person.slash",
                                               description: Text("Try a photo where the face is bigger or turned more towards the camera."))
                    } else {
                        if result.faces.count > 1 { facePicker(result) }
                        matches(result.faces[min(face, result.faces.count - 1)])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The photo with its faces outlined; the face being matched stands out, a click on another picks it.
    func photo(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    ForEach(result?.faces ?? []) { f in
                        let r = CGRect(x: f.box.minX * g.size.width, y: f.box.minY * g.size.height,
                                       width: f.box.width * g.size.width, height: f.box.height * g.size.height)
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(f.id == face ? Color.accent : Color.white.opacity(0.7), lineWidth: f.id == face ? 3 : 1.5)
                            .frame(width: r.width, height: r.height)
                            .contentShape(Rectangle())
                            .onTapGesture { face = f.id }
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func facePicker(_ result: PhotoLookup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(result.faces) { f in
                    Group {
                        if let p = f.preview { Image(decorative: p, scale: 1).resizable() } else { Image(systemName: "person.crop.square").resizable().padding(10) }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(f.id == face ? Color.accent : .clear, lineWidth: 3))
                    .onTapGesture { face = f.id }
                    .help(f.matches.first.map { "Looks most like \($0.name ?? "an unnamed person")" } ?? "Not readable")
                }
            }
            .padding(2)
        }
    }

    @ViewBuilder
    func matches(_ f: PhotoLookup.Face) -> some View {
        if f.matches.isEmpty {
            Text("This face can't be read well enough to match (too small, or turned away).").foregroundStyle(.secondary)
        } else {
            filesRow(f)
            Text(f.matches[0].likely ? "Looks like \(f.matches[0].name ?? "this person"); also close:" : "Nobody in the library is a sure match. Closest:")
                .font(.headline)
            if (f.quality ?? 1) < 0.3 {
                Text("A blurred or half-turned face: matches are less reliable.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                    ForEach(f.matches) { m in tile(m) }
                }
            }
        }
    }

    /// How many photos and videos the face is in, and Show All. Found when the face is picked (a second or so).
    func filesRow(_ f: PhotoLookup.Face) -> some View {
        let found = files[f.id]
        return HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.title3).foregroundStyle(Color.accent)
            if let found {
                let videos = found.count { $0.kind == .video }
                Text(found.isEmpty ? "In no photo or video of \(model.projectName)"
                                   : "In \(found.count - videos) photos and \(videos) videos of \(model.projectName)")
            } else {
                ProgressView().controlSize(.small)
                Text("Finding the photos and videos with this face…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show All") {
                dismiss()
                showFiles(FaceFilesRoute(face: f))
            }
            .disabled(found?.isEmpty ?? true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accent.opacity(0.08)))
        .task(id: TaskKey(url: url, face: f.id)) {
            guard found == nil, let store = model.store, let v = f.vector else { return }
            let project = model.currentProject, person = f.matches.first.flatMap { $0.likely ? $0.personId : nil }
            let r = await Task.detached(priority: .userInitiated) {
                (try? store.files(like: v, person: person, project: project)) ?? []
            }.value
            if !Task.isCancelled { files[f.id] = r }
        }
    }

    struct TaskKey: Hashable { var url: URL?; var face: Int }

    func tile(_ m: PhotoLookup.Match) -> some View {
        Button {
            dismiss()
            open(m.personId)
        } label: {
            VStack(spacing: 4) {
                FaceImage(faceId: m.coverFaceId, side: 112).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(m.name ?? "Unnamed").font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if m.likely {
                        Text("Likely").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accent.opacity(0.18)))
                    }
                    Text("\(Int((m.similarity * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .opacity(m.likely ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .help("\(m.faces) faces · open \(m.name ?? "this person")")
    }

    // MARK: - Getting the photo

    func choose() {
        Panels.choose(folders: false, files: true, types: [.image], prompt: "Find People") { if let u = $0.first { look(at: u) } }
    }

    func paste() {
        let pb = NSPasteboard.general
        if let u = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            look(at: u)
        } else if let img = NSImage(pasteboard: pb) {
            look(at: img)
        } else {
            error = "There is no photo on the clipboard."
        }
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { Task { @MainActor in look(at: u) } }
            }
            return true
        }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                if let img = img as? NSImage { Task { @MainActor in look(at: img) } }
            }
            return true
        }
        return false
    }

    /// An image from the clipboard or a browser: written to a temporary file, read like any other.
    func look(at img: NSImage) {
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            error = "That image can't be read."
            return
        }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("photo-lookup-\(UUID().uuidString).png")
        do { try png.write(to: u) } catch { self.error = error.localizedDescription; return }
        look(at: u)
    }

    func look(at u: URL) {
        guard let service = model.service else { return }
        url = u
        image = NSImage(contentsOf: u)
        result = nil
        files = [:]
        error = image == nil ? "That file isn't a photo this Mac can read." : nil
        face = 0
        guard image != nil else { return }
        looking = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try service.lookUpPeople(in: u) } }.value
            if u.lastPathComponent.hasPrefix("photo-lookup-") { try? FileManager.default.removeItem(at: u) }
            guard url == u else { return }  // another photo came meanwhile
            looking = false
            switch r {
            case .success(let found): result = found
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}

/// Pushed from Find by Photo to show every file a face is in.
struct FaceFilesRoute: Hashable {
    /// The face's embedding (normalized).
    let vector: [Float]
    /// The person it is likely to be, with their name: their files come too.
    let person: Int64?
    let name: String?
    /// The face, as PNG.
    let preview: Data?

    init(face: PhotoLookup.Face) {
        vector = face.vector ?? []
        let likely = face.matches.first.flatMap { $0.likely ? $0 : nil }
        person = likely?.personId
        name = likely?.name
        preview = face.preview.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }
}

/// Every photo and video a face from a photo is in (Find by Photo, Show All): the faces in the library alike enough
/// to it, grouped with somebody or not, and the files of the person it is likely to be. Best match first, or by
/// date; open, look closer or export them as from a search.
struct FaceFilesView: View {
    @EnvironmentObject var model: FaceGroupingModel
    let route: FaceFilesRoute
    @State private var strictness = FaceMatchStrictness.normal
    @State private var withPerson = true
    @State private var kind: MediaKind?
    @State private var byDate = false
    @State private var hideSimilar = false
    @State private var matches: [FaceMatch] = []
    @State private var searching = false
    @State private var error: String?
    @State private var exporting = false

    /// What the search depends on (the rest only filters or orders what it found).
    struct Search: Hashable {
        var strictness: FaceMatchStrictness
        var person: Int64?
        var project: Int64?
    }

    var shown: [FaceMatch] {
        var out = matches.filter { kind == nil || $0.kind == kind }
        if hideSimilar {
            // A burst keeps its best match.
            var seen = Set<Int64>()
            out = out.filter { m in m.burstId.map { seen.insert($0).inserted } ?? true }
        }
        if byDate { out.sort { ($0.takenAt ?? .distantPast, $0.path) < ($1.takenAt ?? .distantPast, $1.path) } }
        return out
    }

    var body: some View {
        let shown = self.shown
        VStack(spacing: 0) {
            filters
            Divider()
            if searching && matches.isEmpty {
                ProgressView("Looking through every face in the library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaResultsGrid(
                    hits: shown.map { m in
                        MediaHit(id: m.id, path: m.path, kind: m.kind, faceId: m.faceId, time: m.time, score: Double(m.similarity),
                                 takenAt: m.takenAt, burstId: m.burstId)
                    },
                    empty: error ?? "No photos or videos with this face",
                    badges: Dictionary(uniqueKeysWithValues: shown.map { m in
                        (m.id, m.throughPerson ? "Grouped" : "\(Int((m.similarity * 100).rounded()))%")
                    }))
                .id(Search(strictness: strictness, person: withPerson ? route.person : nil, project: model.currentProject))
            }
        }
        .navigationTitle(route.name.map { "Files with \($0)" } ?? "Files with This Face")
        .navigationSubtitle(subtitle(shown))
        .toolbar {
            ToolbarItem {
                Button { exporting = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }.disabled(shown.isEmpty)
            }
        }
        .sheet(isPresented: $exporting) {
            ExportSheet(scope: .media(shown.map(\.id), title: route.name ?? "Find by Photo"), mode: .copy, initialName: route.name ?? "Find by Photo")
        }
        .task(id: Search(strictness: strictness, person: withPerson ? route.person : nil, project: model.currentProject)) { await search() }
    }

    func subtitle(_ shown: [FaceMatch]) -> String {
        let videos = shown.count { $0.kind == .video }
        return "\(shown.count - videos) photos · \(videos) videos · \(model.projectName)"
    }

    var filters: some View {
        FlowLayout(spacing: 10, lineSpacing: 8) {
            Group {
                if let data = route.preview, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable()
                } else {
                    Image(systemName: "person.crop.square").resizable().padding(6).foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Picker("", selection: $strictness) {
                Text("Strict").tag(FaceMatchStrictness.strict)
                Text("Normal").tag(FaceMatchStrictness.normal)
                Text("Loose").tag(FaceMatchStrictness.loose)
            }
            .pickerStyle(.segmented).fixedSize()
            .help("How alike a face must be: Strict lets in fewer of somebody else's, Loose misses fewer of theirs")
            if let name = route.name {
                Toggle("Everything grouped as \(name)", isOn: $withPerson).toggleStyle(.checkbox).fixedSize()
                    .help("Also the files the library put \(name) in, though the face there isn't alike enough on its own (a profile, a face half hidden)")
            }
            Picker("", selection: $kind) {
                Text("Photos & videos").tag(MediaKind?.none)
                Text("Photos").tag(MediaKind?.some(.photo))
                Text("Videos").tag(MediaKind?.some(.video))
            }
            .fixedSize()
            Picker("", selection: $byDate) {
                Text("Best match first").tag(false)
                Text("By date").tag(true)
            }
            .fixedSize()
            Toggle("Hide similar shots", isOn: $hideSimilar).toggleStyle(.checkbox).fixedSize()
            if searching { ProgressView().controlSize(.small) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func search() async {
        guard let store = model.store, !route.vector.isEmpty else { return }
        let v = route.vector, st = strictness, person = withPerson ? route.person : nil, project = model.currentProject
        searching = true
        let r = await Task.detached(priority: .userInitiated) { Result { try store.files(like: v, strictness: st, person: person, project: project) } }.value
        guard !Task.isCancelled else { return }
        searching = false
        switch r {
        case .success(let found): matches = found; error = nil
        case .failure(let e): matches = []; error = e.localizedDescription
        }
    }
}
