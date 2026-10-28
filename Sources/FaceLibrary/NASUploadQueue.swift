import Foundation
import GRDB
import Network

/// A folder waiting to go to the NAS, or gone, or stuck (`nasUpload` table). Survives quitting the app: the queue
/// picks up where it was on the next launch.
public struct NASUploadJob: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "nasUpload"
    public enum State: String, Codable, Sendable {
        case queued, uploading, done, failed
    }
    public var id: Int64?
    /// The folder on this Mac (a card's hand-over folder in the staging area).
    public var localFolder: String
    /// Where it goes under the connection's base path (or an absolute path on the NAS).
    public var remotePath: String
    /// Shown in the status pill: "Nam R5 card 1 · 2026-10-28 14.05".
    public var title: String
    public var state: State
    public var attempts: Int
    /// The last failure's words; stays on a done job as a note of what it went through.
    public var lastError: String?
    /// Not before this moment (retries back off).
    public var nextAttemptAt: Double
    /// JSON to leave in the remote folder as `.suzu-upload.json` once everything is there, so the office Mac knows
    /// the folder is complete and which card it came from.
    public var marker: String?
    /// Remove the local folder once it is on the NAS and verified.
    public var deleteLocalWhenDone: Bool
    /// Only the folder's own files, not its folders (an event folder's loose files; see StagingWatcher).
    public var filesOnly: Bool
    public var createdAt: Double
    public var finishedAt: Double?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var localURL: URL { URL(fileURLWithPath: localFolder, isDirectory: true) }
}

/// Runs the uploads one after the other, in the background, for as long as the app is open: waits for the network
/// when there is none, tries again after a failure with a growing pause, and tells the app what it is doing
/// (`onChange`). `CardCopyTool` puts a hand-over folder in with `enqueue` once the card has landed in the staging
/// folder; the user never sees rsync.
public actor NASUploadQueue {
    public struct Status: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            case idle
            case uploading(NASUploadJob, RsyncUpload.Progress)
            /// Nothing to do until the network is back.
            case waitingForNetwork
            /// Between attempts of a job that failed (`at` is when it tries again).
            case waiting(NASUploadJob, until: Date, reason: String)
            /// Not connected to a NAS (no connection configured).
            case notConnected
        }
        public var phase: Phase = .idle
        public var queued: Int = 0
        /// Jobs that need a person: a refused key, a folder the NAS user can't write to.
        public var failed: [NASUploadJob] = []
        public init() {}
    }

    public static let markerName = ".suzu-upload.json"

    private let store: LibraryStore
    private let rsync: URL
    private let connection: @Sendable () -> NASConnection?
    private let passes: [RsyncUpload.Pass]
    private let backoff: @Sendable (Int) -> TimeInterval
    private var onChange: (@Sendable (Status) -> Void)?
    public private(set) var status = Status()
    private var running = false
    private var currentFlag: CancelFlag?
    private var currentId: Int64?
    private var online = true
    private var monitor: NWPathMonitor?
    private var wake: CheckedContinuation<Void, Never>?

    /// `connection`: asked before every job, so a change in Settings takes effect on the next one. `backoff`: the
    /// pause before attempt N of a job that failed (tests shorten it).
    public init(store: LibraryStore, rsync: URL = RsyncUpload.bundledRsync,
                passes: [RsyncUpload.Pass] = RsyncUpload.Pass.cardFolder,
                backoff: @escaping @Sendable (Int) -> TimeInterval = NASUploadQueue.backoff,
                connection: @escaping @Sendable () -> NASConnection?) {
        self.store = store
        self.rsync = rsync
        self.passes = passes
        self.backoff = backoff
        self.connection = connection
    }

    public func setOnChange(_ f: @escaping @Sendable (Status) -> Void) {
        onChange = f
        f(status)
    }

    /// Adds a folder; the queue sends it when its turn comes. `remotePath` is under the connection's base path.
    @discardableResult
    public func enqueue(local: URL, remotePath: String, title: String, marker: Data? = nil, deleteLocalWhenDone: Bool = false, filesOnly: Bool = false) throws -> NASUploadJob {
        var job = NASUploadJob(localFolder: local.standardizedFileURL.path, remotePath: remotePath, title: title, state: .queued, attempts: 0,
                               lastError: nil, nextAttemptAt: 0, marker: marker.map { String(decoding: $0, as: UTF8.self) },
                               deleteLocalWhenDone: deleteLocalWhenDone, filesOnly: filesOnly, createdAt: Date().timeIntervalSince1970, finishedAt: nil)
        try store.db.write { db in try job.insert(db) }
        wakeUp()
        refresh()
        return job
    }

    /// Every job, newest first.
    public func jobs() throws -> [NASUploadJob] {
        try store.db.read { db in try NASUploadJob.order(Column("createdAt").desc).fetchAll(db) }
    }

    /// A failed or stopped job goes back in the queue, now.
    public func retry(_ id: Int64) throws {
        try store.db.write { db in
            try db.execute(sql: "UPDATE nasUpload SET state = 'queued', nextAttemptAt = 0 WHERE id = ? AND state IN ('failed', 'queued')", arguments: [id])
        }
        wakeUp()
        refresh()
    }

    /// Takes a job out (a running one is stopped; what is already on the NAS stays).
    public func remove(_ id: Int64) throws {
        if id == currentId { currentFlag?.set() }
        try store.db.write { db in _ = try NASUploadJob.deleteOne(db, key: id) }
        refresh()
    }

    /// Stops the running job; it goes back in the queue, to run again on `retry` or the next launch.
    public func pauseCurrent() {
        currentFlag?.set()
    }

    /// Starts the loop (once). Jobs left "uploading" by a crash go back in the queue.
    public func start() {
        guard !running else { return }
        running = true
        try? store.db.write { db in
            try db.execute(sql: "UPDATE nasUpload SET state = 'queued' WHERE state = 'uploading'")
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.network(path.status == .satisfied) }
        }
        m.start(queue: DispatchQueue(label: "nas-upload-network"))
        monitor = m
        refresh()
        Task { await loop() }
    }

    private func network(_ up: Bool) {
        guard up != online else { return }
        online = up
        wakeUp()
        refresh()
    }

    private func wakeUp() {
        if let w = wake { wake = nil; w.resume() }
    }

    private func sleepUntilWoken(_ seconds: TimeInterval) async {
        let t = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, seconds)))
            await self?.wakeUp()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in wake = c }
        t.cancel()
    }

    private func loop() async {
        while running {
            guard online else { await sleepUntilWoken(3600); continue }
            guard let conn = connection() else { await sleepUntilWoken(3600); continue }
            let now = Date().timeIntervalSince1970
            let next = read { db in
                try NASUploadJob.filter(Column("state") == NASUploadJob.State.queued.rawValue).order(Column("nextAttemptAt"), Column("createdAt")).fetchOne(db)
            }
            guard let job = next ?? nil, let id = job.id else { await sleepUntilWoken(3600); continue }
            if job.nextAttemptAt > now {
                await sleepUntilWoken(job.nextAttemptAt - now)
                continue
            }
            await run(job, id: id, connection: conn)
        }
    }

    private func run(_ job: NASUploadJob, id: Int64, connection conn: NASConnection) async {
        write { db in try db.execute(sql: "UPDATE nasUpload SET state = 'uploading', attempts = attempts + 1 WHERE id = ?", arguments: [id]) }
        currentId = id
        status.phase = .uploading(job, RsyncUpload.Progress(pass: passes.first ?? .everything))
        refresh()
        let remote = conn.remotePath(job.remotePath)
        let local = job.localURL
        let rsync = rsync, passes = passes
        let flag = CancelFlag()
        currentFlag = flag
        let progressSink = ProgressSink()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if let p = progressSink.take() { await self?.report(job, p) }
            }
        }
        // On a thread of its own: rsync runs for hours and `upload` blocks for all of it, which would hold one of
        // the few threads Swift's tasks share.
        let result: Result<Void, Error> = await withCheckedContinuation { c in
            let t = Thread {
                do {
                    try RsyncUpload.upload(local, to: remote, connection: conn, rsync: rsync, passes: passes, filesOnly: job.filesOnly,
                                           progress: { progressSink.put($0) }, isCancelled: { flag.value })
                    if let marker = job.marker {
                        try Self.leaveMarker(marker, in: remote, connection: conn, rsync: rsync)
                    }
                    c.resume(returning: .success(()))
                } catch { c.resume(returning: .failure(error)) }
            }
            t.name = "nas-upload"
            t.qualityOfService = .utility
            t.start()
        }
        ticker.cancel()
        currentId = nil
        currentFlag = nil
        switch result {
        case .success:
            write { db in
                try db.execute(sql: "UPDATE nasUpload SET state = 'done', finishedAt = ?, lastError = NULL WHERE id = ?", arguments: [Date().timeIntervalSince1970, id])
            }
            if job.deleteLocalWhenDone, !job.filesOnly { try? FileManager.default.removeItem(at: local) }
            status.phase = .idle
        case .failure(let e):
            let f = (e as? RsyncUpload.Failure) ?? .other(code: -1, message: e.localizedDescription)
            if f == .cancelled {
                // Back in the queue, at the end; the next launch or Sync Now picks it up.
                write { db in
                    try db.execute(sql: "UPDATE nasUpload SET state = 'queued', nextAttemptAt = ?, lastError = NULL WHERE id = ?",
                                   arguments: [Date().timeIntervalSince1970 + 3600 * 24 * 365, id])
                }
                status.phase = .idle
            } else if f.isRetryable {
                let pause = backoff(job.attempts + 1)
                let at = Date().timeIntervalSince1970 + pause
                write { db in
                    try db.execute(sql: "UPDATE nasUpload SET state = 'queued', nextAttemptAt = ?, lastError = ? WHERE id = ?", arguments: [at, f.message, id])
                }
                var j = job; j.lastError = f.message; j.attempts += 1
                status.phase = f == .unreachable && !online ? .waitingForNetwork : .waiting(j, until: Date(timeIntervalSince1970: at), reason: f.message)

            } else {
                write { db in
                    try db.execute(sql: "UPDATE nasUpload SET state = 'failed', lastError = ? WHERE id = ?", arguments: [f.message, id])
                }
                status.phase = .idle
            }
        }
        refresh()
    }

    /// The synchronous GRDB calls (from an async method they would resolve to GRDB's async ones).
    private func write(_ f: (Database) throws -> Void) { try? store.db.write(f) }
    private func read<T>(_ f: (Database) throws -> T) -> T? { try? store.db.read(f) }

    /// 30 s, 1 min, 2, 4, 8, then every 10 minutes.
    public static func backoff(attempt: Int) -> TimeInterval {
        min(600, 30 * pow(2, Double(max(0, attempt - 1))))
    }

    /// Writes the marker next to the uploaded files, as the last thing: an rsync of one small file.
    static func leaveMarker(_ json: String, in remote: String, connection: NASConnection, rsync: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("suzu-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try json.write(to: dir.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
        var args = RsyncUpload.arguments(local: dir, remotePath: remote, connection: connection, pass: .everything)
        // Only the marker: no deleting, no touching what is there.
        args.insert("--include=\(markerName)", at: 0)
        args.insert("--exclude=*", at: 1)
        try RsyncUpload.run(rsync, arguments: args, pass: .everything, progress: { _ in }, isCancelled: { false })
    }

    private func report(_ job: NASUploadJob, _ p: RsyncUpload.Progress) {
        guard currentId == job.id else { return }
        status.phase = .uploading(job, p)
        onChange?(status)
    }

    private func refresh() {
        let rows = (try? store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM nasUpload GROUP BY state")
        }) ?? []
        var queued = 0
        for r in rows where (r["state"] as String) == NASUploadJob.State.queued.rawValue { queued = r["n"] }
        status.queued = queued
        status.failed = (try? store.db.read { db in
            try NASUploadJob.filter(Column("state") == NASUploadJob.State.failed.rawValue).order(Column("createdAt")).fetchAll(db)
        }) ?? []
        if connection() == nil { status.phase = .notConnected }
        else if !online, case .idle = status.phase, queued > 0 { status.phase = .waitingForNetwork }
        else if case .notConnected = status.phase { status.phase = .idle }
        onChange?(status)
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
        func set() { lock.lock(); v = true; lock.unlock() }
    }

    /// The latest progress, handed from rsync's reader thread to the actor four times a second.
    final class ProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private var p: RsyncUpload.Progress?
        func put(_ x: RsyncUpload.Progress) { lock.lock(); p = x; lock.unlock() }
        func take() -> RsyncUpload.Progress? { lock.lock(); defer { lock.unlock() }; let x = p; p = nil; return x }
    }
}
