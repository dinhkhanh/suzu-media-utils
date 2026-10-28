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
    @AppStorage("nasStagingFolder") var stagingPath = "" { didSet { restartWatcher() } }
    @AppStorage("nasDeleteStagedWhenDone") var deleteStagedWhenDone = false
    /// Anything new under the staging folder goes up by itself (StagingWatcher); off: only what Copy from Cards
    /// puts there, and Send All Now.
    @AppStorage("nasAutoSend") var autoSend = true { didSet { restartWatcher() } }
    private var watcher: StagingWatcher?

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

    /// Called once the library is open: the queue starts and picks up where it was, and the staging folder is
    /// watched.
    func attach(store: LibraryStore, teams: [TeamRecord]) {
        self.store = store
        let q = NASUploadQueue(store: store, connection: { [connection] in connection.value })
        queue = q
        teamsChanged(teams)
        restartWatcher()
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

    // MARK: - The staging folder

    /// Where Copy from Cards copies: the staging folder, or `<staging>/<event>` when an event sub-folder is wanted
    /// (the folder on the NAS holding several events). Either way it mirrors the NAS.
    func stagingFolder(event: String) -> URL {
        let e = event.trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? stagingFolder : stagingFolder.appendingPathComponent(e, isDirectory: true)
    }

    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        guard queue != nil, autoSend else { return }
        let w = StagingWatcher(root: stagingFolder) { [weak self] units in
            Task { @MainActor in self?.enqueue(units) }
        }
        w.start()
        watcher = w
    }

    /// Everything under the staging folder goes up now, sent or not (rsync sends only what is new).
    func sendAllNow() {
        if let watcher { watcher.reportAll(); return }
        let w = StagingWatcher(root: stagingFolder) { [weak self] units in Task { @MainActor in self?.enqueue(units) } }
        w.reportAll()
    }

    // MARK: - Uploads

    /// Puts units of the staging folder in the queue, each to land at `<event>/<folder>` on the NAS. A unit already
    /// queued or on its way is left alone; one already sent goes again (more files landed; rsync sends the new ones).
    func enqueue(_ units: [StagingWatcher.Unit], marker: Data? = nil) {
        guard let queue else { return }
        let delete = deleteStagedWhenDone
        let from = Host.current().localizedName ?? "Mac"
        Task {
            for u in units {
                let path = u.local.standardizedFileURL.path
                if let existing = try? await queue.jobs().first(where: { $0.localFolder == path && $0.filesOnly == u.filesOnly }) {
                    switch existing.state {
                    case .queued, .uploading: continue
                    case .failed: try? await queue.retry(existing.id!); continue
                    case .done: try? await queue.remove(existing.id!)
                    }
                }
                let data = marker ?? (try? JSONEncoder().encode(Marker(folder: u.folder, from: from, sentAt: Date().timeIntervalSince1970)))
                _ = try? await queue.enqueue(local: u.local, remotePath: u.remotePath, title: u.title, marker: data,
                                             deleteLocalWhenDone: delete && !u.filesOnly, filesOnly: u.filesOnly)
            }
            await MainActor.run { self.reloadJobs() }
        }
    }

    /// A card's hand-over just landed in `<staging>[/<event>]/<card>/<handover>`: its top-level folder goes up (the
    /// hand-over with it; what is there already costs nothing), with a marker naming the card.
    func enqueueCard(event: String, card: CardRecord, handover: String?, outcome: CardCopier.Outcome) {
        let cardName = CardCopier.cardFolderName(card)
        let e = event.trimmingCharacters(in: .whitespaces)
        let unit = StagingWatcher.Unit(root: stagingFolder, folder: e.isEmpty ? cardName : e)
        let marker = Marker(folder: unit.folder, from: Host.current().localizedName ?? "Mac", sentAt: Date().timeIntervalSince1970,
                            event: e.isEmpty ? nil : e, card: cardName, cardUuid: card.uuid, handover: handover,
                            files: outcome.copied.count + outcome.skipped.count, bytes: outcome.bytes)
        enqueue([unit], marker: try? JSONEncoder().encode(marker))
        watcher?.markSent(unit)
    }

    /// `.suzu-upload.json` in the folder on the NAS: where it came from and, for a card, which.
    struct Marker: Codable {
        var format = 1
        var folder: String?
        var from: String
        var sentAt: Double
        var event: String?
        var card: String?
        var cardUuid: String?
        var handover: String?
        var files: Int?
        var bytes: Int64?
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

    /// Attaches the NAS to `team`: asks the NAS for its host keys, makes a key for the team (or keeps the one the
    /// team already has, so changing the address, user or folder doesn't mean a new line on the NAS), writes both
    /// to the team folder. Off the main thread; `done` gets the line for the NAS, or the reason it didn't work.
    func attach(_ c: NASConnection, to team: TeamRecord, done: @escaping (Result<Attached, Error>) -> Void) {
        let folder = URL(fileURLWithPath: team.folder, isDirectory: true)
        let by = Host.current().localizedName ?? NSUserName()
        Task.detached(priority: .userInitiated) {
            let r: Result<Attached, Error>
            do {
                let hostKeys = try NASTeamConfig.scanHostKeys(host: c.host, port: c.port)
                let key: (privateKey: Data, publicKey: String)
                if let existing = try NASTeamConfig.existingKey(teamFolder: folder) {
                    key = existing
                } else {
                    key = try NASTeamConfig.makeKey(comment: "suzu-team-nas")
                }
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
