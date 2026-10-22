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

    @discardableResult
    public func addSource(_ url: URL, kind: SourceKind = .media) throws -> SourceRecord {
        var s = SourceRecord(path: canonicalPath(url), kind: kind)
        try store.db.write { db in try s.insert(db) }
        startMonitor(s)
        return s
    }

    /// Forgets a source and everything found in it. Files on disk are not touched.
    public func removeSource(_ id: Int64) throws {
        lock.withLock { monitors.removeValue(forKey: id) }?.stop()
        let affected = try store.db.write { db -> Set<Int64> in
            let p = Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT personId FROM face JOIN media ON media.id = face.mediaId
                WHERE media.sourceId = ? AND personId IS NOT NULL
                """, arguments: [id]))
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id])
            return p
        }
        engine.peopleChanged(affected)
        deleteEmptyPeople()
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

    /// Unnamed people with no faces left are clutter; named ones are kept so their name is not lost.
    public func deleteEmptyPeople() {
        try? store.db.write { db in
            try db.execute(sql: """
                DELETE FROM person WHERE name IS NULL AND id NOT IN (SELECT personId FROM face WHERE personId IS NOT NULL)
                """)
        }
    }
}
