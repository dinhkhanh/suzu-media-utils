import AppKit
import FaceLibrary
import SwiftUI

/// Top of the sidebar: the team (who you work with) above the project (which event), since a team holds many
/// projects. Both are menus.
struct SidebarHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            TeamBar()
            ProjectSwitcher()
        }
    }
}

/// The open project's team, how the sharing is going, and the team's actions. A project shared with nobody says so
/// and offers to share or join.
struct TeamBar: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var confirmLeave = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let team = model.currentTeam
        let status = team.flatMap { model.teamStatus[$0.id!] }
        Menu {
            if let team {
                let projects = model.projects(in: team)
                Section("\(projects.count) project\(projects.count == 1 ? "" : "s") in this team") {
                    ForEach(projects) { p in
                        Button(p.id == model.currentProject ? "✓ \(p.name)" : p.name) { model.currentProject = p.id }
                    }
                }
                Divider()
                Button("Sync Now") { model.syncTeamNow() }
                Button("Rename Team…") { newName = team.name; renaming = true }
                Button("Show Team Sync Folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: team.folder) }
                // The NAS got a new address or the share a new mount name: same team, new path.
                Button("Locate Team Sync Folder…") {
                    Panels.chooseFolder(prompt: "Use This Folder", start: URL(fileURLWithPath: team.folder).deletingLastPathComponent(), key: "teamFolder") {
                        model.relocateTeam(team.id!, to: $0)
                    }
                }
                Button("Copy Team Sync Folder Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(team.folder, forType: .string)
                }
                if let status, !status.devices.isEmpty {
                    Section("Macs") {
                        ForEach(status.devices, id: \.id) { d in
                            Text(d.isThisMac ? "\(d.name) (this Mac)" : "\(d.name)\(d.lastSeen.map { " · \(Self.ago($0))" } ?? "")")
                        }
                    }
                }
                // One strong Mac can do the face work; the others take its results from the team sync folder.
                Section("Face processing") {
                    let mine = model.isProcessor(team)
                    Button(mine ? "✓ This Mac processes faces for the team" : "This Mac processes faces for the team") { model.setProcessor(team, thisMac: true) }
                        .disabled(mine)
                    if let name = team.processorName, !mine {
                        Text("Processed by \(name) — this Mac processes only the cards it copies and sends their faces there")
                    } else if mine {
                        Text("Macs copying cards process their own cards and send the faces here to be grouped")
                    }
                    Button(team.processorId == nil ? "✓ Every Mac processes its own files" : "Every Mac processes its own files") { model.setProcessor(team, thisMac: false) }
                        .disabled(team.processorId == nil)
                }
                Divider()
                Button("Join Another Team…") { model.askJoinTeam = true }
                Button("Leave Team…", role: .destructive) { confirmLeave = true }
            } else {
                if model.currentProject != nil {
                    ForEach(model.teams) { t in Button("Share with Team “\(t.name)”") { model.shareProject(with: t) } }
                    Button(model.teams.isEmpty ? "Share with a Team…" : "Share with a New Team…") { model.askShareTeam = true }
                }
                Button("Join a Team…") { model.askJoinTeam = true }
                if !model.teams.isEmpty {
                    Section("Your teams") {
                        ForEach(model.teams) { t in
                            let first = model.projects(in: t).first
                            Button(t.name) { if let first { model.currentProject = first.id } }
                        }
                    }
                }
            }
        } label: {
            label(team: team, status: status)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Newly opened windows hand keyboard focus to the first control; a focus ring on this label looks wrong.
        .focusEffectDisabled()
        .padding(.horizontal, 10).padding(.vertical, 8)
        // A faint tint, not a ring: a coral outline here reads as keyboard focus.
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accent.opacity(team == nil ? 0.04 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accent.opacity(team == nil ? 0.12 : 0.2), lineWidth: 1))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
        .help(team.map { "Names, people, projects, session names and rules are shared with every Mac in the team through \($0.folder)" }
              ?? "A team is a folder every Mac can reach; its projects, people and rules are shared between those Macs.")
        .alert("Rename Team", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { if let team { model.renameTeam(team.id!, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Mac in the team sees the new name.")
        }
        .confirmationDialog("Leave the team “\(team?.name ?? "")”?", isPresented: $confirmLeave) {
            Button("Leave Team", role: .destructive) { if let team { model.leaveTeam(team.id!) } }
        } message: {
            Text("This Mac stops sharing with the team. Its projects stay here, now only on this Mac; people keep their names; what teammates' Macs saw of their faces is forgotten. The team sync folder and the other Macs are not touched.")
        }
    }

    var teamCount: String { "\(model.teams.count) team\(model.teams.count == 1 ? "" : "s")" }

    func title(_ team: TeamRecord?) -> String {
        if let team { return team.name }
        return model.currentProject == nil ? teamCount : "Only on this Mac"
    }

    func caption(_ team: TeamRecord?, _ status: TeamSync.TeamStatus?) -> String {
        if let team {
            let role = team.processorId == nil ? "" : model.isProcessor(team) ? " · faces: this Mac" : " · faces: \(team.processorName ?? "a teammate")"
            return Self.subtitle(status) + role
        }
        return model.currentProject == nil ? "Pick a project to see its team" : "Share to work on it from other Macs"
    }

    func label(team: TeamRecord?, status: TeamSync.TeamStatus?) -> some View {
        let offline = status?.reachable == false
        let tint: Color = team == nil ? .secondary : offline ? .orange : .accentColor
        return HStack(spacing: 8) {
            Image(systemName: team == nil ? "person.3" : "person.3.fill").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("TEAM").font(.caption2.weight(.semibold)).foregroundStyle(team == nil ? Color.secondary.opacity(0.6) : Color.accent.opacity(0.8))
                Text(title(team)).font(.headline).lineLimit(1)
                Text(caption(team, status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    static func subtitle(_ status: TeamSync.TeamStatus?) -> String {
        guard let status else { return "Connecting…" }
        if !status.reachable { return "Folder not reachable — resumes when it is back (moved? Locate Team Sync Folder…)" }
        if let e = status.error { return e }
        let macs = status.devices.count
        let synced = status.lastSync.map { "synced \(ago($0))" } ?? "syncing…"
        return "\(macs) Mac\(macs == 1 ? "" : "s") · \(synced)"
    }

    static func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 10 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Share the open project: with a team this Mac is already in, or a new team in a folder every teammate's Mac can
/// reach; then tell them to join it.
struct ShareTeamSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?
    @State private var existing: Int64? = nil
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if done, let team = model.currentTeam {
                Text("Shared with Team \(team.name)").font(.title2.bold())
                Text("The project now appears on every Mac in the team. People you name, merges, session names and rules reach them within seconds, and theirs reach you. Photos stay where they are.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                GroupBox("Tell teammates who are not in the team yet") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On their Mac: File → Join a Team… and pick this folder:")
                        HStack {
                            Text(team.folder).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            Spacer()
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(team.folder, forType: .string) }
                            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: team.folder) }
                        }
                        Text("Folders you add as Team Folders (the sources on the NAS) and Edited Folders appear on their Macs by themselves; folders only on this Mac stay here. Everyone must be able to open this folder (the same NAS share, or the same Dropbox / iCloud Drive folder).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Share Project with Team").font(.title2.bold())
                Text("Work on the same event from several Macs — yours or your teammates'. Name a person once and every Mac recognises them; session names and rules are shared too. Nothing to sign up for: the team lives in a folder every Mac can reach, and holds every event you share with it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.teams.isEmpty {
                    Picker("Team", selection: $existing) {
                        ForEach(model.teams) { t in Text("\(t.name)  ·  \(model.projects(in: t).count) projects").tag(Int64?.some(t.id!)) }
                        Text("New team…").tag(Int64?.none)
                    }
                    .pickerStyle(.radioGroup)
                }
                if existing == nil {
                    TextField("Team name", text: $name, prompt: Text(model.teams.isEmpty ? "e.g. SuZu Media" : "Team name")).textFieldStyle(.roundedBorder)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Team sync folder").font(.headline)
                            Spacer()
                            Button("Choose…") {
                                Panels.choose(folders: true, files: false, prompt: "Use This Folder",
                                              message: "Choose an empty folder on the NAS (or in Dropbox / iCloud Drive) that every Mac of the team can open.",
                                              start: model.projectSources.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }, key: "teamFolder") { folder = $0.first }
                            }
                        }
                        Text(folder?.path ?? "An empty folder on the NAS, or in Dropbox / iCloud Drive").foregroundStyle(folder == nil ? .secondary : .primary)
                            .lineLimit(2).truncationMode(.middle)
                        Text("One team sync folder serves every event: keep it somewhere permanent, e.g. “SuZu Media – Team”.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Share") {
                        if let id = existing, let team = model.teams.first(where: { $0.id == id }) {
                            model.shareProject(with: team)
                            done = model.currentTeam != nil
                        } else if let folder {
                            done = model.createTeam(named: name.isEmpty ? "SuZu Media" : name, folder: folder)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled((existing == nil && folder == nil) || model.currentProject == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { existing = model.teams.first?.id }
    }
}

/// Join a team a teammate created: pick its folder; its projects appear by themselves.
struct JoinTeamSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var info: TeamSync.Info?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join a Team").font(.title2.bold())
            Text("Pick the team sync folder a teammate shared (on the NAS, or in Dropbox / iCloud Drive). Its projects appear here, the people they name are recognised here, and yours there.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(folder?.path ?? "No folder chosen").foregroundStyle(folder == nil ? .secondary : .primary).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    Panels.choose(folders: true, files: false, prompt: "Join", message: "Choose the team sync folder your teammate shared.",
                                  start: model.projectSources.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }, key: "teamFolder") { urls in
                        guard let u = urls.first else { return }
                        folder = u
                        info = TeamSync.readInfo(u)
                        problem = info == nil ? "That folder has no team in it. Ask your teammate for the folder they created with “Share Project with Team…”." : nil
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let info {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(info.name, systemImage: "person.3").font(.headline)
                        Text("Created by \(info.createdBy) on \(Date(timeIntervalSince1970: info.createdAt).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The team's projects open here within seconds, with the team's folders and the edited folders in them; add any folder of your own to the one you are shooting. Your photos stay where they are; names, session names, rules and the shared folders' places are what travels.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Join Team") {
                    guard let folder else { return }
                    if model.joinTeam(folder: folder) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(info == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
