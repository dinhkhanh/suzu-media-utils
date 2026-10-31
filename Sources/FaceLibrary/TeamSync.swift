import Foundation
import GRDB

/// Shares projects between Macs — yours and your teammates' — through a folder they can all reach: a NAS share,
/// Dropbox, iCloud Drive. No account, no server: one Mac creates the team in a folder, the others join by picking
/// that folder. A team holds any number of projects (one per event); joining brings them all.
///
/// What travels: projects (stable id and name), people (stable id, name, picture, pin, and a summary of their faces
/// so every Mac recognises them), merges, session names, rules, and the folders the team shares (the sources every Mac works
/// on, and the editing Mac's folder; see `SourceShare`). Photos, face boxes and crops stay on the Mac that
/// processed them.
///
/// How: every Mac appends its changes to its own log file (`devices/<id>.jsonl`) and reads everyone else's; nobody
/// writes anyone else's file, so a shared folder needs no locking. Changes carry the time they were made and the
/// newest wins. A Mac that was offline catches up from where it left off. Each Mac also overwrites its own
/// `summaries/<id>.json` with the mean embedding of every person's faces it has seen.
///
/// Two lanes: the logs (names, merges, pins, lists, rules, folders…) go every couple of seconds and at once after a
/// change here, on their own queue; faces (records, crops, summaries) on another, so a backlog of faces over the NAS
/// never holds a name or a pin back.
///
/// The format is the contract; the folder is one transport. Another (iCloud, a server) would move the same files.
public final class TeamSync: @unchecked Sendable {
    public let store: LibraryStore
    let engine: GroupingEngine
    /// The logs: short passes.
    let queue = DispatchQueue(label: "teamsync", qos: .utility)
    /// Faces and summaries: passes that can take long (crops and content keys over the NAS, the grouping engine).
    let faceQueue = DispatchQueue(label: "teamsync.faces", qos: .utility)
    var timer: DispatchSourceTimer?
    var faceTimer: DispatchSourceTimer?
    /// A log pass is queued and hasn't started yet (pushSoon doesn't queue another).
    var logPassQueued = false
    /// Per team: what went wrong in the last face pass, shown with the team's status.
    var faceErrors: [Int64: String] = [:]
    let lock = NSLock()
    var statuses: [Int64: TeamStatus] = [:]
    var summariesWritten: [Int64: Date] = [:]
    var summariesChecked: [Int64: Date] = [:]
    var wanted = false
    /// Per person: the signature of their faces when the centroid was computed.
    var centroids: [Int64: (signature: String, centroid: [Float], count: Int, exemplars: [[Float]])] = [:]
    /// Called off the main thread after a pass changed something or a status.
    public var onChange: (@Sendable () -> Void)?
    /// Called off the main thread when a team's processing Mac changed (this Mac may now have to process, or stop).
    public var onRolesChanged: (@Sendable () -> Void)?
    var rolesVersion = 0
    /// Called off the main thread after a teammate's change added, moved or took away a folder here (the app
    /// starts or stops watching it, see LibraryService.reconcileMonitors).
    public var onSourcesChanged: (@Sendable () -> Void)?
    var sourcesChanged = false
    /// When each file's record was last written for the team (shared processing).
    var facesPublishedAt: [Int64: Double] = [:]
    /// Per team: when another Mac's face records were last read (copying Macs sending the cards' faces).
    var foreignFacesAt: [Int64: Date] = [:]
    /// Files taken from a copying Mac's record on the processing Mac, for the engine to group (see pullFaces).
    var takenToGroup: [Int64] = []
    /// Teams whose taken files were checked for faces without pictures since the app started (see queueMissingCrops).
    var cropsChecked: Set<Int64> = []
    /// Per team: the last file fetchMissingCrops tried, so files that can't be fetched yet don't hold up the rest.
    var cropRetryCursor: [Int64: Int64] = [:]
    var cropsFetched = 0
    public let deviceId: String
    public var deviceName: String
    /// Log passes (names, pins, lists…): a teammate's change shows here within about this, plus the share's delay.
    public static let passInterval: Double = 2
    public static let facePassInterval: Double = 5
    public static let summaryInterval: Double = 60
    public static let summaryCheckInterval: Double = 15
    public static let model = "ArcFaceR50"
    /// Changes from a teammate's log applied per transaction (see pull).
    static let opChunk = 200

    public struct Device: Hashable, Sendable {
        public var id: String
        public var name: String
        public var lastSeen: Date?
        public var isThisMac: Bool
    }

    public struct TeamStatus: Hashable, Sendable {
        public var teamId: Int64
        public var reachable = false
        public var devices: [Device] = []
        public var lastSync: Date?
        public var error: String?
    }

    /// `team.json` in the shared folder.
    public struct Info: Codable, Sendable {
        public var format = 1
        public var uuid: String
        public var name: String
        public var createdAt: Double
        public var createdBy: String
        /// The Mac that does the team's face work, when one was chosen (see SharedFaces).
        public var processor: Processor?
    }

    public enum TeamError: LocalizedError {
        case notATeamFolder, alreadyATeamFolder(String), projectAlreadyShared(String), folderUnreachable
        case differentTeam(String, String)
        public var errorDescription: String? {
            switch self {
            case .notATeamFolder: "That folder has no team in it. Pick the team sync folder a teammate shared, or create a team."
            case .alreadyATeamFolder(let n): "That folder already holds the team “\(n)”. Join it instead."
            case .projectAlreadyShared(let n): "This project is already shared with the team “\(n)”."
            case .folderUnreachable: "The folder can't be reached. Mount the share (or open Dropbox / iCloud Drive) and try again."
            case .differentTeam(let found, let expected):
                "That folder holds the team “\(found)”, not “\(expected)”. Pick the folder of this team at its new place."
            }
        }
    }

    public init(store: LibraryStore, engine: GroupingEngine) {
        self.store = store
        self.engine = engine
        deviceId = (try? store.db.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'deviceId'") }) ?? SyncIds.new()
        deviceName = Host.current().localizedName ?? "Mac"
    }

    // MARK: - Teams and their projects

    public func teams() throws -> [TeamRecord] {
        try store.db.read { db in try TeamRecord.order(Column("joinedAt")).fetchAll(db) }
    }

    public func team(forProject project: Int64) throws -> TeamRecord? {
        try store.db.read { db in
            guard let tid = try Int64.fetchOne(db, sql: "SELECT teamId FROM project WHERE id = ?", arguments: [project]) else { return nil }
            return try TeamRecord.fetchOne(db, key: tid)
        }
    }

    public func projects(in teamId: Int64) throws -> [ProjectRecord] {
        try store.db.read { db in try ProjectRecord.filter(Column("teamId") == teamId).order(Column("createdAt").desc).fetchAll(db) }
    }

    public func status(_ teamId: Int64) -> TeamStatus? { lock.withLock { statuses[teamId] } }
    /// Goes up each time faces' pictures came in from a teammate's folder after their faces did (see
    /// fetchMissingCrops): pictures shown empty are worth looking for again.
    public var picturesFetched: Int { lock.withLock { cropsFetched } }

    static func infoURL(_ folder: URL) -> URL { folder.appendingPathComponent("team.json") }
    static func devicesURL(_ folder: URL) -> URL { folder.appendingPathComponent("devices", isDirectory: true) }
    static func summariesURL(_ folder: URL) -> URL { folder.appendingPathComponent("summaries", isDirectory: true) }

    /// The id of the one project a team held before teams could hold several (and of changes logged without a
    /// project): the same on every Mac of that team.
    public static func legacyProjectUuid(_ teamUuid: String) -> String { "\(teamUuid)-project" }

    public static func readInfo(_ folder: URL) -> Info? {
        (try? Data(contentsOf: infoURL(folder))).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    /// Starts a team in an empty (or new) folder that every teammate's Mac can reach, sharing `project` with it.
    @discardableResult
    public func create(name: String, folder: URL, project: Int64) throws -> TeamRecord {
        if let existing = try team(forProject: project) { throw TeamError.projectAlreadyShared(existing.name) }
        if let info = Self.readInfo(folder) { throw TeamError.alreadyATeamFolder(info.name) }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.devicesURL(folder), withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.summariesURL(folder), withIntermediateDirectories: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = Info(uuid: SyncIds.new(), name: trimmed.isEmpty ? folder.lastPathComponent : trimmed,
                        createdAt: Date().timeIntervalSince1970, createdBy: deviceName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: Self.infoURL(folder), options: .atomic)
        let team = try register(info, folder: folder)
        try share(project: project, team: team.id!)
        return team
    }

    /// Joins the team in `folder`; its projects appear here as the teammates' logs are read. Joining a team this
    /// Mac is already in just points it at this folder (the share may be mounted under another name).
    @discardableResult
    public func join(folder: URL) throws -> TeamRecord {
        guard let info = Self.readInfo(folder) else {
            throw FileManager.default.fileExists(atPath: folder.path) ? TeamError.notATeamFolder : TeamError.folderUnreachable
        }
        if let existing = try store.db.read({ db in try TeamRecord.filter(Column("uuid") == info.uuid).fetchOne(db) }) {
            try relocate(existing.id!, to: folder)
            return try store.db.read { db in try TeamRecord.fetchOne(db, key: existing.id)! }
        }
        return try register(info, folder: folder)
    }

    func register(_ info: Info, folder: URL) throws -> TeamRecord {
        var t = TeamRecord(uuid: info.uuid, name: info.name, folder: canonicalPath(folder))
        try store.db.write { db in try t.insert(db) }
        lock.withLock { statuses[t.id!] = TeamStatus(teamId: t.id!, reachable: true) }
        syncSoon()
        return t
    }

    /// Shares a project of this Mac with a team: it appears on every Mac of the team, and its session names and
    /// rules travel from then on.
    public func share(project: Int64, team teamId: Int64) throws {
        if let existing = try team(forProject: project), existing.id != teamId { throw TeamError.projectAlreadyShared(existing.name) }
        try store.db.write { db in
            try db.execute(sql: "UPDATE project SET teamId = ?, updatedAt = ? WHERE id = ?", arguments: [teamId, Date().timeIntervalSince1970, project])
        }
        syncSoon()
    }

    /// Stops sharing a project from this Mac; teammates' Macs keep their copy of it.
    public func unshare(project: Int64) throws {
        try store.db.write { db in try db.execute(sql: "UPDATE project SET teamId = NULL WHERE id = ?", arguments: [project]) }
        onChange?()
    }

    /// Renames the team for every Mac: the name lives in `team.json`, which every Mac re-reads on each pass.
    public func rename(_ teamId: Int64, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let team = try store.db.read({ db in try TeamRecord.fetchOne(db, key: teamId) }) else { return }
        guard var info = Self.readInfo(team.url) else { throw TeamError.folderUnreachable }
        info.name = name
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = Self.infoURL(team.url).appendingPathExtension("tmp")
        try encoder.encode(info).write(to: tmp)
        guard Darwin.rename(tmp.path, Self.infoURL(team.url).path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
        try store.db.write { db in try db.execute(sql: "UPDATE team SET name = ? WHERE id = ?", arguments: [name, teamId]) }
        onChange?()
    }

    /// The team folder moved (the NAS has a new address, the share is mounted under another name): point the team
    /// at the same folder in its new place. Everything already read or published stays valid.
    ///
    /// The folder the team already uses changes nothing: the team's state is kept and no pass is started (it used
    /// to drop the Macs and "synced" state and run a whole pass, which under heavy processing took a while).
    /// Returns whether the team now points somewhere else.
    @discardableResult
    public func relocate(_ teamId: Int64, to folder: URL) throws -> Bool {
        guard let team = try store.db.read({ db in try TeamRecord.fetchOne(db, key: teamId) }) else { return false }
        guard let info = Self.readInfo(folder) else {
            throw FileManager.default.fileExists(atPath: folder.path) ? TeamError.notATeamFolder : TeamError.folderUnreachable
        }
        guard info.uuid == team.uuid else { throw TeamError.differentTeam(info.name, team.name) }
        let path = canonicalPath(folder)
        if path == team.folder {
            // Unreachable a moment ago (share remounted at the same place): look again soon, keeping what is known.
            if lock.withLock({ statuses[teamId]?.reachable }) != true { syncSoon() }
            return false
        }
        try store.db.write { db in
            try db.execute(sql: "UPDATE team SET folder = ? WHERE id = ?", arguments: [path, teamId])
        }
        lock.withLock { statuses[teamId] = TeamStatus(teamId: teamId, reachable: true) }
        syncSoon()
        return true
    }

    /// The team already registered for the team in `folder`, if this Mac is in it.
    public func member(of folder: URL) -> TeamRecord? {
        guard let info = Self.readInfo(folder) else { return nil }
        return try? store.db.read { db in try TeamRecord.filter(Column("uuid") == info.uuid).fetchOne(db) }
    }

    /// Leaves the team: forgets its folder and what teammates' Macs saw. Its projects stay here, now only on this
    /// Mac; people keep their names.
    public func leave(_ teamId: Int64) throws {
        let affected = try store.db.write { db -> Set<Int64> in
            let ids = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM personRemote WHERE teamId = ?", arguments: [teamId]))
            try db.execute(sql: "UPDATE project SET teamId = NULL WHERE teamId = ?", arguments: [teamId])
            _ = try TeamRecord.deleteOne(db, key: teamId)
            return ids
        }
        lock.withLock { statuses[teamId] = nil }
        engine.peopleChanged(affected)
    }

    // MARK: - Running

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: Self.passInterval)
        t.setEventHandler { [weak self] in self?.logPass() }
        t.resume()
        timer = t
        let f = DispatchSource.makeTimerSource(queue: faceQueue)
        f.schedule(deadline: .now() + 3, repeating: Self.facePassInterval)
        f.setEventHandler { [weak self] in self?.facePass() }
        f.resume()
        faceTimer = f
    }

    public func stop() {
        timer?.cancel(); timer = nil
        faceTimer?.cancel(); faceTimer = nil
    }

    /// Something changed (a name, a merge, a rule): a log pass now, and summaries on the next face pass without
    /// waiting for the summary interval.
    public func pushSoon() {
        let queueOne = lock.withLock { () -> Bool in
            wanted = true
            defer { logPassQueued = true }
            return !logPassQueued
        }
        if queueOne { queue.async { [weak self] in self?.logPass() } }
    }

    public func syncSoon() {
        pushSoon()
        faceQueue.async { [weak self] in self?.facePass() }
    }

    /// A log pass as soon as its queue is free, then `completion` (off the main thread). Nothing waits on the pass.
    public func syncSoon(then completion: @escaping @Sendable () -> Void) {
        pushSoon()
        queue.async { [weak self] in
            self?.logPass()
            completion()
        }
    }

    /// One pass over every team now, logs then faces (tests). Returns whether anything was read or written.
    @discardableResult
    public func syncNow() -> Bool {
        let logs = queue.sync { logPass() }
        let faces = faceQueue.sync { facePass() }
        return logs || faces
    }

    /// The teams' logs: what this Mac changed goes out, what teammates changed comes in.
    @discardableResult
    func logPass() -> Bool {
        lock.withLock { logPassQueued = false }
        guard let teams = try? teams(), !teams.isEmpty else { return false }
        var changed = false
        for team in teams {
            var status = lock.withLock { statuses[team.id!] } ?? TeamStatus(teamId: team.id!)
            let folder = team.url
            guard FileManager.default.fileExists(atPath: Self.infoURL(folder).path) else {
                status.reachable = false
                status.error = "Can't reach \(folder.path)"
                lock.withLock { statuses[team.id!] = status }
                continue
            }
            status.reachable = true
            status.error = nil
            if status.devices.isEmpty { status.devices = devices(team) }
            lock.withLock { statuses[team.id!] = status }
            do {
                // A teammate renamed the team, or chose the Mac that processes faces.
                var team = team
                if let info = Self.readInfo(folder), info.uuid == team.uuid {
                    if info.name != team.name {
                        try store.db.write { db in try db.execute(sql: "UPDATE team SET name = ? WHERE id = ?", arguments: [info.name, team.id]) }
                        changed = true
                    }
                    if info.processor?.id != team.processorId || info.processor?.name != team.processorName {
                        try applyProcessor(info.processor, team: team)
                        team.processorId = info.processor?.id
                        team.processorName = info.processor?.name
                        changed = true
                    }
                }
                if try push(team) { changed = true }
                if try pull(team) { changed = true }
                status.devices = devices(team)
                status.lastSync = Date()
                status.error = lock.withLock { faceErrors[team.id!] }
            } catch {
                status.error = error.localizedDescription
            }
            lock.withLock { statuses[team.id!] = status }
        }
        onChange?()
        return changed
    }

    /// The teams' faces: summaries and face records out, teammates' summaries and face records in.
    @discardableResult
    func facePass() -> Bool {
        guard let teams = try? teams(), !teams.isEmpty else { return false }
        var changed = false
        let forced = lock.withLock { let w = wanted; wanted = false; return w }
        for team in teams where FileManager.default.fileExists(atPath: Self.infoURL(team.url).path) {
            var error: String?
            do {
                if try publishSummaries(team, people: try relevantPeople(team), state: try state(team.id!), forced: forced) { changed = true }
                if try publishFaces(team) { changed = true }
                if try pullSummaries(team) { changed = true }
                if try pullFaces(team) { changed = true }
                try queueMissingCrops(team)
                if try fetchMissingCrops(team) { changed = true; lock.withLock { cropsFetched += 1 } }
            } catch let e {
                error = e.localizedDescription
            }
            let shown = lock.withLock { () -> Bool in
                let was = faceErrors[team.id!]
                faceErrors[team.id!] = error
                guard was != error, var s = statuses[team.id!], s.reachable else { return false }
                s.error = error
                statuses[team.id!] = s
                return true
            }
            if shown { changed = true }
        }
        if changed { onChange?() }
        return changed
    }

    // MARK: - State

    func state(_ team: Int64) throws -> [String: String] {
        try store.db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM syncState WHERE teamId = ?", arguments: [team])
                .map { ($0["key"] as String, $0["value"] as String) })
        }
    }

    func setState(_ team: Int64, _ values: [String: String]) throws {
        guard !values.isEmpty else { return }
        try store.db.write { db in
            for (k, v) in values {
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [team, k, v])
            }
        }
    }

    // MARK: - Publishing

    /// One change in a device's log.
    struct Op: Codable {
        /// device, person, merge, session, rule, summary (deferred only), card, cardFile, face, folder, cover,
        /// pin (uuid = the person, deleted = unpinned), bio (uuid = the person, name = the note, none = cleared),
        /// tag (uuid = the person, name = the tag, deleted = taken off), watermark (uuid = the saved watermark, name, deleted),
        /// list (uuid, name, deleted), listMember (uuid = the list, into = the person, deleted = taken off)
        var t: String
        var at: Double
        var uuid: String?
        var name: String?
        var into: String?
        var moment: Double?
        var rule: RulePayload?
        var deleted: Bool?
        var device: String?
        var centroid: String?
        var count: Int?
        /// session, rule: the project's stable id (older logs: none = the team's first project).
        var project: String?
        /// card: a memory card (uuid = its volume UUID, name = its label, at = when the label was given).
        var card: CardPayload?
        /// cardFile: one file copied from a card (uuid = the card's, at = when it was copied).
        var file: CardFilePayload?
        /// face: a face rejected or moved (key = the file's content key, index = the face's position in the file,
        /// uuid = the person now or none, assign = user/auto, rejected = the person it is not).
        var key: String?
        var index: Int?
        var assign: String?
        var rejected: String?
        /// summary: the person's exemplar faces (Float16 rows, base64).
        var exemplars: String?
        /// folder: a photo & video folder shared with the team (uuid = the folder's stable id, project = its
        /// project, deleted = taken out of the team).
        var folder: FolderPayload?
        /// watermark: the saved watermark and its files in the team folder.
        var watermark: WatermarkPayload?
        /// look: the saved look's sliders.
        var look: LookPayload?
    }

    struct FolderPayload: Codable {
        /// The folder's path on the Mac that shared it.
        var path: String
        /// The same folder relative to the team folder, when both sit on the same volume: the NAS share may be
        /// mounted under another name on each Mac, but it holds both folders at the same distance.
        var rel: String?
        /// team / edited; mac = no longer shared.
        var share: String
        /// Its subfolders left out of the library (nil from a Mac before them: what is here stays).
        var excluded: [String]? = nil
    }

    struct CardPayload: Codable {
        var volume: String?
        var make: String?
        var model: String?
        var serial: String?
        var seen: Double
    }

    struct CardFilePayload: Codable {
        var path: String
        var size: Int64
        var mtime: Double
        var key: String
        var sha: String?
        var to: String?
    }

    struct RulePayload: Codable {
        var name: String?
        var folder: String?
        var layout: String
        /// nil from Macs before it existed: together.
        var splitKinds: Bool?
        var recipe: String?
        var writeNames: Bool
        var enabled: Bool
        /// People by stable id; the query's own people list is empty.
        var people: [String]
        var query: MediaQuery
        var createdAt: Double
    }

    struct Summaries: Codable {
        var model: String
        var device: String
        var people: [String: Summary]
    }
    struct Summary: Codable {
        var c: String
        var n: Int
        /// Up to 8 exemplar faces (Float16 rows, base64), from 0.8.3 on.
        var e: String?
    }

    /// Everyone with a name on this Mac: people are shared by every project, so what one event taught travels to
    /// the next event's team — a Mac joining its first team gets years of names and faces at once.
    func relevantPeople(_ team: TeamRecord) throws -> [(id: Int64, uuid: String, name: String, nameAt: Double?)] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, uuid, name, nameAt FROM person WHERE name IS NOT NULL ORDER BY id")
                .map { ($0["id"], $0["uuid"], $0["name"], $0["nameAt"]) }
        }
    }

    func push(_ team: TeamRecord) throws -> Bool {
        let teamId = team.id!
        var state = try state(teamId)
        var ops: [Op] = []
        var updates: [String: String] = [:]
        let now = Date().timeIntervalSince1970

        if state["pub:device"] != deviceName {
            ops.append(Op(t: "device", at: now, name: deviceName))
            updates["pub:device"] = deviceName
        }
        let projects = try projects(in: teamId)
        for p in projects {
            let value = "\(p.updatedAt)|\(p.name)"
            if state["pub:project:\(p.uuid)"] != value {
                ops.append(Op(t: "project", at: p.updatedAt, uuid: p.uuid, name: p.name))
                updates["pub:project:\(p.uuid)"] = value
            }
        }
        let people = try relevantPeople(team)
        for p in people {
            let at = p.nameAt ?? 0
            let value = "\(at)|\(p.name)"
            if state["pub:person:\(p.uuid)"] != value {
                ops.append(Op(t: "person", at: at, uuid: p.uuid, name: p.name))
                updates["pub:person:\(p.uuid)"] = value
            }
        }
        // A name taken away travels too (the person was named once: nameAt is set), or teammates kept it.
        for r in try store.db.read({ db in try Row.fetchAll(db, sql: "SELECT uuid, nameAt FROM person WHERE name IS NULL AND nameAt IS NOT NULL") }) {
            let uuid: String = r["uuid"], at: Double = r["nameAt"]
            let value = "\(at)|"
            if state["pub:person:\(uuid)"] != value {
                ops.append(Op(t: "person", at: at, uuid: uuid))
                updates["pub:person:\(uuid)"] = value
            }
        }
        for r in try store.db.read({ db in try Row.fetchAll(db, sql: "SELECT fromUuid, intoUuid, at FROM personMerge") }) {
            let from: String = r["fromUuid"], into: String = r["intoUuid"]
            if state["pub:merge:\(from)"] != into {
                ops.append(Op(t: "merge", at: r["at"], uuid: from, into: into))
                updates["pub:merge:\(from)"] = into
            }
        }
        let uuidOf = Dictionary(people.map { ($0.id, $0.uuid) }, uniquingKeysWith: { a, _ in a })
        for project in projects {
            let pid = project.id!
            for r in try store.db.read({ db in try Row.fetchAll(db, sql: "SELECT at, name, updatedAt FROM sessionLabel WHERE projectId = ?", arguments: [pid]) }) {
                let moment: Double = r["at"], updatedAt: Double = r["updatedAt"]
                let value = "\(updatedAt)"
                if state["pub:session:\(project.uuid):\(moment)"] != value {
                    ops.append(Op(t: "session", at: updatedAt, name: r["name"], moment: moment, project: project.uuid))
                    updates["pub:session:\(project.uuid):\(moment)"] = value
                }
            }
            for rule in try store.db.read({ db in try DeliveryRule.filter(Column("projectId") == pid).fetchAll(db) }) {
                let value = "\(rule.updatedAt)|\(rule.deletedAt != nil)"
                guard state["pub:rule:\(rule.uuid)"] != value else { continue }
                var q = rule.mediaQuery
                let uuids = q.people.compactMap { uuidOf[$0] }
                guard uuids.count == q.people.count else { continue }  // a person without a name can't travel yet
                q.people = []
                q.project = nil
                q.sourceId = nil
                let payload = RulePayload(name: rule.name, folder: rule.folder, layout: rule.layout.rawValue, splitKinds: rule.splitKinds, recipe: rule.recipe,
                                          writeNames: rule.writeNames, enabled: rule.enabled, people: uuids, query: q,
                                          createdAt: rule.createdAt.timeIntervalSince1970)
                ops.append(Op(t: "rule", at: rule.updatedAt, uuid: rule.uuid, rule: payload, deleted: rule.deletedAt != nil, project: project.uuid))
                updates["pub:rule:\(rule.uuid)"] = value
            }
        }
        // The folders the team shares: the sources every Mac works on and the editing Mac's folder. A folder once
        // shared and now this Mac's own says so (teammates drop it); one removed here is in sourceGone.
        let projectUuid = Dictionary(projects.map { ($0.id!, $0.uuid) }, uniquingKeysWith: { a, _ in a })
        for s in try store.db.read({ db in try SourceRecord.filter(Column("shareAt") != nil && Column("removedAt") == nil).fetchAll(db) }) {
            guard let pid = s.projectId, let puuid = projectUuid[pid], let at = s.shareAt else { continue }
            let value = "\(at)|\(s.share.rawValue)|\(s.path)"
            guard state["pub:folder:\(s.uuid)"] != value else { continue }
            var op = Op(t: "folder", at: at, uuid: s.uuid, project: puuid)
            op.folder = FolderPayload(path: s.path, rel: Self.relativePath(of: s.path, to: team.url), share: s.share.rawValue, excluded: s.excluded)
            ops.append(op)
            updates["pub:folder:\(s.uuid)"] = value
        }
        let gone = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT g.uuid, g.at, p.uuid AS project FROM sourceGone g JOIN project p ON p.id = g.projectId WHERE p.teamId = ?", arguments: [teamId])
        }
        for g in gone {
            var op = Op(t: "folder", at: g["at"], uuid: g["uuid"], deleted: true, project: g["project"])
            op.folder = FolderPayload(path: "", rel: nil, share: SourceShare.mac.rawValue)
            ops.append(op)
        }
        // Memory cards and what was copied from them, so a card handed to a teammate's Mac next time is known there.
        for c in try store.db.read({ db in try CardRecord.fetchAll(db) }) {
            let at = c.labelAt ?? c.firstSeenAt.timeIntervalSince1970
            let value = "\(at)|\(c.label ?? "")|\(c.volumeName ?? "")|\(c.camera ?? "")|\(c.cameraSerial ?? "")"
            if state["pub:card:\(c.uuid)"] != value {
                ops.append(Op(t: "card", at: at, uuid: c.uuid, name: c.label,
                              card: CardPayload(volume: c.volumeName, make: c.cameraMake, model: c.cameraModel, serial: c.cameraSerial,
                                                seen: c.firstSeenAt.timeIntervalSince1970)))
                updates["pub:card:\(c.uuid)"] = value
            }
        }
        let fileCursor = Int64(state["pub:cardFiles"] ?? "0") ?? 0
        let files = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, c.uuid, f.relPath, f.size, f.mtime, f.contentKey, f.sha256, f.copiedAt, f.copiedTo FROM cardFile f
                JOIN card c ON c.id = f.cardId WHERE f.device IS NULL AND f.id > ? ORDER BY f.id
                """, arguments: [fileCursor])
        }
        for r in files {
            let copiedAt: Date = r["copiedAt"]
            ops.append(Op(t: "cardFile", at: copiedAt.timeIntervalSince1970, uuid: r["uuid"],
                          file: CardFilePayload(path: r["relPath"], size: r["size"], mtime: r["mtime"], key: r["contentKey"], sha: r["sha256"], to: r["copiedTo"])))
        }
        if let last = files.last { updates["pub:cardFiles"] = String(last["id"] as Int64) }
        // Faces the user moved or rejected here, for the Mac that does the processing (and everyone else).
        let (faceOps, edited) = try faceEditOps()
        ops += faceOps
        // People's pictures picked by hand (by the face's file and position, the same on every Mac).
        for r in try store.db.read({ db in
            try Row.fetchAll(db, sql: """
                SELECT p.uuid, p.coverAt, f.id AS face, m.id AS media, m.path, m.size, m.contentKey,
                       (SELECT COUNT(*) FROM face g WHERE g.mediaId = f.mediaId AND g.id < f.id) AS idx
                FROM person p LEFT JOIN face f ON f.id = p.coverFaceId LEFT JOIN media m ON m.id = f.mediaId
                WHERE p.coverAt IS NOT NULL
                """)
        }) {
            let uuid: String = r["uuid"], at: Double = r["coverAt"]
            guard state["pub:cover:\(uuid)"] != "\(at)" else { continue }
            var op = Op(t: "cover", at: at, uuid: uuid)
            if (r["face"] as Int64?) != nil {
                // A picked face of a file without a content key yet: computed now. Sent without one, it read as
                // "back to automatic" on every other Mac.
                var key: String? = r["contentKey"]
                if key == nil, let path: String = r["path"], let size: Int64 = r["size"] {
                    key = ContentKey.compute(URL(fileURLWithPath: path, isDirectory: false), size: size)
                    if let key { try store.db.write { db in try db.execute(sql: "UPDATE media SET contentKey = ? WHERE id = ?", arguments: [key, r["media"] as Int64]) } }
                }
                guard let key else { continue }  // offline: next pass
                op.key = key
                op.index = r["idx"]
            }
            ops.append(op)
            updates["pub:cover:\(uuid)"] = "\(at)"
        }
        // Pins: who is pinned and who was unpinned, newest wins.
        for r in try store.db.read({ db in try Row.fetchAll(db, sql: "SELECT uuid, pinAt, pinnedAt IS NOT NULL AS pinned FROM person WHERE pinAt IS NOT NULL") }) {
            let uuid: String = r["uuid"], at: Double = r["pinAt"]
            guard state["pub:pin:\(uuid)"] != "\(at)" else { continue }
            ops.append(Op(t: "pin", at: at, uuid: uuid, deleted: !(r["pinned"] as Bool)))
            updates["pub:pin:\(uuid)"] = "\(at)"
        }
        // Notes on who people are, newest wins.
        for r in try store.db.read({ db in try Row.fetchAll(db, sql: "SELECT uuid, bio, bioAt FROM person WHERE bioAt IS NOT NULL") }) {
            let uuid: String = r["uuid"], at: Double = r["bioAt"]
            guard state["pub:bio:\(uuid)"] != "\(at)" else { continue }
            ops.append(Op(t: "bio", at: at, uuid: uuid, name: r["bio"]))
            updates["pub:bio:\(uuid)"] = "\(at)"
        }
        // Saved watermarks, with their logo and banner files.
        let (wmOps, wmUpdates) = try watermarkOps(team, state: state)
        ops += wmOps
        updates.merge(wmUpdates) { _, b in b }
        // Saved looks.
        let (lookOps, lookUpdates) = try lookOps(state: state)
        ops += lookOps
        updates.merge(lookUpdates) { _, b in b }
        // Tags on people.
        let (tagOps, tagUpdates) = try tagOps(state: state)
        ops += tagOps
        updates.merge(tagUpdates) { _, b in b }
        // Lists of people and who is on them.
        let (listOps, listUpdates) = try listOps(teamId: teamId, state: state)
        ops += listOps
        updates.merge(listUpdates) { _, b in b }
        var wrote = false
        if !ops.isEmpty {
            try append(ops, to: Self.devicesURL(team.url).appendingPathComponent("\(deviceId).jsonl"))
            try setState(teamId, updates)
            for (k, v) in updates { state[k] = v }
            wrote = true
        }
        if !gone.isEmpty {
            let uuids = gone.map { $0["uuid"] as String }
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM sourceGone WHERE uuid IN (\(uuids.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(uuids))
                // Removals of folders in projects no team has can't go anywhere.
                try db.execute(sql: "DELETE FROM sourceGone WHERE projectId IS NULL OR projectId NOT IN (SELECT id FROM project WHERE teamId IS NOT NULL)")
            }
        }
        if !edited.isEmpty {
            try store.db.write { db in try db.execute(sql: "DELETE FROM faceEditPublish WHERE faceId IN (\(edited.map(String.init).joined(separator: ",")))") }
        }
        return wrote
    }

    func append(_ ops: [Op], to url: URL) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for op in ops {
            data += try encoder.encode(op)
            data += Data("\n".utf8)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        try Self.appendLines(data, to: h)
    }

    /// Appends whole lines. A write cut short (the share went away mid-append) leaves a half line; the next lines
    /// glued to it made one unreadable line that every reader dropped, so a half line is ended first (the change
    /// in it is written again, as its state wasn't saved). `h` is open for reading and writing.
    static func appendLines(_ data: Data, to h: FileHandle) throws {
        let end = try h.seekToEnd()
        if end > 0 {
            try h.seek(toOffset: end - 1)
            if try h.read(upToCount: 1) != Data("\n".utf8) {
                try h.seekToEnd()
                try h.write(contentsOf: Data("\n".utf8))
            }
            try h.seekToEnd()
        }
        try h.write(contentsOf: data)
    }

    /// Rewrites `summaries/<device>.json` when a relevant person's faces changed. Checked every pass (a cheap
    /// count per person); while faces keep arriving it is written at most once a minute, and at once after the
    /// user changed something or a Known-People photo was enrolled.
    func publishSummaries(_ team: TeamRecord, people: [(id: Int64, uuid: String, name: String, nameAt: Double?)], state: [String: String], forced: Bool) throws -> Bool {
        let teamId = team.id!
        guard !people.isEmpty else { return false }
        // Counting every named person's faces is an index scan: not every pass unless something just changed.
        let checked = lock.withLock { summariesChecked[teamId] }
        guard forced || checked == nil || Date().timeIntervalSince(checked!) >= Self.summaryCheckInterval else { return false }
        lock.withLock { summariesChecked[teamId] = Date() }
        let ids = people.map { String($0.id) }.joined(separator: ",")
        let signatures = Dictionary(uniqueKeysWithValues: try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT personId, COUNT(*) AS n, MAX(id) AS last FROM face WHERE personId IN (\(ids)) GROUP BY personId")
                .map { ($0["personId"] as Int64, "\($0["n"] as Int)|\($0["last"] as Int64)") }
        })
        let idOf = Dictionary(people.map { ($0.uuid, $0.id) }, uniquingKeysWith: { a, _ in a })
        // What the file would hold: skip the write when nothing changed since the last one.
        let full = people.map(\.uuid).sorted().map { k in "\(k):\(idOf[k].flatMap { signatures[$0] } ?? "")" }.joined(separator: ",")
        if state["pub:summaries"] == full { return false }
        let last = lock.withLock { summariesWritten[teamId] }
        guard forced || last == nil || Date().timeIntervalSince(last!) >= Self.summaryInterval else { return false }
        lock.withLock { summariesWritten[teamId] = Date() }
        var out: [String: Summary] = [:]
        for p in people {
            guard let sig = signatures[p.id] else { continue }
            let cached = lock.withLock { centroids[p.id] }
            let entry: (signature: String, centroid: [Float], count: Int, exemplars: [[Float]])
            if let cached, cached.signature == sig { entry = cached } else {
                guard let s = engine.localSummary(p.id) else { continue }
                entry = (sig, s.centroid, s.count, engine.localExemplars(p.id))
                lock.withLock { centroids[p.id] = entry }
            }
            out[p.uuid] = Summary(c: Vector.encode(entry.centroid).base64EncodedString(), n: entry.count,
                                  e: entry.exemplars.isEmpty ? nil : Vector.encodeHalfRows(entry.exemplars).base64EncodedString())
        }
        let summaries = Summaries(model: Self.model, device: deviceName, people: out)
        let url = Self.summariesURL(team.url).appendingPathComponent("\(deviceId).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try JSONEncoder().encode(summaries).write(to: tmp)
        guard Darwin.rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
        try setState(teamId, ["pub:summaries": full])
        return true
    }

    // MARK: - Reading teammates

    func devices(_ team: TeamRecord) -> [Device] {
        let dir = Self.devicesURL(team.url)
        let names = (try? state(team.id!)) ?? [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [Device] = []
        for f in files where f.pathExtension == "jsonl" {
            let id = f.deletingPathExtension().lastPathComponent
            let seen = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let mine = id == deviceId
            out.append(Device(id: id, name: mine ? deviceName : names["dev:\(id)"] ?? "A teammate's Mac", lastSeen: seen, isThisMac: mine))
        }
        return out.sorted { ($0.isThisMac ? 0 : 1, $0.name) < ($1.isThisMac ? 0 : 1, $1.name) }
    }

    /// Entry kinds added after the first team release, with the reader version that knows them. An older version
    /// skips an entry it doesn't know and still moves its place in the log past it, so the entry was lost on that
    /// Mac for good (0.8.3 did this to the first team and edited folders). When a newer version first reads a
    /// team, it goes over what it had already read once more, for just the kinds it learnt since. A new kind of
    /// entry is added here with the next version number.
    static let lateKinds: [(version: Int, kinds: Set<String>)] = [(2, ["folder"]), (3, ["pin"]), (4, ["watermark", "list", "listMember"]), (5, ["look"]), (6, ["bio", "tag"])]
    static var readerVersion: Int { lateKinds.map(\.version).max() ?? 1 }

    /// Reads what this Mac already read of each teammate's log again, applying only the kinds learnt since
    /// reader version `since`. Returns whether anything was applied or deferred.
    func replayLateKinds(_ team: TeamRecord, since: Int, state: [String: String],
                         affected: inout Set<Int64>, remoteChanged: inout Set<Int64>) throws -> Bool {
        let kinds = Self.lateKinds.filter { $0.version > since }.reduce(into: Set<String>()) { $0.formUnion($1.kinds) }
        guard !kinds.isEmpty else { return false }
        let teamId = team.id!
        var any = false
        let logs = (try? FileManager.default.contentsOfDirectory(at: Self.devicesURL(team.url), includingPropertiesForKeys: nil)) ?? []
        for f in logs where f.pathExtension == "jsonl" {
            let id = f.deletingPathExtension().lastPathComponent
            let cursor = Int(state["cursor:\(id)"] ?? "0") ?? 0
            guard id != deviceId, cursor > 0 else { continue }
            let h = try FileHandle(forReadingFrom: f)
            defer { try? h.close() }
            let data = try h.read(upToCount: cursor) ?? Data()
            let decoder = JSONDecoder()
            // A cheap look for the kind's name first: most lines are other kinds.
            let ops = data.split(separator: 0x0A).compactMap { line -> Op? in
                guard kinds.contains(where: { line.range(of: Data("\"\($0)\"".utf8)) != nil }) else { return nil }
                guard let op = try? decoder.decode(Op.self, from: line), kinds.contains(op.t) else { return nil }
                return op
            }
            guard !ops.isEmpty else { continue }
            try store.db.write { db in
                for op in ops {
                    switch try apply(op, team: team, device: id, db: db) {
                    case .applied(let people, let remote):
                        affected.formUnion(people); remoteChanged.formUnion(remote); any = true
                    case .deferred:
                        var kept = op
                        kept.device = kept.device ?? id
                        try db.execute(sql: "INSERT INTO syncDeferred (teamId, op) VALUES (?, ?)",
                                       arguments: [teamId, String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)])
                        any = true
                    case .ignored: break
                    }
                }
            }
        }
        return any
    }

    func pull(_ team: TeamRecord) throws -> Bool {
        let teamId = team.id!
        var changed = false
        var affected: Set<Int64> = []
        var remoteChanged: Set<Int64> = []
        let fm = FileManager.default
        let state = try state(teamId)
        // A newer version than the one that read this team so far: entries it skipped then are read now.
        let reader = Int(state["reader"] ?? "1") ?? 1
        if reader < Self.readerVersion {
            if try replayLateKinds(team, since: reader, state: state, affected: &affected, remoteChanged: &remoteChanged) { changed = true }
            try store.db.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)",
                               arguments: [teamId, "reader", String(Self.readerVersion)])
            }
        }
        let logs = (try? fm.contentsOfDirectory(at: Self.devicesURL(team.url), includingPropertiesForKeys: nil)) ?? []
        for f in logs where f.pathExtension == "jsonl" {
            let id = f.deletingPathExtension().lastPathComponent
            guard id != deviceId else { continue }
            let cursor = Int(state["cursor:\(id)"] ?? "0") ?? 0
            let h = try FileHandle(forReadingFrom: f)
            defer { try? h.close() }
            guard try Self.size(of: h) > cursor else { continue }
            try h.seek(toOffset: UInt64(cursor))
            let data = try h.readToEnd() ?? Data()
            // Only whole lines: a teammate's Mac may be in the middle of appending one.
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let complete = data[data.startIndex...lastNewline]
            let decoder = JSONDecoder()
            var ops: [Op] = []
            for line in complete.split(separator: 0x0A) where !line.isEmpty {
                if let op = try? decoder.decode(Op.self, from: line) { ops.append(op) }
            }
            var updates: [String: String] = [:]
            // Short transactions (a teammate's whole log on joining can be thousands of changes), the cursor
            // written last: a card copy landing files meanwhile never waits long for the writer.
            for chunk in stride(from: 0, to: ops.count, by: Self.opChunk).map({ ops[$0..<min($0 + Self.opChunk, ops.count)] }) {
                try store.db.write { db in
                    for op in chunk {
                        if op.t == "device", let name = op.name { updates["dev:\(id)"] = name; continue }
                        switch try apply(op, team: team, device: id, db: db) {
                        case .applied(let people, let remote):
                            affected.formUnion(people)
                            remoteChanged.formUnion(remote)
                        case .deferred:
                            // Whose change it was stays with it (a shared folder remembers the Mac that shared it).
                            var kept = op
                            kept.device = kept.device ?? id
                            try db.execute(sql: "INSERT INTO syncDeferred (teamId, op) VALUES (?, ?)",
                                           arguments: [teamId, String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)])
                        case .ignored: break
                        }
                    }
                }
            }
            updates["cursor:\(id)"] = String(cursor + complete.count)
            try store.db.write { db in
                for (k, v) in updates {
                    try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [teamId, k, v])
                }
            }
            changed = true
        }
        // Changes that waited for a person to become known.
        let deferred = try store.db.read { db in try Row.fetchAll(db, sql: "SELECT id, op FROM syncDeferred WHERE teamId = ? ORDER BY id", arguments: [teamId]) }
        if !deferred.isEmpty {
            try store.db.write { db in
                for r in deferred {
                    guard let op = try? JSONDecoder().decode(Op.self, from: Data((r["op"] as String).utf8)) else {
                        try db.execute(sql: "DELETE FROM syncDeferred WHERE id = ?", arguments: [r["id"] as Int64]); continue
                    }
                    switch try apply(op, team: team, device: op.device ?? "", db: db) {
                    case .applied(let people, let remote):
                        affected.formUnion(people); remoteChanged.formUnion(remote); changed = true
                        try db.execute(sql: "DELETE FROM syncDeferred WHERE id = ?", arguments: [r["id"] as Int64])
                    case .ignored:
                        try db.execute(sql: "DELETE FROM syncDeferred WHERE id = ?", arguments: [r["id"] as Int64])
                    case .deferred: break
                    }
                }
            }
        }
        // Teammates' edits (faces rejected or moved there) teach these people the same as edits made here.
        if !affected.isEmpty { engine.corrected(from: affected, to: affected) }
        if !remoteChanged.isEmpty { engine.remoteChanged(remoteChanged) }
        if lock.withLock({ let c = sourcesChanged; sourcesChanged = false; return c }) { onSourcesChanged?() }
        return changed
    }

    /// The size of a teammate's file as the share has it now. Not from a folder listing: macOS can keep an SMB
    /// share's listing for many seconds, and a teammate's change sat unseen behind the old size.
    static func size(of h: FileHandle) throws -> Int {
        let end = try h.seekToEnd()
        return Int(end)
    }

    /// Teammates' summaries of the people they have faces of: whole files, re-read when they change.
    func pullSummaries(_ team: TeamRecord) throws -> Bool {
        let teamId = team.id!
        var changed = false
        var remoteChanged: Set<Int64> = []
        let fm = FileManager.default
        let state = try state(teamId)
        let sums = (try? fm.contentsOfDirectory(at: Self.summariesURL(team.url), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        for f in sums where f.pathExtension == "json" {
            let id = f.deletingPathExtension().lastPathComponent
            guard id != deviceId else { continue }
            let rv = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let stamp = "\(rv?.fileSize ?? 0)|\(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            guard state["sum:\(id)"] != stamp else { continue }
            guard let data = try? Data(contentsOf: f), let s = try? JSONDecoder().decode(Summaries.self, from: data) else { continue }
            try store.db.write { db in
                let before = Set(try Int64.fetchAll(db, sql: "SELECT personId FROM personRemote WHERE teamId = ? AND deviceId = ?", arguments: [teamId, id]))
                try db.execute(sql: "DELETE FROM personRemote WHERE teamId = ? AND deviceId = ?", arguments: [teamId, id])
                remoteChanged.formUnion(before)
                if s.model == Self.model {
                    for (uuid, summary) in s.people {
                        var op = Op(t: "summary", at: 0, uuid: uuid, device: id, centroid: summary.c, count: summary.n)
                        op.exemplars = summary.e
                        switch try apply(op, team: team, device: id, db: db) {
                        case .applied(_, let remote): remoteChanged.formUnion(remote)
                        case .deferred:
                            try db.execute(sql: "INSERT INTO syncDeferred (teamId, op) VALUES (?, ?)",
                                           arguments: [teamId, String(decoding: try JSONEncoder().encode(op), as: UTF8.self)])
                        case .ignored: break
                        }
                    }
                }
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [teamId, "sum:\(id)", stamp])
            }
            changed = true
        }
        if !remoteChanged.isEmpty { engine.remoteChanged(remoteChanged) }
        return changed
    }

    // MARK: - Shared folders

    /// `path` relative to the team folder ("../Events/Gala/Cards"), when both sit on the same volume; nil
    /// otherwise. Each Mac may mount the share under another name, but the two folders keep their distance.
    static func relativePath(of path: String, to teamFolder: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), fm.fileExists(atPath: teamFolder.path) else { return nil }
        guard let a = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let b = try? teamFolder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier, a.isEqual(b) else { return nil }
        let from = canonicalPath(teamFolder).split(separator: "/").map(String.init)
        let to = path.split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        guard common > 0 else { return nil }  // nothing in common but the root: not the same share
        let rel = Array(repeating: "..", count: from.count - common) + to[common...]
        return rel.isEmpty ? "." : rel.joined(separator: "/")
    }

    /// Where a teammate's shared folder is on this Mac: at the same distance from the team folder when that exists,
    /// else at the path the teammate has, else (offline for now) whichever of the two is likelier.
    static func resolvePath(_ f: FolderPayload, team: TeamRecord) -> String {
        let fm = FileManager.default
        let fromRel = f.rel.map { canonicalPath(team.url.appendingPathComponent($0).standardizedFileURL) }
        if let fromRel, fm.fileExists(atPath: fromRel) { return fromRel }
        if fm.fileExists(atPath: f.path) { return canonicalPath(URL(fileURLWithPath: f.path, isDirectory: true)) }
        return fromRel ?? f.path
    }

    /// A teammate shared a folder, changed what it is, or took it out of the team.
    func applyFolderOp(_ op: Op, team: TeamRecord, device: String, db: Database) throws -> Outcome {
        guard let uuid = op.uuid, let f = op.folder else { return .ignored }
        let projectId: Int64
        switch try Self.resolveProject(op.project, team: team, db: db) {
        case .found(let id): projectId = id
        case .unknown: return .deferred
        case .gone: return .ignored
        }
        let share = op.deleted == true ? SourceShare.mac : SourceShare(rawValue: f.share) ?? .mac
        let now = op.at
        if let s = try SourceRecord.filter(Column("uuid") == uuid).fetchOne(db) {
            guard now > (s.shareAt ?? 0), s.removedAt == nil else { return .ignored }
            if share == .mac {
                // Out of the team. A folder this Mac added itself stays, as its own; one that came from the team goes.
                if s.fromDevice != nil {
                    try db.execute(sql: "UPDATE source SET share = 'mac', shareAt = ?, removedAt = ? WHERE id = ?", arguments: [now, now, s.id])
                } else {
                    try db.execute(sql: "UPDATE source SET share = 'mac', shareAt = ? WHERE id = ?", arguments: [now, s.id])
                }
                lock.withLock { sourcesChanged = true }
                return .applied(people: [], remote: [])
            }
            try db.execute(sql: "UPDATE source SET share = ?, shareAt = ?, projectId = ? WHERE id = ?", arguments: [share.rawValue, now, projectId, s.id])
            try Self.applyExcluded(f, to: s.id!, db: db)
            // The teammate's folder moved: follow when this Mac's copy of the path no longer works.
            if !FileManager.default.fileExists(atPath: s.path) {
                let path = Self.resolvePath(f, team: team)
                if path != s.path, FileManager.default.fileExists(atPath: path), !(try Self.overlaps(path, excluding: s.id!, db: db)) {
                    try LibraryService.relinkPaths(s.id!, from: s.path, to: path, db: db)
                }
            }
            lock.withLock { sourcesChanged = true }
            return .applied(people: [], remote: [])
        }
        guard share != .mac else { return .ignored }
        let path = Self.resolvePath(f, team: team)
        if let same = try SourceRecord.filter(Column("path") == path).fetchOne(db) {
            // This Mac already has that folder: it becomes the team's. Two Macs that shared it independently keep
            // the smaller id, so every Mac ends up with the same one.
            guard same.kind == .media, same.share == .mac || uuid < same.uuid else { return .ignored }
            try db.execute(sql: "UPDATE source SET uuid = ?, share = ?, shareAt = ?, projectId = ? WHERE id = ?",
                           arguments: [uuid, share.rawValue, now, projectId, same.id])
            try Self.applyExcluded(f, to: same.id!, db: db)
            lock.withLock { sourcesChanged = true }
            return .applied(people: [], remote: [])
        }
        // Inside or around a folder this Mac has: wait for the user to sort that out (Remove or Locate).
        if try Self.overlaps(path, excluding: nil, db: db) { return .deferred }
        var s = SourceRecord(path: path, kind: .media, projectId: projectId, share: share, uuid: uuid)
        s.shareAt = now
        s.fromDevice = device
        s.excluded = f.excluded ?? []
        try s.insert(db)
        lock.withLock { sourcesChanged = true }
        return .applied(people: [], remote: [])
    }

    /// The folder's watcher takes out what is in a newly excluded subfolder, and finds what is in one brought back.
    static func applyExcluded(_ f: FolderPayload, to id: Int64, db: Database) throws {
        guard let excluded = f.excluded, var s = try SourceRecord.fetchOne(db, key: id), s.excluded != excluded else { return }
        s.excluded = excluded
        try s.update(db)
    }

    static func overlaps(_ path: String, excluding id: Int64?, db: Database) throws -> Bool {
        for other in try String.fetchAll(db, sql: "SELECT path FROM source WHERE id IS NOT ?", arguments: [id]) {
            if other == path || path.hasPrefix(other + "/") || other.hasPrefix(path + "/") { return true }
        }
        return false
    }

    // MARK: - Applying a teammate's change

    enum Outcome {
        /// People whose faces moved (merges) and people whose teammates' summaries changed.
        case applied(people: Set<Int64>, remote: Set<Int64>)
        case deferred
        case ignored
    }

    /// The local person with this stable id, following merges it was part of.
    static func resolve(_ uuid: String, db: Database) throws -> Int64? {
        var u = uuid
        for _ in 0..<16 {
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE uuid = ?", arguments: [u]) { return id }
            guard let next = try String.fetchOne(db, sql: "SELECT intoUuid FROM personMerge WHERE fromUuid = ?", arguments: [u]) else { return nil }
            u = next
        }
        return nil
    }

    /// The local project a change belongs to: by stable id (older logs: the team's first project), nil when not
    /// known yet. `.gone` when this Mac deleted it.
    enum ProjectLookup { case found(Int64), unknown, gone }
    static func resolveProject(_ uuid: String?, team: TeamRecord, db: Database) throws -> ProjectLookup {
        let u = uuid ?? legacyProjectUuid(team.uuid)
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM project WHERE uuid = ? AND teamId = ?", arguments: [u, team.id]) { return .found(id) }
        if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE teamId = ? AND key = ?", arguments: [team.id, "gone:project:\(u)"]) ?? 0 > 0 { return .gone }
        return .unknown
    }

    func apply(_ op: Op, team: TeamRecord, device: String, db: Database) throws -> Outcome {
        switch op.t {
        case "project":
            guard let uuid = op.uuid, let name = op.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return .ignored }
            if let p = try ProjectRecord.filter(Column("uuid") == uuid).fetchOne(db) {
                guard p.name != name, op.at > p.updatedAt else { return .ignored }
                try db.execute(sql: "UPDATE project SET name = ?, updatedAt = ?, teamId = ? WHERE id = ?", arguments: [name, op.at, team.id, p.id])
                return .applied(people: [], remote: [])
            }
            if case .gone = try Self.resolveProject(uuid, team: team, db: db) { return .ignored }
            var p = ProjectRecord(name: name, uuid: uuid, teamId: team.id)
            p.updatedAt = op.at
            try p.insert(db)
            return .applied(people: [], remote: [])

        case "person":
            guard let uuid = op.uuid else { return .ignored }
            // No name: the teammate took the name away.
            let name = op.name.map(PersonNames.clean).flatMap { $0.isEmpty ? nil : $0 }
            if let pid = try Self.resolve(uuid, db: db) {
                let row = try Row.fetchOne(db, sql: "SELECT name, nameAt FROM person WHERE id = ?", arguments: [pid])
                let current: String? = row?["name"], currentAt: Double = (row?["nameAt"] as Double?) ?? 0
                guard current != name else { return .ignored }
                // A person never named here (a group from the processing Mac's records) takes the name whatever its
                // time: names given before names had a time are sent with 0.
                guard (current == nil && currentAt == 0) || op.at > currentAt else { return .ignored }
                guard let name else {
                    try db.execute(sql: "UPDATE person SET name = NULL, nameAt = ? WHERE id = ?", arguments: [op.at, pid])
                    return .applied(people: [], remote: [])
                }
                return .applied(people: try Self.setName(pid, name, at: op.at, db: db), remote: [])
            }
            guard let name else { return .ignored }
            if let existing = try PersonNames.find(name, db: db) {
                // Both Macs named someone independently: the smaller id becomes the one everybody uses.
                let theirs: String = try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [existing]) ?? ""
                let now = Date().timeIntervalSince1970
                if uuid < theirs {
                    try db.execute(sql: "UPDATE person SET uuid = ? WHERE id = ?", arguments: [uuid, existing])
                    try db.execute(sql: "INSERT OR REPLACE INTO personMerge (fromUuid, intoUuid, at) VALUES (?, ?, ?)", arguments: [theirs, uuid, now])
                    try db.execute(sql: "UPDATE personMerge SET intoUuid = ? WHERE intoUuid = ?", arguments: [uuid, theirs])
                } else {
                    try db.execute(sql: "INSERT OR REPLACE INTO personMerge (fromUuid, intoUuid, at) VALUES (?, ?, ?)", arguments: [uuid, theirs, now])
                }
                return .applied(people: [existing], remote: [])
            }
            var p = PersonRecord(name: name, uuid: uuid)
            p.nameAt = op.at
            try p.insert(db)
            return .applied(people: [], remote: [])

        case "merge":
            guard let from = op.uuid, let into = op.into, from != into else { return .ignored }
            let f = try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE uuid = ?", arguments: [from])
            let i = try Self.resolve(into, db: db)
            if let f, let i, f != i {
                try PersonNames.merge([f], into: i, db: db)
                return .applied(people: [f, i], remote: [])
            }
            if let f, i == nil {
                // Only the merged person is known here: it simply takes the surviving id.
                try db.execute(sql: "UPDATE person SET uuid = ? WHERE id = ?", arguments: [into, f])
            }
            if let f, let i, f == i {
                // The same two people merged the other way round here: each Mac kept its own survivor, with its
                // own name. Both settle on the smaller id (see settleOppositeMerge).
                return try settleOppositeMerge(f, mine: from, theirs: into, team: team, db: db)
            }
            if f == nil, let i, let mine = try Self.resolve(from, db: db), mine != i {
                // `from` went into someone else here: one person to the teammate, two here. The two become one
                // unless both carry a name, each its own (the users told them apart).
                return try Self.reconcileSurvivors(mine, i, db: db)
            }
            try db.execute(sql: "INSERT OR IGNORE INTO personMerge (fromUuid, intoUuid, at) VALUES (?, ?, ?)", arguments: [from, into, op.at])
            return .applied(people: [], remote: [])

        case "session":
            guard let moment = op.moment, let name = op.name else { return .ignored }
            let projectId: Int64
            switch try Self.resolveProject(op.project, team: team, db: db) {
            case .found(let id): projectId = id
            case .unknown: return .deferred
            case .gone: return .ignored
            }
            return try EventSessions.setName(db, project: projectId, at: moment, name: name, updatedAt: op.at)
                ? .applied(people: [], remote: []) : .ignored

        case "rule":
            guard let uuid = op.uuid, let payload = op.rule else { return .ignored }
            let projectId: Int64
            switch try Self.resolveProject(op.project, team: team, db: db) {
            case .found(let id): projectId = id
            case .unknown: return .deferred
            case .gone: return .ignored
            }
            var ids: [Int64] = []
            for u in payload.people {
                guard let id = try Self.resolve(u, db: db) else { return .deferred }
                ids.append(id)
            }
            let existing = try DeliveryRule.filter(Column("uuid") == uuid).fetchOne(db)
            if let e = existing, op.at <= e.updatedAt { return .ignored }
            if existing == nil && op.deleted == true { return .ignored }
            var q = payload.query
            q.people = ids
            q.project = projectId
            var rule = existing ?? DeliveryRule(name: payload.name, query: q, folder: payload.folder, layout: .person, recipe: nil,
                                                writeNames: payload.writeNames, projectId: projectId)
            rule.uuid = uuid
            rule.name = payload.name
            rule.projectId = projectId
            rule.setQuery(q)
            rule.folder = payload.folder
            rule.layout = DeliveryRule.Layout(rawValue: payload.layout) ?? .person
            rule.splitKinds = payload.splitKinds ?? false
            rule.recipe = payload.recipe
            rule.writeNames = payload.writeNames
            rule.enabled = payload.enabled && op.deleted != true
            rule.updatedAt = op.at
            rule.deletedAt = op.deleted == true ? op.at : nil
            rule.createdAt = Date(timeIntervalSince1970: payload.createdAt)
            if existing == nil {
                try rule.insert(db)
            } else {
                try rule.update(db)
                if rule.deletedAt != nil { try db.execute(sql: "DELETE FROM delivery WHERE ruleId = ?", arguments: [rule.id]) }
            }
            return .applied(people: [], remote: [])

        case "card":
            guard let uuid = op.uuid, let p = op.card else { return .ignored }
            if let c = try CardRecord.filter(Column("uuid") == uuid).fetchOne(db) {
                var changed = false
                var card = c
                if card.volumeName == nil, let v = p.volume { card.volumeName = v; changed = true }
                if card.cameraMake == nil, let v = p.make { card.cameraMake = v; changed = true }
                if card.cameraModel == nil, let v = p.model { card.cameraModel = v; changed = true }
                if card.cameraSerial == nil, let v = p.serial { card.cameraSerial = v; changed = true }
                if op.at > (card.labelAt ?? 0), op.name != card.label { card.label = op.name; card.labelAt = op.at; changed = true }
                guard changed else { return .ignored }
                try card.update(db)
                return .applied(people: [], remote: [])
            }
            var card = CardRecord(uuid: uuid, label: op.name, volumeName: p.volume, cameraMake: p.make, cameraModel: p.model,
                                  cameraSerial: p.serial, firstSeenAt: Date(timeIntervalSince1970: p.seen))
            card.labelAt = op.name == nil ? nil : op.at
            try card.insert(db)
            return .applied(people: [], remote: [])

        case "cardFile":
            guard let uuid = op.uuid, let f = op.file else { return .ignored }
            let cardId: Int64
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM card WHERE uuid = ?", arguments: [uuid]) {
                cardId = id
            } else {
                var card = CardRecord(uuid: uuid, firstSeenAt: Date(timeIntervalSince1970: op.at))
                try card.insert(db)
                cardId = card.id!
            }
            // A copy made here of the same file keeps its own entry (and stays published).
            try db.execute(sql: """
                INSERT INTO cardFile (cardId, relPath, size, mtime, contentKey, sha256, copiedAt, copiedTo, device) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cardId, relPath, contentKey) DO NOTHING
                """, arguments: [cardId, f.path, f.size, f.mtime, f.key, f.sha, Date(timeIntervalSince1970: op.at), f.to, device])
            return .applied(people: [], remote: [])

        case "face":
            return try applyFaceOp(op, team: team, db: db)

        case "folder":
            return try applyFolderOp(op, team: team, device: device, db: db)

        case "cover":
            // A person's picture picked on another Mac: the same face here, when this Mac has that file.
            guard let uuid = op.uuid, let pid = try Self.resolve(uuid, db: db) else { return .deferred }
            let current = try Double?.fetchOne(db, sql: "SELECT coverAt FROM person WHERE id = ?", arguments: [pid]) ?? nil
            guard op.at > (current ?? 0) else { return .ignored }
            guard let key = op.key, let index = op.index else {
                try db.execute(sql: "UPDATE person SET coverFaceId = NULL, coverAt = ? WHERE id = ?", arguments: [op.at, pid])
                return .applied(people: [], remote: [])
            }
            guard let faceId = try Int64.fetchOne(db, sql: """
                SELECT f.id FROM face f JOIN media m ON m.id = f.mediaId WHERE m.contentKey = ? AND m.duplicateOf IS NULL
                  AND (SELECT COUNT(*) FROM face g WHERE g.mediaId = f.mediaId AND g.id < f.id) = ? LIMIT 1
                """, arguments: [key, index]) else { return .deferred }
            try db.execute(sql: "UPDATE person SET coverFaceId = ?, coverAt = ? WHERE id = ?", arguments: [faceId, op.at, pid])
            return .applied(people: [], remote: [])

        case "watermark":
            return try applyWatermarkOp(op, team: team, db: db)

        case "look":
            return try applyLookOp(op, team: team, db: db)

        case "list":
            return try applyListOp(op, team: team, db: db)

        case "listMember":
            return try applyListMemberOp(op, team: team, db: db)

        case "tag":
            return try applyTagOp(op, team: team, db: db)

        case "pin":
            guard let uuid = op.uuid else { return .ignored }
            guard let pid = try Self.resolve(uuid, db: db) else { return .deferred }
            let current = try Double?.fetchOne(db, sql: "SELECT pinAt FROM person WHERE id = ?", arguments: [pid]) ?? nil
            guard op.at > (current ?? 0) else { return .ignored }
            if op.deleted == true {
                try db.execute(sql: "UPDATE person SET pinnedAt = NULL, pinAt = ? WHERE id = ?", arguments: [op.at, pid])
            } else {
                try db.execute(sql: "UPDATE person SET pinnedAt = COALESCE(pinnedAt, ?), pinAt = ? WHERE id = ?", arguments: [op.at, op.at, pid])
            }
            // Known here now: not sent back as this Mac's own change.
            let local: String = try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [pid]) ?? uuid
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [team.id, "pub:pin:\(local)", "\(op.at)"])
            return .applied(people: [], remote: [])

        case "bio":
            guard let uuid = op.uuid else { return .ignored }
            guard let pid = try Self.resolve(uuid, db: db) else { return .deferred }
            let current = try Double?.fetchOne(db, sql: "SELECT bioAt FROM person WHERE id = ?", arguments: [pid]) ?? nil
            guard op.at > (current ?? 0) else { return .ignored }
            try db.execute(sql: "UPDATE person SET bio = ?, bioAt = ? WHERE id = ?", arguments: [op.name, op.at, pid])
            // Known here now: not sent back as this Mac's own change.
            let local: String = try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [pid]) ?? uuid
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [team.id, "pub:bio:\(local)", "\(op.at)"])
            return .applied(people: [], remote: [])

        case "summary":
            guard let uuid = op.uuid, let c = op.centroid, let data = Data(base64Encoded: c), let n = op.count else { return .ignored }
            guard let pid = try Self.resolve(uuid, db: db) else { return .deferred }
            try db.execute(sql: "INSERT OR REPLACE INTO personRemote (personId, teamId, deviceId, centroid, count, exemplars) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [pid, team.id, device, data, n, op.exemplars.flatMap { Data(base64Encoded: $0) }])
            return .applied(people: [], remote: [pid])

        default:
            return .ignored
        }
    }

    /// A merge made here as `theirs` → `mine` while a teammate made it `mine` → `theirs`: both Macs keep the person
    /// with the smaller id, the same one everywhere. When that is this Mac's survivor, its name, pin and picture
    /// are published again (the teammate's copy is put back to "unnamed" so they take them); else this Mac's
    /// survivor takes the other id and waits for the teammate's name.
    func settleOppositeMerge(_ pid: Int64, mine: String, theirs: String, team: TeamRecord, db: Database) throws -> Outcome {
        if mine < theirs {
            for key in ["pub:person:\(mine)", "pub:pin:\(mine)", "pub:cover:\(mine)"] {
                try db.execute(sql: "DELETE FROM syncState WHERE teamId = ? AND key = ?", arguments: [team.id, key])
            }
            // With a fresh time, so the teammate's copy (put back to 0) takes it even if this name had none.
            try db.execute(sql: "UPDATE person SET nameAt = \(SyncIds.stampSQL("nameAt")) WHERE id = ? AND name IS NOT NULL",
                           arguments: [Date().timeIntervalSince1970, pid])
            try db.execute(sql: "INSERT OR REPLACE INTO personMerge (fromUuid, intoUuid, at) VALUES (?, ?, ?)",
                           arguments: [theirs, mine, Date().timeIntervalSince1970])
            return .applied(people: [], remote: [])
        }
        try db.execute(sql: "UPDATE person SET uuid = ?, nameAt = 0 WHERE id = ?", arguments: [theirs, pid])
        try db.execute(sql: "DELETE FROM personMerge WHERE fromUuid = ?", arguments: [theirs])
        try db.execute(sql: "INSERT OR REPLACE INTO personMerge (fromUuid, intoUuid, at) VALUES (?, ?, ?)",
                       arguments: [mine, theirs, Date().timeIntervalSince1970])
        try db.execute(sql: "UPDATE personMerge SET intoUuid = ? WHERE intoUuid = ?", arguments: [theirs, mine])
        return .applied(people: [pid], remote: [])
    }

    /// Two people here that a teammate's merge says are one. Two different names stay two people (each user's
    /// call); otherwise the named one survives, else the one with the smaller id, so every Mac keeps the same.
    static func reconcileSurvivors(_ a: Int64, _ b: Int64, db: Database) throws -> Outcome {
        guard let ra = try Row.fetchOne(db, sql: "SELECT uuid, name FROM person WHERE id = ?", arguments: [a]),
              let rb = try Row.fetchOne(db, sql: "SELECT uuid, name FROM person WHERE id = ?", arguments: [b]) else { return .ignored }
        let na: String? = ra["name"], nb: String? = rb["name"]
        if let na, let nb, PersonNames.key(na) != PersonNames.key(nb) { return .ignored }
        let ua: String = ra["uuid"], ub: String = rb["uuid"]
        let into: Int64
        if na != nil && nb == nil { into = a } else if nb != nil && na == nil { into = b } else { into = ua < ub ? a : b }
        try PersonNames.merge([into == a ? b : a], into: into, db: db)
        return .applied(people: [a, b], remote: [])
    }

    /// Names a person from a teammate's change. A name another person already has merges the two, keeping the
    /// one with the smaller stable id so every Mac keeps the same one.
    static func setName(_ pid: Int64, _ name: String, at: Double, db: Database) throws -> Set<Int64> {
        if let other = try PersonNames.find(name, excluding: pid, db: db) {
            let mine: String = try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [pid]) ?? ""
            let theirs: String = try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [other]) ?? ""
            let survivor = mine < theirs ? pid : other
            let loser = survivor == pid ? other : pid
            try PersonNames.merge([loser], into: survivor, db: db)
            try db.execute(sql: "UPDATE person SET name = ?, nameAt = ? WHERE id = ?", arguments: [name, at, survivor])
            return [pid, other]
        }
        try db.execute(sql: "UPDATE person SET name = ?, nameAt = ? WHERE id = ?", arguments: [name, at, pid])
        return []
    }
}
