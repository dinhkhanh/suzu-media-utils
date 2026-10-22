import FaceCore
import Foundation
import GRDB

/// Wires the library together: source monitors -> processor -> grouping engine, plus the user's people edits.
public final class LibraryService: @unchecked Sendable {
    public let store: LibraryStore
    public let engine: GroupingEngine
    public let processor: Processor
    public var exporter: Exporter { Exporter(store: store) }
    let lock = NSLock()
    var monitors: [Int64: SourceMonitor] = [:]
    var maintenance: DispatchSourceTimer?
    let maintenanceQueue = DispatchQueue(label: "maintenance", qos: .background)
    var burstsDirty = true
    /// Called (on a background queue) after delivery rules handled new files: person name -> count.
    public var onDelivered: (@Sendable (DeliveryService.Report) -> Void)?
    public var delivery: DeliveryService { DeliveryService(store: store) }

    public init(modelURL: URL, directory: URL = LibraryStore.defaultDirectory) throws {
        store = try LibraryStore(directory: directory)
        engine = GroupingEngine(store: store)
        processor = try Processor(store: store, engine: engine, modelURL: modelURL)
    }

    public func start() {
        // Interrupted runs leave nothing half-written (faces and status change in one transaction); just requeue.
        engine.start()
        processor.enqueuePending()
        for s in (try? store.db.read { db in try SourceRecord.fetchAll(db) }) ?? [] { startMonitor(s) }
        let t = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.maintain() }
        t.resume()
        maintenance = t
    }

    /// Background extras (best-shot upgrades of older analyses, burst fingerprints, burst grouping). Each step only
    /// runs while no new file is waiting, so face recognition and grouping are never delayed.
    /// Returns true when there is nothing left to do.
    @discardableResult
    public func maintain() -> Bool {
        guard processor.queuedCount == 0, (try? pendingCount()) == 0 else { return false }
        if processor.backgroundCount > 0 { return false }
        // Deliveries first: they're what people are waiting for. Grouping settles ~30 s after a batch, so files
        // are only delivered once their faces are named.
        engine.waitUntilIdle()
        if let report = try? delivery.run(), !report.newFiles.isEmpty {
            onDelivered?(report)
            if report.remaining > 0 { return false }
        }
        let (old, noPrint) = (try? store.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'done' AND duplicateOf IS NULL AND analysisVersion < ?",
                              arguments: [BestShot.analysisVersion]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'done' AND duplicateOf IS NULL AND kind = 'photo' AND featurePrint IS NULL") ?? 0)
        }) ?? (0, 0)
        if processor.extrasPaused { return false }
        if old > 0 { processor.enqueueUpgrades(limit: 40); burstsDirty = true; return false }
        if noPrint > 0 { processor.enqueueFeaturePrints(limit: 100); burstsDirty = true; return false }
        if burstsDirty {
            burstsDirty = false
            _ = try? BurstGrouper(store: store).regroup()
        }
        return true
    }

    func pendingCount() throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") ?? 0 }
    }

    func startMonitor(_ s: SourceRecord) {
        let m = SourceMonitor(source: s, store: store) { [weak self] newPending, affected in
            guard let self else { return }
            if newPending { processor.enqueuePending() }
            if !affected.isEmpty {
                engine.peopleChanged(affected)
                deleteEmptyPeople()
            }
        }
        lock.withLock { monitors[s.id!] = m }
        m.start()
    }

    public func monitor(_ sourceId: Int64) -> SourceMonitor? { lock.withLock { monitors[sourceId] } }

    public enum ProjectError: LocalizedError {
        case alreadyAdded(folder: String, project: String?)
        case overlaps(folder: String, other: String, project: String?)
        case noProject
        public var errorDescription: String? {
            switch self {
            case .alreadyAdded(let f, let p): "“\(f)” is already in \(p.map { "the project “\($0)”" } ?? "the library")."
            case .overlaps(let f, let o, let p):
                "“\(f)” overlaps “\(o)”\(p.map { " in the project “\($0)”" } ?? ""): a file can only belong to one folder. Add a different folder, or move that one."
            case .noProject: "Choose or create a project first."
            }
        }
    }

    /// Adds a folder. Photo & video folders belong to a project; known-people folders are shared by all projects.
    @discardableResult
    public func addSource(_ url: URL, kind: SourceKind = .media, project: Int64? = nil) throws -> SourceRecord {
        let path = canonicalPath(url)
        if kind == .media && project == nil { throw ProjectError.noProject }
        try Self.checkNewFolder(path, store: store)
        var s = SourceRecord(path: path, kind: kind, projectId: kind == .media ? project : nil)
        try store.db.write { db in try s.insert(db) }
        startMonitor(s)
        return s
    }

    /// Throws when the folder is already in the library, or inside / around one that is (its files would be listed
    /// twice).
    static func checkNewFolder(_ path: String, store: LibraryStore) throws {
        let existing = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT s.path, p.name FROM source s LEFT JOIN project p ON p.id = s.projectId")
        }
        let name = (path as NSString).lastPathComponent
        for r in existing {
            let other: String = r["path"]
            if other == path { throw ProjectError.alreadyAdded(folder: name, project: r["name"]) }
            if path.hasPrefix(other + "/") || other.hasPrefix(path + "/") {
                throw ProjectError.overlaps(folder: name, other: (other as NSString).lastPathComponent, project: r["name"])
            }
        }
    }

    // MARK: - Projects

    @discardableResult
    public func createProject(_ name: String) throws -> ProjectRecord {
        var p = ProjectRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Project" : name)
        try store.db.write { db in try p.insert(db) }
        return p
    }

    public func renameProject(_ id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try store.db.write { db in try db.execute(sql: "UPDATE project SET name = ? WHERE id = ?", arguments: [trimmed, id]) }
    }

    /// Moves a folder (and everything found in it) to another project; nothing is re-scanned.
    public func moveSource(_ sourceId: Int64, to project: Int64) throws {
        try store.db.write { db in
            try db.execute(sql: "UPDATE source SET projectId = ? WHERE id = ? AND kind = 'media'", arguments: [project, sourceId])
        }
    }

    /// Forgets a project and its folders (files on disk are untouched). People keep their names, so they are still
    /// recognised in other projects. Slow for big projects: call it off the main thread.
    public func deleteProject(_ id: Int64) throws {
        let sources = try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM source WHERE projectId = ?", arguments: [id]) }
        for s in sources { try removeSource(s) }
        try store.db.write { db in _ = try ProjectRecord.deleteOne(db, key: id) }
    }

    /// Forgets a source and everything found in it. Files on disk are not touched. Deletes in small batches so the
    /// database stays responsive; call it off the main thread for big folders.
    public func removeSource(_ id: Int64) throws {
        lock.withLock { monitors.removeValue(forKey: id) }?.stop()
        let affected = try Self.deleteSourceContents(id, store: store)
        engine.peopleChanged(affected)
        deleteEmptyPeople()
    }

    /// Deletes a source's media 500 at a time, then the source. Returns the people who lost faces.
    @discardableResult
    static func deleteSourceContents(_ id: Int64, store: LibraryStore) throws -> Set<Int64> {
        var affected: Set<Int64> = []
        while true {
            let n = try store.db.write { db -> Int in
                let ids = try Int64.fetchAll(db, sql: "SELECT id FROM media WHERE sourceId = ? LIMIT 500", arguments: [id])
                guard !ids.isEmpty else { return 0 }
                let list = ids.map(String.init).joined(separator: ",")
                affected.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId IN (\(list)) AND personId IS NOT NULL"))
                try db.execute(sql: "DELETE FROM media WHERE id IN (\(list))")
                return ids.count
            }
            if n == 0 { break }
        }
        try store.db.write { db in try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id]) }
        return affected
    }

    public func rescan(_ sourceId: Int64) { monitor(sourceId)?.scanSoon() }

    // MARK: - People

    /// Renames a person. If another person already has that name, the two are merged; returns the surviving id.
    @discardableResult
    public func rename(_ personId: Int64, to rawName: String) throws -> Int64 {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try store.db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ? COLLATE NOCASE AND id != ?", arguments: [name, personId])
        }
        if let existing, !name.isEmpty {
            try merge([personId], into: existing)
            return existing
        }
        try store.db.write { db in
            try db.execute(sql: "UPDATE person SET name = ? WHERE id = ?", arguments: [name.isEmpty ? nil : name, personId])
        }
        engine.reclusterNow()  // runs autoName, so unnamed groups that match this person join it
        return personId
    }

    public func merge(_ ids: [Int64], into target: Int64) throws {
        let others = ids.filter { $0 != target }
        guard !others.isEmpty else { return }
        try store.db.write { db in
            let list = others.map(String.init).joined(separator: ",")
            try db.execute(sql: "UPDATE face SET personId = ? WHERE personId IN (\(list))", arguments: [target])
            try db.execute(sql: "UPDATE face SET rejectedPersonId = ? WHERE rejectedPersonId IN (\(list))", arguments: [target])
            try db.execute(sql: "DELETE FROM person WHERE id IN (\(list))")
        }
        engine.peopleChanged(Set(ids))
    }

    /// "Not this person": the faces leave the person and are never auto-assigned back to them.
    public func reject(faceIds: [Int64], from personId: Int64) throws {
        try store.db.write { db in
            try db.execute(sql: """
                UPDATE face SET personId = NULL, assignment = 'user', rejectedPersonId = ?
                WHERE id IN (\(faceIds.map(String.init).joined(separator: ",")))
                """, arguments: [personId])
        }
        engine.peopleChanged([personId])
        deleteEmptyPeople()
    }

    /// Puts faces (and, for videos, nothing else) under a person and locks them there.
    public func assign(faceIds: [Int64], to personId: Int64) throws {
        let previous = try store.db.write { db -> Set<Int64> in
            let ids = faceIds.map(String.init).joined(separator: ",")
            let prev = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE id IN (\(ids)) AND personId IS NOT NULL"))
            try db.execute(sql: "UPDATE face SET personId = ?, assignment = 'user' WHERE id IN (\(ids))", arguments: [personId])
            return prev
        }
        engine.peopleChanged(previous.union([personId]))
        deleteEmptyPeople()
    }

    /// Creates a named person from faces (e.g. picked from "Unassigned").
    @discardableResult
    public func newPerson(name: String?, faceIds: [Int64]) throws -> Int64 {
        var p = PersonRecord(name: name)
        try store.db.write { db in try p.insert(db) }
        try assign(faceIds: faceIds, to: p.id!)
        return p.id!
    }

    /// Picks the face used as a person's picture; nil goes back to the best shot automatically.
    public func setCover(_ personId: Int64, faceId: Int64?) throws {
        try store.db.write { db in
            try db.execute(sql: "UPDATE person SET coverFaceId = ? WHERE id = ?", arguments: [faceId, personId])
        }
    }

    /// Unnamed people with no faces left are clutter; named ones are kept so their name is not lost.
    public func deleteEmptyPeople() {
        try? store.db.write { db in
            try db.execute(sql: """
                DELETE FROM person WHERE name IS NULL AND id NOT IN (SELECT personId FROM face WHERE personId IS NOT NULL)
                """)
        }
    }
}
