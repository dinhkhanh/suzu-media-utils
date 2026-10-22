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

    var shown: [PersonSummary] {
        model.people.filter { p in
            p.faces > 0
                && (filter == .all || (filter == .named) == (p.name != nil))
                && (search.isEmpty || (p.name ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            if shown.isEmpty {
                ContentUnavailableView(model.people.isEmpty ? "No people yet" : "No matches", systemImage: "person.2",
                                       description: Text(model.people.isEmpty ? "Add a folder; groups appear as files are processed." : ""))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 18) {
                ForEach(shown) { p in
                    PersonCell(person: p, selected: selected.contains(p.id), editing: $editing) { name in
                        commitName(name, for: p)
                    }
                        .onTapGesture(count: 2) { path.append(PersonRoute(id: p.id)) }
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                if selected.contains(p.id) { selected.remove(p.id) } else { selected.insert(p.id) }
                            } else {
                                selected = [p.id]
                            }
                        }
                        .contextMenu {
                            Button("Open") { path.append(PersonRoute(id: p.id)) }
                            if selected.count > 1 && selected.contains(p.id) {
                                Button("Merge \(selected.count) People") { model.merge(selected); selected = [] }
                            }
                        }
                }
            }
            .padding(20)
        }
        .navigationTitle("People")
        .navigationSubtitle("\(shown.count) people · click a name to edit, double-click to open, ⌘-click to select several")
        .searchable(text: $search, prompt: "Search names")
        .sheet(isPresented: $suggesting) { CelebritySheet() }
        .sheet(item: $exportAll) { ExportSheet(scope: .all, mode: $0) }
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
    @State private var export: ExportMode?
    @State private var sort = MediaSort.best
    @State private var collapseBursts = true
    @State private var topN: Int?
    @State private var session: Int?
    @State private var notifyRule = false

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
        .task(id: reloadKey) { reload() }
        .onAppear { name = person?.name ?? "" }
        .sheet(isPresented: $notifyRule) { NewRuleSheet(presetPerson: personId, notifyOnly: true) }
        .sheet(item: $export) { mode in
            ExportSheet(scope: .person(personId), mode: mode, initialName: person?.name ?? name)
        }
    }

    /// Reload when the person's contents change (new files assigned, edits) or the filter changes.
    var reloadKey: String { "\(person?.faces ?? 0)-\(person?.name ?? "")-\(alsoWith.sorted())" }

    func reload() {
        media = model.media(of: personId, alsoWith: alsoWith)
        faces = model.faces(of: personId)
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
                    .onSubmit(commitName)
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

    var sessions: [Sessions.Session] { Sessions.split(media.compactMap(\.takenAt)) }

    /// The grid after session filter, sort, burst collapsing and Top N.
    func shown(_ kind: MediaKind) -> [PersonMedia] {
        var items = media.filter { $0.kind == kind }
        if let s = session, s < sessions.count {
            let range = sessions[s].start...sessions[s].end
            items = items.filter { $0.takenAt.map(range.contains) ?? false }
        }
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
        HStack(spacing: 10) {
            Picker("", selection: $sort) { ForEach(MediaSort.allCases) { Text($0.rawValue).tag($0) } }
                .fixedSize()
            Picker("", selection: $topN) {
                Text("All").tag(Int?.none)
                ForEach([10, 20, 50, 100], id: \.self) { Text("Best \($0)").tag(Int?.some($0)) }
            }
            .fixedSize()
            .help("Show only the best shots (sharp, eyes open, facing the camera, smiling)")
            if sessions.count > 1 {
                Picker("", selection: $session) {
                    Text("All sessions").tag(Int?.none)
                    ForEach(sessions) { Text($0.label).tag(Int?.some($0.index)) }
                }
                .fixedSize()
                .help("Shooting sessions, split wherever there's a gap of 30 minutes or more")
            }
            Toggle("Hide similar shots", isOn: $collapseBursts)
                .toggleStyle(.checkbox)
                .help("Show only the best photo of each burst of near-identical shots")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10)
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
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(item.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
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
    var menu: (Int64) -> Menu

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
            ForEach(faces) { f in
                FaceImage(faceId: f.id, side: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.contains(f.id) ? Color.accentColor : .clear, lineWidth: 3))
                    .onTapGesture {
                        if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
                    }
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
                    .contextMenu { menu(f.id) }
                    .help("\(URL(fileURLWithPath: f.path).lastPathComponent)\(f.time.map { " at " + MediaThumbnail.timecode($0) } ?? "")")
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
            ForEach(model.people.filter { $0.name != nil && $0.id != excluding }) { p in
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

struct UnassignedView: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var faces: [FaceItem] = []
    @State private var selection: Set<Int64> = []

    var body: some View {
        ScrollView {
            if faces.isEmpty {
                ContentUnavailableView("Nothing unassigned", systemImage: "checkmark.circle",
                                       description: Text("Clear faces that don't belong to any group show up here."))
                    .padding(.top, 80)
            }
            FaceGrid(faces: faces, selection: $selection)
        }
        .navigationTitle("Unassigned Faces")
        .navigationSubtitle("Seen fewer than 3 times, or not matched yet. Select faces to name them.")
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem { MoveFacesMenu(faces: selection) { selection = [] } }
            }
        }
        .task(id: model.stats.unassignedFaces) {
            faces = model.faces(of: nil)
            selection = selection.intersection(faces.map(\.id))
        }
    }
}
