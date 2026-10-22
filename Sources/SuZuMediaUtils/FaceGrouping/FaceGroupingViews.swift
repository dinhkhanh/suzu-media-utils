import FaceLibrary
import SwiftUI

/// Face Grouping's places in the sidebar.
enum FaceRoute: Hashable {
    case people
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
                case .unassigned: UnassignedView()
                case .search: SearchView(albumId: nil)
                case .album(let id): SearchView(albumId: id)
                case .rules: DeliveryRulesView()
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

/// Face Grouping's sidebar sections; rows are tagged with `AppRoute.faces`.
struct FaceGroupingSidebar: View {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some View {
        Section("Face Grouping") {
            Label("People", systemImage: "person.2")
                .badge(model.people.filter { $0.faces > 0 }.count)
                .tag(AppRoute.faces(.people))
            Label("Unassigned Faces", systemImage: "questionmark.square.dashed")
                .badge(model.stats.unassignedFaces)
                .tag(AppRoute.faces(.unassigned))
            Label("Search", systemImage: "magnifyingglass")
                .tag(AppRoute.faces(.search))
            Label("Delivery Rules", systemImage: "paperplane")
                .badge(model.rules.filter(\.enabled).count)
                .tag(AppRoute.faces(.rules))
        }
        if !model.albums.isEmpty {
            Section("Smart Albums") {
                ForEach(model.albums) { a in
                    Label(a.name, systemImage: "rectangle.stack.badge.person.crop")
                        .tag(AppRoute.faces(.album(a.id!)))
                        .contextMenu { Button("Delete Album", role: .destructive) { model.deleteAlbum(a.id!) } }
                }
            }
        }
        Section("Folders") {
            ForEach(model.sources.filter { $0.kind == .media }) { SourceRow(source: $0).tag(AppRoute.faces(.source($0.id))) }
        }
        if model.sources.contains(where: { $0.kind == .reference }) {
            Section("Known People") {
                ForEach(model.sources.filter { $0.kind == .reference }) { SourceRow(source: $0).tag(AppRoute.faces(.source($0.id))) }
            }
        }
    }
}

struct FaceGroupingSidebarToolbar: ToolbarContent {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Add Photo & Video Folder…") { model.addFolder(kind: .media) }
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
            }
        } icon: {
            Image(systemName: !source.online ? "externaldrive.badge.xmark" : source.network ? "server.rack" : "folder")
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: source.path) }
            Button("Rescan") { model.rescan(source.id) }
            Divider()
            Button("Remove from Library", role: .destructive) { model.removeSource(source.id) }
        }
    }

    var status: String {
        if !source.online { return "Offline" }
        if source.scanning && source.found > source.files { return "Scanning… \(source.found.formatted()) files found" }
        if source.pending > 0 { return "Processing \(source.pending.formatted()) of \(source.files.formatted())" }
        return "\(source.files.formatted()) files"
    }
}

struct FaceGroupingStatus: View {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scanning = model.sources.first(where: { $0.scanning && $0.found > $0.files }) {
                ProgressView().progressViewStyle(.linear)
                Text("Scanning \(scanning.name)… \(scanning.found.formatted()) files found").font(.caption).foregroundStyle(.secondary)
            } else if !model.removing.isEmpty {
                ProgressView().progressViewStyle(.linear)
                Text("Removing folder from the library…").font(.caption).foregroundStyle(.secondary)
            } else if model.stats.pending > 0 {
                ProgressView(value: Double(model.stats.files - model.stats.pending), total: Double(max(1, model.stats.files)))
                Text("Processing \(model.stats.pending) files" + (model.rate > 0.1 ? String(format: " · %.0f/s", model.rate) : ""))
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.sources.isEmpty {
                Text("Add a folder to start.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(model.stats.files) files · up to date").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
