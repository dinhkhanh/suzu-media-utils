import FaceLibrary
import SwiftUI

/// Top of the sidebar: which project (event) is open, and switching, creating, renaming and deleting projects.
struct ProjectSwitcher: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var current: ProjectSummary? { model.projects.first { $0.id == model.currentProject } }

    var body: some View {
        Menu {
            // Grouped by team, so it is clear which events are shared and with whom.
            ForEach(model.teams) { team in
                let shared = model.projects(in: team)
                if !shared.isEmpty {
                    Section("Team \(team.name)") {
                        ForEach(shared) { p in projectToggle(p) }
                    }
                }
            }
            let local = model.localProjects
            if !local.isEmpty {
                Section(model.teams.isEmpty ? "Projects" : "Only on this Mac") {
                    ForEach(local) { p in projectToggle(p) }
                }
            }
            if model.projects.count > 1 {
                Divider()
                Toggle("All Projects", isOn: Binding(get: { model.currentProject == nil }, set: { if $0 { model.currentProject = nil } }))
            }
            Divider()
            Button("New Project…") { model.askNewProject = true }
            if current != nil {
                Button("Rename Project…") { newName = current?.name ?? ""; renaming = true }
                Button("Delete Project…", role: .destructive) { confirmDelete = true }
                Divider()
                if let team = model.currentTeam {
                    Button("Stop Sharing with Team “\(team.name)”") { model.stopSharingProject() }
                } else {
                    ForEach(model.teams) { team in Button("Share with Team “\(team.name)”") { model.shareProject(with: team) } }
                    Button(model.teams.isEmpty ? "Share with a Team…" : "Share with a New Team…") { model.askShareTeam = true }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.currentProject == nil ? "square.stack.3d.up" : "calendar")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PROJECT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(model.currentProject == nil ? "All Projects" : current?.name ?? "No project")
                        .font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        // Button style keeps the two-line label (borderless menus flatten it to one line of text).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
        .help("Each event is a project. Names you give people carry over to every project.")
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { if let id = current?.id { model.renameProject(id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(current?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete Project", role: .destructive) { if let id = current?.id { model.deleteProject(id) } }
        } message: {
            Text("The project and its \(current?.folders ?? 0) folders are removed from the library. Files on disk are not touched, and people keep their names for your other projects.")
        }
    }

    func projectToggle(_ p: ProjectSummary) -> some View {
        Toggle(isOn: Binding(get: { model.currentProject == p.id }, set: { if $0 { model.currentProject = p.id } })) {
            Text("\(p.name)  ·  \(p.files.formatted()) files")
        }
    }

    var subtitle: String {
        if model.currentProject == nil { return "\(model.projects.count) projects · \(model.stats.files.formatted()) files" }
        guard let current else { return "Create a project to start" }
        return "\(current.folders) folder\(current.folders == 1 ? "" : "s") · \(current.files.formatted()) files"
    }
}

/// A new project: its name and, optionally, its folders right away.
struct NewProjectSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folders: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.title2.bold())
            Text("One project per event. People you've named in other projects are recognised automatically — no need to name them again.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $name, prompt: Text("e.g. Chị Đẹp Concert – Hà Nội"))
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Folders").font(.headline)
                    Spacer()
                    Button("Add Folders…") {
                        Panels.choose(folders: true, files: false, multiple: true, prompt: "Add",
                                      message: "Choose this event's photo and video folders (local, external drive or NAS).",
                                      start: FileManager.default.homeDirectoryForCurrentUser) { urls in
                            folders += urls.filter { !folders.contains($0) }
                            if name.isEmpty, let first = urls.first { name = first.lastPathComponent }
                        }
                    }
                }
                if folders.isEmpty {
                    Text("You can also add folders later.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(folders, id: \.self) { u in
                    HStack {
                        Image(systemName: "folder")
                        Text(u.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { folders.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Project") {
                    model.createProject(named: name, folders: folders)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
