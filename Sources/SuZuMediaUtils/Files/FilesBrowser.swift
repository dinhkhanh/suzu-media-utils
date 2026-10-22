import FaceLibrary
import QuickLook
import SwiftUI

/// A folder or a file in the Files browser.
struct FileItem: Identifiable, Hashable {
    /// Absolute path.
    var id: String
    var name: String
    var file: ProjectFile?
    /// Photos and videos anywhere under a folder.
    var count = 0
    var offline = false

    init(folder path: String, name: String? = nil, count: Int, offline: Bool = false) {
        id = path; self.name = name ?? (path as NSString).lastPathComponent; self.count = count; self.offline = offline
    }
    init(_ file: ProjectFile) { id = file.path; name = file.name; self.file = file }

    var isFolder: Bool { file == nil }
    static func items(_ n: Int) -> String { "\(n.formatted()) item\(n == 1 ? "" : "s")" }
    // Sort keys; folders sort among themselves by name.
    var date: Double { file.map { $0.takenAt ?? $0.mtime } ?? 0 }
    var size: Int64 { file?.size ?? 0 }
    /// Stars, with picks just above and rejects below everything.
    var rating: Int { file.map { $0.flag == .reject ? -1 : $0.rating * 2 + ($0.flag == .pick ? 1 : 0) } ?? -2 }
    var kind: String {
        guard let file else { return "Folder" }
        return "\((file.path as NSString).pathExtension.uppercased()) \(file.kind == .photo ? "photo" : "video")"
    }
    /// Why the library has nothing (yet) about the file.
    var note: String? {
        guard let file else { return nil }
        if file.duplicate { return "Copy of another file" }
        switch file.status {
        case .pending: return "Processing…"
        case .failed: return "Couldn't read"
        case .done: return nil
        }
    }
    var people: String {
        guard let file else { return "" }
        if !file.people.isEmpty { return file.people.joined(separator: ", ") }
        return file.faces > 0 ? "\(file.faces) face\(file.faces == 1 ? "" : "s")" : ""
    }
}

enum FileFilter: String, CaseIterable, Identifiable {
    case all, photos, videos
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "Photos & Videos"
        case .photos: "Photos"
        case .videos: "Videos"
        }
    }
}

enum FlagFilter: String, CaseIterable, Identifiable {
    case all, hideRejects, picks, unflagged, rejects
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "Any Flag"
        case .hideRejects: "Hide Rejects"
        case .picks: "Picks Only"
        case .unflagged: "Unflagged Only"
        case .rejects: "Rejects Only"
        }
    }
    func allows(_ f: PickFlag) -> Bool {
        switch self {
        case .all: true
        case .hideRejects: f != .reject
        case .picks: f == .pick
        case .unflagged: f == .none
        case .rejects: f == .reject
        }
    }
}

enum FileSort: String, CaseIterable, Identifiable {
    case name, date, rating, size, kind
    var id: Self { self }
    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date Taken"
        case .rating: "Rating"
        case .size: "Size"
        case .kind: "Kind"
        }
    }
    func comparator(_ order: SortOrder) -> KeyPathComparator<FileItem> {
        switch self {
        case .name: KeyPathComparator(\.name, comparator: .localizedStandard, order: order)
        case .date: KeyPathComparator(\.date, order: order)
        case .rating: KeyPathComparator(\.rating, order: order)
        case .size: KeyPathComparator(\.size, order: order)
        case .kind: KeyPathComparator(\.kind, order: order)
        }
    }
}

/// The open project's photos and videos folder by folder, like Finder: icons or a list, Quick Look (space), open
/// (photos in Edit & Export, videos in their app), show in Finder and export. Read from the library, so it also
/// shows who is in each file, filters by people, and keeps culling marks (stars, labels, picks and rejects).
struct FilesBrowser: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.openWindow) private var openWindow
    @State private var files: [ProjectFile] = []
    @State private var loaded = false
    /// The folder shown; nil = the project's folders.
    @State private var folder: String?
    @State private var back: [String?] = []
    @State private var forward: [String?] = []
    @State private var items: [FileItem] = []
    /// People in the folder (and its subfolders) with how many files each is in, most first.
    @State private var present: [(id: Int64, count: Int)] = []
    /// Show only files with all of these people in them.
    @State private var withPeople: Set<Int64> = []
    @State private var selection: Set<String> = []
    @State private var preview: URL?
    @State private var search = ""
    @State private var exportScope: ExportScope?
    @State private var confirmWrite: [Int64]?
    @State private var writeResult: String?
    @FocusState private var focused: Bool
    @AppStorage("files.list") private var asList = false
    @AppStorage("files.filter") private var filter = FileFilter.all
    @AppStorage("files.minRating") private var minRating = 0
    @AppStorage("files.flag") private var flagFilter = FlagFilter.all
    /// "" any, "none" or a ColorLabel.
    @AppStorage("files.label") private var labelFilter = ""
    @AppStorage("files.sort") private var sortKey = FileSort.name
    @AppStorage("files.ascending") private var ascending = true
    @AppStorage("files.subfolders") private var subfolders = false
    @AppStorage("files.iconSize") private var iconSize = 140.0

    private struct Listing: Equatable {
        var folder: String?, filter: FileFilter, minRating: Int, flag: FlagFilter, label: String, people: Set<Int64>
        var sort: FileSort, ascending: Bool, subfolders: Bool, search: String
    }
    private var listing: Listing {
        Listing(folder: folder, filter: filter, minRating: minRating, flag: flagFilter, label: labelFilter, people: withPeople,
                sort: sortKey, ascending: ascending, subfolders: subfolders, search: search)
    }
    var marksFiltered: Bool { minRating > 0 || flagFilter != .all || !labelFilter.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if !present.isEmpty {
                PeopleFilterBar(present: present, selected: $withPeople)
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            pathBar
        }
        .navigationTitle(folder.map { ($0 as NSString).lastPathComponent } ?? model.projectName)
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Name or person")
        .toolbar { toolbar }
        .onWindowKeys(key)
        .quickLookPreview($preview, in: items.compactMap { $0.file?.url })
        .sheet(item: $exportScope) { ExportSheet(scope: $0, mode: .copy, initialName: folder.map { ($0 as NSString).lastPathComponent } ?? model.projectName) }
        .confirmationDialog("Write ratings and labels into \(confirmWrite?.count ?? 0) file\(confirmWrite?.count == 1 ? "" : "s")?",
                            isPresented: Binding(get: { confirmWrite != nil }, set: { if !$0 { confirmWrite = nil } })) {
            Button("Write to Files") {
                let ids = confirmWrite ?? []
                Task { writeResult = await model.writeMarksToFiles(ids) }
            }
        } message: {
            Text("Lightroom, Bridge and Photo Mechanic can then read them (in Lightroom: Metadata → Read Metadata from Files). This changes the original photos' metadata; the pixels stay as they are. Rejects are written as rating −1. Videos and RAW files are skipped.")
        }
        .alert("Ratings & Labels", isPresented: Binding(get: { writeResult != nil }, set: { if !$0 { writeResult = nil } })) {
            Button("OK") { writeResult = nil }
        } message: {
            Text(writeResult ?? "")
        }
        .task(id: model.currentProject) {
            folder = nil; back = []; forward = []; selection = []; withPeople = []; files = []; loaded = false
            // Files arrive and get processed in the background: re-read when the library changed, at most every 3 s.
            var stats: LibraryStats?, people: [PersonSummary] = [], marks = -1
            while !Task.isCancelled {
                if model.store != nil, !loaded || model.stats != stats || model.people != people || model.marksVersion != marks {
                    stats = model.stats; people = model.people; marks = model.marksVersion
                    await load()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: files) { relist() }
        .onChange(of: listing) { relist() }
        .onChange(of: model.sources) { relist() }
    }

    @ViewBuilder var content: some View {
        if let error = model.startupError {
            ContentUnavailableView("Can't open the library", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if !loaded {
            ProgressView()
        } else if model.projectSources.isEmpty {
            ContentUnavailableView {
                Label("No folders yet", systemImage: "folder")
            } description: {
                Text("Add this event's photo and video folders (local, external drive or NAS).")
            } actions: {
                Button("Add Folder…") { model.addFolder(kind: .media) }
            }
        } else if items.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if marksFiltered || !withPeople.isEmpty {
                ContentUnavailableView {
                    Label("Nothing matches the filters", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Filters") { clearFilters() }
                }
            } else {
                ContentUnavailableView("No \(filter == .all ? "photos or videos" : filter.title.lowercased()) here", systemImage: "photo.on.rectangle")
            }
        } else if asList {
            list
        } else {
            grid
        }
    }

    var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize + 8, maximum: iconSize + 48), spacing: 10, alignment: .top)], spacing: 14) {
                ForEach(items) { item in
                    FileIcon(item: item, side: iconSize, selected: selection.contains(item.id))
                        .onTapGesture(count: 2) { open([item.id]) }
                        .onTapGesture { selection.click(item.id); focused = true }
                        .contextMenu { menu(for: selection.contains(item.id) ? selection : [item.id]) }
                }
            }
            .padding(16)
        }
        // A click between icons clears the selection, as in Finder.
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { selection = []; focused = true } }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
    }

    var list: some View {
        Table(items, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    FileIcon.small(item)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let l = item.file?.label { Circle().fill(l.color).frame(width: 8, height: 8) }
                }
                .opacity(item.file?.flag == .reject ? 0.45 : 1)
            }
            .width(min: 180, ideal: 300)
            TableColumn("Rating", value: \.rating) { item in
                if let f = item.file {
                    HStack(spacing: 6) {
                        StarsView(rating: f.rating, size: 9) { mark(.rating($0), [item.id]) }
                        FlagBadge(flag: f.flag, size: 10)
                    }
                }
            }
            .width(min: 80, ideal: 100)
            TableColumn("People") { item in Text(item.people).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 180)
            TableColumn("Date Taken", value: \.date) { item in
                Text(item.isFolder ? "--" : Date(timeIntervalSince1970: item.date).formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? FileItem.items(item.count) : item.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { item in
                Text(item.note.map { "\(item.kind) · \($0)" } ?? item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in menu(for: ids) } primaryAction: { ids in open(ids) }
    }

    /// Project › folder › subfolder…, the filters in use, then how many items; drag the slider for bigger icons.
    var pathBar: some View {
        HStack(spacing: 3) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button { go(to: c.path) } label: {
                    Label(c.title, systemImage: c.path == nil ? "calendar" : "folder").lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(c.path == folder ? .primary : .secondary)
            }
            Spacer(minLength: 12)
            if marksFiltered || !withPeople.isEmpty {
                Button { clearFilters() } label: {
                    Label(filterSummary, systemImage: "xmark.circle.fill").lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Clear the filters")
                .padding(.trailing, 8)
            }
            Text(selection.isEmpty ? FileItem.items(items.count) : "\(selection.count) of \(items.count.formatted()) selected")
                .foregroundStyle(.secondary)
            if !asList {
                Slider(value: $iconSize, in: 80...320).frame(width: 110).controlSize(.mini).padding(.leading, 8)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    var filterSummary: String {
        var parts: [String] = []
        if !withPeople.isEmpty { parts.append(withPeople.count == 1 ? "1 person" : "\(withPeople.count) people") }
        if minRating > 0 { parts.append(String(repeating: "★", count: minRating) + (minRating < 5 ? "+" : "")) }
        if flagFilter != .all { parts.append(flagFilter.title) }
        if labelFilter == "none" { parts.append("No label") } else if let l = ColorLabel(rawValue: labelFilter) { parts.append(l.title) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(back.isEmpty).keyboardShortcut("[", modifiers: .command)
            Button { goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(forward.isEmpty).keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItem {
            Picker("View", selection: $asList) {
                Label("Icons", systemImage: "square.grid.2x2").tag(false)
                Label("List", systemImage: "list.bullet").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Show as icons or as a list")
        }
        ToolbarItem {
            Menu {
                Picker("Show", selection: $filter) { ForEach(FileFilter.allCases) { Text($0.title).tag($0) } }
                Toggle("Include Files in Subfolders", isOn: $subfolders)
                Divider()
                Picker("Rating", selection: $minRating) {
                    Text("Any Rating").tag(0)
                    ForEach(1...5, id: \.self) { n in Text(String(repeating: "★", count: n) + (n < 5 ? " and up" : "")).tag(n) }
                }
                Picker("Flag", selection: $flagFilter) { ForEach(FlagFilter.allCases) { Text($0.title).tag($0) } }
                Picker("Label", selection: $labelFilter) {
                    Text("Any Label").tag("")
                    ForEach(ColorLabel.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    Text("No Label").tag("none")
                }
                Divider()
                Picker("Sort By", selection: $sortKey) { ForEach(FileSort.allCases) { Text($0.title).tag($0) } }
                Picker("Order", selection: $ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: {
                Label("View Options", systemImage: marksFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem {
            Menu {
                Button("Cull Everything Shown") { cull(nil) }
                Button("Cull Selection") { cull(selectedFiles) }.disabled(selectedFiles.count < 2)
                Divider()
                let hinted = shownFiles.filter { ($0.eyesClosed || $0.soft) && $0.flag == .none }
                Button("Reject \(hinted.count) Shot\(hinted.count == 1 ? "" : "s") with Closed Eyes or Soft Focus") { mark(.flag(.reject), Set(hinted.map(\.path))) }
                    .disabled(hinted.isEmpty)
                Divider()
                Button("Write Ratings & Labels to Files…") { confirmWrite = (selectedFiles.isEmpty ? shownFiles : selectedFiles).map(\.id) }
                    .disabled(shownFiles.isEmpty)
            } label: {
                Label("Cull", systemImage: "rectangle.stack.badge.play")
            } primaryAction: {
                cull(selectedFiles.count > 1 ? selectedFiles : nil)
            }
            .help("Go through the photos one by one, full screen, to rate, pick and reject (F)")
            .disabled(shownFiles.isEmpty)
        }
        ToolbarItem {
            Button { export(selection.isEmpty ? Set(items.map(\.id)) : selection) } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .help("Copy the selected files (or everything shown) into a folder")
            .disabled(items.isEmpty)
        }
    }

    @ViewBuilder func menu(for ids: Set<String>) -> some View {
        let chosen = items.filter { ids.contains($0.id) }
        let urls = chosen.map { URL(fileURLWithPath: $0.id, isDirectory: $0.isFolder) }
        let chosenFiles = chosen.compactMap(\.file)
        if chosen.count == 1, let f = chosen.first, f.isFolder {
            Button("Open") { go(to: f.id) }
        } else if !chosenFiles.isEmpty {
            Button(chosenFiles.count > 1 ? "Open \(chosenFiles.count) Files" : "Open") { open(ids) }
            Button("Quick Look") { preview = chosenFiles.first?.url }
            Button("Open With Default App") { chosenFiles.forEach { NSWorkspace.shared.open($0.url) } }
            if chosenFiles.count > 1 { Button("Cull \(chosenFiles.count) Files") { cull(chosenFiles) } }
            Divider()
            MarkMenu(files: chosenFiles) { mark($0, ids) }
            Button("Write Ratings & Labels to File\(chosenFiles.count == 1 ? "" : "s")…") { confirmWrite = chosenFiles.map(\.id) }
        }
        if !chosen.isEmpty {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.map(\.id).joined(separator: "\n"), forType: .string)
            }
            Button("Export…") { export(ids) }
        }
    }

    /// Plain keys: culling marks on the selection, space for Quick Look, return to open, F to cull.
    func key(_ event: NSEvent) -> Bool {
        if event.keyCode == KeyCode.space {
            if preview != nil { preview = nil } else { preview = selectedFiles.first?.url }
            return preview != nil || !selection.isEmpty
        }
        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.enter {
            guard !selection.isEmpty else { return false }
            open(selection)
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "f", !shownFiles.isEmpty {
            cull(selectedFiles.count > 1 ? selectedFiles : nil)
            return true
        }
        guard !selectedFiles.isEmpty, let change = MarkChange.forKey(event, current: selectedFiles) else { return false }
        mark(change, selection)
        return true
    }

    // MARK: - Data

    var shownFiles: [ProjectFile] { items.compactMap(\.file) }
    var selectedFiles: [ProjectFile] { items.compactMap { selection.contains($0.id) ? $0.file : nil } }

    var subtitle: String {
        let shown = shownFiles
        guard !shown.isEmpty else { return "" }
        let videos = shown.filter { $0.kind == .video }.count
        let photos = shown.count - videos
        return "\(photos.formatted()) photo\(photos == 1 ? "" : "s") · \(videos.formatted()) video\(videos == 1 ? "" : "s")"
    }

    /// The project, then the folder of the project the shown folder is in, then each subfolder.
    var crumbs: [(title: String, path: String?)] {
        var result: [(String, String?)] = [(model.projectName, nil)]
        guard let folder, let source = model.projectSources.first(where: { folder == $0.path || folder.hasPrefix($0.path + "/") })
        else { return result }
        var path = source.path
        result.append((source.name, path))
        for part in folder.dropFirst(source.path.count).split(separator: "/") {
            path += "/" + part
            result.append((String(part), path))
        }
        return result
    }

    func load() async {
        guard let store = model.store else { return }
        let project = model.currentProject
        let list = await Task.detached(priority: .userInitiated) {
            (try? store.db.read { db in try ProjectFiles.list(db, project: project) }) ?? []
        }.value
        guard project == model.currentProject, !Task.isCancelled else { return }
        if list != files { files = list }
        // SUZU_START_CULL=1 | <part of a file name> (testing): cull everything as soon as the files are in.
        if !loaded, let start = ProcessInfo.processInfo.environment["SUZU_START_CULL"], !list.isEmpty {
            openWindow(id: "cull", value: CullRequest(ids: list.map(\.id), start: list.first { $0.name.contains(start) }?.id, title: model.projectName))
        }
        loaded = true
    }

    /// Rebuilds what's shown from the files, the folder, the filters and the order.
    func relist() {
        let label = ColorLabel(rawValue: labelFilter)
        // Everything in the folder and its subfolders: the people found there, and what a search or people filter covers.
        let scope = (folder.map { ProjectFiles.contents(of: $0, in: files, recursive: true).files } ?? files)
            .filter { f in filter == .all || f.kind == (filter == .photos ? .photo : .video) }
        var counts: [Int64: Int] = [:]
        for f in scope { for p in f.personIds { counts[p, default: 0] += 1 } }
        present = counts.map { (id: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
        withPeople.formIntersection(counts.keys)

        let pool = scope.filter { f in
            f.rating >= minRating && flagFilter.allows(f.flag)
                && (labelFilter.isEmpty || (labelFilter == "none" ? f.label == nil : f.label == label))
                && withPeople.isSubset(of: f.personIds)
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        // Searching and filtering by marks or people look in every subfolder, as Finder's search does.
        let flat = subfolders || !query.isEmpty || marksFiltered || !withPeople.isEmpty
        var result: [FileItem]
        if let folder, !flat {
            let c = ProjectFiles.contents(of: folder, in: pool)
            result = c.folders.map { FileItem(folder: $0.key, count: $0.value) } + c.files.map(FileItem.init)
        } else if flat {
            result = pool.map(FileItem.init)
        } else {
            result = model.projectSources.map { s in
                FileItem(folder: s.path, name: s.name, count: pool.count { $0.path.hasPrefix(s.path + "/") }, offline: !s.online)
            }
        }
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.people.localizedCaseInsensitiveContains(query) }
        }
        result.sort(using: sortKey.comparator(ascending ? .forward : .reverse))
        items = result.filter(\.isFolder) + result.filter { !$0.isFolder }
        selection.formIntersection(items.map(\.id))
    }

    /// The table's header clicks and the Sort By menu share one order.
    var sortOrder: Binding<[KeyPathComparator<FileItem>]> {
        Binding {
            [sortKey.comparator(ascending ? .forward : .reverse)]
        } set: { order in
            guard let c = order.first, let key = FileSort.allCases.first(where: { $0.comparator(.forward).keyPath == c.keyPath }) else { return }
            sortKey = key
            ascending = c.order == .forward
        }
    }

    // MARK: - Actions

    func clearFilters() {
        minRating = 0; flagFilter = .all; labelFilter = ""; withPeople = []
    }

    func go(to path: String?) {
        guard path != folder else { return }
        back.append(folder)
        forward = []
        folder = path
        selection = []
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(folder)
        // Coming back out of a folder selects it, as in Finder.
        selection = folder.map { [$0] } ?? []
        folder = previous
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(folder)
        folder = next
        selection = []
    }

    /// One folder: go into it. Files: photos open in Edit & Export, videos in their own app.
    func open(_ ids: Set<String>) {
        let chosen = items.filter { ids.contains($0.id) }
        if chosen.count == 1, let f = chosen.first, f.isFolder { return go(to: f.id) }
        let paths = chosen.compactMap(\.file?.path)
        if !paths.isEmpty { openWindow.edit(paths) }
    }

    /// Marks the files among `paths` at once here, then saves.
    func mark(_ change: MarkChange, _ paths: Set<String>) {
        var ids: [Int64] = []
        for i in files.indices where paths.contains(files[i].path) {
            files[i].apply(change)
            ids.append(files[i].id)
        }
        model.mark(ids, change)
    }

    /// The culling window with these files (nil: everything shown), starting at the selected one.
    func cull(_ chosen: [ProjectFile]?) {
        let list = chosen ?? shownFiles
        guard !list.isEmpty else { return }
        let start = chosen == nil ? selectedFiles.first?.id : nil
        openWindow(id: "cull", value: CullRequest(ids: list.map(\.id), start: start, title: folder.map { ($0 as NSString).lastPathComponent } ?? model.projectName))
    }

    /// Copies the chosen files, and everything under the chosen folders, into one folder.
    func export(_ ids: Set<String>) {
        var media: [Int64] = []
        for item in items where ids.contains(item.id) {
            if let f = item.file { media.append(f.id) } else { media += ProjectFiles.contents(of: item.id, in: files, recursive: true).files.map(\.id) }
        }
        guard !media.isEmpty else { return }
        exportScope = .media(media, title: folder.map { ($0 as NSString).lastPathComponent } ?? model.projectName)
    }
}

/// The people in the folder as face chips; click some to show only the files they're all in.
struct PeopleFilterBar: View {
    @EnvironmentObject var model: FaceGroupingModel
    let present: [(id: Int64, count: Int)]
    @Binding var selected: Set<Int64>

    /// Named people first (most files first), then unnamed groups.
    var ordered: [(person: PersonSummary?, id: Int64, count: Int)] {
        let byId = Dictionary(model.people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            .merging(model.knownPeople.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let all = present.map { (person: byId[$0.id], id: $0.id, count: $0.count) }
        return all.filter { $0.person?.name != nil } + all.filter { $0.person?.name == nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2").foregroundStyle(.secondary).help("Show only files with these people")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ordered, id: \.id) { p in
                        let on = selected.contains(p.id)
                        Button {
                            if on { selected.remove(p.id) } else { selected.insert(p.id) }
                        } label: {
                            HStack(spacing: 5) {
                                FaceImage(faceId: p.person?.coverFaceId, side: 22).clipShape(Circle())
                                if let name = p.person?.name { Text(name).lineLimit(1) }
                                Text(p.count.formatted()).foregroundStyle(on ? .white.opacity(0.8) : .secondary)
                            }
                            .font(.caption)
                            .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                            .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.12)))
                            .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(p.person?.name ?? "Unnamed person")
                    }
                }
                .padding(.vertical, 6)
            }
            if !selected.isEmpty {
                Button("Clear") { selected = [] }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// A Finder-style icon: the photo or a frame of the video, whole (not cropped), with the name under it, then the
/// colour label, stars and flag.
struct FileIcon: View {
    let item: FileItem
    let side: CGFloat
    var selected = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let file = item.file {
                    FileThumbnail(file: file, side: side)
                        .opacity(file.flag == .reject ? 0.4 : 1)
                } else {
                    Image(systemName: item.offline ? "externaldrive.badge.xmark" : "folder.fill")
                        .font(.system(size: side * 0.5))
                        .foregroundStyle(item.offline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .frame(width: side, height: side)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.secondary.opacity(0.22) : .clear))
            HStack(spacing: 4) {
                if let l = item.file?.label { Circle().fill(l.color).frame(width: 8, height: 8) }
                Text(item.name)
                    .font(.caption)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear))
            .foregroundStyle(selected ? .white : .primary)
            if let f = item.file, f.rating > 0 || f.flag != .none {
                HStack(spacing: 5) {
                    if f.rating > 0 { StarsView(rating: f.rating, size: 8) }
                    FlagBadge(flag: f.flag, size: 9)
                }
            }
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(width: side + 8)
        .contentShape(Rectangle())
        .help(item.file.map { [$0.name, item.people, item.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") } ?? item.name)
    }

    var detail: String? {
        if item.isFolder { return item.offline ? "Offline" : FileItem.items(item.count) }
        return item.note ?? (item.people.isEmpty ? nil : item.people)
    }

    /// The list's icon in the Name column.
    @ViewBuilder static func small(_ item: FileItem) -> some View {
        if let file = item.file {
            FileThumbnail(file: file, side: 18, badges: false)
        } else {
            Image(systemName: item.offline ? "externaldrive.badge.xmark" : "folder.fill").foregroundStyle(.tint).frame(width: 18, height: 18)
        }
    }
}

/// A photo, or a frame near the start of a video, fitted in a square, with the video's length, the file's status,
/// a pick's flag and closed-eyes / soft-focus warnings.
struct FileThumbnail: View {
    let file: ProjectFile
    let side: CGFloat
    var badges = true
    @State private var image: NSImage?

    /// Thumbnails come in a few sizes so the icon-size slider doesn't make new ones at every step.
    var pixels: CGFloat { side <= 40 ? 40 : side <= 180 ? 180 : 320 }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 4 : 2))
                    .overlay(alignment: .bottomTrailing) { if badges, file.kind == .video { length } }
                    .overlay(alignment: .topLeading) { if badges { status } }
                    .overlay(alignment: .topTrailing) { if badges { marks } }
                    .shadow(color: .black.opacity(side > 40 ? 0.2 : 0), radius: 2, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    .aspectRatio(1.5, contentMode: .fit)
                    .overlay { Image(systemName: file.kind == .video ? "film" : "photo").foregroundStyle(.tertiary) }
            }
        }
        .frame(width: side, height: side)
        .task(id: "\(file.path)#\(pixels)") {
            // A frame a moment in: many videos open on black.
            let time = file.kind == .video ? min(1, (file.duration ?? 2) / 2) : nil
            image = await Thumbnails.shared.media(file.url, time: time, side: pixels)
        }
    }

    @ViewBuilder var length: some View {
        Label(file.duration.map(MediaThumbnail.timecode) ?? "", systemImage: "play.fill")
            .font(.caption2.monospacedDigit())
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(4)
    }

    @ViewBuilder var status: some View {
        let icon: String? = file.duplicate ? "doc.on.doc.fill" : file.status == .pending ? "clock.fill" : file.status == .failed ? "exclamationmark.triangle.fill" : nil
        if let icon {
            Image(systemName: icon)
                .font(.caption2)
                .padding(3)
                .background(.black.opacity(0.6), in: Circle())
                .foregroundStyle(file.status == .failed ? .yellow : .white)
                .padding(4)
        }
    }

    @ViewBuilder var marks: some View {
        if file.flag == .pick || file.eyesClosed || file.soft {
            HStack(spacing: 3) {
                if file.eyesClosed { Image(systemName: "eye.slash").foregroundStyle(.orange) }
                if file.soft { Image(systemName: "camera.metering.unknown").foregroundStyle(.orange) }
                if file.flag == .pick { FlagBadge(flag: .pick, size: 9, onImage: true) }
            }
            .font(.system(size: 9))
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(4)
            .help([file.eyesClosed ? "Eyes closed" : nil, file.soft ? "Soft focus" : nil, file.flag == .pick ? "Pick" : nil].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

/// The Files browser's place in the sidebar, above Face Grouping.
struct FilesSidebar: View {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some View {
        Section("Library") {
            Label("Files", systemImage: "folder")
                .badge(model.stats.files)
                .tag(AppRoute.files)
        }
    }
}
