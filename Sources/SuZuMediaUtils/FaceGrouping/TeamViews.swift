import AppKit
import FaceLibrary
import SwiftUI

/// Under the project switcher: the open project's team and how the sharing is going.
struct TeamBar: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var confirmLeave = false

    var body: some View {
        if let team = model.currentTeam {
            let status = model.teamStatus[team.id!]
            Menu {
                Button("Sync Now") { model.syncTeamNow() }
                Button("Show Team Folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: team.folder) }
                Button("Copy Team Folder Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(team.folder, forType: .string)
                }
                if let status, !status.devices.isEmpty {
                    Divider()
                    ForEach(status.devices, id: \.id) { d in
                        Text(d.isThisMac ? "\(d.name) (this Mac)" : "\(d.name)\(d.lastSeen.map { " · \(Self.ago($0))" } ?? "")")
                    }
                }
                Divider()
                Button("Leave Team…", role: .destructive) { confirmLeave = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: status?.reachable == false ? "person.3.fill" : "person.3")
                        .foregroundStyle(status?.reachable == false ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Team \(team.name)").font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(Self.subtitle(status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            .padding(.horizontal, 10).padding(.bottom, 4)
            .help("Names, people, session names and rules are shared with every Mac in the team through \(team.folder)")
            .confirmationDialog("Leave the team “\(team.name)”?", isPresented: $confirmLeave) {
                Button("Leave Team", role: .destructive) { model.leaveTeam(team.id!) }
            } message: {
                Text("This Mac stops sharing with the team. People keep their names here; what teammates' Macs saw of their faces is forgotten. The team folder and the other Macs are not touched.")
            }
        }
    }

    static func subtitle(_ status: TeamSync.TeamStatus?) -> String {
        guard let status else { return "Connecting…" }
        if !status.reachable { return "Folder not reachable — will resume when it is back" }
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

/// Share the open project: pick a folder every teammate's Mac can reach, and tell them to join it.
struct ShareTeamSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?
    @State private var created: TeamRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let team = created ?? model.currentTeam {
                Text("Shared with Team").font(.title2.bold())
                Text("Your project is shared. People you name, merges, session names and rules reach every Mac in the team within seconds, and theirs reach you. Photos stay where they are.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                GroupBox("Tell your teammates") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On their Mac: File → Join a Team… and pick this folder:")
                        HStack {
                            Text(team.folder).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            Spacer()
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(team.folder, forType: .string) }
                            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: team.folder) }
                        }
                        Text("They then add their own photo folders to the project. Everyone must be able to open this folder (the same NAS share, or the same Dropbox / iCloud Drive folder).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Share Project with Team").font(.title2.bold())
                Text("Work on the same event from several Macs — yours or your teammates'. Name a person once and every Mac recognises them; session names and rules are shared too. Nothing to sign up for: the team lives in a folder every Mac can reach.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Team name", text: $name, prompt: Text(model.projectName)).textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Team folder").font(.headline)
                        Spacer()
                        Button("Choose…") {
                            Panels.choose(folders: true, files: false, prompt: "Use This Folder",
                                          message: "Choose an empty folder on the NAS (or in Dropbox / iCloud Drive) that every Mac of the team can open.",
                                          start: model.projectSources.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }) { folder = $0.first }
                        }
                    }
                    Text(folder?.path ?? "An empty folder on the NAS, or in Dropbox / iCloud Drive").foregroundStyle(folder == nil ? .secondary : .primary)
                        .lineLimit(2).truncationMode(.middle)
                    Text("Tip: make it next to the event's photo folders, e.g. “Gala 2026 – Team”.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create Team") {
                        guard let folder else { return }
                        if model.createTeam(named: name.isEmpty ? model.projectName : name, folder: folder) {
                            created = model.currentTeam ?? TeamRecord(uuid: "", name: name.isEmpty ? model.projectName : name, folder: canonicalPath(folder), projectId: model.currentProject ?? 0)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder == nil || model.currentProject == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Join a team a teammate created: pick its folder, choose which project it becomes.
struct JoinTeamSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var info: TeamSync.Info?
    @State private var problem: String?
    @State private var linkCurrent = false

    var canLinkCurrent: Bool { model.currentProject != nil && model.currentTeam == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join a Team").font(.title2.bold())
            Text("Pick the team folder a teammate shared (on the NAS, or in Dropbox / iCloud Drive). From then on the people they name are recognised here, and yours there.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(folder?.path ?? "No folder chosen").foregroundStyle(folder == nil ? .secondary : .primary).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    Panels.choose(folders: true, files: false, prompt: "Join", message: "Choose the team folder your teammate shared.",
                                  start: model.projectSources.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }) { urls in
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
                Picker("Project", selection: $linkCurrent) {
                    Text("New project “\(info.name)”").tag(false)
                    if canLinkCurrent { Text("This project (\(model.projectName))").tag(true) }
                }
                .pickerStyle(.radioGroup)
                Text("Then add your own photo folders to it. Your photos stay on your Mac; only names, session names and rules are shared.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Join Team") {
                    guard let folder else { return }
                    if model.joinTeam(folder: folder, project: linkCurrent ? model.currentProject : nil) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(info == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
