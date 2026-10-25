import FaceCore
import FaceLibrary
import MediaKit
import SwiftUI

/// Auto tone, face-aware social crop, watermark and resize for files or people's photos: a large preview of the
/// result on the left, source, edits and output in an inspector on the right.
struct BatchExportTool: View {
    @State private var items: [ToolItem]
    var title = "Edit & Export"
    /// The event's session bar on top: a session can be exported on its own. Not for photos opened from the library
    /// (the Edit & Export window), which are exactly the ones asked for.
    var sessionBar = true
    /// `initial`: photos opened from the library (the Edit & Export window).
    init(initial: [ToolItem] = [], title: String = "Edit & Export") {
        _items = State(initialValue: initial)
        self.title = title
        sessionBar = initial.isEmpty
    }

    /// Photos unticked in the preview; everything else is exported.
    @State private var excluded: Set<ToolItem> = []
    /// Unticked by the check for similar and blurry shots (a subset of `excluded` until the user ticks one back).
    @State private var culled: [ToolItem: ShotCuller.Reason] = [:]
    @State private var checking: (done: Int, total: Int)?
    @AppStorage("batchExport.skipSimilar") private var skipSimilar = false
    @AppStorage("batchExport.skipBlurry") private var skipBlurry = false
    @State private var recipe = EditRecipe()
    /// The photo in the preview, for "This photo only" in the controls.
    @State private var shownPhoto: URL?
    @StateObject private var history = EditHistory()
    @Environment(\.undoManager) private var undoManager
    @State private var output: URL?
    @State private var suffix = ""
    @State private var folderPerPerson = true
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var failures: [String] = []
    @State private var skipped = 0
    @State private var finished = false
    @State private var cancel = false
    /// Photos already in the destination folder, asked about one at a time before the export starts.
    @State private var existing: [Existing] = []
    @State private var questions: [Existing] = []
    @State private var answers: [String: Existing.Answer] = [:]
    /// The files of the export being started (two per photo when exporting both shapes).
    @State private var jobs: [ExportJob] = []
    /// Keeps "skipped" apart from failures in the export's results.
    nonisolated static let skippedMark = "\u{0}skipped"

    var fromPeople: Bool { items.contains { $0.personName != nil } }
    var chosen: [ToolItem] { excluded.isEmpty ? items : items.filter { !excluded.contains($0) } }
    var chosenCount: Int { items.count - excluded.count }

    var body: some View {
        VStack(spacing: 0) {
            if sessionBar { SessionBar(divider: true) }
            HStack(spacing: 0) {
                EditPreview(recipe: $recipe, samples: items, excluded: $excluded, notes: culled.mapValues(Self.label), shown: $shownPhoto)
                    .frame(minWidth: 260, maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        InspectorSection(title: "Photos") {
                            ToolInputView(items: $items, kinds: MediaTypes.photos, mediaKind: .photo, label: "photos", rawPairs: true)
                        }
                        EditControls(recipe: $recipe, photo: shownPhoto, photoCount: items.count)
                        Text(fromPeople ? "Crops keep each person's face in frame; names are written into the files."
                                        : "Crops find the faces in each photo (or the most eye-catching area) and keep them in frame.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        InspectorSection(title: "Output") {
                            FolderField(title: "Save to", url: $output)
                            if fromPeople { Toggle("A folder per person", isOn: $folderPerPerson) }
                            HStack {
                                Text("Name suffix")
                                TextField("Name suffix", text: $suffix, prompt: Text("e.g. _ig")).textFieldStyle(.roundedBorder).labelsHidden()
                            }
                            .help("Added to the end of each file name: IMG_0001\(suffix.isEmpty ? "_ig" : suffix).jpg")
                        }
                    }
                    .padding(16)
                }
                .frame(width: 320)
            }
            Divider()
            HStack(spacing: 14) {
                cullOptions
                Divider().frame(height: 18)
                if running || finished {
                    ProgressView(value: Double(done), total: Double(max(1, total))).frame(maxWidth: 200)
                    Text(finished ? "Done: \(done - failures.count - skipped) saved\(skipped == 0 ? "" : ", \(skipped) skipped")\(failures.isEmpty ? "" : ", \(failures.count) failed")"
                         : "\(done) of \(total)")
                        .foregroundStyle(.secondary).monospacedDigit()
                    if let f = failures.first { Text(f).font(.caption).foregroundStyle(.red).lineLimit(1).help(failures.prefix(10).joined(separator: "\n")) }
                } else {
                    (Text("\(chosenCount) of \(items.count)").fontWeight(.semibold) + Text(" ticked"))
                        .monospacedDigit()
                    Text(output.map { "→ \($0.lastPathComponent)" } ?? "Choose where to save (Output, on the right)")
                        .foregroundStyle(output == nil ? Color.amber : .secondary).lineLimit(1)
                }
                Spacer()
                if running { Button("Stop") { cancel = true } }
                if finished, let output { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                HStack(spacing: 4) {
                    Button { start(bothShapes: false) } label: {
                        Label("Export \(chosenCount) Photo\(chosenCount == 1 ? "" : "s")", systemImage: "square.and.arrow.up")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    // Rarely needed: every photo in both of the crop shapes picked (⌘-click) in Crop.
                    Menu {
                        let shapes = Self.bothShapes(recipe)
                        Button("Export Each Photo in Both Shapes\(shapes.map { " (\(Self.title($0[0])) + \(Self.title($0[1])))" } ?? "")") { start(bothShapes: true) }
                            .disabled(shapes == nil)
                        if shapes == nil { Text("⌘-click two shapes in Crop first") }
                    } label: { EmptyView() }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("More ways to export")
                }
                .disabled(running || chosenCount == 0 || output == nil || checking != nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(item: Binding(get: { questions.first }, set: { _ in })) { q in
            ExistingSheet(existing: q, remaining: questions.count) { answer, all in
                switch answer {
                case nil: questions = []
                case let a?:
                    for x in all ? questions : [q] { answers[x.id] = a }
                    questions.removeFirst(all ? questions.count : 1)
                    if questions.isEmpty { run() }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("Light, colour & detail · crop & straighten · watermark · resize")
        .rememberEdits("batchExport", recipe: $recipe)
        // ⌘Z / ⇧⌘Z (Edit menu) step back through the sliders, crops and looks.
        .onChange(of: undoManager, initial: true) { history.undoManager = undoManager }
        .onChange(of: items, initial: true) { history.urls = items.map(\.url) }
        .onAppear { history.setRecipe = { recipe = $0 } }
        .onChange(of: recipe) { old, new in history.recipeChanged(from: old, to: new) }
        .onReceive(NotificationCenter.default.publisher(for: CropPlacements.changed)) { _ in history.editsChanged(recipe: recipe) }
        // Only photos still in the list can be left out.
        .onChange(of: items) { if !excluded.isEmpty { excluded.formIntersection(items) } }
        .task(id: "\(skipSimilar)|\(skipBlurry)|\(items.map(\.url.path).hashValue)") { await check() }
        .task {
            // SUZU_TOOL_SAMPLES=1 (testing): start with the project's best photos as input.
            if ProcessInfo.processInfo.environment["SUZU_TOOL_SAMPLES"] != nil, items.isEmpty, let faces = ToolWork.faces {
                try? await Task.sleep(for: .seconds(2))
                items = await faces.samples(limit: 40)
                if ProcessInfo.processInfo.environment["SUZU_TOOL_SAMPLES"] == "grid" { excluded = Set(items.dropFirst(1).prefix(3)) }
            }
        }
    }

    /// Similar and blurry shots are unticked in the preview, not hidden: the user sees what goes and can tick any back.
    var cullOptions: some View {
        HStack(spacing: 12) {
            // People already come as the best of each burst (the Skip similar shots option above).
            if !fromPeople {
                Toggle("Skip similar", isOn: $skipSimilar)
                    .help("Shots taken within a couple of seconds that look the same: only the best one is exported")
            }
            Toggle("Skip blurry", isOn: $skipBlurry)
                .help("Photos whose main face is out of focus or moved; without a face, photos that are smeared all over")
            if let c = checking {
                ProgressView().controlSize(.mini)
                Text("Checking \(c.done) of \(c.total)…").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if skipSimilar || skipBlurry, !items.isEmpty {
                let similar = culled.values.filter { if case .similar = $0 { true } else { false } }.count, blurry = culled.count - similar
                Text(culled.isEmpty ? "nothing to skip" : "−\(culled.count) unticked (\(similar) similar, \(blurry) blurry) · tick any to keep it")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    static func count(_ n: Int, _ what: String) -> String { "\(n) \(what) photo\(n == 1 ? "" : "s")" }

    static func label(_ r: ShotCuller.Reason) -> String {
        switch r {
        case .blurry: "Blurry: unticked"
        case .similar(let best): "Similar to \(best.lastPathComponent): unticked"
        }
    }

    /// Finds the similar and blurry shots and unticks them; turning the options off ticks them back. The library's
    /// measurements are used for photos it has processed; the others are read here (faces take ~¼ s each).
    func check() async {
        excluded.subtract(culled.keys)
        culled = [:]
        let similar = skipSimilar && !fromPeople, blurry = skipBlurry
        guard similar || blurry, !items.isEmpty else { checking = nil; return }
        let items = items, store = ToolWork.faces?.store, workers = ToolWork.parallelism
        checking = (0, items.count)
        let known = await Task.detached(priority: .userInitiated) { (try? store.map { try Selection.measures($0, urls: items.map(\.url)) }) ?? [:] }.value
        guard !Task.isCancelled else { return }
        var measures: [Int: ShotCuller.Measure] = [:]
        await withTaskGroup(of: (Int, ShotCuller.Measure).self) { group in
            var next = 0
            func add() {
                guard next < items.count, !Task.isCancelled else { return }
                let i = next, url = items[i].url, have = known[url]; next += 1
                group.addTask(priority: .userInitiated) {
                    // A processed photo without a usable face needs the frame's blur; one from before the idle pass
                    // needs its feature print. Both come from the thumbnail, which is quick.
                    var m = have ?? ShotCuller.Measure(url: url)
                    let needPrint = similar && m.featurePrint == nil, needBlur = blurry && m.faceSharpness == nil && m.blur == nil
                    if have == nil || needPrint || needBlur {
                        let fresh = ShotCuller.measure(url, faces: blurry && have == nil)
                        if have == nil { m = fresh } else {
                            if needPrint { m.featurePrint = fresh.featurePrint }
                            if needBlur { m.blur = fresh.blur }
                            if m.takenAt == nil { m.takenAt = fresh.takenAt }
                        }
                    }
                    return (i, m)
                }
            }
            for _ in 0..<workers { add() }
            for await (i, m) in group {
                measures[i] = m
                checking = (measures.count, items.count)
                add()
            }
        }
        guard !Task.isCancelled, measures.count == items.count else { checking = nil; return }
        let shots = items.indices.map { measures[$0]! }
        let result = await Task.detached(priority: .userInitiated) { ShotCuller.cull(shots, similar: similar, blurry: blurry) }.value
        guard !Task.isCancelled else { return }
        culled = Dictionary(result.map { (items[$0.key], $0.value) }, uniquingKeysWith: { a, _ in a })
        excluded.formUnion(culled.keys)
        checking = nil
    }

    /// Where a photo goes: its person's folder or the output folder.
    nonisolated static func folder(_ item: ToolItem, _ output: URL, perPerson: Bool) -> URL {
        if perPerson, let name = item.personName { return output.appendingPathComponent(Exporter.folderName(name)) }
        return output
    }

    /// The two crop shapes picked for portraits and landscapes, when there are two.
    static func bothShapes(_ r: EditRecipe) -> [AspectPreset?]? { r.cropByOrientation == true && r.crops ? [r.portraitAspect, r.aspect] : nil }
    static func title(_ a: AspectPreset?) -> String { a?.rawValue ?? "Original" }
    /// For file names: "4x5", "16x9", "original".
    static func tag(_ a: AspectPreset?) -> String { a?.rawValue.replacingOccurrences(of: ":", with: "x") ?? "original" }

    /// The files to write: one per photo, or one per shape ("_4x5", "_16x9") when exporting both shapes. A photo
    /// with its own crop shape goes out once, in that shape.
    func makeJobs(bothShapes: Bool) -> [ExportJob] {
        let shapes = bothShapes ? Self.bothShapes(recipe) : nil
        return chosen.flatMap { item -> [ExportJob] in
            let base = item.url.deletingPathExtension().lastPathComponent + suffix
            guard let shapes, CropPlacements.shared.shape(for: item.url) == nil else { return [ExportJob(item: item, recipe: recipe, name: base)] }
            return shapes.map { shape in
                var r = recipe
                r.cropByOrientation = nil; r.portraitAspect = nil; r.aspect = shape
                return ExportJob(item: item, recipe: r, name: base + "_" + Self.tag(shape))
            }
        }
    }

    /// Asks about the files already in the destination folder (exported there before), then exports.
    func start(bothShapes: Bool) {
        guard let output else { return }
        let jobs = makeJobs(bothShapes: bothShapes), all = items, perPerson = folderPerPerson && fromPeople
        self.jobs = jobs
        answers = [:]
        Task {
            let found = await Task.detached(priority: .userInitiated) { Existing.find(jobs, all: all, output: output, perPerson: perPerson) }.value
            existing = found
            if found.isEmpty { run() } else { questions = found }
        }
    }

    func run() {
        guard let output else { return }
        running = true; finished = false; done = 0; failures = []; skipped = 0; cancel = false
        let jobs = jobs, perPerson = folderPerPerson && fromPeople
        let answers = answers, paths = Dictionary(existing.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        total = jobs.count
        let workers = ToolWork.parallelism
        // Writes over a file only when asked to (an earlier export of the same photo, or a file of the same name in an
        // export folder): never an original, and never another photo of this run with the same name (two cameras
        // both shooting IMG_0001), which gets " (2)".
        let names = OutputNames()
        ToolWork.begin()
        Task.detached(priority: .utility) {
            await withTaskGroup(of: String?.self) { group in
                var next = 0
                func add() async {
                    guard next < jobs.count, !(await MainActor.run { cancel }) else { return }
                    let job = jobs[next], item = job.item, recipe = job.recipe; next += 1
                    group.addTask(priority: .utility) {
                        if answers[job.id] == .skip { return Self.skippedMark }
                        let dir = Self.folder(item, output, perPerson: perPerson)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        // Overwrite: the earlier file's name, with this export's extension (a JPEG replaced by a PNG).
                        var earlier: URL?, dest: URL?
                        if answers[job.id] == .overwrite, let p = paths[job.id] {
                            let old = URL(fileURLWithPath: p), same = old.deletingPathExtension().appendingPathExtension(recipe.fileExtension)
                            if (same.path == old.path || !FileManager.default.fileExists(atPath: same.path)), names.claim(same) { earlier = old; dest = same }
                        }
                        let to = dest ?? names.reserve(in: dir, base: job.name, ext: recipe.fileExtension)
                        do {
                            try EditPipeline.render(item.url, recipe: recipe, focus: item.focus, people: item.people, to: to)
                            if let earlier, earlier.path != to.path { try? FileManager.default.trashItem(at: earlier, resultingItemURL: nil) }
                            ExportHistory.shared.add(item.url, to: to, replacing: earlier?.path)
                            return nil
                        } catch { return "\(to.lastPathComponent): \(error.localizedDescription)" }
                    }
                }
                for _ in 0..<workers { await add() }
                for await r in group {
                    await MainActor.run { done += 1; if r == Self.skippedMark { skipped += 1 } else if let r { failures.append(r) } }
                    await add()
                }
            }
            ExportHistory.shared.save()
            await MainActor.run { running = false; finished = true; ToolWork.end() }
        }
    }
}

/// One file to write: a photo through a recipe, under a name (without extension).
struct ExportJob: Hashable, Sendable {
    var item: ToolItem
    var recipe: EditRecipe
    var name: String
    var id: String { "\(item.url.path)|\(item.personName ?? "")|\(name)" }
}

/// A file of the export already in the destination folder: the photo's earlier export under that name, or a file of
/// the same name.
struct Existing: Identifiable {
    enum Answer: Sendable { case skip, overwrite }
    var job: ExportJob
    var path: String
    /// When the app exported it there; nil for a file it has no record of (an export from an earlier version).
    var date: Date?
    var id: String { job.id }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }

    /// `path` is `url`'s name in `url`'s folder, of any type, or with " (2)"… (given when another photo had the name).
    static func sameName(_ path: String, as url: URL) -> Bool {
        let p = URL(fileURLWithPath: path)
        guard key(p.deletingLastPathComponent()) == key(url.deletingLastPathComponent()) else { return false }
        let stem = p.deletingPathExtension().lastPathComponent.lowercased(), base = url.deletingPathExtension().lastPathComponent.lowercased()
        guard stem != base else { return true }
        return stem.hasPrefix(base + " (") && stem.hasSuffix(")") && Int(stem.dropFirst(base.count + 2).dropLast()) != nil
    }

    /// The files of these jobs already there. A file of the same name counts only in an export folder: never an
    /// original photo (`all` is every photo in the list) or a folder of originals, nor another photo's recorded export.
    static func find(_ jobs: [ExportJob], all: [ToolItem], output: URL, perPerson: Bool) -> [Existing] {
        let history = ExportHistory.shared, sources = history.sources()
        let originals = Set(all.map { key($0.url) }), originalFolders = Set(all.map { key($0.url.deletingLastPathComponent()) })
        var out: [Existing] = [], taken: Set<String> = []
        for job in jobs {
            let dir = BatchExportTool.folder(job.item, output, perPerson: perPerson)
            let url = dir.appendingPathComponent(job.name).appendingPathExtension(job.recipe.fileExtension)
            if let r = history.exports(of: job.item.url).first(where: { sameName($0.path, as: url) }) {
                if taken.insert(key(URL(fileURLWithPath: r.path))).inserted { out.append(Existing(job: job, path: r.path, date: r.date)) }
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path), !originals.contains(key(url)), !originalFolders.contains(key(dir)),
                  sources[url.standardizedFileURL.path] == nil, taken.insert(key(url)).inserted else { continue }
            out.append(Existing(job: job, path: url.path, date: nil))
        }
        return out
    }
}

/// "Already in the destination folder": skip or overwrite, for this photo or all the rest.
struct ExistingSheet: View {
    let existing: Existing
    let remaining: Int
    /// nil stops the export.
    let answer: (Existing.Answer?, _ all: Bool) -> Void
    @State private var all = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                StripThumb(url: existing.job.item.url, selected: false, side: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(existing.job.item.url.lastPathComponent)” is already in the destination folder").font(.headline)
                    Text(existing.date.map { "Exported \($0.formatted(date: .abbreviated, time: .shortened)) as “\((existing.path as NSString).lastPathComponent)”." }
                         ?? "A file named “\((existing.path as NSString).lastPathComponent)” is there.")
                        .foregroundStyle(.secondary)
                    Text("Overwrite replaces it with this export; Skip leaves it as it is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if remaining > 1 { Toggle("Apply to all (\(remaining) photos)", isOn: $all) }
            HStack {
                Button("Stop", role: .cancel) { answer(nil, false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Overwrite") { answer(.overwrite, all) }
                Button("Skip") { answer(.skip, all) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: existing.id) { all = false }
    }
}


/// Undo for the editing screen: the recipe (every slider, crop shape, watermark, size) and the photos' own edits
/// (crops, levels, looks). A slider drag is one step, not one per pixel: changes within a moment of each other
/// coalesce into the first.
@MainActor
final class EditHistory: ObservableObject {
    struct State {
        var recipe: EditRecipe
        /// Each photo's own edit, nil for none, so restoring removes edits made since.
        var edits: [String: CropPlacements.Edit?]
    }

    weak var undoManager: UndoManager?
    var urls: [URL] = [] { didSet { lastEdits = currentEdits() } }
    var setRecipe: ((EditRecipe) -> Void)?
    private var lastEdits: [String: CropPlacements.Edit?] = [:]
    private var lastTime = Date.distantPast
    private var lastKind = ""
    /// The recipe an undo is putting back: its own change is not a new step.
    private var restoring: EditRecipe?

    func currentEdits() -> [String: CropPlacements.Edit?] {
        let found = CropPlacements.shared.edits(for: urls)
        return Dictionary(urls.map { ($0.path, found[$0.path]) }, uniquingKeysWith: { a, _ in a })
    }

    func recipeChanged(from old: EditRecipe, to new: EditRecipe) {
        if let r = restoring, r == new { restoring = nil; return }
        guard old != new else { return }
        step(kind: "recipe", before: State(recipe: old, edits: lastEdits))
    }

    func editsChanged(recipe: EditRecipe) {
        let now = currentEdits()
        guard now != lastEdits else { return }
        let before = lastEdits
        lastEdits = now
        if restoring != nil { return }
        step(kind: "edits", before: State(recipe: recipe, edits: before))
    }

    /// Registers one undo step unless it continues the last one (the same kind of change, a moment ago).
    private func step(kind: String, before: State) {
        let now = Date()
        defer { lastTime = now; lastKind = kind }
        if kind == lastKind, now.timeIntervalSince(lastTime) < 0.8, undoManager?.isUndoRegistrationEnabled == true { return }
        register(before)
    }

    private func register(_ before: State) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { h in
            let now = State(recipe: h.currentRecipe ?? before.recipe, edits: h.currentEdits())
            h.apply(before)
            h.register(now)
        }
        um.setActionName("Edit")
        lastKind = ""
    }

    private var currentRecipe: EditRecipe?

    private func apply(_ s: State) {
        restoring = s.recipe
        currentRecipe = s.recipe
        setRecipe?(s.recipe)
        lastEdits = s.edits
        CropPlacements.shared.restore(s.edits)
        lastTime = .distantPast
    }
}
