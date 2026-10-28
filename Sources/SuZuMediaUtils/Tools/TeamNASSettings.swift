import AppKit
import FaceLibrary
import SwiftUI

/// Settings → Team NAS: the NAS the team uploads to (attached once, through the team sync folder), a connection
/// test, the staging folder, and the uploads on their way.
struct TeamNASSettings: View {
    @EnvironmentObject var faces: FaceGroupingModel
    @ObservedObject var nas: TeamNASModel
    @State private var askAttach = false
    @State private var askDetach = false

    var body: some View {
        Form {
            connectionSection
            if nas.isConnected { uploadsSection }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .sheet(isPresented: $askAttach) { AttachNASSheet(nas: nas).environmentObject(faces) }
        .confirmationDialog("Detach the NAS from the team?", isPresented: $askDetach) {
            Button("Detach", role: .destructive) { nas.detach() }
        } message: {
            Text("Every Mac of the team stops uploading to it. The NAS keeps accepting the key until its line is taken out of the NAS user's authorized_keys.")
        }
        .onAppear { nas.resolve(); nas.reloadJobs() }
    }

    @ViewBuilder var connectionSection: some View {
        if let a = nas.attached {
            Section {
                LabeledContent("NAS") { Text("\(a.file.user)@\(a.file.host), port \(a.file.port)").textSelection(.enabled) }
                LabeledContent("Folder on the NAS") { Text(a.file.basePath).textSelection(.enabled) }
                LabeledContent("Through the team") {
                    Text("\(a.team.name) · attached by \(a.file.attachedBy) on \(Date(timeIntervalSince1970: a.file.attachedAt).formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Host key") { Text(a.file.hostKeys.isEmpty ? "not pinned" : "pinned (\(a.file.hostKeys.count))").foregroundStyle(.secondary) }
                HStack {
                    Button("Test Connection") { nas.test() }.disabled(nas.testing)
                    if nas.testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Copy authorized_keys Line") { copy(a.file.authorizedKeysLine) }
                        .help("The line that lets this key run rsync on the NAS, and nothing else, for the NAS user's ~/.ssh/authorized_keys")
                    Button("Change…") { askAttach = true }
                        .help("Attach again with another address, user or folder; the team's key stays, so the line on the NAS stays valid")
                    Button("Detach…", role: .destructive) { askDetach = true }
                }
                if let r = nas.testResult {
                    Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? Color.good : Color.notice)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Team NAS")
            } footer: {
                Text("Every Mac of the team uploads with this key. Uploads go over ssh on this one port; the NAS's shared folders stay off the internet.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                if faces.teams.isEmpty {
                    Text("Join or create a team first (File → Share Project with Team…). The NAS's address and key travel with the team sync folder, so every Mac of the team gets them.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No NAS is attached to your team yet. Attach it once from a Mac that can reach the NAS's admin; every other Mac of the team then uploads to it without any setup.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Attach a NAS…") { askAttach = true }
                }
            } header: {
                Text("Team NAS")
            } footer: {
                Text("With a NAS attached, Copy from Cards can send a card's files to the NAS from anywhere: the card is copied to this Mac in minutes and handed back, and the upload goes on by itself — resumed after a dropped connection, checked once there, and the team sees the folder only when it is complete.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var uploadsSection: some View {
        Section {
            LabeledContent("Staging folder") {
                HStack {
                    Text(nas.stagingFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Change…") { Panels.chooseFolder(key: "nas.staging") { nas.stagingPath = $0.path } }.controlSize(.small)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([nas.stagingFolder]) }.controlSize(.small)
                }
            }
            Toggle("Send anything new in the staging folder by itself", isOn: $nas.autoSend)
                .help("The staging folder mirrors the folder on the NAS: whatever lands in it (a card copy, a folder dragged in, an export) goes up under the same name once it has been quiet for 20 seconds")
            Toggle("Delete the staging copy once it is on the NAS and verified", isOn: $nas.deleteStagedWhenDone)
            HStack {
                Button("Send All Now") { nas.sendAllNow() }
                    .help("Every folder under the staging folder goes up now; what is already on the NAS costs nothing")
                Spacer()
            }
            if !nas.jobs.isEmpty {
                ForEach(nas.jobs) { job in UploadRow(job: job, nas: nas) }
                HStack {
                    Spacer()
                    if nas.jobs.contains(where: { $0.state == .done }) {
                        Button("Delete Uploaded Copies") { nas.deleteUploadedCopies() }
                            .help("Removes the staging copies of uploads that are done and verified")
                    }
                }
            } else {
                Text("No uploads yet. Pick “Team NAS” as the destination in Copy from Cards.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Uploads")
        } footer: {
            Text("The staging folder mirrors the folder on the NAS: a folder at its top goes to the same name there, files at its top go there too. Copy from Cards puts each card's folder there. Keep the copies until the event is delivered; they are this Mac's backup.")
                .foregroundStyle(.secondary)
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// One upload: what, where it stands, and Retry or Remove.
struct UploadRow: View {
    let job: NASUploadJob
    @ObservedObject var nas: TeamNASModel

    var current: RsyncUpload.Progress? {
        if case .uploading(let j, let p) = nas.status.phase, j.id == job.id { return p }
        return nil
    }

    var waiting: (Date, String)? {
        if case .waiting(let j, let until, let reason) = nas.status.phase, j.id == job.id { return (until, reason) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.title).fontWeight(.medium)
                Spacer()
                Text(job.remotePath).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .uploading: Button("Pause") { nas.pauseCurrent() }.controlSize(.small)
                case .failed, .queued: Button(job.state == .failed ? "Retry" : "Now") { nas.retry(job) }.controlSize(.small)
                case .done: EmptyView()
                }
                Button { nas.remove(job) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(job.state == .uploading ? "Stop and take this upload out (what is already on the NAS stays)" : "Take this upload out")
            }
            if let p = current {
                ProgressView(value: Double(p.percent), total: 100).controlSize(.small)
                Text(progressLine(p)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if let (until, reason) = waiting {
                Text("\(reason) Next try \(until.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
            } else if let e = job.lastError, job.state == .failed {
                Text(e).font(.caption).foregroundStyle(Color.notice)
            } else if job.state == .done, let at = job.finishedAt {
                Text("Done \(Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } else if job.state == .queued {
                Text("Waiting its turn").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    var icon: String {
        switch job.state {
        case .queued: "clock"
        case .uploading: "arrow.up.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch job.state {
        case .queued: .secondary
        case .uploading: .accent
        case .done: .good
        case .failed: .notice
        }
    }

    func progressLine(_ p: RsyncUpload.Progress) -> String {
        var parts = [TeamNASModel.progressDetail(p)]
        if p.pass != .verify, p.percent < 100, p.bytesPerSecond > 0 { parts.append("\(Int64(p.bytesPerSecond).formatted(.byteCount(style: .file)))/s") }
        if p.pass != .verify, let n = p.filesLeft, n > 0 { parts.append("\(n) files to go") }
        if !p.current.isEmpty { parts.append(p.current) }
        return parts.joined(separator: " · ")
    }
}

extension TeamNASModel {
    /// What the status pill and the upload list say after the title: the pass, the percent and the time left while
    /// bytes are moving; "checking" during the checksum pass, where rsync's percent and time mean nothing (nothing
    /// is sent, and its estimate runs on).
    static func progressDetail(_ p: RsyncUpload.Progress) -> String {
        switch p.pass {
        case .verify: return "checking"
        case .photosFirst, .everything:
            var parts: [String] = []
            if p.pass == .photosFirst { parts.append("photos first") }
            if p.percent < 100 {
                parts.append("\(p.percent)%")
                if let r = p.remaining, r > 0, p.bytesPerSecond > 0 { parts.append(timeLeft(r)) }
            } else {
                parts.append("finishing")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// "1 h 20 min left", "45 s left".
    static func timeLeft(_ s: TimeInterval) -> String {
        if s < 90 { return "\(Int(s.rounded())) s left" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min left" }
        let h = Int(s / 3600), m = Int((s - Double(h) * 3600) / 60)
        return m > 0 ? "\(h) h \(m) min left" : "\(h) h left"
    }
}

/// Attach the NAS to a team: its address and user, then the line to put on the NAS.
struct AttachNASSheet: View {
    @EnvironmentObject var faces: FaceGroupingModel
    @ObservedObject var nas: TeamNASModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = NASConnection.suzu.host
    @State private var port = String(NASConnection.suzu.port)
    @State private var user = NASConnection.suzu.user
    @State private var basePath = NASConnection.suzu.basePath
    @State private var teamId: Int64?
    @State private var working = false
    @State private var error: String?
    @State private var result: TeamNASModel.Attached?
    @State private var copied = false

    var team: TeamRecord? { faces.teams.first { $0.id == teamId } ?? faces.currentTeam ?? faces.teams.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result {
                done(result)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            teamId = (faces.currentTeam ?? faces.teams.first)?.id
            // Attaching again starts from what is attached, so one field can be changed.
            if let a = nas.attached {
                host = a.file.host; port = String(a.file.port); user = a.file.user; basePath = a.file.basePath; teamId = a.team.id
            }
        }
    }

    var form: some View {
        Group {
            Text("Attach a NAS to the team").font(.title2.bold())
            Text("The NAS's address and a new key go into the team sync folder; every Mac of the team then uploads with them. You will put one line on the NAS afterwards.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                if faces.teams.count > 1 {
                    Picker("Team", selection: $teamId) { ForEach(faces.teams) { Text($0.name).tag($0.id) } }
                }
                TextField("Address", text: $host, prompt: Text("nas.example.com or 192.168.1.10"))
                TextField("SSH port", text: $port)
                TextField("NAS user", text: $user)
                TextField("Folder on the NAS", text: $basePath, prompt: Text("/volume1/photo"))
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            Text("The folder as the NAS itself sees it, not as the share is mounted here: on a Synology every share is under /volume1, so the share “homes” is /volume1/homes. The NAS's rsync only writes where DSM's shared-folder permissions give the user Read/Write (Control Panel → Shared Folder → Permissions); the user's own home, /volume1/homes/<user>, always works. SSH must be on (Control Panel → Terminal & SNMP).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.notice).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Asking the NAS for its host key…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") { attach() }.keyboardShortcut(.defaultAction)
                    .disabled(working || team == nil || host.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil || user.isEmpty || !basePath.hasPrefix("/"))
            }
        }
    }

    func done(_ r: TeamNASModel.Attached) -> some View {
        Group {
            Text("Attached").font(.title2.bold())
            Text("\(user)@\(host) is now the team's NAS (\(r.hostKeys) host key\(r.hostKeys == 1 ? "" : "s") pinned). Last step, unless this line is on the NAS already: put it in the NAS user's ~/.ssh/authorized_keys. It lets the key run rsync and nothing else.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(r.authorizedKeysLine)
                .font(.caption.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Text("On the NAS, as that user:\nmkdir -p ~/.ssh && chmod 700 ~/.ssh && chmod 755 ~\necho '<the line>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(copied ? "Copied" : "Copy Line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(r.authorizedKeysLine, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    func attach() {
        guard let team, let p = Int(port) else { return }
        working = true
        error = nil
        let c = NASConnection(host: host.trimmingCharacters(in: .whitespaces), port: p, user: user.trimmingCharacters(in: .whitespaces),
                              basePath: basePath.trimmingCharacters(in: .whitespaces))
        nas.attach(c, to: team) { r in
            working = false
            switch r {
            case .success(let a): result = a
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}
