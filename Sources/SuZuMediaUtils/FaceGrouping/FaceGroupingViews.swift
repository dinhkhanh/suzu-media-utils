import FaceLibrary
import SwiftUI

/// Face Grouping's places in the sidebar.
enum FaceRoute: Hashable {
    case people
    case unassigned
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
        if source.pending > 0 { return "\(source.pending) of \(source.files) to process" }
        return "\(source.files) files"
    }
}

struct FaceGroupingStatus: View {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.stats.pending > 0 {
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
