import FaceCore
import FaceLibrary
import SwiftUI

enum PeopleFilter: String, CaseIterable, Identifiable {
    case all = "All", named = "Named", unnamed = "Unnamed"
    var id: String { rawValue }
}

/// Which people a grid shows: everyone, the pinned, or one list.
enum PeopleScope: Hashable {
    case all, pinned, group(Int64)
}

/// Everyone in the project as face tiles. Naming is the night's main job, so it is built for a run: click a tile's
/// name field, type, ⏎ — the cursor moves to the next unnamed person; ⇥ skips one; names from every project are
/// suggested. Several tiles selected (⌘-click, ⇧-click) bring up a bar to merge them, pin them, or put them on a list.
struct PeopleGrid: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Binding var path: NavigationPath
    @State private var search = ""
    @State private var filter: PeopleFilter
    /// Only people with every one of these tags (their keys, see PersonNames.key).
    @State private var tagFilter: Set<String> = []
    let scope: PeopleScope
    @State private var selected: Set<Int64> = []
    @FocusState private var editing: Int64?
    /// The tile naming moved to (or last typed in): it keeps a real name field even without the mouse over it, so
    /// the cursor has a field to land in (see `PersonCell.liveField`).
    @State private var fieldFor: Int64?
    @State private var suggesting = false
    @State private var exportAll: ExportMode?
    @State private var galleryExport = false
    @State private var findingByPhoto = false
    /// The selection bar's tag popover is open.
    @State private var tagging = false
    /// The person whose face space enlarged (see `Peek`).
    @State private var peek: PeekState<Int64>?
    @State private var pointer = Peek<Int64>()

    init(path: Binding<NavigationPath>, filter: PeopleFilter = .all, scope: PeopleScope = .all) {
        _path = path
        _filter = State(initialValue: filter)
        self.scope = scope
    }

    var inScope: [PersonSummary] {
        model.people.filter { p in
            p.faces > 0 && {
                switch scope {
                case .all: true
                case .pinned: p.pinned
                case .group(let g): p.groups.contains(g)
                }
            }()
        }
    }
    var shown: [PersonSummary] {
        inScope.filter { p in
            (filter == .all || (filter == .named) == (p.name != nil))
                && (search.isEmpty || (p.name ?? "").localizedCaseInsensitiveContains(search)
                    || p.tags.contains { $0.localizedCaseInsensitiveContains(search) })
                && (tagFilter.isEmpty || tagFilter.isSubset(of: p.tags.map(PersonNames.key)))
        }
    }
    var unnamed: Int { inScope.count { $0.name == nil } }
    var named: Int { inScope.count { $0.name != nil } }
    var group: PersonGroupSummary? { if case .group(let g) = scope { model.groups.first { $0.id == g } } else { nil } }

    var title: String {
        switch scope {
        case .all: "People"
        case .pinned: "Pinned"
        case .group: group?.name ?? "List"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionBar(divider: true)
            if unnamed > 0 && filter != .named && search.isEmpty && scope == .all { namingBanner }
            ScrollView {
                // Filtered once per redraw, not once per tile.
                let shown = self.shown
                let order = shown.map(\.id)
                if shown.isEmpty { empty.padding(.top, 80) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 6)], spacing: 6) {
                    ForEach(shown) { p in cell(p, order: order) }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                // Room for the selection bar.
                .padding(.bottom, selected.isEmpty ? 0 : 64)
            }
            // A click between tiles clears the selection.
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { selected = []; editing = nil } }
        }
        .overlay(alignment: .bottom) { if !selected.isEmpty { selectionBar } }
        .onWindowKeys { pointer.key($0, open: &peek, selection: selected, order: shown.map(\.id)) }
        // Clicking into a name field selects that person (the click lands in the field, not on the tile).
        .onChange(of: editing) { _, now in
            if let now {
                fieldFor = now
                if selected != [now] { selected = [now] }
            }
        }
        .navigationTitle(model.currentSession.map { "\(title) · \(model.sessionTitle($0))" } ?? title)
        .navigationSubtitle("\(named + unnamed) · \(named) named" + (unnamed > 0 ? " · \(unnamed) to name" : ""))
        .searchable(text: $search, prompt: "Search names and tags")
        .sheet(isPresented: $suggesting) { CelebritySheet() }
        .sheet(item: $exportAll) { ExportSheet(scope: .all, mode: $0) }
        .sheet(isPresented: $galleryExport) { GalleryExportSheet() }
        .sheet(isPresented: $findingByPhoto) {
            PhotoLookupSheet(open: { path.append(PersonRoute(id: $0)) }, showFiles: { path.append($0) })
        }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(PeopleFilter.allCases) { f in
                        Text(f == .unnamed && unnamed > 0 ? "Unnamed \(unnamed)" : f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
            if !model.tags.isEmpty || !tagFilter.isEmpty {
                ToolbarItem {
                    Menu {
                        ForEach(model.tags, id: \.self) { t in
                            let key = PersonNames.key(t)
                            Toggle(t, isOn: Binding(get: { tagFilter.contains(key) },
                                                    set: { if $0 { tagFilter.insert(key) } else { tagFilter.remove(key) } }))
                        }
                        if !tagFilter.isEmpty {
                            Divider()
                            Button("Show Everyone") { tagFilter = [] }
                        }
                    } label: {
                        Label(tagFilter.isEmpty ? "Tags" : "Tags (\(tagFilter.count))", systemImage: tagFilter.isEmpty ? "tag" : "tag.fill")
                    }
                    .help("Show only the people with the chosen tags (all of them)")
                }
            }
            if let group {
                ToolbarItem {
                    Menu {
                        Button("Rename List…") { model.askRenameGroup = group }
                        Button("Delete List", role: .destructive) { model.deleteGroup(group.id) }
                    } label: {
                        Label("List", systemImage: "ellipsis.circle")
                    }
                }
            }
            ToolbarItem {
                Button { findingByPhoto = true } label: { Label("Find by Photo", systemImage: "person.fill.viewfinder") }
                    .help("Find by a photo: drop, paste or choose one, and see who each face in it looks like and every photo and video it is in")
            }
            ToolbarItem {
                Button { suggesting = true } label: { Label("Suggest Names", systemImage: "sparkles") }
                    .help("Look up unnamed groups with Amazon Rekognition celebrity recognition")
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
        }
    }

    func cell(_ p: PersonSummary, order: [Int64]) -> some View {
        let mergeCount: Int = selected.count > 1 && selected.contains(p.id) ? selected.count : 0
        // The known-people array is passed whole (shared storage compares in O(1)); the tile leaves itself out
        // only when its menu opens. Filtering it per tile made every click cost people² work.
        return PersonGridCell(person: p, selected: selected.contains(p.id), mergeCount: mergeCount,
                              known: model.knownPeople, groups: model.groups, editing: editing == p.id, field: fieldFor == p.id, focus: $editing,
                              open: { path.append(PersonRoute(id: p.id)) },
                              click: {
                                  pointer.clicked = p.id
                                  selected.click(p.id, in: order)
                                  // Typing a name and clicking another tile moves the typing there; a ⌘/⇧-click
                                  // that builds a selection ends it.
                                  if editing != nil { editing = selected == [p.id] ? p.id : nil }
                              },
                              mergeSelected: { model.merge(selected); selected = [] },
                              thisIs: { model.mergeInto(p.id, $0) },
                              rename: { commitName($0, for: p) },
                              skip: { skip(from: p) },
                              pin: { model.pin(targets(p), $0) },
                              list: { g, on in model.setGroup(g, people: targets(p), member: on) },
                              newList: { model.askNewGroup = targets(p) })
            .equatable()
            .onHover { pointer.hover(p.id, $0) }
            .peekPopover(p.id, open: $peek, keys: { pointer.key($0, open: &peek, selection: selected, order: order) }) { id in
                let person = model.people.first { $0.id == id }
                FacePeek(faceId: person?.coverFaceId, title: person?.displayName)
            }
    }

    /// Right-click acts on the whole selection when the clicked person is part of it.
    func targets(_ p: PersonSummary) -> Set<Int64> { selected.contains(p.id) ? selected : [p.id] }

    @ViewBuilder var empty: some View {
        switch scope {
        case .pinned:
            ContentUnavailableView("Nobody pinned", systemImage: "star",
                                   description: Text("Pin the people who matter tonight — right-click a tile, or ★ on their page — and they come first in every grid."))
        case .group:
            ContentUnavailableView("Nobody on this list yet", systemImage: "list.bullet",
                                   description: Text("Select people in People and use Add to List, or right-click a tile."))
        case .all:
            ContentUnavailableView(model.people.isEmpty ? "No people yet" : filter == .unnamed ? "Everyone has a name" : "No matches",
                                   systemImage: filter == .unnamed ? "checkmark.circle" : "person.2",
                                   description: Text(model.people.isEmpty ? "Add a folder; groups appear as files are processed." : ""))
        }
    }

    /// "24 people still need a name" with the keys, and a button that starts the run.
    var namingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil").foregroundStyle(Color.notice)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(unnamed) \(unnamed == 1 ? "person still needs" : "people still need") a name").fontWeight(.semibold)
                Text("Click a tile's name, type, press ⏎ — the cursor moves to the next unnamed person. ⇥ skips one; names from every project are suggested as you type.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Start Naming") { startNaming() }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.notice.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.notice.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 18).padding(.top, 12)
    }

    var selectionBar: some View {
        let chosen = model.people.filter { selected.contains($0.id) }
        let allPinned = !chosen.isEmpty && chosen.allSatisfy(\.pinned)
        return SelectionBar(title: selected.count == 1 ? "1 person selected" : "\(selected.count) people selected", clear: { selected = [] }) {
            Button("Merge into One") { model.merge(selected); selected = [] }
                .buttonStyle(.borderedProminent)
                .disabled(selected.count < 2)
                .help("Merge the selected people into one (keeps the name if one of them is named)")
            Menu("This Is…") {
                ForEach(model.knownPeople.filter { !selected.contains($0.id) }) { k in
                    Button(k.displayName) {
                        for id in selected { model.mergeInto(id, k.id) }
                        selected = []
                    }
                }
            }
            .fixedSize()
            .disabled(model.knownPeople.allSatisfy { selected.contains($0.id) })
            .help("The selected people are someone already named, here or in another project")
            Button { model.pin(selected, !allPinned) } label: { Label(allPinned ? "Unpin" : "Pin", systemImage: allPinned ? "star.slash" : "star") }
                .help(allPinned ? "Take the selected people off the top of the grids" : "Pinned people come first in every grid")
            Menu {
                ListsMenu(people: selected, groups: model.groups, chosen: chosen)
            } label: {
                Label("Add to List", systemImage: "list.bullet")
            }
            .fixedSize()
            .help("Put the selected people on a list of this event: cast, sponsors, VIP…")
            Button { tagging = true } label: { Label("Tag", systemImage: "tag") }
                .popover(isPresented: $tagging, arrowEdge: .top) { BulkTags(people: selected).padding(14).frame(width: 320) }
                .help("Tag the selected people: singer, actor, model, KOL…")
            if selected.count == 1, let id = selected.first {
                Button("Open") { path.append(PersonRoute(id: id)) }
            }
        }
    }
}

extension PeopleGrid {
    /// Saves an inline rename, then moves the cursor to the next unnamed person for fast labelling.
    func commitName(_ raw: String, for person: PersonSummary) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && name != person.name { model.rename(person.id, to: name) }
        focusName(person.name == nil && !name.isEmpty ? nextUnnamed(after: person)?.id : nil)
    }

    /// ⇥: leave this one for later and go to the next unnamed person.
    func skip(from person: PersonSummary) {
        focusName(nextUnnamed(after: person)?.id)
    }

    func startNaming() {
        if filter == .named { filter = .all }
        focusName(shown.first { $0.name == nil }?.id)
    }

    /// Puts the cursor in this person's name field. The tile gets its field first (only the tile under the mouse has
    /// one otherwise), and focus is asked for again once the field is there.
    func focusName(_ id: Int64?) {
        if let id { fieldFor = id }
        editing = id
        guard let id else { return }
        DispatchQueue.main.async { if fieldFor == id, editing != id { editing = id } }
    }

    func nextUnnamed(after person: PersonSummary) -> PersonSummary? {
        let list = shown
        return list.drop { $0.id != person.id }.dropFirst().first { $0.name == nil }
            ?? list.first { $0.name == nil && $0.id != person.id }
    }
}

/// A person's tags, each a chip (click to take it off), then a field to add one: it suggests the tags in use as
/// you type; ⏎ adds what was typed, as a new tag if no one has it yet.
struct TagsRow: View {
    @EnvironmentObject var model: FaceGroupingModel
    let personId: Int64
    let tags: [String]
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                Chip(title: t, help: "Tagged \(t) — click to take off", action: { model.setTag(t, people: [personId], on: false) }) {
                    Image(systemName: "tag").font(.caption)
                }
            }
            TagField(prompt: tags.isEmpty ? "Add a tag: singer, actor, KOL…" : "Add a tag", except: tags) {
                model.setTag($0, people: [personId], on: true)
            }
            .frame(width: tags.isEmpty ? 220 : 120)
        }
    }
}

/// A field to add a tag: it suggests the tags in use as you type (a pick adds it); ⏎ adds what was typed, as a new
/// tag if no one has it yet.
struct TagField: View {
    @EnvironmentObject var model: FaceGroupingModel
    let prompt: String
    /// Tags not suggested (the person's own).
    var except: [String] = []
    let add: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(.callout)
            .textInputSuggestions {
                ForEach(matches(text), id: \.self) { t in Text(t).textInputCompletion(t) }
            }
            .onChange(of: text) { old, new in
                // A pick replaces the text with one of the tags suggested for it (not typing its last letter).
                let typedOneMore = new.hasPrefix(old) && new.count == old.count + 1
                if !typedOneMore, matches(old).contains(new) { commit(new) }
            }
            .onSubmit { commit(text) }
            .help("Type to pick a tag in use, or press ⏎ to make a new one; tags apply in every project")
    }

    /// Tags in use that contain what was typed, other than `except`.
    func matches(_ text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        let skip = Set(except.map(PersonNames.key))
        return Array(model.tags.filter { $0.localizedCaseInsensitiveContains(typed) && !skip.contains(PersonNames.key($0)) }.prefix(8))
    }

    func commit(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard !t.isEmpty, !except.contains(where: { PersonNames.key($0) == PersonNames.key(t) }) else { return }
        add(t)
    }
}

/// Tags for several people at once: a field to tag them all, then the tags any of them has: filled when all of
/// them have it (click to take it off them all), else click to give it to the rest.
struct BulkTags: View {
    @EnvironmentObject var model: FaceGroupingModel
    let people: Set<Int64>

    var body: some View {
        let chosen = model.people.filter { people.contains($0.id) }
        // Each tag once (any spelling), in the order of the tags in use.
        let keys = Set(chosen.flatMap(\.tags).map(PersonNames.key))
        let tags = model.tags.filter { keys.contains(PersonNames.key($0)) }
        VStack(alignment: .leading, spacing: 10) {
            Text(people.count == 1 ? "Tag 1 person" : "Tag \(people.count) people").font(.headline)
            TagField(prompt: "Add a tag: singer, actor, KOL…") { model.setTag($0, people: people, on: true) }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        let key = PersonNames.key(t)
                        let n = chosen.count { $0.tags.contains { PersonNames.key($0) == key } }
                        let all = n == chosen.count
                        Chip(t, count: all ? nil : "\(n)/\(chosen.count)", on: all,
                             help: all ? "Everyone selected is tagged \(t) — click to take it off them all"
                                       : "\(n) of \(chosen.count) tagged \(t) — click to tag them all") {
                            model.setTag(t, people: people, on: !all)
                        }
                    }
                }
            }
        }
    }
}

/// The lists, ticked for the people who are on them, then "New List…" and the usual names not made yet.
struct ListsMenu: View {
    @EnvironmentObject var model: FaceGroupingModel
    let people: Set<Int64>
    let groups: [PersonGroupSummary]
    /// The people's summaries (for the ticks).
    let chosen: [PersonSummary]

    var body: some View {
        if model.currentProject == nil {
            Text("Open a project to use its lists")
        } else {
            menu
        }
    }

    @ViewBuilder var menu: some View {
        ForEach(groups) { g in
            let on = !chosen.isEmpty && chosen.allSatisfy { $0.groups.contains(g.id) }
            Toggle(g.name, isOn: Binding(get: { on }, set: { model.setGroup(g.id, people: people, member: $0) }))
        }
        if !groups.isEmpty { Divider() }
        Button("New List…") { model.askNewGroup = people }
        let missing = PersonGroups.suggestedNames.filter { n in !groups.contains { PersonNames.key($0.name) == PersonNames.key(n) } }
        if !missing.isEmpty {
            Section("Suggested") {
                ForEach(missing, id: \.self) { n in Button(n) { model.createGroup(n, people: people) } }
            }
        }
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
    let groups: [PersonGroupSummary]
    /// This person's name is being edited.
    let editing: Bool
    /// Keeps a real name field (see `PersonCell.liveField`).
    let field: Bool
    var focus: FocusState<Int64?>.Binding
    let open: () -> Void
    let click: () -> Void
    let mergeSelected: () -> Void
    let thisIs: (Int64) -> Void
    let rename: (String) -> Void
    let skip: () -> Void
    let pin: (Bool) -> Void
    let list: (Int64, Bool) -> Void
    let newList: () -> Void

    static func == (a: PersonGridCell, b: PersonGridCell) -> Bool {
        a.person == b.person && a.selected == b.selected && a.mergeCount == b.mergeCount && a.known == b.known
            && a.groups == b.groups && a.editing == b.editing && a.field == b.field
    }

    var body: some View {
        PersonCell(person: person, selected: selected, groups: groups, editing: focus, keepField: field, onRename: rename, onSkip: skip)
            .onClick(click, double: open)
            .contextMenu {
                Button("Open", action: open)
                if mergeCount > 1 { Button("Merge \(mergeCount) People", action: mergeSelected) }
                ThisIsMenu(others: known.filter { $0.id != person.id }, merge: thisIs)
                Divider()
                Button(person.pinned ? "Unpin" : "Pin") { pin(!person.pinned) }
                Menu("Add to List") {
                    ForEach(groups) { g in
                        Toggle(g.name, isOn: Binding(get: { person.groups.contains(g.id) }, set: { list(g.id, $0) }))
                    }
                    if !groups.isEmpty { Divider() }
                    Button("New List…", action: newList)
                }
            }
    }
}

/// A face, the name field (click into it and type; "Add name" while empty) and the counts. A star marks a pinned
/// person; the lists they are on sit under the counts.
struct PersonCell: View {
    let person: PersonSummary
    let selected: Bool
    var groups: [PersonGroupSummary] = []
    var editing: FocusState<Int64?>.Binding?
    /// Has a real name field even without the mouse over it (naming moved here).
    var keepField = false
    var onRename: ((String) -> Void)?
    var onSkip: (() -> Void)?
    @State private var name = ""
    /// The mouse is over the tile: a long name scrolls so it can be read in full.
    @State private var hovering = false

    var isEditing: Bool { editing?.wrappedValue == person.id }
    /// A real text field (an AppKit control each, slow to make) only where it can be used: on the tile under the
    /// mouse, which a click lands in, and the one being named. Every other tile draws the same look as plain text,
    /// so scrolling past hundreds of tiles doesn't make hundreds of fields.
    var liveField: Bool { isEditing || hovering || keepField }
    /// A name shown, not being typed: the field's own (truncated) text gives way to the marquee on top of it.
    var marquee: Bool { person.name != nil && !isEditing }

    var body: some View {
        VStack(spacing: 8) {
            FaceImage(faceId: person.coverFaceId, side: 112)
                .clipShape(Circle())
                .overlay(Circle().stroke(.separator, lineWidth: 1))
                .overlay(Circle().stroke(selected || isEditing ? Color.accent : .clear, lineWidth: 3))
                .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 6, y: 2)
                .overlay(alignment: .topTrailing) {
                    if person.pinned {
                        Image(systemName: "star.fill")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(5).background(Circle().fill(Color.accent))
                            .overlay(Circle().stroke(Color.panel, lineWidth: 2))
                            .offset(x: 2, y: -2)
                            .help("Pinned: comes first in every grid")
                    }
                }
            if let editing, let onRename, liveField {
                // Inline name field, always there: click, type, Return. Escape restores the old name. Unnamed, it
                // shows as a dashed "Add name" until it has focus.
                TextField("Add name", text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(person.name == nil && !isEditing ? .callout.weight(.medium) : .headline)
                    .foregroundStyle(person.name == nil && !isEditing ? Color.accent : marquee ? .clear : .primary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isEditing ? Color.primary.opacity(0.06) : .clear))
                    .overlay {
                        if person.name == nil && !isEditing {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        } else if marquee {
                            // The name in full on hover (a click still lands on the field and starts editing).
                            MarqueeText(text: person.displayName, scrolling: hovering)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .allowsHitTesting(false)
                        }
                    }
                    .fixedSize(horizontal: person.name == nil && !isEditing, vertical: false)
                    .focused(editing, equals: person.id)
                    .knownNameSuggestions(for: name) { onRename($0) }
                    .onSubmit { onRename(name) }
                    .onKeyPress(.tab) {
                        // Skip to the next unnamed person; an unsaved name is left behind.
                        if person.name == nil { name = ""; onSkip?(); return .handled }
                        return .ignored
                    }
                    .onExitCommand { name = person.name ?? ""; editing.wrappedValue = nil }
                    .onAppear { name = person.name ?? "" }
                    .onChange(of: person.name) { name = person.name ?? "" }
                    .help(person.name == nil ? "Click and type a name" : "Click to rename")
            } else if editing != nil, person.name == nil {
                // The field's look while unnamed: a dashed "Add name".
                Text("Add name")
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .fixedSize()
            } else if editing != nil {
                MarqueeText(text: person.displayName, scrolling: hovering)
                    .padding(.horizontal, 8).padding(.vertical, 3)
            } else {
                MarqueeText(text: person.displayName, scrolling: hovering)
                    .foregroundStyle(person.name == nil ? .secondary : .primary)
                    .padding(.horizontal, 8)
            }
            Text(counts).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if !listNames.isEmpty {
                Text(listNames).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 6)
        // Top-aligned, so a tile with a list line under it doesn't push its neighbours' faces down.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    var counts: String {
        var parts = ["\(person.photos.formatted()) photo\(person.photos == 1 ? "" : "s")"]
        if person.videos > 0 { parts.append("\(person.videos) video\(person.videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var listNames: String { groups.filter { person.groups.contains($0.id) }.map(\.name).joined(separator: " · ") }
}

enum MediaSort: String, CaseIterable, Identifiable {
    case best = "Best first", time = "By time", name = "By name"
    var id: String { rawValue }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case photos = "Photos", videos = "Videos", faces = "Faces"
    var id: String { rawValue }
}

/// One person: a header with their picture, name, counts and who they are often with; then their photos (best
/// first, one of each burst), videos and faces.
struct PersonDetail: View {
    @EnvironmentObject var model: FaceGroupingModel
    let personId: Int64
    @Binding var path: NavigationPath
    @State private var name = ""
    @State private var bio = ""
    @FocusState private var bioFocused: Bool
    @State private var tab = DetailTab.photos
    @State private var media: [PersonMedia] = []
    @State private var faces: [FaceItem] = []
    @State private var alsoWith: Set<Int64> = []
    @State private var selectedFaces: Set<Int64> = []
    /// Photos and videos selected in the grid (⌘-click for several), for Open.
    @State private var selectedMedia: Set<Int64> = []
    /// The photo or video space opened (see `Peek`).
    @State private var mediaPeek: PeekState<Int64>?
    @State private var pointer = Peek<Int64>()
    @Environment(\.openWindow) private var openWindow
    @State private var export: ExportMode?
    @State private var sort = MediaSort.best
    @State private var collapseBursts = true
    @State private var topN: Int?
    /// The Photos and Videos grids, worked out when what goes into them changes (see `relist`).
    @State private var lists = MediaLists()
    @State private var notifyRule = false
    @State private var videoExport = false
    @State private var otherProjects: [String] = []
    @State private var companions: [Companion] = []

    var person: PersonSummary? { model.people.first { $0.id == personId } }

    var body: some View {
        VStack(spacing: 0) {
            SessionBar(divider: true)
            // The header and the tabs stay put; only the grid below them scrolls.
            header
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .photos: mediaGrid(shown(.photo), empty: "No photos of this person")
                    case .videos: mediaGrid(shown(.video), empty: "No videos of this person")
                    case .faces: faceGrid
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, selectedMedia.isEmpty && selectedFaces.isEmpty ? 0 : 64)
            }
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { selectedMedia = []; selectedFaces = [] } }
        }
        .overlay(alignment: .bottom) {
            if tab != .faces && !selectedMedia.isEmpty { mediaSelectionBar }
            if tab == .faces && !selectedFaces.isEmpty { faceSelectionBar }
        }
        .navigationTitle(person?.displayName ?? "Person")
        .toolbar { toolbar }
        .onWindowKeys(mediaKey)
        .task(id: reloadKey) { await reload() }
        .onChange(of: sort) { relist() }
        .onChange(of: collapseBursts) { relist() }
        .onChange(of: topN) { relist() }
        // The name, once the model has the person (and after a rename elsewhere); not while it is being typed.
        .onChange(of: person?.name, initial: true) { if name != (person?.name ?? ""), name.isEmpty || name == person?.name { name = person?.name ?? "" } }
        // The note likewise (a teammate's edit), not while it is being typed.
        .onChange(of: person?.bio, initial: true) { if !bioFocused { bio = person?.bio ?? "" } }
        .onChange(of: bioFocused) { if !bioFocused { commitBio() } }
        .onDisappear(perform: commitBio)
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
        async let c = model.companions(of: personId)
        let (newMedia, newFaces, others, together) = await (m, f, o, c)
        guard !Task.isCancelled else { return }
        otherProjects = others
        companions = together
        media = newMedia
        relist()
        faces = newFaces
        selectedFaces = selectedFaces.intersection(faces.map(\.id))
        selectedMedia = selectedMedia.intersection(media.map(\.id))
    }

    // MARK: - Header

    var header: some View {
        HStack(alignment: .center, spacing: 18) {
            FaceImage(faceId: person?.coverFaceId, side: 96).clipShape(Circle())
                .overlay(Circle().stroke(.separator, lineWidth: 1))
                .contextMenu {
                    Button("Pick Best Shot Automatically") { model.setCover(personId, faceId: nil) }
                }
                .help("Right-click a photo or face to use it as the picture")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    TextField("Add a name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .bold))
                        .knownNameSuggestions(for: name) { _ in commitName() }
                        .onSubmit(commitName)
                        .fixedSize()
                        .help("Click to rename; the name applies in every project")
                    Button { model.pin([personId], !(person?.pinned ?? false)) } label: {
                        Image(systemName: person?.pinned == true ? "star.fill" : "star")
                            .font(.title3).foregroundStyle(person?.pinned == true ? Color.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(person?.pinned == true ? "Pinned: comes first in every grid. Click to unpin" : "Pin: comes first in every grid")
                    if !otherProjects.isEmpty {
                        Label("Known in \(otherProjects.count + 1) projects", systemImage: "checkmark.seal")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .help("Also in \(otherProjects.joined(separator: ", ")): a name given here applies to all of them")
                    }
                }
                TextField("Add a note: singer, actor, model, KOL…", text: $bio)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($bioFocused)
                    .onSubmit(commitBio)
                    .frame(maxWidth: 420, alignment: .leading)
                    .help("Who this person is; the note applies in every project")
                TagsRow(personId: personId, tags: person?.tags ?? [])
                Text(summary).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(model.groups.filter { person?.groups.contains($0.id) == true }) { g in
                        Chip(g.name, on: true, help: "On the list \(g.name) — click to take off") { model.setGroup(g.id, people: [personId], member: false) }
                    }
                    Menu {
                        if let p = person { ListsMenu(people: [personId], groups: model.groups, chosen: [p]) }
                    } label: {
                        Label("Add to list", systemImage: "plus.circle").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.primary)
                    .help("Cast, sponsors, VIP…: the lists this person is on at this event")
                }
                .padding(.top, 2)
                if !companions.isEmpty || !alsoWith.isEmpty {
                    HStack(spacing: 6) {
                        Text("Often with").font(.callout).foregroundStyle(.secondary).padding(.trailing, 2)
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(companions) { c in
                                    FaceChip(faceId: c.coverFaceId, title: c.name, count: c.count.formatted(), on: alsoWith.contains(c.id),
                                             help: "Only photos with \(c.name) in them too") {
                                        if alsoWith.contains(c.id) { alsoWith.remove(c.id) } else { alsoWith.insert(c.id) }
                                    }
                                }
                                // Someone picked who no longer shows in the top companions: still a chip, so it can be removed.
                                ForEach(Array(alsoWith).filter { id in !companions.contains { $0.id == id } }, id: \.self) { id in
                                    let p = model.people.first { $0.id == id } ?? model.knownPeople.first { $0.id == id }
                                    FaceChip(faceId: p?.coverFaceId, title: p?.displayName ?? "?", on: true) { alsoWith.remove(id) }
                                }
                                Menu {
                                    ForEach(model.people.filter { $0.name != nil && $0.id != personId && !alsoWith.contains($0.id) }) { p in
                                        Button(p.displayName) { alsoWith.insert(p.id) }
                                    }
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                                .help("Only photos where this person is together with someone else")
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    /// "1,204 photos · 12 videos · 18:14 → 23:38".
    var summary: String {
        var parts: [String] = []
        if let p = person { parts.append(PersonCell(person: p, selected: false).counts) }
        let times = media.compactMap(\.takenAt)
        if let first = times.min(), let last = times.max() {
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDate(first, inSameDayAs: last) ? "HH:mm" : "d MMM HH:mm"
            parts.append("\(f.string(from: first)) → \(f.string(from: last))")
        }
        if !alsoWith.isEmpty { parts.append("only together with \(alsoWith.count == 1 ? "them" : "all of them")") }
        return parts.joined(separator: " · ")
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

    func commitBio() {
        let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (person?.bio ?? "") else { return }
        model.setBio(personId, trimmed)
    }

    // MARK: - Tabs and controls

    var tabs: some View {
        HStack(spacing: 18) {
            ForEach(DetailTab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 5) {
                        Text(t.rawValue).fontWeight(.medium)
                        Text(tabCount(t).formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(tab == t ? Color.accent : .clear).frame(height: 2) }
                    .foregroundStyle(tab == t ? .primary : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if tab != .faces {
                Picker("Sort", selection: $sort) { ForEach(MediaSort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Menu {
                    Picker("Show", selection: $topN) {
                        Text("All").tag(Int?.none)
                        ForEach([10, 20, 50, 100], id: \.self) { Text("Best \($0)").tag(Int?.some($0)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Chip(topN.map { "Best \($0)" } ?? "All shots", on: topN != nil) {}
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.primary)
                .help("Show only the best shots (sharp, eyes open, facing the camera, smiling)")
                let hidden = tab == .videos ? lists.hiddenVideos : lists.hiddenPhotos
                Chip("Hide bursts", count: collapseBursts && hidden > 0 ? "−\(hidden)" : nil, on: collapseBursts,
                     help: "Show only the best photo of each burst of near-identical shots") { collapseBursts.toggle() }
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { Divider() }
    }

    func tabCount(_ t: DetailTab) -> Int {
        switch t {
        case .photos: lists.photoCount
        case .videos: lists.videoCount
        case .faces: faces.count
        }
    }

    /// The grid after session filter, sort, burst collapsing and Top N.
    func shown(_ kind: MediaKind) -> [PersonMedia] { kind == .video ? lists.videos : lists.photos }

    /// Works the grids out again, when the media, the sort, bursts or Top N change. Not in `body`: every click
    /// (a selection) redraws the page, and sorting a few thousand photos there each time made selecting lag.
    func relist() {
        let photos = media.filter { $0.kind == .photo }, videos = media.filter { $0.kind == .video }
        let p = Self.list(photos, sort: sort, collapseBursts: collapseBursts, topN: topN)
        let v = Self.list(videos, sort: sort, collapseBursts: collapseBursts, topN: topN)
        lists = MediaLists(photos: p.items, videos: v.items, photoCount: photos.count, videoCount: videos.count,
                           hiddenPhotos: p.hidden, hiddenVideos: v.hidden)
    }

    /// One kind's grid, and how many shots its bursts hide.
    static func list(_ all: [PersonMedia], sort: MediaSort, collapseBursts: Bool, topN: Int?) -> (items: [PersonMedia], hidden: Int) {
        var items = all
        if collapseBursts {
            var best: [Int64: Int] = [:]
            var out: [PersonMedia] = []
            // The shot kept of a burst: a RAW file first (it holds the most), then the best by score. Whether a file
            // is RAW is looked up once per file, not in every comparison.
            let ranked = items.map { (raw: ImageLoader.isRaw($0.url) ? 1 : 0, item: $0) }
                .sorted { ($0.raw, $0.item.score) > ($1.raw, $1.item.score) }
            for (_, item) in ranked {
                if let b = item.burstId, let i = best[b] { out[i].hiddenInBurst += 1; continue }
                if let b = item.burstId { best[b] = out.count }
                out.append(item)
            }
            items = out
        }
        let hidden = all.count - items.count
        switch sort {
        case .best: items.sort { $0.score > $1.score }
        case .time: items.sort { ($0.takenAt ?? .distantPast, $0.path) < ($1.takenAt ?? .distantPast, $1.path) }
        case .name: items.sort { $0.path < $1.path }
        }
        if let n = topN { items = Array(items.sorted { $0.score > $1.score }.prefix(n)) }
        return (items, hidden)
    }

    // MARK: - Grids

    @ViewBuilder
    func mediaGrid(_ items: [PersonMedia], empty: String) -> some View {
        if items.isEmpty {
            ContentUnavailableView(empty, systemImage: tab == .videos ? "video.slash" : "photo")
                .padding(.top, 60)
        }
        // The order once per redraw (not per tile), and a tile redraws only when its own state changes: a click
        // used to re-render every tile on the page, which showed as a late highlight.
        let order = items.map(\.id)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 240), spacing: 10)], spacing: 10) {
            ForEach(items) { item in
                PersonMediaTile(item: item, session: sessionName(item), selected: selectedMedia.contains(item.id))
                    .equatable()
                    .onClick({ pointer.clicked = item.id; selectedMedia.click(item.id, in: order) },
                             double: { openWindow.edit([item.path], faces: [item.path: item.faceId]) })
                    .onHover { pointer.hover(item.id, $0) }
                    .peekPopover(item.id, open: $mediaPeek, keys: mediaKey) { id in
                        if let m = media.first(where: { $0.id == id }) {
                            MediaPeek(url: m.url, mediaId: m.id, time: m.kind == .video ? m.time : nil, faceId: m.faceId)
                        }
                    }
                    .contextMenu {
                        // The selection when this photo is in it, else just this photo.
                        let open = selectedMedia.contains(item.id) ? items.filter { selectedMedia.contains($0.id) } : [item]
                        Button(open.count > 1 ? "Open \(open.count) Photos in Edit & Export" : "Open in Edit & Export") { openInEditor(open) }
                        Button("Open With Default App") { open.forEach { NSWorkspace.shared.open($0.url) } }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(open.map(\.url)) }
                        Button("Copy File Path") { Clipboard.copyPaths(open.map(\.url)) }
                        Divider()
                        Button("Use as \(person?.name ?? "Person")'s Picture") { model.setCover(personId, faceId: item.faceId) }
                    }
                    .help(item.url.lastPathComponent)
            }
        }
        .padding(20)
    }

    /// Space: a closer look at the photo or video under the mouse (else the one clicked last, else the first
    /// selected); see `Peek`. The faces tab enlarges faces itself (`FaceGrid`).
    func mediaKey(_ e: NSEvent) -> Bool {
        guard tab != .faces else { return false }
        return pointer.key(e, open: &mediaPeek, selection: selectedMedia, order: shown(tab == .videos ? .video : .photo).map(\.id))
    }

    /// The named session a photo was taken in, when the event has named sessions.
    func sessionName(_ item: PersonMedia) -> String? {
        guard let t = item.takenAt?.timeIntervalSince1970 else { return nil }
        return model.sessions.first { $0.contains(t) }?.name
    }

    func openInEditor(_ items: [PersonMedia]) {
        openWindow.edit(items.map(\.path), faces: Dictionary(items.map { ($0.path, $0.faceId) }, uniquingKeysWith: { a, _ in a }))
    }

    var faceGrid: some View {
        FaceGrid(faces: faces, selection: $selectedFaces) { faceId in
            Button("Use as \(person?.name ?? "Person")'s Picture") { model.setCover(personId, faceId: faceId) }
        }
    }

    var mediaSelectionBar: some View {
        let chosen = media.filter { selectedMedia.contains($0.id) }
        return SelectionBar(title: "\(chosen.count) selected", clear: { selectedMedia = [] }) {
            Button("Open in Edit & Export") { openInEditor(chosen) }.buttonStyle(.borderedProminent)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.url)) }
            Button("Copy File Path") { Clipboard.copyPaths(chosen.map(\.url)) }
            if chosen.count == 1, let one = chosen.first {
                Button("Use as Picture") { model.setCover(personId, faceId: one.faceId) }
            }
        }
    }

    var faceSelectionBar: some View {
        SelectionBar(title: "\(selectedFaces.count) face\(selectedFaces.count == 1 ? "" : "s") selected", clear: { selectedFaces = [] }) {
            Button("Not \(person?.name ?? "This Person")") {
                model.reject(selectedFaces, from: personId)
                selectedFaces = []
            }
            .help("Remove the selected faces; they won't be put back here automatically")
            Button("Regroup") {
                model.regroup(selectedFaces)
                selectedFaces = []
            }
            .help("Let the app place the selected faces again: each goes to whoever it looks most like (this person too, if right), or into a new group. Faces you placed by hand stay. After a wrong merge, move a few faces to the right names first, then regroup the rest.")
            MoveFacesMenu(faces: selectedFaces, excluding: personId) { selectedFaces = [] }.fixedSize()
            if selectedFaces.count < faces.count {
                Button("Select All \(faces.count.formatted())") { selectedFaces = Set(faces.map(\.id)) }
            }
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        if tab == .videos && !media.filter({ $0.kind == .video }).isEmpty {
            ToolbarItem {
                Button { videoExport = true } label: { Label("Video Moments…", systemImage: "film.stack") }
                    .help("Clips of each appearance, a highlight reel, or best still frames")
            }
        }
        ToolbarItem {
            Button {
                let photos = shown(.photo)
                openInEditor(selectedMedia.isEmpty ? Array(photos.prefix(topN ?? 50)) : photos.filter { selectedMedia.contains($0.id) })
            } label: {
                Label("Edit & Export", systemImage: "slider.horizontal.3")
            }
            .disabled(media.isEmpty)
            .help(selectedMedia.isEmpty ? "Open the best \(topN ?? 50) photos shown in Edit & Export (select some to open just those)"
                                        : "Open the selected photos in Edit & Export")
        }
        ToolbarItem {
            Button { notifyRule = true } label: { Label("Deliver / Notify…", systemImage: "bell.badge") }
                .help("Get notified, and optionally copy new photos of this person to a folder, as they arrive")
        }
        ToolbarItem {
            Menu {
                Button("Copy to Folder…") { export = .copy }
                Button("Move to Folder…") { export = .move }
            } label: {
                Label("Copy to Folder", systemImage: "folder")
            } primaryAction: {
                export = .copy
            }
            .help("Copy (or move) this person's photos and videos into a folder named after them")
        }
    }
}

/// A person's Photos and Videos grids (see `PersonDetail.relist`).
struct MediaLists {
    var photos: [PersonMedia] = [], videos: [PersonMedia] = []
    /// Every photo and video, before bursts and Top N (the tabs' counts).
    var photoCount = 0, videoCount = 0
    /// Shots hidden behind the best of their burst.
    var hiddenPhotos = 0, hiddenVideos = 0
}

/// A photo or video of the person: best-shot score, burst count, time and session.
struct PersonMediaTile: View, Equatable {
    let item: PersonMedia
    let session: String?
    let selected: Bool

    var body: some View {
        MediaThumbnail(item: item, side: 176)
            .overlay(alignment: .topLeading) {
                if item.kind == .photo && item.score > 0 {
                    Label("\(Int((item.score * 100).rounded()))", systemImage: "star.fill")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                        .help("Best-shot score: sharpness, eyes open, facing the camera, smile")
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.hiddenInBurst > 0 {
                    Text("+\(item.hiddenInBurst)")
                        .font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(6)
                        .help("\(item.hiddenInBurst) similar shots hidden; this is the best of the burst")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .photo, let t = item.takenAt {
                    Text(t.formatted(date: .omitted, time: .shortened) + (session.map { " · \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accent : .clear, lineWidth: 3))
            .contentShape(Rectangle())
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
    /// The face space enlarged (see `Peek`).
    @State private var peek: PeekState<Int64>?
    @State private var pointer = Peek<Int64>()

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
            ForEach(faces) { f in
                FaceImage(faceId: f.id, side: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.contains(f.id) ? Color.accent : .clear, lineWidth: 3))
                    .onHover { pointer.hover(f.id, $0) }
                    .peekPopover(f.id, open: $peek, keys: key) { FacePeek(faceId: $0) }
                    .onClick({
                        pointer.clicked = f.id
                        // A click ticks or unticks; ⇧-click ticks everything from the selection to here.
                        if NSEvent.modifierFlags.contains(.shift) { selection.extend(to: f.id, in: faces.map(\.id)) }
                        else if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
                    }, double: { NSWorkspace.shared.open(URL(fileURLWithPath: f.path, isDirectory: false)) })
                    .contextMenu {
                        // The selected faces' photos when this face is selected, else this face's photo.
                        let open = selection.contains(f.id) ? faces.filter { selection.contains($0.id) } : [f]
                        let paths = open.reduce(into: [String]()) { if !$0.contains($1.path) { $0.append($1.path) } }
                        Button(paths.count > 1 ? "Open \(paths.count) Photos" : "Open") {
                            openWindow.edit(paths, faces: Dictionary(open.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a }))
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0, isDirectory: false) }) }
                        Button("Copy File Path") { Clipboard.copyPaths(paths.map { URL(fileURLWithPath: $0, isDirectory: false) }) }
                        if Menu.self != EmptyView.self {
                            Divider()
                            menu(f.id)
                        }
                    }
                    .help("\(URL(fileURLWithPath: f.path, isDirectory: false).lastPathComponent)\(f.time.map { " at " + MediaThumbnail.timecode($0) } ?? "")")
            }
        }
        .padding(16)
        .onWindowKeys(key)
    }

    func key(_ e: NSEvent) -> Bool {
        pointer.key(e, open: &peek, selection: selection, order: faces.map(\.id))
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
    @State private var pairs: [[FaceItem]] = []
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
            if !pairs.isEmpty { pairsSection }
            FaceGrid(faces: faces, selection: $selection) { faceId in
                // The selected faces when this one is selected, else just this one.
                let targets = selection.contains(faceId) ? selection : [faceId]
                FaceAssignItems(faces: targets, known: model.knownPeople, newPerson: { naming = targets },
                                assign: { model.assign(targets, to: $0); selection.subtract(targets) })
            }
        }
        }
        .navigationTitle("Unassigned Faces")
        .navigationSubtitle("Seen fewer than 3 times, or not matched yet. Right-click a face (or click several, ⇧-click for a range) to name it.")
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
            pairs = await model.likelyPairs()
        }
    }

    /// Faces seen twice that look like one person: a guest shot twice. One click makes them a person.
    var pairsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("SEEN TWICE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(pairs.count) pair\(pairs.count == 1 ? "" : "s") that look like one person; groups need three faces")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 260), spacing: 8)], spacing: 8) {
                ForEach(pairs, id: \.[0].id) { pair in
                    let ids = Set(pair.map(\.id))
                    HStack(spacing: 6) {
                        ForEach(pair) { f in
                            FaceImage(faceId: f.id, side: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.isSuperset(of: ids) ? Color.accent : .clear, lineWidth: 2))
                        }
                        Menu {
                            FaceAssignItems(faces: ids, known: model.knownPeople, newPerson: { naming = ids },
                                            assign: { model.assign(ids, to: $0); selection.subtract(ids) })
                        } label: {
                            Label("Name", systemImage: "person.badge.plus")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("A new person from both faces, or someone already named")
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = selection.isSuperset(of: ids) ? selection.subtracting(ids) : selection.union(ids) }
                    .help("Click to select both faces (then Move to… in the toolbar), or use the menu")
                }
            }
            Divider().padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.top, 12)
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
    /// Picking a suggestion saves it at once (`onPick`), without Return.
    func knownNameSuggestions(for text: String, onPick: @escaping (String) -> Void) -> some View {
        modifier(KnownNameSuggestions(text: text, onPick: onPick))
    }
}

struct KnownNameSuggestions: ViewModifier {
    @EnvironmentObject var model: FaceGroupingModel
    let text: String
    let onPick: (String) -> Void

    func body(content: Content) -> some View {
        content
            .textInputSuggestions {
                ForEach(matches(text), id: \.self) { name in
                    Text(name).textInputCompletion(name)
                }
            }
            .onChange(of: text) { old, new in
                // A pick replaces the text with one of the names suggested for it. Typing the last letter of a
                // suggested name is not a pick: "Na" must not save while "Nami" is being typed.
                let typedOneMore = new.hasPrefix(old) && new.count == old.count + 1
                if !typedOneMore, matches(old).contains(new) { onPick(new) }
            }
    }

    func matches(_ text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return Array(model.knownPeople.compactMap(\.name)
            .filter { $0.localizedCaseInsensitiveContains(typed) && $0.compare(typed, options: .caseInsensitive) != .orderedSame }
            .prefix(8))
    }
}
