import AppKit
import FaceLibrary
import SwiftUI

/// The team NAS from the app's side: which NAS the team has (read from the team sync folders, see NASTeamConfig),
/// the upload queue and what it is doing, the staging folder cards are copied to before they go, and the one-time
/// attaching from Settings → Team NAS. Owned by FaceGroupingModel (`faces.nas`).
@MainActor
final class TeamNASModel: ObservableObject {
    /// The NAS every Mac of the team uploads to, and the team it came with. nil: none attached (or its team folder
    /// can't be reached right now).
    @Published private(set) var attached: (team: TeamRecord, file: NASTeamConfig.File)?
    @Published private(set) var status = NASUploadQueue.Status()
    @Published private(set) var jobs: [NASUploadJob] = []
    @Published var testing = false
    @Published var testResult: (ok: Bool, text: String)?
    /// Where cards are copied before they go to the NAS; the copy stays until the upload is verified (and after,
    /// unless `deleteStagedWhenDone`).
    @AppStorage("nasStagingFolder") var stagingPath = ""
    @AppStorage("nasDeleteStagedWhenDone") var deleteStagedWhenDone = false

    private var queue: NASUploadQueue?
    private var store: LibraryStore?
    private var teams: [TeamRecord] = []
    private let connection = ConnectionBox()
    private var relook: Timer?

    var isConnected: Bool { attached != nil }

    var stagingFolder: URL {
        if !stagingPath.isEmpty { return URL(fileURLWithPath: stagingPath, isDirectory: true) }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SuZu Staging", isDirectory: true)
    }

    /// Called once the library is open: the queue starts and picks up where it was.
    func attach(store: LibraryStore, teams: [TeamRecord]) {
        self.store = store
        let q = NASUploadQueue(store: store, connection: { [connection] in connection.value })
        queue = q
        teamsChanged(teams)
        Task {
            await q.setOnChange { [weak self] s in Task { @MainActor in self?.status = s; self?.reloadJobs() } }
            await q.start()
        }
        // A NAS attached on another Mac shows up here within a minute (its team folder is read again).
        relook = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resolve() }
        }
    }

    func teamsChanged(_ teams: [TeamRecord]) {
        self.teams = teams
        resolve()
    }

    /// Reads the teams' folders for a NAS; the queue takes the result on its next job.
    func resolve() {
        let teams = self.teams
        Task.detached(priority: .utility) {
            var found: (TeamRecord, NASTeamConfig.File, NASConnection)?
            for t in teams {
                let folder = URL(fileURLWithPath: t.folder, isDirectory: true)
                if let f = try? NASTeamConfig.read(teamFolder: folder),
                   let c = try? NASTeamConfig.connection(teamFolder: folder, teamUuid: t.uuid) {
                    found = (t, f, c)
                    break
                }
            }
            let result = found
            await MainActor.run {
                self.connection.value = result?.2
                if result?.0.id != self.attached?.team.id || result?.1 != self.attached?.file {
                    self.attached = result.map { ($0.0, $0.1) }
                }
                self.reloadJobs()
            }
        }
    }

    func reloadJobs() {
        guard let queue else { return }
        Task { let j = (try? await queue.jobs()) ?? []; await MainActor.run { if j != self.jobs { self.jobs = j } } }
    }

    // MARK: - Uploads

    /// Puts a hand-over's folder (in the staging area) in the queue, to land at `<event>/<card>/<handover>` on the
    /// NAS. A folder already queued or on its way is left alone; one already sent goes again (more files landed).
    func enqueue(folder: URL, event: String, card: CardRecord, handover: String?, outcome: CardCopier.Outcome) {
        guard let queue else { return }
        let cardName = CardCopier.cardFolderName(card)
        var remote = (event.isEmpty ? "Uploads" : event) + "/" + cardName
        if let handover { remote += "/" + handover }
        let title = handover.map { "\(cardName) · \($0)" } ?? cardName
        let marker = Marker(card: cardName, cardUuid: card.uuid, event: event, handover: handover, from: Host.current().localizedName ?? "Mac",
                            files: outcome.copied.count + outcome.skipped.count, bytes: outcome.bytes, copiedAt: Date().timeIntervalSince1970)
        let data = try? JSONEncoder().encode(marker)
        let delete = deleteStagedWhenDone
        Task {
            if let existing = try? await queue.jobs().first(where: { $0.localFolder == folder.standardizedFileURL.path }) {
                switch existing.state {
                case .queued, .uploading: return
                case .failed: try? await queue.retry(existing.id!); return
                case .done: try? await queue.remove(existing.id!)
                }
            }
            _ = try? await queue.enqueue(local: folder, remotePath: remote, title: title, marker: data, deleteLocalWhenDone: delete)
            await MainActor.run { self.reloadJobs() }
        }
    }

    struct Marker: Codable {
        var format = 1
        var card: String
        var cardUuid: String
        var event: String
        var handover: String?
        var from: String
        var files: Int
        var bytes: Int64
        var copiedAt: Double
    }

    func retry(_ job: NASUploadJob) { guard let id = job.id, let queue else { return }; Task { try? await queue.retry(id); reloadJobs() } }
    func remove(_ job: NASUploadJob) { guard let id = job.id, let queue else { return }; Task { try? await queue.remove(id); reloadJobs() } }
    func pauseCurrent() { guard let queue else { return }; Task { await queue.pauseCurrent() } }

    /// Bytes under the staging folder (what the laptop still holds).
    func stagingSize() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: stagingFolder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Removes staging copies whose upload is done and verified.
    func deleteUploadedCopies() {
        for j in jobs where j.state == .done {
            try? FileManager.default.removeItem(at: j.localURL)
        }
    }

    // MARK: - Settings → Team NAS

    func test() {
        guard let c = connection.value else { testResult = (false, "No NAS attached."); return }
        testing = true
        testResult = nil
        Task.detached(priority: .userInitiated) {
            let r: (Bool, String)
            do { r = (true, try RsyncUpload.testConnection(c)) }
            catch let f as RsyncUpload.Failure { r = (false, f.message) }
            catch { r = (false, error.localizedDescription) }
            await MainActor.run { self.testing = false; self.testResult = r }
        }
    }

    /// What `attach` produced: the line for the NAS, to show and copy.
    struct Attached {
        var authorizedKeysLine: String
        var hostKeys: Int
    }

    /// Attaches the NAS to `team`: asks the NAS for its host keys, makes a key for the team, writes both to the
    /// team folder. Off the main thread; `done` gets the line to put on the NAS, or the reason it didn't work.
    func attach(_ c: NASConnection, to team: TeamRecord, done: @escaping (Result<Attached, Error>) -> Void) {
        let folder = URL(fileURLWithPath: team.folder, isDirectory: true)
        let by = Host.current().localizedName ?? NSUserName()
        Task.detached(priority: .userInitiated) {
            let r: Result<Attached, Error>
            do {
                let hostKeys = try NASTeamConfig.scanHostKeys(host: c.host, port: c.port)
                let key = try NASTeamConfig.makeKey(comment: "suzu-team-nas")
                try NASTeamConfig.attach(to: folder, connection: c, privateKey: key.privateKey, publicKey: key.publicKey, hostKeys: hostKeys, by: by)
                let file = try NASTeamConfig.read(teamFolder: folder)!
                r = .success(Attached(authorizedKeysLine: file.authorizedKeysLine, hostKeys: hostKeys.count))
            } catch { r = .failure(error) }
            await MainActor.run { self.resolve(); done(r) }
        }
    }

    func detach() {
        guard let attached else { return }
        let folder = URL(fileURLWithPath: attached.team.folder, isDirectory: true)
        Task.detached { try? NASTeamConfig.detach(from: folder); await MainActor.run { self.resolve() } }
    }

    final class ConnectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: NASConnection?
        var value: NASConnection? {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }
}
