import GRDB
import XCTest
@testable import FaceLibrary

/// Projects: each event is a set of folders; people and their names are shared by every project.
final class ProjectTests: XCTestCase {
    var tmp: URL!
    var store: LibraryStore!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func project(_ name: String) throws -> Int64 {
        var p = ProjectRecord(name: name)
        try store.db.write { db in try p.insert(db) }
        return p.id!
    }

    func source(_ name: String, project: Int64?, kind: SourceKind = .media) throws -> Int64 {
        var s = SourceRecord(path: tmp.appendingPathComponent(name).path, kind: kind, projectId: project)
        try store.db.write { db in try s.insert(db) }
        return s.id!
    }

    /// A processed photo with one face of `person` (nil = waiting to be grouped).
    @discardableResult
    func photo(_ name: String, source: Int64, person: Int64?, vector: [Float] = [Float](repeating: 0.1, count: 512)) throws -> (media: Int64, face: Int64) {
        var m = MediaRecord(sourceId: source, path: tmp.appendingPathComponent(name).path, kind: .photo, size: 100, mtime: 0, contentKey: name)
        m.status = .done; m.width = 1500; m.height = 1000
        try store.db.write { db in try m.insert(db) }
        var f = FaceRecord(id: nil, mediaId: m.id!, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                           embedding: Vector.encode(Vector.normalized(vector)), track: nil, personId: person,
                           assignment: person == nil ? .none : .auto, rejectedPersonId: nil)
        try store.db.write { db in try f.insert(db) }
        return (m.id!, f.id!)
    }

    func person(_ name: String?) throws -> Int64 {
        var p = PersonRecord(name: name)
        try store.db.write { db in try p.insert(db) }
        return p.id!
    }

    func testFoldersFromBeforeProjectsBecomeTheFirstProject() throws {
        let dir = tmp.appendingPathComponent("old")
        let db = try DatabaseQueue(path: tmp.appendingPathComponent("old.sqlite").path)
        try LibraryStore.migrator.migrate(db, upTo: "v4-albums-delivery")
        try db.write { db in
            try db.execute(sql: "INSERT INTO source (path, kind, addedAt) VALUES (?, 'media', ?), (?, 'reference', ?)",
                           arguments: [dir.appendingPathComponent("Gala").path, Date(), dir.appendingPathComponent("Known").path, Date()])
            try db.execute(sql: "INSERT INTO smartAlbum (name, query, createdAt) VALUES ('A', '{}', ?)", arguments: [Date()])
        }
        try LibraryStore.migrator.migrate(db)
        try db.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM project"), ["Gala"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE projectId IS NOT NULL"), 1, "known-people folders stay shared")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM smartAlbum WHERE projectId IS NOT NULL"), 1)
        }
    }

    func testEveryFeatureSeesOnlyTheOpenProject() throws {
        let gala = try project("Gala"), cup = try project("Cup")
        let sGala = try source("Gala", project: gala), sCup = try source("Cup", project: cup)
        let an = try person("An")
        try photo("Gala/1.jpg", source: sGala, person: an)
        try photo("Gala/2.jpg", source: sGala, person: an)
        try photo("Cup/1.jpg", source: sCup, person: an)

        var q = MediaQuery(); q.people = [an]
        XCTAssertEqual(try q.run(store).count, 3, "nil = every project")
        q.project = cup
        XCTAssertEqual(try q.run(store).map { ($0.path as NSString).lastPathComponent }, ["1.jpg"])
        XCTAssertEqual(try Selection.files(store, personIds: [an], kind: .photo, topN: nil, bestOfBurst: false, project: gala).count, 2)
        var opts = Exporter.Options(); opts.project = gala
        XCTAssertEqual(try Exporter(store: store).plan(personId: an, name: "An", base: tmp, options: opts).items.count, 2)
        XCTAssertEqual(try Exporter(store: store).planAll(people: [(an, "An")], base: tmp, mode: .copy, options: opts).items.count, 2)
        XCTAssertEqual(try GalleryData(store: store, project: cup).people().first?.photos, 1)

        // Delivery rules for one project ignore the others.
        let rules = DeliveryService(store: store)
        try rules.add(DeliveryRule(personId: nil, folder: nil, recipe: nil, writeNames: false, projectId: cup), includeExisting: true)
        XCTAssertEqual(try rules.run().newFiles["An"], 1)
    }

    func testNameGivenInOneProjectIsRecognisedInTheNext() throws {
        let gala = try project("Gala"), cup = try project("Cup")
        let sGala = try source("Gala", project: gala), sCup = try source("Cup", project: cup)
        var rng = SplitMix(seed: 3)
        let face = Vector.normalized((0..<512).map { _ in Float(rng.gaussian()) })
        func near() -> [Float] { Vector.normalized(face.map { $0 + 0.5 * Float(rng.gaussian()) / Float(512).squareRoot() }) }
        // Three photos in the first event form a group, which the user names.
        for i in 0..<3 { try photo("Gala/\(i).jpg", source: sGala, person: nil, vector: near()) }
        let engine = GroupingEngine(store: store)
        try engine.rebuildAll()
        try engine.recluster()
        let pid = try XCTUnwrap(try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM person") })
        try store.db.write { db in try db.execute(sql: "UPDATE person SET name = 'Mỹ Tâm' WHERE id = ?", arguments: [pid]) }
        // A new event: her face is named on arrival, no naming needed.
        let new = try photo("Cup/1.jpg", source: sCup, person: nil, vector: near())
        try engine.assignPending(mediaIds: [new.media])
        XCTAssertEqual(try store.db.read { db in try FaceRecord.fetchOne(db, key: new.face)!.personId }, pid)
    }

    func testClusteringKeepsEachProjectsNewGroupsApart() throws {
        let gala = try project("Gala"), cup = try project("Cup")
        let sGala = try source("Gala", project: gala), sCup = try source("Cup", project: cup)
        var rng = SplitMix(seed: 9)
        let a = Vector.normalized((0..<512).map { _ in Float(rng.gaussian()) })
        let b = Vector.normalized((0..<512).map { _ in Float(rng.gaussian()) })
        func near(_ v: [Float]) -> [Float] { Vector.normalized(v.map { $0 + 0.5 * Float(rng.gaussian()) / Float(512).squareRoot() }) }
        for i in 0..<3 { try photo("Gala/a\(i).jpg", source: sGala, person: nil, vector: near(a)) }
        for i in 0..<3 { try photo("Cup/b\(i).jpg", source: sCup, person: nil, vector: near(b)) }
        // One face of the Gala person in the Cup folders: too few to form a group there, but it is recognised as
        // the person grouped at the Gala.
        let stray = try photo("Cup/a.jpg", source: sCup, person: nil, vector: near(a))
        let engine = GroupingEngine(store: store)
        try engine.recluster()
        let groups = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT personId, COUNT(*) AS n FROM face WHERE personId IS NOT NULL GROUP BY personId").map { $0["n"] as Int }
        }
        XCTAssertEqual(groups.sorted(), [3, 4])
        let galaPerson = try store.db.read { db in
            try Int64.fetchOne(db, sql: "SELECT f.personId FROM face f JOIN media m ON m.id = f.mediaId WHERE m.path LIKE '%Gala/a0.jpg'")
        }
        XCTAssertEqual(try store.db.read { db in try FaceRecord.fetchOne(db, key: stray.face)!.personId }, galaPerson)
    }

    func testAFolderBelongsToOneProject() throws {
        let gala = try project("Gala")
        _ = try source("Event", project: gala)
        XCTAssertThrowsError(try LibraryService.checkNewFolder(tmp.appendingPathComponent("Event").path, store: store)) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("Gala") ?? false)
        }
        XCTAssertThrowsError(try LibraryService.checkNewFolder(tmp.appendingPathComponent("Event/Day 2").path, store: store))
        XCTAssertThrowsError(try LibraryService.checkNewFolder(tmp.path, store: store))
        XCTAssertNoThrow(try LibraryService.checkNewFolder(tmp.appendingPathComponent("Event 2").path, store: store))
    }
}
