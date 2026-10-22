import FaceCore
import FaceLibrary
import MediaKit
import SwiftUI
import UniformTypeIdentifiers

/// The tools beyond Face Grouping. Each is a self-contained view over MediaKit.
enum ToolRoute: String, Hashable, CaseIterable {
    case batchExport, rename, verify, video

    var title: String {
        switch self {
        case .batchExport: "Batch Export"
        case .rename: "Batch Rename"
        case .verify: "Copy Verifier"
        case .video: "Video Tools"
        }
    }
    var icon: String {
        switch self {
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

    static func begin() { faces?.service?.processor.extrasPaused = true }
    static func end() { faces?.service?.processor.extrasPaused = false }
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
    @State private var mode = 0
    @State private var files: [URL] = []
    @State private var chosen: Set<Int64> = []
    @State private var topN: Int? = nil
    @State private var bestOfBurst = true
    @State private var search = ""
    @State private var resolving = false

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
                FileInputList(files: $files, kinds: kinds, label: label)
            } else {
                peoplePicker
            }
        }
        .onChange(of: files) { if mode == 0 { items = files.map { ToolItem(url: $0) } } }
        .onChange(of: mode) { mode == 0 ? (items = files.map { ToolItem(url: $0) }) : resolve() }
        .task(id: "\(chosen.sorted())|\(topN ?? 0)|\(bestOfBurst)|\(faces.currentProject ?? 0)|\(faces.sessionRange.map { "\($0)" } ?? "")") { if mode == 1 { resolve() } }
        // People of another project aren't in this one.
        .onChange(of: faces.currentProject) { chosen = [] }
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
                SessionPicker()
            }
        }
    }

    func resolve() {
        guard let store = faces.store else { return }
        let ids = Array(chosen), kind = mediaKind, topN = topN, burst = bestOfBurst, project = faces.currentProject, taken = faces.sessionRange
        resolving = true
        Task.detached(priority: .userInitiated) {
            let files = (try? Selection.files(store, personIds: ids, kind: kind, topN: topN, bestOfBurst: burst, project: project, taken: taken)) ?? []
            let items = files.map { ToolItem(url: $0.url, personName: $0.personName, people: $0.people, takenAt: $0.takenAt, focus: $0.focus) }
            await MainActor.run { self.items = items; resolving = false }
        }
    }
}

/// A list of input files with Add Files…, folders (scanned in the background) and drag & drop.
struct FileInputList: View {
    @Binding var files: [URL]
    let kinds: Set<String>
    var label = "files"
    @State private var scanning = false

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
                List(files.prefix(300), id: \.self) { u in
                    Text(u.lastPathComponent).font(.callout).lineLimit(1).help(u.path)
                }
                .frame(minHeight: 90, maxHeight: 160)
                if files.count > 300 { Text("…and \(files.count - 300) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5])))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { add([url]) } }
                }
            }
            return true
        }
    }

    func pick() {
        Panels.choose(folders: true, files: true, multiple: true, prompt: "Add") { add($0) }
    }

    /// Folder scanning happens off the main thread (NAS folders can take seconds to list).
    func add(_ urls: [URL]) {
        let current = files, kinds = kinds
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
            let result = out.filter { seen.insert($0.path).inserted }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            await MainActor.run { files = result; scanning = false }
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
            Button("Choose…") { Panels.chooseFolder { url = $0 } }
        }
    }
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
