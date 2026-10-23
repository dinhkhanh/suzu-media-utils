import FaceCore
import Foundation
import GRDB
import MediaKit

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
    /// Projects shared with other Macs through a folder (see TeamSync).
    public let teamSync: TeamSync

    public init(modelURL: URL, directory: URL = LibraryStore.defaultDirectory) throws {
        store = try LibraryStore(directory: directory)
        engine = GroupingEngine(store: store)
        processor = try Processor(store: store, engine: engine, modelURL: modelURL)
        teamSync = TeamSync(store: store, engine: engine)
        processor.onReferenceEnrolled = { [teamSync] _ in teamSync.pushSoon() }
    }

    public func start() {
        // Interrupted runs leave nothing half-written (faces and status change in one transaction); just requeue.
        engine.start()
        processor.enqueuePending()
        teamSync.start()
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
        let (old, noPrint, wantBursts) = (try? store.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'done' AND duplicateOf IS NULL AND analysisVersion < ?",
                              arguments: [BestShot.analysisVersion]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'done' AND duplicateOf IS NULL AND kind = 'photo' AND featurePrint IS NULL") ?? 0,
             try DeliveryService.rules(db).contains { $0.enabled && $0.mediaQuery.collapseBursts })
        }) ?? (0, 0, false)
        // Deliveries first: they're what people are waiting for. Grouping settles ~30 s after a batch, so files
        // are only delivered once their faces are named. A rule that skips similar shots waits until the new
        // photos' bursts are known, or it would deliver every shot of a burst.
        engine.waitUntilIdle()
        if !(wantBursts && (noPrint > 0 || burstsDirty)), let report = try? delivery.run(), !report.newFiles.isEmpty {
            onDelivered?(report)
            if report.remaining > 0 { return false }
        }
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
        // The same event folder, renamed or moved in Finder: relink it rather than start over.
        if let old = try Self.offlineSource(matching: path, kind: kind, store: store) {
            try relinkSource(old, to: url)
            if kind == .media, let project { try moveSource(old, to: project) }
            if let s = try store.db.read({ db in try SourceRecord.fetchOne(db, key: old) }) { return s }
        }
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
        try store.db.write { db in
            try db.execute(sql: "UPDATE project SET name = ?, updatedAt = ? WHERE id = ?", arguments: [trimmed, Date().timeIntervalSince1970, id])
        }
        teamSync.pushSoon()
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
        try store.db.write { db in
            // A shared project deleted here stays on teammates' Macs; their later changes to it are ignored here
            // rather than bringing it back.
            if let p = try ProjectRecord.fetchOne(db, key: id), let team = p.teamId {
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, '1')", arguments: [team, "gone:project:\(p.uuid)"])
            }
            _ = try ProjectRecord.deleteOne(db, key: id)
        }
    }

    /// Forgets a source and everything found in it. Files on disk are not touched. Named people stay, and what
    /// their faces looked like is remembered (PersonMemory), so they are recognised when the photos come back. Deletes in small batches so the
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
                try PersonMemory.remember("face.mediaId IN (\(list))", db: db)
                try db.execute(sql: "DELETE FROM media WHERE id IN (\(list))")
                return ids.count
            }
            if n == 0 { break }
        }
        try store.db.write { db in try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id]) }
        return affected
    }

    public func rescan(_ sourceId: Int64) { monitor(sourceId)?.scanSoon() }

    /// Runs `body` while every folder watcher waits, so no scan sees files half-way through being renamed or
    /// relinked (it would take them for deleted and new files and drop their faces). Call it off the main thread.
    func holdingMonitors<T>(_ body: () throws -> T) rethrows -> T {
        let queues = lock.withLock { monitors.sorted { $0.key < $1.key }.map(\.value.queue) }
        func hold(_ rest: ArraySlice<DispatchQueue>) throws -> T {
            guard let q = rest.first else { return try body() }
            return try q.sync { try hold(rest.dropFirst()) }
        }
        return try hold(queues[...])
    }

    /// Batch Rename: renames the files and their library records together, so faces, names and fixes stay with
    /// each file. Swaps and shifted numbers are fine; the database is updated in two steps for the same reason.
    public func renameFiles(_ items: [RenamePattern.Item], names: [String]) throws -> RenamePattern.Outcome {
        var affected: Set<Int64> = []
        let outcome = try holdingMonitors { () throws -> RenamePattern.Outcome in
            // Library paths are canonical; work them out while the old names still exist.
            let before = Dictionary(items.map { ($0.url, canonicalPath($0.url)) }, uniquingKeysWith: { a, _ in a })
            let outcome = RenamePattern.apply(items, names: names)
            affected = try Self.recordRenames(outcome.renamed.map { (before[$0.0] ?? canonicalPath($0.0), $0.1.lastPathComponent) }, store: store)
            return outcome
        }
        if !affected.isEmpty { engine.peopleChanged(affected); deleteEmptyPeople() }
        return outcome
    }

    /// Points library records at their files' new names: (old canonical path, new file name in the same folder).
    /// Two steps, so swaps and shifted numbers never collide with each other's old names. Returns the people who
    /// lost faces (only from leftover records of files no longer on disk).
    static func recordRenames(_ renames: [(path: String, newName: String)], store: LibraryStore) throws -> Set<Int64> {
        guard !renames.isEmpty else { return [] }
        return try store.db.write { db in
            var affected: Set<Int64> = []
            var moved: [(id: Int64, path: String)] = []
            for r in renames {
                let newPath = (r.path as NSString).deletingLastPathComponent + "/" + r.newName
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM media WHERE path = ?", arguments: [r.path]) { moved.append((id, newPath)) }
            }
            for m in moved {
                try db.execute(sql: "UPDATE media SET path = ? WHERE id = ?", arguments: ["\u{1}renaming/\(m.id)", m.id])
            }
            let ids = Set(moved.map(\.id))
            for m in moved {
                // A leftover record of a file that is no longer on disk under that name.
                if let stale = try Int64.fetchOne(db, sql: "SELECT id FROM media WHERE path = ?", arguments: [m.path]), !ids.contains(stale) {
                    affected.formUnion(try SourceMonitor.remove(mediaId: stale, db: db))
                }
                try db.execute(sql: "UPDATE media SET path = ? WHERE id = ?", arguments: [m.path, m.id])
            }
            return affected
        }
    }

    /// A folder renamed or moved in Finder: points the library at its new place, keeping every face and name.
    /// Throws if the new folder overlaps another one in the library.
    public func relinkSource(_ id: Int64, to url: URL) throws {
        let path = canonicalPath(url)
        guard let source = try store.db.read({ db in try SourceRecord.fetchOne(db, key: id) }) else { return }
        guard source.path != path else { return }
        let others = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT s.path, p.name FROM source s LEFT JOIN project p ON p.id = s.projectId WHERE s.id != ?", arguments: [id])
        }
        for r in others {
            let other: String = r["path"]
            if other == path || path.hasPrefix(other + "/") || other.hasPrefix(path + "/") {
                throw ProjectError.overlaps(folder: (path as NSString).lastPathComponent, other: (other as NSString).lastPathComponent, project: r["name"])
            }
        }
        if let m = lock.withLock({ monitors.removeValue(forKey: id) }) {
            m.stop()
            m.queue.sync {}  // let a scan already under way finish first
        }
        try Self.relinkPaths(id, from: source.path, to: path, store: store)
        if let s = try store.db.read({ db in try SourceRecord.fetchOne(db, key: id) }) { startMonitor(s) }
    }

    static func relinkPaths(_ id: Int64, from old: String, to new: String, store: LibraryStore) throws {
        let oldPrefix = old + "/"
        try store.db.write { db in
            try db.execute(sql: "UPDATE source SET path = ? WHERE id = ?", arguments: [new, id])
            // substr counts code points from 1 (not Swift characters: "ư" may be two): keep what follows the old path.
            try db.execute(sql: "UPDATE media SET path = ? || substr(path, ?) WHERE sourceId = ? AND substr(path, 1, ?) = ?",
                           arguments: [new + "/", oldPrefix.unicodeScalars.count + 1, id, oldPrefix.unicodeScalars.count, oldPrefix])
        }
    }

    /// An offline folder (renamed, moved, or its drive not mounted) whose files are all found under `path`.
    /// Adding that folder again relinks the old entry instead, so nothing is lost or processed twice.
    static func offlineSource(matching path: String, kind: SourceKind, store: LibraryStore) throws -> Int64? {
        let fm = FileManager.default
        let offline = try store.db.read { db in try SourceRecord.filter(Column("kind") == kind.rawValue).fetchAll(db) }
            .filter { !fm.fileExists(atPath: $0.path) }
        for s in offline {
            let sample = try store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT path, size, contentKey FROM media WHERE sourceId = ? AND duplicateOf IS NULL AND contentKey IS NOT NULL
                    ORDER BY random() LIMIT 12
                    """, arguments: [s.id])
            }
            guard !sample.isEmpty else { continue }
            let prefix = s.path + "/"
            // Same relative path is not enough (cameras restart at DSC_0001): the contents must match too.
            let found = sample.filter { r in
                let old: String = r["path"], size: Int64 = r["size"]
                guard old.hasPrefix(prefix) else { return false }
                let url = URL(fileURLWithPath: path + "/" + old.dropFirst(prefix.count), isDirectory: false)
                let actual = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
                return actual == size && ContentKey.compute(url, size: size) == r["contentKey"]
            }
            if found.count == sample.count { return s.id }
        }
        return nil
    }

    // MARK: - People

    /// Renames a person. If another person already has that name, the two are merged; returns the surviving id.
    @discardableResult
    public func rename(_ personId: Int64, to rawName: String) throws -> Int64 {
        let name = PersonNames.clean(rawName)
        let existing = try store.db.read { db in try PersonNames.find(name, excluding: personId, db: db) }
        if let existing, !name.isEmpty {
            try merge([personId], into: existing)
            return existing
        }
        try store.db.write { db in
            try db.execute(sql: "UPDATE person SET name = ?, nameAt = ? WHERE id = ?",
                           arguments: [name.isEmpty ? nil : name, Date().timeIntervalSince1970, personId])
        }
        engine.reclusterNow()  // runs autoName, so unnamed groups that match this person join it
        teamSync.pushSoon()
        return personId
    }

    public func merge(_ ids: [Int64], into target: Int64) throws {
        let others = ids.filter { $0 != target }
        guard !others.isEmpty else { return }
        try store.db.write { db in try PersonNames.merge(others, into: target, db: db) }
        engine.peopleChanged(Set(ids))
        teamSync.pushSoon()
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
        teamSync.pushSoon()
    }

    /// Creates a named person from faces (e.g. picked from "Unassigned"). A name someone already has adds the
    /// faces to that person instead.
    @discardableResult
    public func newPerson(name rawName: String?, faceIds: [Int64]) throws -> Int64 {
        let name = rawName.map(PersonNames.clean).flatMap { $0.isEmpty ? nil : $0 }
        let id = try store.db.write { db -> Int64 in
            if let name, let existing = try PersonNames.find(name, db: db) { return existing }
            var p = PersonRecord(name: name)
            try p.insert(db)
            return p.id!
        }
        try assign(faceIds: faceIds, to: id)
        return id
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
