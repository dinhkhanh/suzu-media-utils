import FaceCore
import FaceLibrary
import MediaKit
import SwiftUI
import UniformTypeIdentifiers

/// The tools beyond Face Grouping. Each is a self-contained view over MediaKit.
enum ToolRoute: String, Hashable, CaseIterable {
    case cards, batchExport, rename, verify, video

    var title: String {
        switch self {
        case .cards: "Copy from Cards"
        case .batchExport: "Edit & Export"
        case .rename: "Batch Rename"
        case .verify: "Copy Verifier"
        case .video: "Video Tools"
        }
    }
    var icon: String {
        switch self {
        case .cards: "sdcard"
        case .batchExport: "wand.and.stars"
        case .rename: "character.cursor.ibeam"
        case .verify: "checkmark.shield"
        case .video: "film"
        }
    }
}

struct ToolsSidebar: View {
    var body: some View {
        Section("Tools") {
            ForEach(ToolRoute.allCases, id: \.self) { t in
                Label(t.title, systemImage: t.icon).tag(AppRoute.tool(t))
            }
        }
    }
}

struct ToolDetail: View {
    let route: ToolRoute
    var body: some View {
        switch route {
        case .cards: CardCopyTool()
        case .batchExport: BatchExportTool()
        case .rename: BatchRenameTool()
        case .verify: CopyVerifierTool()
        case .video: VideoToolsView()
        }
    }
}

/// Tools run below face processing so they never slow recognition: utility priority, half the cores while files
/// are being processed (all but two otherwise), and background extras are paused while a tool works.
@MainActor
enum ToolWork {
    static weak var faces: FaceGroupingModel?

    static var parallelism: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let busy = (faces?.service?.processor.queuedCount ?? 0) > 0
        return max(1, busy ? cores / 2 : cores - 2)
    }

    /// Jobs under way (several cards can copy at once): the library's extras wait until the last one is done, and
    /// face work goes on with fewer workers so the transfers get the disk and the network first.
    private static var active = 0
    static var isActive: Bool { active > 0 }
    static func begin() {
        active += 1
        faces?.service?.processor.extrasPaused = true
        faces?.service?.processor.setForeground(true)
    }
    static func end() {
        active = max(0, active - 1)
        if active == 0 {
            faces?.service?.processor.extrasPaused = false
            faces?.service?.processor.setForeground(false)
        }
    }
}

/// One input to a batch tool: a file, and when it came from the library, who is in it and where.
struct ToolItem: Hashable {
    var url: URL
    var personName: String?
    var people: [String] = []
    var takenAt: Date?
    var focus: FocusHint?
    static func == (a: ToolItem, b: ToolItem) -> Bool { a.url == b.url && a.personName == b.personName }
    func hash(into h: inout Hasher) { h.combine(url); h.combine(personName) }
}

/// Where a batch tool's files come from: files and folders, or people from Face Grouping.
struct ToolInputView: View {
    @EnvironmentObject var faces: FaceGroupingModel
    @Binding var items: [ToolItem]
    let kinds: Set<String>
    let mediaKind: MediaKind?
    var label = "files"
    /// A camera's RAW+JPEG pair comes in as its RAW (Edit & Export: it holds the most); else as its JPEG.
    var rawPairs = false
    @State private var mode = 0
    @State private var files: [URL] = []
    @State private var chosen: Set<Int64> = []
    @State private var topN: Int? = nil
    @State private var bestOfBurst = true
    /// The same setting as Edit & Export's Skip blurry, so ticking it there fills the best N from the sharp shots.
    @AppStorage("batchExport.skipBlurry") private var skipBlurry = false
    @State private var search = ""
    @State private var resolving = false
    /// When the chosen files were shot (EXIF, else the file's date, as the library reckons it), so a session picked
    /// for the event narrows them too.
    @State private var dates: [URL: Date] = [:]
    @State private var dating = false

    var named: [PersonSummary] {
        faces.people.filter { $0.name != nil && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                Text("Files & Folders").tag(0)
                Text("People").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            if mode == 0 {
                FileInputList(files: $files, kinds: kinds, label: label, rawPairs: rawPairs)
                if let s = faces.currentSession, !files.isEmpty {
                    Text(dating ? "Reading capture times…" : "\(items.count) of \(files.count) \(label) in \(faces.sessionTitle(s))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Only files shot during the session picked in the bar; choose Whole event for all of them")
                }
            } else {
                peoplePicker
            }
        }
        .onChange(of: files) { if mode == 0 { items = fileItems() } }
        .onChange(of: mode) { mode == 0 ? (items = fileItems()) : resolve() }
        .task(id: "\(chosen.sorted())|\(topN ?? 0)|\(bestOfBurst)|\(skipBlurry)|\(faces.currentProject ?? 0)|\(faces.sessionRange.map { "\($0)" } ?? "")") {
            // Runs on appear too: with no files chosen here, the items are the ones handed in (photos opened from
            // the library) and stay.
            if mode == 1 { resolve() } else if !files.isEmpty { items = fileItems() }
        }
        .task(id: "\(files.hashValue)|\(faces.currentProject != nil && !faces.sessions.isEmpty)") { await readDates() }
        // People of another project aren't in this one.
        .onChange(of: faces.currentProject) { chosen = [] }
    }

    /// The chosen files as items: all of them, or, with a session picked, those shot during it (a file whose time
    /// isn't read yet stays until it is).
    func fileItems() -> [ToolItem] {
        let range = faces.sessionRange
        return files.compactMap { u in
            let t = dates[u]
            if let range, let t, !range.contains(t.timeIntervalSince1970) { return nil }
            return ToolItem(url: u, takenAt: t)
        }
    }

    /// Reads the capture times the session filter needs (only while a project with sessions is open), a few
    /// milliseconds per file, off the main thread.
    func readDates() async {
        guard faces.currentProject != nil, !faces.sessions.isEmpty else { return }
        let missing = files.filter { dates[$0] == nil }
        guard !missing.isEmpty else { return }
        dating = true
        let found = await Task.detached(priority: .userInitiated) { () -> [URL: Date] in
            var out: [URL: Date] = [:]
            for u in missing {
                if Task.isCancelled { break }
                let exif = (try? ImageLoader.source(u)).flatMap { ImageLoader.captureDate($0.0) }
                out[u] = exif ?? (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date)
            }
            return out
        }.value
        guard !Task.isCancelled else { dating = false; return }
        dates.merge(found) { _, new in new }
        dating = false
        if mode == 0 { items = fileItems() }
    }

    var peoplePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search people", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Button("All") { chosen = Set(faces.people.filter { $0.name != nil }.map(\.id)) }
                Button("None") { chosen = [] }
                Spacer()
                Text(resolving ? "Finding files…" : "\(chosen.count) people · \(items.count) \(label)").foregroundStyle(.secondary).lineLimit(1)
            }
            .controlSize(.small)
            if faces.people.allSatisfy({ $0.name == nil }) {
                Text("Name people in Face Grouping first.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(named) { p in
                        Toggle(isOn: Binding(get: { chosen.contains(p.id) }, set: { if $0 { chosen.insert(p.id) } else { chosen.remove(p.id) } })) {
                            HStack {
                                FaceImage(faceId: p.coverFaceId, side: 22).clipShape(Circle())
                                Text(p.displayName)
                                Text(PersonCell(person: p, selected: false).counts).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 180)
            FlowLayout(spacing: 12) {
                Picker("", selection: $topN) {
                    Text("All files").tag(Int?.none)
                    ForEach([10, 20, 50, 100], id: \.self) { Text("Best \($0) per person").tag(Int?.some($0)) }
                }
                .labelsHidden().fixedSize()
                Toggle("Skip similar shots", isOn: $bestOfBurst).toggleStyle(.checkbox)
                Toggle("Skip blurry shots", isOn: $skipBlurry).toggleStyle(.checkbox)
                SessionPicker()
            }
        }
    }

    func resolve() {
        guard let store = faces.store else { return }
        let ids = Array(chosen), kind = mediaKind, topN = topN, burst = bestOfBurst, blurry = skipBlurry, project = faces.currentProject, taken = faces.sessionRange
        let rawPairs = rawPairs
        resolving = true
        Task.detached(priority: .userInitiated) {
            let files = (try? Selection.files(store, personIds: ids, kind: kind, topN: topN, bestOfBurst: burst, skipBlurry: blurry, project: project, taken: taken)) ?? []
            let raws = rawPairs ? ((try? await store.db.read { db in try Selection.rawPartners(db, mediaIds: files.map(\.mediaId)) }) ?? [:]) : [:]
            // A photo of two chosen people is listed once (the first person's), or the tools would edit it twice.
            var seen: Set<String> = []
            let items = files.filter { seen.insert($0.url.path).inserted }
                .map { ToolItem(url: raws[$0.mediaId] ?? $0.url, personName: $0.personName, people: $0.people, takenAt: $0.takenAt, focus: $0.focus) }
            await MainActor.run { self.items = items; resolving = false }
        }
    }
}

/// A list of input files with Add Files…, folders (scanned in the background) and drag & drop.
struct FileInputList: View {
    @Binding var files: [URL]
    let kinds: Set<String>
    var label = "files"
    /// A RAW+JPEG pair is listed as its RAW; else as its JPEG (see `ToolInputView.rawPairs`).
    var rawPairs = false
    @State private var scanning = false
    /// Files picked in the list, and the one space opened (see `Peek`).
    @State private var picked: Set<URL> = []
    @State private var peek: PeekState<URL>?
    @State private var pointer = Peek<URL>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                Button("Add Files or Folders…") { pick() }
                if !files.isEmpty { Button("Clear") { files = [] } }
                HStack(spacing: 6) {
                    if scanning { ProgressView().controlSize(.small) }
                    Text(scanning ? "Looking for \(label)…" : files.isEmpty ? "or drop \(label) here" : "\(files.count) \(label)").foregroundStyle(.secondary)
                }
            }
            if !files.isEmpty {
                // Long lists only show their start: thousands of rows would make every redraw slow.
                List(files.prefix(300), id: \.self, selection: $picked) { u in
                    Text(u.lastPathComponent).font(.callout).lineLimit(1).help(u.path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .peekPopover(u, open: $peek, keys: key) { MediaPeek(url: $0) }
                }
                .frame(minHeight: 90, maxHeight: 160)
                .onWindowKeys(key)
                .onChange(of: peek?.current) { if let c = peek?.current, picked != [c] { picked = [c] } }
                .onChange(of: picked) { if picked.count == 1 { pointer.clicked = picked.first } }
                if files.count > 300 { Text("…and \(files.count - 300) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5])))
        // SUZU_TOOL_FOLDER=/path (testing): start with that folder's files.
        .task { if files.isEmpty, let p = ProcessInfo.processInfo.environment["SUZU_TOOL_FOLDER"] { add([URL(fileURLWithPath: p)]) } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { add([url]) } }
                }
            }
            return true
        }
    }

    /// Space, and ← → esc while it is open: a closer look at the picked file (see `Peek`). Only while the list has
    /// the keyboard: in Edit & Export, space on the photo ticks it.
    func key(_ e: NSEvent) -> Bool {
        guard peek != nil || e.window?.firstResponder is NSTableView else { return false }
        return pointer.key(e, open: &peek, selection: picked, order: Array(files.prefix(300)))
    }

    func pick() {
        Panels.choose(folders: true, files: true, multiple: true, prompt: "Add") { add($0) }
    }

    /// Folder scanning happens off the main thread (NAS folders can take seconds to list).
    func add(_ urls: [URL]) {
        let current = files, kinds = kinds, rawPairs = rawPairs
        scanning = true
        Task.detached(priority: .userInitiated) {
            var out = current
            for u in urls {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    while let f = e?.nextObject() as? URL {
                        if kinds.contains(f.pathExtension.lowercased()) { out.append(f) }
                    }
                } else if kinds.contains(u.pathExtension.lowercased()) {
                    out.append(u)
                }
            }
            var seen: Set<String> = []
            var result = out.filter { seen.insert($0.path).inserted }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            // A camera's RAW+JPEG pair is one photo: one file stands for both.
            if rawPairs {
                let raws = Set(result.filter { ImageLoader.isRaw($0) }.map { ImageLoader.pairKey($0.path) })
                result.removeAll { !ImageLoader.isRaw($0) && raws.contains(ImageLoader.pairKey($0.path)) }
            } else {
                let jpegs = Set(result.filter { !ImageLoader.isRaw($0) }.map { ImageLoader.pairKey($0.path) })
                result.removeAll { ImageLoader.isRaw($0) && jpegs.contains(ImageLoader.pairKey($0.path)) }
            }
            let final = result
            await MainActor.run { files = final; scanning = false }
        }
    }
}

struct FolderField: View {
    let title: String
    @Binding var url: URL?
    var body: some View {
        HStack {
            Text(title)
            Text(url?.path ?? "Not chosen").foregroundStyle(url == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let url { CopyPathButton(path: url.path, what: "folder", iconOnly: true) }
            Button("Choose…") { Panels.chooseFolder(key: "folderField.\(title)") { url = $0 } }
        }
    }
}

/// Copies a full path to the clipboard, and says "Copied" (a checkmark) for a moment after.
struct CopyPathButton: View {
    let path: String
    /// What the path is, for the tooltip ("photo", "folder").
    var what = "file"
    var iconOnly = false
    @State private var copiedPath: String?

    var body: some View {
        let copied = copiedPath == path
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copiedPath = path }
            // Back to "Copy Path" after a moment, unless it was clicked again meanwhile.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedPath == path { withAnimation(.easeOut(duration: 0.2)) { copiedPath = nil } }
            }
        } label: {
            // Both labels take the same room, so nothing shifts when the text changes.
            ZStack(alignment: .leading) {
                Label("Copy Path", systemImage: "doc.on.doc").opacity(copied ? 0 : 1)
                Label("Copied", systemImage: "checkmark").foregroundStyle(.green).opacity(copied ? 1 : 0)
            }
            .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        }
        .help(copied ? "Copied to the clipboard: \(path)" : "Copy the \(what)'s full path: \(path)")
        .accessibilityLabel(copied ? "Path copied" : "Copy Path")
    }
}

/// A label style chosen at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Lays its children out left to right and wraps to the next line when the window is narrow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

enum MediaTypes {
    static let photos = ImageLoader.extensions
    static let videos = VideoSampler.extensions
}

/// The clipboard, for file paths: one per line, as the Finder's "Copy as Pathname" gives them.
enum Clipboard {
    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
