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

    /// The Files browser: only the project's files, with the names in them; copies show the original's people.
    func testProjectFilesListsTheProjectsFilesByFolder() throws {
        let gala = try project("Gala"), other = try project("Other")
        let g = try source("Gala", project: gala), o = try source("Other", project: other)
        let known = try source("Known", project: nil, kind: .reference)
        let an = try person("An"), unnamed = try person(nil)
        let first = try photo("Gala/Stage/1.jpg", source: g, person: an)
        try photo("Gala/Stage/Close/2.jpg", source: g, person: unnamed)
        try photo("Gala/3.jpg", source: g, person: nil)
        try photo("Other/4.jpg", source: o, person: an)
        try photo("Known/An/5.jpg", source: known, person: an)
        var copy = MediaRecord(sourceId: g, path: tmp.appendingPathComponent("Gala/Copy of 1.jpg").path, kind: .photo, size: 100, mtime: 0, contentKey: "1")
        copy.duplicateOf = first.media
        try store.db.write { db in try copy.insert(db) }

        let files = try store.db.read { db in try ProjectFiles.list(db, project: gala) }
        XCTAssertEqual(files.map(\.name).sorted(), ["1.jpg", "2.jpg", "3.jpg", "Copy of 1.jpg"])
        XCTAssertEqual(files.first { $0.name == "1.jpg" }?.people, ["An"])
        let unnamedOnly = try XCTUnwrap(files.first { $0.name == "2.jpg" })
        XCTAssertEqual(unnamedOnly.people, [])
        XCTAssertEqual(unnamedOnly.faces, 1)
        let dup = try XCTUnwrap(files.first { $0.duplicate })
        XCTAssertEqual(dup.people, ["An"])

        let root = tmp.appendingPathComponent("Gala").path
        let top = ProjectFiles.contents(of: root, in: files)
        XCTAssertEqual(top.folders, [root + "/Stage": 2])
        XCTAssertEqual(top.files.map(\.name).sorted(), ["3.jpg", "Copy of 1.jpg"])
        XCTAssertEqual(ProjectFiles.contents(of: root + "/Stage", in: files).folders, [root + "/Stage/Close": 1])
        XCTAssertEqual(ProjectFiles.contents(of: root, in: files, recursive: true).files.count, 4)
        // A folder whose name starts like another's is not inside it.
        XCTAssertTrue(ProjectFiles.contents(of: root + "/Sta", in: files).files.isEmpty)
        XCTAssertEqual(try store.db.read { db in try ProjectFiles.list(db, project: nil) }.count, 5)
    }

    /// Culling marks and the closed-eyes / soft-focus hints come with each file.
    func testProjectFilesCarryMarksAndHints() throws {
        let gala = try project("Gala"), g = try source("Gala", project: gala)
        let an = try person("An")
        let sharp = try photo("Gala/1.jpg", source: g, person: an), blink = try photo("Gala/2.jpg", source: g, person: nil)
        let small = try photo("Gala/3.jpg", source: g, person: nil)
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET eyesOpen = 0.9, sharpness = 800 WHERE id = ?", arguments: [sharp.face])
            try db.execute(sql: "UPDATE face SET eyesOpen = 0.1, sharpness = 30 WHERE id = ?", arguments: [blink.face])
            // A tiny face in the crowd says nothing about the shot.
            try db.execute(sql: "UPDATE face SET eyesOpen = 0.1, sharpness = 30, w = 0.01, h = 0.01 WHERE id = ?", arguments: [small.face])
            try Marks.apply(.rating(5), to: [sharp.media], db: db)
            try Marks.apply(.label(.red), to: [sharp.media, blink.media], db: db)
            try Marks.apply(.flag(.reject), to: [blink.media], db: db)
            try Marks.apply(.rating(9), to: [blink.media], db: db)
        }
        let files = Dictionary(uniqueKeysWithValues: try store.db.read { db in try ProjectFiles.list(db, project: gala) }.map { ($0.name, $0) })
        XCTAssertEqual(files["1.jpg"]?.rating, 5)
        XCTAssertEqual(files["1.jpg"]?.label, .red)
        XCTAssertEqual(files["1.jpg"]?.flag, PickFlag.none)
        XCTAssertEqual(files["1.jpg"]?.personIds, [an])
        XCTAssertEqual(files["1.jpg"].map { [$0.eyesClosed, $0.soft] }, [false, false])
        XCTAssertEqual(files["2.jpg"]?.flag, .reject)
        XCTAssertEqual(files["2.jpg"]?.rating, 5, "ratings stop at five stars")
        XCTAssertEqual(files["2.jpg"].map { [$0.eyesClosed, $0.soft] }, [true, true])
        XCTAssertEqual(files["3.jpg"].map { [$0.eyesClosed, $0.soft] }, [false, false])
        XCTAssertEqual(try store.db.read { db in try ProjectFiles.faces(db, mediaId: sharp.media) }.map(\.name), ["An"])
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

    /// The real upgrade (foreign keys off while it runs): lists from before go to the projects their people appear
    /// in, and the library opens.
    func testListsFromBeforeProjectsGoToTheirProjects() throws {
        let db = try DatabaseQueue(path: tmp.appendingPathComponent("lists.sqlite").path)
        try LibraryStore.migrator.migrate(db, upTo: "v28-person-tags")
        try db.write { db in
            let now = Date()
            try db.execute(sql: "INSERT INTO project (id, name, createdAt, uuid) VALUES (1, 'Gala', ?, 'gala'), (2, 'Cup', ?, 'cup')",
                           arguments: [now.addingTimeInterval(-60), now])
            try db.execute(sql: "INSERT INTO source (id, path, kind, addedAt, projectId) VALUES (1, '/Gala', 'media', ?, 1), (2, '/Cup', 'media', ?, 2)",
                           arguments: [now, now])
            try db.execute(sql: "INSERT INTO person (id, name, createdAt, uuid) VALUES (1, 'An', ?, 'an'), (2, 'Bình', ?, 'binh'), (3, 'Cẩm', ?, 'cam')",
                           arguments: [now, now, now])
            for (media, source, person) in [(1, 1, 1), (2, 1, 2), (3, 2, 2)] {
                try db.execute(sql: "INSERT INTO media (id, sourceId, path, kind, size, mtime, status) VALUES (?, ?, ?, 'photo', 1, 0, 'done')",
                               arguments: [media, source, "/\(media).jpg"])
                try db.execute(sql: "INSERT INTO face (mediaId, x, y, w, h, personId, assignment) VALUES (?, 0, 0, 1, 1, ?, 'user')",
                               arguments: [media, person])
            }
            try db.execute(sql: "INSERT INTO personGroup (id, name, sortOrder, createdAt, uuid) VALUES (1, 'Cast', 0, ?, 'cast'), (2, 'VIP', 1, ?, 'vip')",
                           arguments: [now, now])
            try db.execute(sql: "INSERT INTO personGroupMember (groupId, personId) VALUES (1, 1), (1, 2), (1, 3), (2, 3)")
        }
        try LibraryStore.migrator.migrate(db)
        try db.read { db in
            let lists = try Row.fetchAll(db, sql: """
                SELECT g.uuid, g.projectId, group_concat(gm.personId) AS people FROM personGroup g
                LEFT JOIN (SELECT * FROM personGroupMember ORDER BY personId) gm ON gm.groupId = g.id GROUP BY g.id ORDER BY g.uuid
                """).map { "\($0["uuid"] as String) \($0["projectId"] as Int64) \($0["people"] as String? ?? "")" }
            XCTAssertEqual(lists, ["cast:cup 2 2", "cast:gala 1 1,2", "vip:cup 2 3"], "no one on VIP appears anywhere: the newest project, with everyone")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personGroupMember WHERE groupId IN (1, 2)"), 0)
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

final class SessionTests: XCTestCase {
    func testSessionsSplitAtGapsKeepNamesAndFilterPeople() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try LibraryStore(directory: tmp)
        var p = ProjectRecord(name: "Cup")
        try store.db.write { db in try p.insert(db) }
        var s = SourceRecord(path: "/Cup", projectId: p.id)
        try store.db.write { db in try s.insert(db) }
        var an = PersonRecord(name: "An"), binh = PersonRecord(name: "Bình")
        try store.db.write { db in try an.insert(db); try binh.insert(db) }
        // Opening 10:00-10:20, awards 14:00-14:05 (a 3.5 h pause in between).
        let day = 1_790_000_000.0
        let shots: [(Double, Int64)] = [(0, an.id!), (600, an.id!), (1200, binh.id!), (4 * 3600, binh.id!), (4 * 3600 + 300, binh.id!)]
        for (i, (t, pid)) in shots.enumerated() {
            var m = MediaRecord(sourceId: s.id, path: "/Cup/\(i).jpg", kind: .photo, size: 1, mtime: 0, contentKey: "\(i)")
            m.status = .done; m.takenAt = day + t
            try store.db.write { db in try m.insert(db) }
            var f = FaceRecord(id: nil, mediaId: m.id!, x: 0, y: 0, w: 0.1, h: 0.1, quality: 0.8, time: nil, embedding: nil,
                               track: nil, personId: pid, assignment: .user, rejectedPersonId: nil)
            try store.db.write { db in try f.insert(db) }
        }
        var sessions = try store.db.read { db in try EventSessions.list(db, project: p.id) }
        XCTAssertEqual(sessions.map(\.photos), [3, 2])

        try EventSessions.setName(store, project: p.id!, session: sessions[1], name: "Awards")
        // A later file extends the session; its name stays.
        var late = MediaRecord(sourceId: s.id, path: "/Cup/late.jpg", kind: .photo, size: 1, mtime: 0, contentKey: "late")
        late.status = .done; late.takenAt = day + 4 * 3600 + 900
        try store.db.write { db in try late.insert(db) }
        sessions = try store.db.read { db in try EventSessions.list(db, project: p.id) }
        XCTAssertEqual(sessions.map(\.name), [nil, "Awards"])
        XCTAssertEqual(sessions[1].photos, 3)

        // Who is in the awards session, and their files only.
        let awards = sessions[1].range
        XCTAssertEqual(Set(try Selection.files(store, personIds: [an.id!, binh.id!], kind: nil, topN: nil, bestOfBurst: false,
                                               project: p.id, taken: awards).map(\.personName)), ["Bình"])
        var opts = Exporter.Options(); opts.taken = sessions[0].range
        XCTAssertEqual(try Exporter(store: store).plan(personId: binh.id!, name: "Bình", base: tmp, options: opts).items.count, 1)
        // Wider gaps merge the two sessions.
        XCTAssertEqual(try store.db.read { db in try EventSessions.list(db, project: p.id, gap: 5 * 3600) }.count, 1)
    }
}
