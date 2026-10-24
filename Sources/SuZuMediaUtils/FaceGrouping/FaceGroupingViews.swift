import FaceLibrary
import SwiftUI

/// Face Grouping's places in the sidebar.
enum FaceRoute: Hashable {
    case people
    /// The people grid showing only the unnamed, for a naming run.
    case toName
    /// Pinned people only.
    case pinned
    /// One list of people (cast, sponsors…).
    case group(Int64)
    case unassigned
    case search
    case album(Int64)
    case rules
    case source(Int64)
}

/// Pushed onto the navigation stack to open a person.
struct PersonRoute: Hashable {
    let id: Int64
}

/// Face Grouping's right-hand side for a sidebar selection.
struct FaceGroupingDetail: View {
    @EnvironmentObject var model: FaceGroupingModel
    let route: FaceRoute
    @Binding var path: NavigationPath

    var body: some View {
        if let error = model.startupError {
            ContentUnavailableView("Face Grouping can't start", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            Group {
                switch route {
                case .people: PeopleGrid(path: $path)
                case .toName: PeopleGrid(path: $path, filter: .unnamed).id("toName")
                case .pinned: PeopleGrid(path: $path, scope: .pinned).id("pinned")
                case .group(let id): PeopleGrid(path: $path, scope: .group(id)).id("group.\(id)")
                case .unassigned: UnassignedView()
                case .search: SearchView(albumId: nil)
                case .album(let id): SearchView(albumId: id)
                case .rules: RulesView()
                case .source(let id): SourceView(sourceId: id)
                }
            }
            .navigationDestination(for: PersonRoute.self) { PersonDetail(personId: $0.id, path: $path) }
            .alert("Something went wrong", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
                Button("OK") { model.actionError = nil }
            } message: {
                Text(model.actionError ?? "")
            }
        }
    }
}

/// Face Grouping's sidebar sections; rows are tagged with `AppRoute.faces`. People first (naming is the night's
/// main job), albums and rules with them; the folders themselves fold away (they are browsed in Files) but stay
/// here for their status and right-click actions (Locate, Rescan, Remove).
struct FaceGroupingSidebar: View {
    @EnvironmentObject var model: FaceGroupingModel
    @AppStorage("sidebar.folders") private var foldersOpen = false
    @AppStorage("sidebar.teamFolders") private var teamFoldersOpen = true
    @AppStorage("sidebar.editedFolders") private var editedFoldersOpen = true
    @AppStorage("sidebar.known") private var knownOpen = false
    @AppStorage("sidebar.lists") private var listsOpen = true

    /// The open project's albums (all of them in "All Projects").
    var albums: [SmartAlbum] { model.albums.filter { model.currentProject == nil || $0.projectId == model.currentProject } }
    var unnamed: Int { model.people.count { $0.faces > 0 && $0.name == nil } }

    var body: some View {
        Section("People") {
            Label("People", systemImage: "person.2")
                .badge(model.people.filter { $0.faces > 0 }.count)
                .tag(AppRoute.faces(.people))
            Label("To Name", systemImage: "questionmark.circle")
                .badge(Text(unnamed.formatted()).foregroundStyle(unnamed > 0 ? Color.amber : .secondary))
                .tag(AppRoute.faces(.toName))
                .help("People without a name yet")
            Label("Pinned", systemImage: "star")
                .badge(model.people.count { $0.faces > 0 && $0.pinned })
                .tag(AppRoute.faces(.pinned))
                .help("The people who matter tonight; they come first in every grid")
            Label("Unassigned Faces", systemImage: "questionmark.square.dashed")
                .badge(model.stats.unassignedFaces)
                .tag(AppRoute.faces(.unassigned))
            Label("Search", systemImage: "magnifyingglass")
                .tag(AppRoute.faces(.search))
            Label("Auto Rules", systemImage: "wand.and.stars")
                .badge(model.rules.filter(\.enabled).count)
                .tag(AppRoute.faces(.rules))
        }
        Section("Lists", isExpanded: $listsOpen) {
            ForEach(model.groups) { g in
                Label(g.name, systemImage: "list.bullet")
                    .badge(model.people.count { $0.faces > 0 && $0.groups.contains(g.id) })
                    .tag(AppRoute.faces(.group(g.id)))
                    .contextMenu {
                        Button("Rename List…") { model.askRenameGroup = g }
                        Button("Delete List", role: .destructive) { model.deleteGroup(g.id) }
                    }
            }
            Button { model.askNewGroup = [] } label: { Label("New List…", systemImage: "plus") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("A list of people to find again among hundreds: cast, producers, sponsors, guests, VIP (right-click for the usual names)")
                .contextMenu {
                    let missing = PersonGroups.suggestedNames.filter { n in !model.groups.contains { PersonNames.key($0.name) == PersonNames.key(n) } }
                    ForEach(missing, id: \.self) { n in Button(n) { model.createGroup(n) } }
                }
        }
        if !albums.isEmpty {
            Section("Smart Albums") {
                ForEach(albums) { a in
                    Label(a.name, systemImage: "rectangle.stack.badge.person.crop")
                        .tag(AppRoute.faces(.album(a.id!)))
                        .contextMenu { Button("Delete Album", role: .destructive) { model.deleteAlbum(a.id!) } }
                }
            }
        }
        if model.foldersGrouped {
            // In a team the folders come in three kinds: the team's sources (on every Mac), the editing Mac's
            // folder (on every Mac too), and this Mac's own.
            Section(isExpanded: $teamFoldersOpen) {
                folderRows(.team, add: "Add Team Folder…", help: "The folders the whole team works on: every Mac in the team gets them")
            } header: { folderHeader(.team) }
            Section(isExpanded: $editedFoldersOpen) {
                folderRows(.edited, add: "Add Edited Folder…", help: "Where the editing Mac puts edited and selected photos: every Mac in the team sees it")
            } header: { folderHeader(.edited) }
            Section(isExpanded: $foldersOpen) {
                folderRows(.mac, add: "Add Folder…", help: "A folder only this Mac works on")
            } header: { folderHeader(.mac) }
        } else {
            Section(isExpanded: $foldersOpen) {
                folderRows(nil, add: "Add Folder…", help: nil)
            } header: { folderHeader(nil) }
        }
        if model.sources.contains(where: { $0.kind == .reference }) {
            Section("Known People", isExpanded: $knownOpen) {
                ForEach(model.sources.filter { $0.kind == .reference }) { SourceRow(source: $0).tag(AppRoute.faces(.source($0.id))) }
            }
        }
    }

    @ViewBuilder
    func folderRows(_ share: SourceShare?, add: String, help: String?) -> some View {
        ForEach(model.projectSources.filter { share == nil || $0.share == share }) { SourceRow(source: $0).tag(AppRoute.faces(.source($0.id))) }
        if model.service != nil {
            Button { model.addFolder(kind: .media, share: share ?? .mac) } label: { Label(add, systemImage: "plus") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(help ?? "")
        }
    }

    /// "Folders · 3", with a warning when one is offline so it is noticed even folded.
    func folderHeader(_ share: SourceShare?) -> some View {
        let offline = model.projectSources.count { !$0.online && (share == nil || $0.share == share) }
        let title: String = switch share {
        case nil: model.currentProject == nil ? "Folders (all projects)" : "Folders"
        case .team: "Team Folders"
        case .edited: "Edited Folders"
        case .mac: "Folders on This Mac"
        }
        return HStack(spacing: 6) {
            Text(title)
            if offline > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.amber)
                    .help("\(offline) folder\(offline == 1 ? " is" : "s are") offline — renamed or moved? Open to locate it")
            }
        }
    }
}

struct FaceGroupingSidebarToolbar: ToolbarContent {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("New Project…") { model.askNewProject = true }
                Divider()
                Button("Add Photo & Video Folder to Project…") { model.addFolder(kind: .media) }
                if model.currentTeam != nil {
                    Button("Add Team Folder…") { model.addFolder(kind: .media, share: .team) }
                    Button("Add Edited Folder…") { model.addFolder(kind: .media, share: .edited) }
                }
                Button("Add Known-People Folder…") { model.addFolder(kind: .reference) }
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
        }
    }
}

struct SourceRow: View {
    @EnvironmentObject var model: FaceGroupingModel
    let source: SourceSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary)
                if model.currentProject == nil, let p = model.projects.first(where: { $0.id == source.projectId }) {
                    Text(p.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: source.icon)
        }
        .help(source.share == .mac ? "" : model.shareCaption(source))
        .contextMenu {
            if source.online {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: source.path) }
                Button("Rescan") { model.rescan(source.id) }
            }
            // Renamed or moved in Finder: relink instead of removing (which forgets every face in it).
            Button("Locate Folder…") { model.locateSource(source.id) }
            if source.kind == .media && model.projects.count > 1 {
                Menu("Move to Project") {
                    ForEach(model.projects.filter { $0.id != source.projectId }) { p in
                        Button(p.name) { model.moveSource(source.id, to: p.id) }
                    }
                }
            }
            ShareMenu(source: source)
            Divider()
            Button(source.share == .mac ? "Remove from Library" : "Remove from Library and Team", role: .destructive) { model.removeSource(source.id) }
        }
    }

    var status: String {
        if !source.online { return "Offline (renamed? right-click → Locate Folder…)" }
        if source.scanning && source.found > source.files { return "Scanning… \(source.found.formatted()) files found" }
        if source.pending > 0 { return "Processing \(source.pending.formatted()) of \(source.files.formatted())" }
        return "\(source.files.formatted()) files"
    }
}

/// Team folder / Edited folder / Only on this Mac, for a folder of a project that is in a team.
struct ShareMenu: View {
    @EnvironmentObject var model: FaceGroupingModel
    let source: SourceSummary

    var body: some View {
        if source.kind == .media, model.projects.first(where: { $0.id == source.projectId })?.teamId != nil {
            Menu("In the Team") {
                ForEach(SourceShare.allCases, id: \.self) { s in
                    Toggle(s.title, isOn: Binding(get: { source.share == s }, set: { if $0 { model.setShare(source.id, s) } }))
                }
                Divider()
                Text(ShareMenu.explanation)
            }
        }
    }

    static let explanation = "Team folders and edited folders appear on every Mac in the team; a folder only on this Mac stays here."
}

extension SourceSummary {
    var icon: String {
        if !online { return "externaldrive.badge.xmark" }
        switch share {
        case .team: return "person.3"
        case .edited: return "checkmark.rectangle.stack"
        case .mac: return network ? "server.rack" : "folder"
        }
    }
}

extension FaceGroupingModel {
    /// Whether the Folders section splits into team / edited / this Mac: when the open project is in a team, or a
    /// shared folder is in view.
    var foldersGrouped: Bool { currentTeam != nil || projectSources.contains { $0.share != .mac } }

    /// "Team folder · shared by An's Mac".
    func shareCaption(_ s: SourceSummary) -> String {
        guard s.share != .mac else { return "" }
        return sharer(of: s).map { "\(s.share.title) · shared by \($0)" } ?? "\(s.share.title) · shared from this Mac"
    }
}

/// The status pill at the bottom of the sidebar: what the library is doing, how fast, how long it will take, and
/// the team's sync. Click it for tonight's activity.
struct FaceGroupingStatus: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var showActivity = false

    var body: some View {
        // The rate changes every second during ingest; only this pill follows it (see ProcessingStatus).
        FaceGroupingStatusBody(model: model, processing: model.processing, showActivity: $showActivity)
    }
}

struct FaceGroupingStatusBody: View {
    @ObservedObject var model: FaceGroupingModel
    @ObservedObject var processing: ProcessingStatus
    @Binding var showActivity: Bool

    /// Title, detail (right-aligned), and a progress fraction (nil: busy without a known end; -1: no bar).
    var state: (title: String, detail: String, progress: Double?) {
        if model.service == nil && model.startupError == nil { return ("Opening library…", "", nil) }
        if let scanning = model.sources.first(where: { $0.scanning && $0.found > $0.files }) {
            return ("Scanning \(scanning.name)…", "\(scanning.found.formatted()) found", nil)
        }
        if !model.removing.isEmpty { return ("Removing folder…", "", nil) }
        // Files this Mac processes itself (the cards it copies) show as processing even when another Mac does the
        // team's face work; the rest waits for that Mac.
        if model.stats.pending > 0, let mac = model.processingMac, (model.service?.processor.queuedCount ?? 0) == 0 {
            return ("Waiting for \(mac): \(model.stats.pending.formatted()) files", "faces are processed there and read from the team folder",
                    Double(model.stats.files - model.stats.pending) / Double(max(1, model.stats.files)))
        }
        if model.stats.pending > 0 {
            var detail = processing.rate > 0.1 ? String(format: "%.0f/s", processing.rate) : ""
            if processing.rate > 0.1 {
                let s = Double(model.stats.pending) / processing.rate
                detail += s < 90 ? " · ~\(Int(s.rounded())) s" : s < 5400 ? " · ~\(Int((s / 60).rounded())) min" : " · ~\(Int((s / 3600).rounded())) h"
            }
            return ("Processing \(model.stats.pending.formatted()) files", detail,
                    Double(model.stats.files - model.stats.pending) / Double(max(1, model.stats.files)))
        }
        if model.projects.isEmpty { return ("Create a project to start", "", -1) }
        if model.projectSources.isEmpty { return ("Add this event's folders to start", "", -1) }
        return ("\(model.stats.files.formatted()) files", "up to date", -1)
    }

    var body: some View {
        let (title, detail, progress) = state
        Button { showActivity.toggle() } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if let progress, progress >= 0 {
                    ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
                } else if progress == nil {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
                teamLine
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
        .help("What the library is doing. Click for tonight's activity.")
        .popover(isPresented: $showActivity, arrowEdge: .top) { ActivityPopover() }
    }

    @ViewBuilder var teamLine: some View {
        if let team = model.currentTeam {
            let status = model.teamStatus[team.id!]
            let ok = status?.reachable == true && status?.error == nil
            HStack(spacing: 5) {
                Circle().fill(ok ? Color.good : Color.amber).frame(width: 7, height: 7)
                Text(ok ? "Team \(TeamBar.subtitle(status))" : "Team \(team.name): \(TeamBar.subtitle(status))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Tonight's activity, newest first.
struct ActivityPopover: View {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            if model.activity.isEmpty {
                Text("Names, merges, deliveries and folders show up here as they happen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.activity) { ActivityRow(item: $0) }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                .frame(width: 54, alignment: .leading)
            Image(systemName: item.icon).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            Text(item.text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SourceView: View {
    @EnvironmentObject var model: FaceGroupingModel
    let sourceId: Int64

    var body: some View {
        if let s = model.sources.first(where: { $0.id == sourceId }) {
            Form {
                LabeledContent("Folder", value: s.path)
                LabeledContent("Type", value: s.kind == .media ? "Photos & videos" : "Known people (subfolder name = person)")
                if s.share != .mac {
                    LabeledContent("In the team", value: model.shareCaption(s))
                } else if model.projects.first(where: { $0.id == s.projectId })?.teamId != nil {
                    LabeledContent("In the team", value: "Only on this Mac (right-click the folder → In the Team to share it)")
                }
                LabeledContent("Storage", value: s.network ? "Network share, checked every 5 s" : "Local, watched live")
                LabeledContent("Status", value: s.online ? "Online" : "Offline — will resume when it's back")
                LabeledContent("Files", value: "\(s.files)")
                LabeledContent("Waiting", value: "\(s.pending)")
                if s.failed > 0 { LabeledContent("Could not read", value: "\(s.failed)") }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.path) }
                    Button("Rescan") { model.rescan(s.id) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(s.name)
        } else {
            ContentUnavailableView("Folder removed", systemImage: "folder")
        }
    }
}
