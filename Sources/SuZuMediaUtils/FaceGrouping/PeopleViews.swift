import FaceLibrary
import SwiftUI

enum PeopleFilter: String, CaseIterable, Identifiable {
    case all = "All", named = "Named", unnamed = "Unnamed"
    var id: String { rawValue }
}

struct PeopleGrid: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Binding var path: NavigationPath
    @State private var search = ""
    @State private var filter = PeopleFilter.all
    @State private var selected: Set<Int64> = []
    @FocusState private var editing: Int64?
    @State private var suggesting = false
    @State private var exportAll: ExportMode?
    @State private var galleryExport = false

    var shown: [PersonSummary] {
        model.people.filter { p in
            p.faces > 0
                && (filter == .all || (filter == .named) == (p.name != nil))
                && (search.isEmpty || (p.name ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
        SessionBar()
        ScrollView {
            if shown.isEmpty {
                ContentUnavailableView(model.people.isEmpty ? "No people yet" : "No matches", systemImage: "person.2",
                                       description: Text(model.people.isEmpty ? "Add a folder; groups appear as files are processed." : ""))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 18) {
                ForEach(shown) { p in
                    PersonGridCell(person: p, selected: selected.contains(p.id), mergeCount: selected.count > 1 && selected.contains(p.id) ? selected.count : 0,
                                   known: model.knownPeople.filter { $0.id != p.id }, editing: editing == p.id, focus: $editing,
                                   open: { path.append(PersonRoute(id: p.id)) },
                                   click: {
                                       if NSEvent.modifierFlags.contains(.command) {
                                           if selected.contains(p.id) { selected.remove(p.id) } else { selected.insert(p.id) }
                                       } else {
                                           selected = [p.id]
                                       }
                                   },
                                   mergeSelected: { model.merge(selected); selected = [] },
                                   thisIs: { model.mergeInto(p.id, $0) },
                                   rename: { commitName($0, for: p) })
                        .equatable()
                }
            }
            .padding(20)
        }
        }
        .navigationTitle(model.currentSession.map { "People · \(model.sessionTitle($0))" } ?? "People")
        .navigationSubtitle("\(shown.count) people · click a name to edit, double-click to open, ⌘-click to select several")
        .searchable(text: $search, prompt: "Search names")
        .sheet(isPresented: $suggesting) { CelebritySheet() }
        .sheet(item: $exportAll) { ExportSheet(scope: .all, mode: $0) }
        .sheet(isPresented: $galleryExport) { GalleryExportSheet() }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(PeopleFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Menu {
                    Button("Copy All to Person Folders…") { exportAll = .copy }
                    Button("Move All to Person Folders…") { exportAll = .move }
                    Divider()
                    Button("Export Web Gallery…") { galleryExport = true }
                } label: {
                    Label("Export All", systemImage: "folder.badge.person.crop")
                }
                .help("Copy or move every named person's photos and videos into folders named after them, in one go")
            }
            ToolbarItem {
                Button { suggesting = true } label: { Label("Suggest Names…", systemImage: "sparkles") }
                    .help("Look up unnamed groups with Amazon Rekognition celebrity recognition")
            }
            ToolbarItem {
                Button("Merge") { model.merge(selected); selected = [] }
                    .disabled(selected.count < 2)
                    .help("Merge the selected people into one (keeps the name if one of them is named)")
            }
        }
    }
}

extension PeopleGrid {
    /// Saves an inline rename, then moves the cursor to the next unnamed person for fast labelling.
    func commitName(_ raw: String, for person: PersonSummary) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let list = shown
        let next = list.drop { $0.id != person.id }.dropFirst().first { $0.name == nil }
            ?? list.first { $0.name == nil && $0.id != person.id }
        if !name.isEmpty && name != person.name { model.rename(person.id, to: name) }
        editing = person.name == nil && !name.isEmpty ? next?.id : nil
    }
}

/// One person in the grid, with its clicks and right-click menu. Equatable on its data alone, so the model's
/// background updates (counts, progress) don't redraw it, and don't rebuild its menu while that is open: a menu
/// rebuilt under the mouse flashes, and its "This Is ▸ name" submenu can't be clicked.
struct PersonGridCell: View, Equatable {
    let person: PersonSummary
    let selected: Bool
    /// How many people the selection holds when this one is part of it (0: no merge item).
    let mergeCount: Int
    /// Everyone named, in any project, other than this person.
    let known: [PersonSummary]
    /// This person's name is being edited.
    let editing: Bool
    var focus: FocusState<Int64?>.Binding
    let open: () -> Void
    let click: () -> Void
    let mergeSelected: () -> Void
    let thisIs: (Int64) -> Void
    let rename: (String) -> Void

    static func == (a: PersonGridCell, b: PersonGridCell) -> Bool {
        a.person == b.person && a.selected == b.selected && a.mergeCount == b.mergeCount && a.known == b.known && a.editing == b.editing
    }

    var body: some View {
        PersonCell(person: person, selected: selected, editing: focus, onRename: rename)
            .onTapGesture(count: 2, perform: open)
            .onTapGesture(perform: click)
            .contextMenu {
                Button("Open", action: open)
                if mergeCount > 1 { Button("Merge \(mergeCount) People", action: mergeSelected) }
                ThisIsMenu(others: known, merge: thisIs)
            }
    }
}

struct PersonCell: View {
    let person: PersonSummary
    let selected: Bool
    var editing: FocusState<Int64?>.Binding?
    var onRename: ((String) -> Void)?
    @State private var name = ""

    var body: some View {
        VStack(spacing: 6) {
            FaceImage(faceId: person.coverFaceId, side: 110)
                .clipShape(Circle())
                .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            if let editing, let onRename {
                // Inline name field: click, type, Return. Escape restores the old name.
                TextField("Add name", text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.headline)
                    .focused(editing, equals: person.id)
                    .knownNameSuggestions(for: name)
                    .onSubmit { onRename(name) }
                    .onExitCommand { name = person.name ?? ""; editing.wrappedValue = nil }
                    .onAppear { name = person.name ?? "" }
                    .onChange(of: person.name) { name = person.name ?? "" }
            } else {
                Text(person.displayName)
                    .font(.headline)
                    .foregroundStyle(person.name == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            Text(counts).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 130)
        .contentShape(Rectangle())
    }

    var counts: String {
        var parts = ["\(person.photos) photo\(person.photos == 1 ? "" : "s")"]
        if person.videos > 0 { parts.append("\(person.videos) video\(person.videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

enum MediaSort: String, CaseIterable, Identifiable {
    case best = "Best First", time = "By Time", name = "By Name"
    var id: String { rawValue }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case photos = "Photos", videos = "Videos", faces = "Faces"
    var id: String { rawValue }
}

struct PersonDetail: View {
    @EnvironmentObject var model: FaceGroupingModel
    let personId: Int64
    @Binding var path: NavigationPath
    @State private var name = ""
    @State private var tab = DetailTab.photos
    @State private var media: [PersonMedia] = []
    @State private var faces: [FaceItem] = []
    @State private var alsoWith: Set<Int64> = []
    @State private var selectedFaces: Set<Int64> = []
    /// Photos and videos selected in the grid (⌘-click for several), for Open.
    @State private var selectedMedia: Set<Int64> = []
    @Environment(\.openWindow) private var openWindow
    @State private var export: ExportMode?
    @State private var sort = MediaSort.best
    @State private var collapseBursts = true
    @State private var topN: Int?
    @State private var notifyRule = false
    @State private var videoExport = false
    @State private var otherProjects: [String] = []

    var person: PersonSummary? { model.people.first { $0.id == personId } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                switch tab {
                case .photos: mediaGrid(shown(.photo), empty: "No photos of this person")
                case .videos: mediaGrid(shown(.video), empty: "No videos of this person")
                case .faces: faceGrid
                }
            }
        }
        .navigationTitle(person?.displayName ?? "Person")
        .toolbar { toolbar }
        .task(id: reloadKey) { await reload() }
        .onAppear { name = person?.name ?? "" }
        .sheet(isPresented: $notifyRule) { RuleSheet(presetPerson: personId, notifyOnly: true) }
        .sheet(isPresented: $videoExport) { VideoExportSheet(personId: personId, name: person?.name ?? "Person") }
        .sheet(item: $export) { mode in
            ExportSheet(scope: .person(personId), mode: mode, initialName: person?.name ?? name)
        }
    }

    /// Reload when the person's contents change (new files assigned, edits) or the filter changes.
    var reloadKey: String { "\(person?.faces ?? 0)-\(person?.name ?? "")-\(alsoWith.sorted())-\(model.sessionRange.map { "\($0)" } ?? "")" }

    func reload() async {
        async let m = model.media(of: personId, alsoWith: alsoWith)
        async let f = model.faces(of: personId)
        async let o = model.otherProjects(of: personId)
        let (newMedia, newFaces, others) = await (m, f, o)
        guard !Task.isCancelled else { return }
        otherProjects = others
        media = newMedia
        faces = newFaces
        selectedFaces = selectedFaces.intersection(faces.map(\.id))
    }

    var header: some View {
        HStack(spacing: 16) {
            FaceImage(faceId: person?.coverFaceId, side: 84).clipShape(Circle())
                .contextMenu {
                    Button("Pick Best Shot Automatically") { model.setCover(personId, faceId: nil) }
                }
                .help("Right-click a photo or face to use it as the picture")
            VStack(alignment: .leading, spacing: 6) {
                TextField("Add a name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title.bold())
                    .knownNameSuggestions(for: name)
                    .onSubmit(commitName)
                if !otherProjects.isEmpty {
                    Label("Also in \(otherProjects.prefix(3).joined(separator: ", "))\(otherProjects.count > 3 ? " and \(otherProjects.count - 3) more" : "")",
                          systemImage: "calendar.badge.checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Recognised in these projects too: a name given here applies to all of them")
                }
                HStack(spacing: 12) {
                    if let p = person { Text(PersonCell(person: p, selected: false).counts).foregroundStyle(.secondary) }
                    filterMenu
                    ForEach(Array(alsoWith), id: \.self) { id in
                        Button {
                            alsoWith.remove(id)
                        } label: {
                            Label("with \(model.people.first { $0.id == id }?.displayName ?? "?")", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Spacer()
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { t in Text(tabTitle(t)).tag(t) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        .padding(16)
    }

    var filterMenu: some View {
        Menu("Also with…") {
            ForEach(model.people.filter { $0.name != nil && $0.id != personId && !alsoWith.contains($0.id) }) { p in
                Button(p.displayName) { alsoWith.insert(p.id) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Only show files where this person appears together with someone else")
    }

    func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != person?.name else { return }
        let survivor = model.rename(personId, to: trimmed)
        if survivor != personId, !path.isEmpty {
            // Merged into an existing person with that name: show the survivor instead.
            path.removeLast()
            path.append(PersonRoute(id: survivor))
        }
    }

    /// The grid after session filter, sort, burst collapsing and Top N.
    func shown(_ kind: MediaKind) -> [PersonMedia] {
        var items = media.filter { $0.kind == kind }
        if collapseBursts {
            var best: [Int64: Int] = [:]
            var out: [PersonMedia] = []
            for item in items.sorted(by: { $0.score > $1.score }) {
                if let b = item.burstId, let i = best[b] { out[i].hiddenInBurst += 1; continue }
                if let b = item.burstId { best[b] = out.count }
                out.append(item)
            }
            items = out
        }
        switch sort {
        case .best: items.sort { $0.score > $1.score }
        case .time: items.sort { ($0.takenAt ?? .distantPast, $0.path) < ($1.takenAt ?? .distantPast, $1.path) }
        case .name: items.sort { $0.path < $1.path }
        }
        if let n = topN { items = Array(items.sorted { $0.score > $1.score }.prefix(n)) }
        return items
    }

    var viewControls: some View {
        FlowLayout(spacing: 10) {
            Picker("", selection: $sort) { ForEach(MediaSort.allCases) { Text($0.rawValue).tag($0) } }
                .fixedSize()
            Picker("", selection: $topN) {
                Text("All").tag(Int?.none)
                ForEach([10, 20, 50, 100], id: \.self) { Text("Best \($0)").tag(Int?.some($0)) }
            }
            .fixedSize()
            .help("Show only the best shots (sharp, eyes open, facing the camera, smiling)")
            SessionPicker()
            Toggle("Hide similar shots", isOn: $collapseBursts)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Show only the best photo of each burst of near-identical shots")
        }
        .padding(.horizontal, 16).padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func tabTitle(_ t: DetailTab) -> String {
        switch t {
        case .photos: "Photos (\(media.filter { $0.kind == .photo }.count))"
        case .videos: "Videos (\(media.filter { $0.kind == .video }.count))"
        case .faces: "Faces (\(faces.count))"
        }
    }

    @ViewBuilder
    func mediaGrid(_ items: [PersonMedia], empty: String) -> some View {
        if items.isEmpty {
            ContentUnavailableView(empty, systemImage: tab == .videos ? "video.slash" : "photo")
                .padding(.top, 60)
        }
        viewControls
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
            ForEach(items) { item in
                MediaThumbnail(item: item)
                    .overlay(alignment: .topTrailing) {
                        if item.hiddenInBurst > 0 {
                            Text("+\(item.hiddenInBurst)")
                                .font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(6)
                                .help("\(item.hiddenInBurst) similar shots hidden; this is the best of the burst")
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selectedMedia.contains(item.id) ? Color.accentColor : .clear, lineWidth: 3))
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                    .onTapGesture { selectedMedia.click(item.id) }
                    .contextMenu {
                        // The selection when this photo is in it, else just this photo.
                        let open = selectedMedia.contains(item.id) ? items.filter { selectedMedia.contains($0.id) } : [item]
                        Button(open.count > 1 ? "Open \(open.count) Photos" : "Open") {
                            openWindow.edit(open.map(\.path), faces: Dictionary(open.map { ($0.path, $0.faceId) }, uniquingKeysWith: { a, _ in a }))
                        }
                        Button("Open With Default App") { open.forEach { NSWorkspace.shared.open($0.url) } }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(open.map(\.url)) }
                        Divider()
                        Button("Use as \(person?.name ?? "Person")'s Picture") { model.setCover(personId, faceId: item.faceId) }
                    }
                    .help(item.url.lastPathComponent)
            }
        }
        .padding(16)
    }

    var faceGrid: some View {
        FaceGrid(faces: faces, selection: $selectedFaces) { faceId in
            Button("Use as \(person?.name ?? "Person")'s Picture") { model.setCover(personId, faceId: faceId) }
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        if tab == .faces && !selectedFaces.isEmpty {
            ToolbarItem {
                Button("Not \(person?.name ?? "This Person")") {
                    model.reject(selectedFaces, from: personId)
                    selectedFaces = []
                }
                .help("Remove the selected faces; they won't be put back here automatically")
            }
            ToolbarItem {
                MoveFacesMenu(faces: selectedFaces, excluding: personId) { selectedFaces = [] }
            }
        }
        if tab == .videos && !media.filter({ $0.kind == .video }).isEmpty {
            ToolbarItem {
                Button { videoExport = true } label: { Label("Export Clips…", systemImage: "film.stack") }
                    .help("Clips of each appearance, a highlight reel, or best still frames")
            }
        }
        ToolbarItem {
            Button { notifyRule = true } label: { Label("Deliver / Notify…", systemImage: "bell.badge") }
                .help("Get notified, and optionally copy new photos of this person to a folder, as they arrive")
        }
        ToolbarItem {
            Button { export = .copy } label: { Label("Copy to Folder…", systemImage: "doc.on.doc") }
                .help("Copy this person's photos and videos into a folder named after them")
        }
        ToolbarItem {
            Button { export = .move } label: { Label("Move to Folder…", systemImage: "folder") }
                .help("Move this person's photos and videos into a folder named after them")
        }
    }
}

extension ExportMode: Identifiable {
    public var id: String { rawValue }
}

struct FaceGrid<Menu: View>: View {
    let faces: [FaceItem]
    @Binding var selection: Set<Int64>
    @ViewBuilder var menu: (Int64) -> Menu
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
            ForEach(faces) { f in
                FaceImage(faceId: f.id, side: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.contains(f.id) ? Color.accentColor : .clear, lineWidth: 3))
                    .onTapGesture {
                        if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
                    }
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: f.path, isDirectory: false)) }
                    .contextMenu {
                        // The selected faces' photos when this face is selected, else this face's photo.
                        let open = selection.contains(f.id) ? faces.filter { selection.contains($0.id) } : [f]
                        let paths = open.reduce(into: [String]()) { if !$0.contains($1.path) { $0.append($1.path) } }
                        Button(paths.count > 1 ? "Open \(paths.count) Photos" : "Open") {
                            openWindow.edit(paths, faces: Dictionary(open.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a }))
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0, isDirectory: false) }) }
                        if Menu.self != EmptyView.self {
                            Divider()
                            menu(f.id)
                        }
                    }
                    .help("\(URL(fileURLWithPath: f.path, isDirectory: false).lastPathComponent)\(f.time.map { " at " + MediaThumbnail.timecode($0) } ?? "")")
            }
        }
        .padding(16)
    }
}

extension FaceGrid where Menu == EmptyView {
    init(faces: [FaceItem], selection: Binding<Set<Int64>>) {
        self.init(faces: faces, selection: selection) { _ in EmptyView() }
    }
}

/// "Move to…" for selected faces: an existing named person, or a new person.
struct MoveFacesMenu: View {
    @EnvironmentObject var model: FaceGroupingModel
    let faces: Set<Int64>
    var excluding: Int64?
    let done: () -> Void
    @State private var askName = false
    @State private var newName = ""

    var body: some View {
        Menu("Move to…") {
            Button("New Person…") { askName = true }
            Divider()
            // Anyone named in any project.
            ForEach(model.knownPeople.filter { $0.id != excluding }) { p in
                Button(p.displayName) { model.assign(faces, to: p.id); done() }
            }
        }
        .alert("New person", isPresented: $askName) {
            TextField("Name", text: $newName)
            Button("Create") {
                model.newPerson(named: newName, faces: faces)
                newName = ""
                done()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// "New Person…" and "Move to ▸ <name>" as menu items, for a right-click menu (which can't show the name alert
/// itself: `newPerson` asks for the name).
struct FaceAssignItems: View {
    let faces: Set<Int64>
    /// Anyone named in any project (plain data, so the model's updates don't rebuild the open menu).
    let known: [PersonSummary]
    let newPerson: () -> Void
    let assign: (Int64) -> Void

    var body: some View {
        Button(faces.count > 1 ? "New Person from \(faces.count) Faces…" : "New Person…", action: newPerson)
        Menu(faces.count > 1 ? "Move \(faces.count) Faces to" : "Move to") {
            ForEach(known) { p in
                Button(p.displayName) { assign(p.id) }
            }
        }
        .disabled(known.isEmpty)
    }
}

struct UnassignedView: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var faces: [FaceItem] = []
    @State private var selection: Set<Int64> = []
    /// Faces to give a new person, while asking for the name.
    @State private var naming: Set<Int64>?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
        SessionBar()
        ScrollView {
            if faces.isEmpty {
                ContentUnavailableView("Nothing unassigned", systemImage: "checkmark.circle",
                                       description: Text("Clear faces that don't belong to any group show up here."))
                    .padding(.top, 80)
            }
            FaceGrid(faces: faces, selection: $selection) { faceId in
                // The selected faces when this one is selected, else just this one.
                let targets = selection.contains(faceId) ? selection : [faceId]
                FaceAssignItems(faces: targets, known: model.knownPeople, newPerson: { naming = targets },
                                assign: { model.assign(targets, to: $0); selection.subtract(targets) })
            }
        }
        }
        .navigationTitle("Unassigned Faces")
        .navigationSubtitle("Seen fewer than 3 times, or not matched yet. Right-click a face (or ⌘-click several) to name it.")
        .alert("New person", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $newName)
            Button("Create") {
                if let faces = naming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.newPerson(named: newName, faces: faces)
                    selection.subtract(faces)
                }
                newName = ""; naming = nil
            }
            Button("Cancel", role: .cancel) { newName = ""; naming = nil }
        } message: {
            if let n = naming?.count, n > 1 { Text("\(n) faces") }
        }
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem { MoveFacesMenu(faces: selection) { selection = [] } }
            }
        }
        .task(id: "\(model.stats.unassignedFaces)|\(model.sessionRange.map { "\($0)" } ?? "")") {
            faces = await model.faces(of: nil)
            selection = selection.intersection(faces.map(\.id))
        }
    }
}

/// "This Is ▸ <name>": the group is someone already named (in this or an earlier project); merges into them. Takes
/// the names as plain data rather than watching the model, so the open menu isn't rebuilt by its updates.
struct ThisIsMenu: View {
    let others: [PersonSummary]
    let merge: (Int64) -> Void

    var body: some View {
        if !others.isEmpty {
            Menu("This Is…") {
                ForEach(others) { k in
                    Button(k.displayName) { merge(k.id) }
                }
            }
        }
    }
}

extension View {
    /// While typing a name, suggests people already named in any project, so a name is given once and reused.
    func knownNameSuggestions(for text: String) -> some View {
        modifier(KnownNameSuggestions(text: text))
    }
}

struct KnownNameSuggestions: ViewModifier {
    @EnvironmentObject var model: FaceGroupingModel
    let text: String

    func body(content: Content) -> some View {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let matches = typed.isEmpty ? [] : model.knownPeople.compactMap(\.name)
            .filter { $0.localizedCaseInsensitiveContains(typed) && $0.compare(typed, options: .caseInsensitive) != .orderedSame }
            .prefix(8)
        content.textInputSuggestions {
            ForEach(Array(matches), id: \.self) { name in
                Text(name).textInputCompletion(name)
            }
        }
    }
}
