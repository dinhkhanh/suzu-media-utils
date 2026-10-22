import Foundation
import GRDB

/// Shares a project between Macs — yours and your teammates' — through a folder they can all reach: a NAS share,
/// Dropbox, iCloud Drive. No account, no server: one Mac creates the team in a folder, the others join by picking
/// that folder.
///
/// What travels: people (stable id, name, and a summary of their faces so every Mac recognises them), merges,
/// session names and rules. Photos, face boxes and crops stay on the Mac that processed them.
///
/// How: every Mac appends its changes to its own log file (`devices/<id>.jsonl`) and reads everyone else's; nobody
/// writes anyone else's file, so a shared folder needs no locking. Changes carry the time they were made and the
/// newest wins. A Mac that was offline catches up from where it left off. Each Mac also overwrites its own
/// `summaries/<id>.json` with the mean embedding of every person's faces it has seen.
///
/// The format is the contract; the folder is one transport. Another (iCloud, a server) would move the same files.
public final class TeamSync: @unchecked Sendable {
    public let store: LibraryStore
    let engine: GroupingEngine
    let queue = DispatchQueue(label: "teamsync", qos: .utility)
    var timer: DispatchSourceTimer?
    let lock = NSLock()
    var statuses: [Int64: TeamStatus] = [:]
    var summariesWritten: [Int64: Date] = [:]
    var wanted = false
    /// Per person: the signature of their faces when the centroid was computed.
    var centroids: [Int64: (signature: String, centroid: [Float], count: Int)] = [:]
    /// Called off the main thread after a pass changed something or a status.
    public var onChange: (@Sendable () -> Void)?
    public let deviceId: String
    public var deviceName: String
    public static let passInterval: Double = 5
    public static let summaryInterval: Double = 60
    public static let model = "ArcFaceR50"

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
    }

    public enum TeamError: LocalizedError {
        case notATeamFolder, alreadyATeamFolder(String), projectAlreadyShared(String), folderUnreachable
        public var errorDescription: String? {
            switch self {
            case .notATeamFolder: "That folder has no team in it. Pick the folder a teammate shared, or create a team."
            case .alreadyATeamFolder(let n): "That folder already holds the team “\(n)”. Join it instead."
            case .projectAlreadyShared(let n): "This project is already shared with the team “\(n)”."
            case .folderUnreachable: "The folder can't be reached. Mount the share (or open Dropbox / iCloud Drive) and try again."
            }
        }
    }

    public init(store: LibraryStore, engine: GroupingEngine) {
        self.store = store
        self.engine = engine
        deviceId = (try? store.db.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'deviceId'") }) ?? SyncIds.new()
        deviceName = Host.current().localizedName ?? "Mac"
    }

    // MARK: - Teams

    public func teams() throws -> [TeamRecord] {
        try store.db.read { db in try TeamRecord.order(Column("joinedAt")).fetchAll(db) }
    }

    public func team(forProject project: Int64) throws -> TeamRecord? {
        try store.db.read { db in try TeamRecord.filter(Column("projectId") == project).fetchOne(db) }
    }

    public func status(_ teamId: Int64) -> TeamStatus? { lock.withLock { statuses[teamId] } }

    static func infoURL(_ folder: URL) -> URL { folder.appendingPathComponent("team.json") }
    static func devicesURL(_ folder: URL) -> URL { folder.appendingPathComponent("devices", isDirectory: true) }
    static func summariesURL(_ folder: URL) -> URL { folder.appendingPathComponent("summaries", isDirectory: true) }

    public static func readInfo(_ folder: URL) -> Info? {
        (try? Data(contentsOf: infoURL(folder))).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    /// Starts a team for a project in an empty (or new) folder that every teammate's Mac can reach.
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
        return try register(info, folder: folder, project: project)
    }

    /// Joins the team in `folder`, linking it to `project` (nil = a new project named after the team).
    @discardableResult
    public func join(folder: URL, project: Int64?) throws -> TeamRecord {
        guard let info = Self.readInfo(folder) else {
            throw FileManager.default.fileExists(atPath: folder.path) ? TeamError.notATeamFolder : TeamError.folderUnreachable
        }
        if let project, let existing = try team(forProject: project) { throw TeamError.projectAlreadyShared(existing.name) }
        if let existing = try store.db.read({ db in try TeamRecord.filter(Column("uuid") == info.uuid).fetchOne(db) }) {
            // Already joined (maybe from another path to the same share): just point at this folder.
            try store.db.write { db in
                try db.execute(sql: "UPDATE team SET folder = ? WHERE id = ?", arguments: [canonicalPath(folder), existing.id])
            }
            syncSoon()
            return try store.db.read { db in try TeamRecord.fetchOne(db, key: existing.id)! }
        }
        let pid: Int64
        if let project { pid = project } else {
            var p = ProjectRecord(name: info.name)
            try store.db.write { db in try p.insert(db) }
            pid = p.id!
        }
        return try register(info, folder: folder, project: pid)
    }

    func register(_ info: Info, folder: URL, project: Int64) throws -> TeamRecord {
        var t = TeamRecord(uuid: info.uuid, name: info.name, folder: canonicalPath(folder), projectId: project)
        try store.db.write { db in try t.insert(db) }
        lock.withLock { statuses[t.id!] = TeamStatus(teamId: t.id!, reachable: true) }
        syncSoon()
        return t
    }

    /// Leaves the team: forgets its folder and what teammates' Macs saw. People keep their names.
    public func leave(_ teamId: Int64) throws {
        let affected = try store.db.write { db -> Set<Int64> in
            let ids = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM personRemote WHERE teamId = ?", arguments: [teamId]))
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
        t.setEventHandler { [weak self] in self?.pass() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// Something changed (a name, a merge, a rule): publish on the next pass without waiting for the summary interval.
    public func pushSoon() { lock.withLock { wanted = true } }

    public func syncSoon() {
        pushSoon()
        queue.async { [weak self] in self?.pass() }
    }

    /// One pass over every team now (tests). Returns whether anything was read or written.
    @discardableResult
    public func syncNow() -> Bool { queue.sync { pass() } }

    @discardableResult
    func pass() -> Bool {
        guard let teams = try? teams(), !teams.isEmpty else { return false }
        var changed = false
        let forced = lock.withLock { let w = wanted; wanted = false; return w }
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
            do {
                if try push(team, forced: forced) { changed = true }
                if try pull(team) { changed = true }
                status.devices = devices(team)
                status.lastSync = Date()
            } catch {
                status.error = error.localizedDescription
            }
            lock.withLock { statuses[team.id!] = status }
        }
        onChange?()
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
        /// device, person, merge, session, rule, summary (deferred only)
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
    }

    struct RulePayload: Codable {
        var name: String?
        var folder: String?
        var layout: String
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
    }

    /// Named people of the team's project or of a Known-People folder (those are for every project), plus anyone
    /// its rules name.
    func relevantPeople(_ team: TeamRecord) throws -> [(id: Int64, uuid: String, name: String, nameAt: Double?)] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, uuid, name, nameAt FROM person p WHERE name IS NOT NULL AND (
                    EXISTS (SELECT 1 FROM face f JOIN media m ON m.id = f.mediaId JOIN source s ON s.id = m.sourceId
                            WHERE f.personId = p.id AND (s.projectId = ? OR s.kind = 'reference'))
                    OR id IN (SELECT personId FROM deliveryRule WHERE projectId = ? AND personId IS NOT NULL))
                ORDER BY id
                """, arguments: [team.projectId, team.projectId]).map { ($0["id"], $0["uuid"], $0["name"], $0["nameAt"]) }
        }
    }

    func push(_ team: TeamRecord, forced: Bool) throws -> Bool {
        let teamId = team.id!
        var state = try state(teamId)
        var ops: [Op] = []
        var updates: [String: String] = [:]
        let now = Date().timeIntervalSince1970

        if state["pub:device"] != deviceName {
            ops.append(Op(t: "device", at: now, name: deviceName))
            updates["pub:device"] = deviceName
        }
        var people = try relevantPeople(team)
        // People a rule names count too, so a teammate's Mac can apply the rule.
        let ruleRows = try store.db.read { db in
            try DeliveryRule.filter(Column("projectId") == team.projectId).fetchAll(db)
        }
        let rulePeople = Set(ruleRows.filter { $0.deletedAt == nil }.flatMap { $0.mediaQuery.people })
        let known = Set(people.map(\.id))
        if !rulePeople.subtracting(known).isEmpty {
            let extra = try store.db.read { db in
                try Row.fetchAll(db, sql: "SELECT id, uuid, name, nameAt FROM person WHERE name IS NOT NULL AND id IN (\(rulePeople.subtracting(known).map(String.init).joined(separator: ",")))")
                    .map { ($0["id"] as Int64, $0["uuid"] as String, $0["name"] as String, $0["nameAt"] as Double?) }
            }
            people += extra
        }
        for p in people {
            let at = p.nameAt ?? 0
            let value = "\(at)|\(p.name)"
            if state["pub:person:\(p.uuid)"] != value {
                ops.append(Op(t: "person", at: at, uuid: p.uuid, name: p.name))
                updates["pub:person:\(p.uuid)"] = value
            }
        }
        for r in try store.db.read({ db in try Row.fetchAll(db, sql: "SELECT fromUuid, intoUuid, at FROM personMerge") }) {
            let from: String = r["fromUuid"], into: String = r["intoUuid"]
            if state["pub:merge:\(from)"] != into {
                ops.append(Op(t: "merge", at: r["at"], uuid: from, into: into))
                updates["pub:merge:\(from)"] = into
            }
        }
        for r in try store.db.read({ db in try Row.fetchAll(db, sql: "SELECT at, name, updatedAt FROM sessionLabel WHERE projectId = ?", arguments: [team.projectId]) }) {
            let moment: Double = r["at"], updatedAt: Double = r["updatedAt"]
            let value = "\(updatedAt)"
            if state["pub:session:\(moment)"] != value {
                ops.append(Op(t: "session", at: updatedAt, name: r["name"], moment: moment))
                updates["pub:session:\(moment)"] = value
            }
        }
        let uuidOf = Dictionary(people.map { ($0.id, $0.uuid) }, uniquingKeysWith: { a, _ in a })
        for rule in ruleRows {
            let value = "\(rule.updatedAt)|\(rule.deletedAt != nil)"
            guard state["pub:rule:\(rule.uuid)"] != value else { continue }
            var q = rule.mediaQuery
            let uuids = q.people.compactMap { uuidOf[$0] }
            guard uuids.count == q.people.count else { continue }  // a person without a name can't travel yet
            q.people = []
            q.project = nil
            q.sourceId = nil
            let payload = RulePayload(name: rule.name, folder: rule.folder, layout: rule.layout.rawValue, recipe: rule.recipe,
                                      writeNames: rule.writeNames, enabled: rule.enabled, people: uuids, query: q,
                                      createdAt: rule.createdAt.timeIntervalSince1970)
            ops.append(Op(t: "rule", at: rule.updatedAt, uuid: rule.uuid, rule: payload, deleted: rule.deletedAt != nil))
            updates["pub:rule:\(rule.uuid)"] = value
        }
        var wrote = false
        if !ops.isEmpty {
            try append(ops, to: Self.devicesURL(team.url).appendingPathComponent("\(deviceId).jsonl"))
            try setState(teamId, updates)
            for (k, v) in updates { state[k] = v }
            wrote = true
        }
        if try publishSummaries(team, people: people, state: state, forced: forced) { wrote = true }
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
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
    }

    /// Rewrites `summaries/<device>.json` when a relevant person's faces changed. Checked every pass (a cheap
    /// count per person); while faces keep arriving it is written at most once a minute, and at once after the
    /// user changed something or a Known-People photo was enrolled.
    func publishSummaries(_ team: TeamRecord, people: [(id: Int64, uuid: String, name: String, nameAt: Double?)], state: [String: String], forced: Bool) throws -> Bool {
        let teamId = team.id!
        guard !people.isEmpty else { return false }
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
            let entry: (signature: String, centroid: [Float], count: Int)
            if let cached, cached.signature == sig { entry = cached } else {
                guard let s = engine.localSummary(p.id) else { continue }
                entry = (sig, s.centroid, s.count)
                lock.withLock { centroids[p.id] = entry }
            }
            out[p.uuid] = Summary(c: Vector.encode(entry.centroid).base64EncodedString(), n: entry.count)
        }
        let summaries = Summaries(model: Self.model, device: deviceName, people: out)
        let url = Self.summariesURL(team.url).appendingPathComponent("\(deviceId).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try JSONEncoder().encode(summaries).write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else {
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

    func pull(_ team: TeamRecord) throws -> Bool {
        let teamId = team.id!
        var changed = false
        var affected: Set<Int64> = []
        var remoteChanged: Set<Int64> = []
        let fm = FileManager.default
        let state = try state(teamId)
        let logs = (try? fm.contentsOfDirectory(at: Self.devicesURL(team.url), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for f in logs where f.pathExtension == "jsonl" {
            let id = f.deletingPathExtension().lastPathComponent
            guard id != deviceId else { continue }
            let cursor = Int(state["cursor:\(id)"] ?? "0") ?? 0
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > cursor else { continue }
            let h = try FileHandle(forReadingFrom: f)
            defer { try? h.close() }
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
            var updates = ["cursor:\(id)": String(cursor + complete.count)]
            try store.db.write { db in
                for op in ops {
                    if op.t == "device", let name = op.name { updates["dev:\(id)"] = name; continue }
                    switch try apply(op, team: team, device: id, db: db) {
                    case .applied(let people, let remote):
                        affected.formUnion(people)
                        remoteChanged.formUnion(remote)
                    case .deferred:
                        try db.execute(sql: "INSERT INTO syncDeferred (teamId, op) VALUES (?, ?)",
                                       arguments: [teamId, String(decoding: try JSONEncoder().encode(op), as: UTF8.self)])
                    case .ignored: break
                    }
                }
                for (k, v) in updates {
                    try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [teamId, k, v])
                }
            }
            changed = true
        }
        // Summaries: whole files, re-read when they change.
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
                        let op = Op(t: "summary", at: 0, uuid: uuid, device: id, centroid: summary.c, count: summary.n)
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
        if !affected.isEmpty { engine.peopleChanged(affected) }
        if !remoteChanged.isEmpty { engine.remoteChanged(remoteChanged) }
        return changed
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

    func apply(_ op: Op, team: TeamRecord, device: String, db: Database) throws -> Outcome {
        switch op.t {
        case "person":
            guard let uuid = op.uuid, let name = op.name.map(PersonNames.clean), !name.isEmpty else { return .ignored }
            if let pid = try Self.resolve(uuid, db: db) {
                let row = try Row.fetchOne(db, sql: "SELECT name, nameAt FROM person WHERE id = ?", arguments: [pid])
                guard (row?["name"] as String?) != name, op.at > ((row?["nameAt"] as Double?) ?? 0) else { return .ignored }
                return .applied(people: try Self.setName(pid, name, at: op.at, db: db), remote: [])
            }
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
            try db.execute(sql: "INSERT OR IGNORE INTO personMerge (fromUuid, intoUuid, at) VALUES (?, ?, ?)", arguments: [from, into, op.at])
            return .applied(people: [], remote: [])

        case "session":
            guard let moment = op.moment, let name = op.name else { return .ignored }
            return try EventSessions.setName(db, project: team.projectId, at: moment, name: name, updatedAt: op.at)
                ? .applied(people: [], remote: []) : .ignored

        case "rule":
            guard let uuid = op.uuid, let payload = op.rule else { return .ignored }
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
            q.project = team.projectId
            var rule = existing ?? DeliveryRule(name: payload.name, query: q, folder: payload.folder, layout: .person, recipe: nil,
                                                writeNames: payload.writeNames, projectId: team.projectId)
            rule.uuid = uuid
            rule.name = payload.name
            rule.projectId = team.projectId
            rule.setQuery(q)
            rule.folder = payload.folder
            rule.layout = DeliveryRule.Layout(rawValue: payload.layout) ?? .person
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

        case "summary":
            guard let uuid = op.uuid, let c = op.centroid, let data = Data(base64Encoded: c), let n = op.count else { return .ignored }
            guard let pid = try Self.resolve(uuid, db: db) else { return .deferred }
            try db.execute(sql: "INSERT OR REPLACE INTO personRemote (personId, teamId, deviceId, centroid, count) VALUES (?, ?, ?, ?, ?)",
                           arguments: [pid, team.id, device, data, n])
            return .applied(people: [], remote: [pid])

        default:
            return .ignored
        }
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
