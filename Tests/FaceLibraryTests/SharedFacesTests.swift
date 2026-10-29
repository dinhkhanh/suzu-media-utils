import FaceCore
import GRDB
import MediaKit
import XCTest
@testable import FaceLibrary

/// One Mac processes faces for the team; the others take its results (see SharedFaces).
final class SharedFacesTests: XCTestCase {
    var tmp: URL!
    var shared: URL!
    var a: TeamSyncTests.Mac!
    var b: TeamSyncTests.Mac!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("shared-\(UUID().uuidString)")
        shared = tmp.appendingPathComponent("NAS/Gala Team", isDirectory: true)
        a = try TeamSyncTests.Mac(tmp.appendingPathComponent("A"), name: "Studio")
        b = try TeamSyncTests.Mac(tmp.appendingPathComponent("B"), name: "Laptop")
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        let team = try b.sync.join(folder: shared)
        exchange()
        let uuid = try a.projectUuid()
        let bp = try XCTUnwrap(try b.store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM project WHERE uuid = ?", arguments: [uuid]) })
        try b.store.db.write { db in try db.execute(sql: "UPDATE source SET projectId = ? WHERE id = ?", arguments: [bp, b.source]) }
        b.project = bp
        _ = team
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func exchange() {
        for _ in 0..<4 {
            a.sync.pushSoon(); b.sync.pushSoon()
            a.sync.syncNow(); b.sync.syncNow()
            a.settle(); b.settle()
        }
    }

    func vector(_ seed: Int) -> [Float] {
        var x = UInt64(seed &* 2654435761)
        return (0..<512).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: x >> 11) % 1000) / 1000 - 0.5
        }
    }

    /// A processed photo on A with a crop on disk, queued for publishing as the processor would.
    @discardableResult
    func processed(_ name: String, person: Int64?, vector: [Float], quality: Double = 0.8) throws -> (media: Int64, face: Int64) {
        let (m, f) = try a.photo(name, person: person, vector: vector, assignment: person == nil ? .none : .auto)
        try Data("crop".utf8).write(to: a.store.faceCropURL(f))
        // Distinct bytes per file (the helper's differ only by first letter) and the real content key, so B's copy
        // of the same bytes matches it and nothing else.
        try Self.bytes(name).write(to: a.root.appendingPathComponent(name))
        let key = ContentKey.compute(a.root.appendingPathComponent(name), size: 2048)
        try a.store.db.write { db in
            try db.execute(sql: "UPDATE media SET contentKey = ? WHERE id = ?", arguments: [key, m])
            try db.execute(sql: "INSERT OR IGNORE INTO facePublish (mediaId) VALUES (?)", arguments: [m])
        }
        return (m, f)
    }

    /// The same file waiting on B (same bytes, so the same content key), as B's scan would leave it.
    @discardableResult
    func waiting(_ name: String) throws -> Int64 {
        let url = b.root.appendingPathComponent(name)
        try Self.bytes(name).write(to: url)
        var m = MediaRecord(sourceId: b.source, path: url.path, kind: .photo, size: 2048, mtime: 0, contentKey: nil)
        try b.store.db.write { db in try m.insert(db) }
        return m.id!
    }

    static func bytes(_ name: String) -> Data {
        var d = Data()
        while d.count < 2048 { d += Data(name.utf8) }
        return d.prefix(2048)
    }

    func faces(_ mac: TeamSyncTests.Mac, media: Int64) throws -> [FaceRecord] {
        try mac.store.db.read { db in try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ? ORDER BY id", arguments: [media]) }
    }

    func testTheProcessingMacsFacesAppearOnTheOthers() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        exchange()
        let bt = try XCTUnwrap(try b.sync.teams().first)
        XCTAssertEqual(bt.processorId, a.sync.deviceId, "B knows which Mac processes")
        XCTAssertEqual(bt.processorName, "Studio")
        XCTAssertFalse(b.sync.processesLocally(project: b.project))
        XCTAssertTrue(a.sync.processesLocally(project: a.project))
        XCTAssertEqual(b.sync.passiveProjects(), [b.project])

        // A processes two photos: one of a named person, one of an unnamed group.
        let an = try a.person("An")
        let group = try a.person(nil)
        let (m1, f1) = try processed("p1.jpg", person: an, vector: vector(1))
        let (m2, _) = try processed("p2.jpg", person: group, vector: vector(2))
        a.engine.peopleChanged([an, group]); a.settle()
        // B has the same files waiting (one before the record arrives, one after).
        let w1 = try waiting("p1.jpg")
        exchange()
        let bf1 = try faces(b, media: w1)
        XCTAssertEqual(bf1.count, 1, "B took A's faces for the file it had waiting")
        XCTAssertEqual(try b.store.db.read { db in try String.fetchOne(db, sql: "SELECT status FROM media WHERE id = ?", arguments: [w1]) }, "done")
        XCTAssertEqual(try b.store.db.read { db in try String?.fetchOne(db, sql: "SELECT importedFrom FROM media WHERE id = ?", arguments: [w1]) } ?? nil, a.sync.deviceId)
        XCTAssertEqual(try b.personId(named: "An"), bf1[0].personId, "with the same person, by stable id")
        XCTAssertEqual(bf1[0].assignment, .auto)
        XCTAssertEqual(bf1[0].vector?.count, 512)
        XCTAssertEqual(try Data(contentsOf: b.store.faceCropURL(bf1[0].id!)), Data("crop".utf8), "and the crop")
        _ = m1

        let w2 = try waiting("p2.jpg")
        exchange()
        let bf2 = try faces(b, media: w2)
        XCTAssertEqual(bf2.count, 1, "a file that turned up after its record was published is matched from the index")
        let groupUuid = try a.uuid(group)
        XCTAssertEqual(try b.store.db.read { db in try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [bf2[0].personId!]) }, groupUuid,
                       "an unnamed group is the same group on B")
        XCTAssertEqual(try b.people().count, 2)

        // Grouping moves on A (the face joins An): B follows without re-reading the embeddings.
        try a.store.db.write { db in try db.execute(sql: "UPDATE face SET personId = ?, assignment = 'auto' WHERE mediaId = ?", arguments: [an, m2]) }
        a.sync.lock.withLock { a.sync.facesPublishedAt = [:] }
        exchange()
        XCTAssertEqual(try faces(b, media: w2)[0].personId, try b.personId(named: "An"))

        // B's own engine leaves the waiting faces alone and never clusters A's project.
        let w3 = try waiting("p3.jpg")
        b.engine.reclusterNow(); b.settle()
        XCTAssertEqual(try faces(b, media: w3).count, 0)
    }

    func testARejectionOnALaptopReachesTheProcessingMacAndComesBack() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An")
        let (m1, af) = try processed("p1.jpg", person: an, vector: vector(1))
        a.engine.peopleChanged([an]); a.settle()
        let w1 = try waiting("p1.jpg")
        exchange()
        let bf = try faces(b, media: w1)
        XCTAssertEqual(bf.count, 1)

        // "Not this person" on B.
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        try b.store.db.write { db in
            try db.execute(sql: "UPDATE face SET personId = NULL, assignment = 'user', rejectedPersonId = ? WHERE id = ?", arguments: [bAn, bf[0].id])
            try db.execute(sql: "INSERT INTO faceEditPublish (faceId) VALUES (?)", arguments: [bf[0].id])
        }
        exchange()
        let aFace = try XCTUnwrap(try a.store.db.read { db in try FaceRecord.fetchOne(db, key: af) })
        XCTAssertNil(aFace.personId, "A applied the rejection")
        XCTAssertEqual(aFace.assignment, .user)
        XCTAssertEqual(aFace.rejectedPersonId, an)
        _ = m1
        // And A's republished record keeps B where it is (no flip back).
        a.sync.lock.withLock { a.sync.facesPublishedAt = [:] }
        exchange()
        let bAgain = try faces(b, media: w1)[0]
        XCTAssertNil(bAgain.personId)
        XCTAssertEqual(bAgain.rejectedPersonId, bAn)
    }

    func testAPickedPictureTravelsAndSoDoesPuttingItBack() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An")
        let (_, f1) = try processed("p1.jpg", person: an, vector: vector(1))
        let (_, f2) = try processed("p2.jpg", person: an, vector: vector(1))
        a.engine.peopleChanged([an]); a.settle()
        let w1 = try waiting("p1.jpg"), w2 = try waiting("p2.jpg")
        exchange()
        _ = f1
        // A picks the second photo's face as An's picture.
        try a.store.db.write { db in try db.execute(sql: "UPDATE person SET coverFaceId = ?, coverAt = ? WHERE id = ?", arguments: [f2, 1_700_000_100, an]) }
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        let bf2 = try faces(b, media: w2)[0]
        XCTAssertEqual(try b.store.db.read { db in try Int64?.fetchOne(db, sql: "SELECT coverFaceId FROM person WHERE id = ?", arguments: [bAn]) } ?? nil, bf2.id,
                       "B shows the same face as An's picture")
        _ = w1
        // Back to automatic on A: B follows; an older pick doesn't override.
        try a.store.db.write { db in try db.execute(sql: "UPDATE person SET coverFaceId = NULL, coverAt = ? WHERE id = ?", arguments: [1_700_000_200, an]) }
        exchange()
        XCTAssertNil(try b.store.db.read { db in try Int64?.fetchOne(db, sql: "SELECT coverFaceId FROM person WHERE id = ?", arguments: [bAn]) } ?? nil)
    }

    /// Hybrid: the laptop copying cards processes its own card's files and sends the faces; the Studio takes them
    /// for the file it has waiting (no read from the share), groups them, and sends the file back with the people;
    /// the laptop takes that grouping for the very faces it found.
    func testACopyingMacsOwnWorkReachesTheProcessingMacAndComesBackGrouped() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        exchange()
        XCTAssertFalse(b.sync.processesLocally(project: b.project))
        XCTAssertEqual(a.sync.processingGrace(sourceId: a.source), 0, "nobody is sending yet: the Studio reads fresh files at once")
        // B processed c1.jpg itself off a card (localWork), nobody assigned; queued for publishing as the processor would be.
        let (bm, bf) = try b.photo("c1.jpg", person: nil, vector: vector(5))
        try Data("crop".utf8).write(to: b.store.faceCropURL(bf))
        try Self.bytes("c1.jpg").write(to: b.root.appendingPathComponent("c1.jpg"))
        let key = ContentKey.compute(b.root.appendingPathComponent("c1.jpg"), size: 2048)
        try b.store.db.write { db in
            try db.execute(sql: "UPDATE media SET contentKey = ?, localWork = 1 WHERE id = ?", arguments: [key, bm])
            try db.execute(sql: "INSERT OR IGNORE INTO facePublish (mediaId) VALUES (?)", arguments: [bm])
        }
        // A's scan found the same file on the share, waiting.
        let url = a.root.appendingPathComponent("c1.jpg")
        try Self.bytes("c1.jpg").write(to: url)
        var am = MediaRecord(sourceId: a.source, path: url.path, kind: .photo, size: 2048, mtime: 0, contentKey: nil)
        try a.store.db.write { db in try am.insert(db) }
        exchange()
        func media(_ mac: TeamSyncTests.Mac, _ id: Int64) throws -> (status: String, from: String?) {
            try mac.store.db.read { db in
                let r = try Row.fetchOne(db, sql: "SELECT status, importedFrom FROM media WHERE id = ?", arguments: [id])!
                return (r["status"], r["importedFrom"])
            }
        }
        let af = try faces(a, media: am.id!)
        XCTAssertEqual(af.count, 1, "A took B's faces instead of reading the file")
        XCTAssertEqual(try media(a, am.id!).status, "done")
        XCTAssertEqual(try media(a, am.id!).from, b.sync.deviceId)
        XCTAssertNil(af[0].personId)
        XCTAssertEqual(try Data(contentsOf: a.store.faceCropURL(af[0].id!)), Data("crop".utf8))
        XCTAssertEqual(a.sync.processingGrace(sourceId: a.source), TeamSync.copierGrace, "a copier is sending: fresh files get a moment")
        XCTAssertEqual(b.sync.processingGrace(sourceId: b.source), 0, "only the processing Mac waits")
        // A groups the face (here by hand, as its engine would): An.
        let an = try a.person("An")
        try a.store.db.write { db in try db.execute(sql: "UPDATE face SET personId = ?, assignment = 'auto' WHERE id = ?", arguments: [an, af[0].id]) }
        a.sync.lock.withLock { a.sync.facesPublishedAt = [:] }
        exchange()
        let bFaces = try faces(b, media: bm)
        XCTAssertEqual(bFaces.map(\.id), [bf], "the same face B found, not replaced")
        XCTAssertEqual(bFaces[0].personId, try b.personId(named: "An"), "with A's grouping")
        XCTAssertEqual(try media(b, bm).from, a.sync.deviceId, "A's record is the truth for it from here on")
        XCTAssertEqual(try b.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facePublish") }, 0, "B published once and keeps no queue")
        // A's own work is never overwritten by a copier's record.
        let (am2, _) = try processed("p9.jpg", person: an, vector: vector(9))
        let (bm2, _) = try b.photo("p9.jpg", person: nil, vector: vector(9))
        try Self.bytes("p9.jpg").write(to: b.root.appendingPathComponent("p9.jpg"))
        try b.store.db.write { db in
            try db.execute(sql: "UPDATE media SET contentKey = ?, localWork = 1 WHERE id = ?", arguments: [ContentKey.compute(b.root.appendingPathComponent("p9.jpg"), size: 2048), bm2])
            try db.execute(sql: "INSERT OR IGNORE INTO facePublish (mediaId) VALUES (?)", arguments: [bm2])
        }
        exchange()
        XCTAssertEqual(try faces(a, media: am2)[0].personId, an)
        XCTAssertNil(try media(a, am2).from)
        XCTAssertEqual(try faces(b, media: bm2)[0].personId, try b.personId(named: "An"), "and B gets A's grouping of its own faces")
    }

    func records() -> Int {
        let dir = TeamSync.facesURL(shared, device: a.sync.deviceId)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.reduce(0) { n, f in
            n + ((try? Data(contentsOf: f)).map { $0.split(separator: 0x0A).count } ?? 0)
        }
    }

    /// Faces found again on A: the old ones go, these come, queued for publishing as the processor would.
    func redetect(_ media: Int64, _ faces: [(x: Double, person: Int64?, crop: String)]) throws {
        try a.store.db.write { db in
            try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [media])
            for f in faces {
                var r = FaceRecord(id: nil, mediaId: media, x: f.x, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                                   embedding: Vector.encode(Vector.normalized(vector(Int(f.x * 100)))), track: nil, personId: f.person,
                                   assignment: f.person == nil ? .none : .auto, rejectedPersonId: nil)
                try r.insert(db)
                try Data(f.crop.utf8).write(to: a.store.faceCropURL(r.id!))
            }
        }
    }

    /// The same two people found again in the other order: B must put each name on the right face (it used to
    /// pair them by position) and show the new crops (the old ones stayed on the share, numbered as before).
    func testFacesFoundAgainInAnotherOrderKeepTheirPeople() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An"), bo = try a.person("Bo")
        let (m, _) = try processed("p1.jpg", person: nil, vector: vector(1))
        try redetect(m, [(0.1, an, "an"), (0.6, bo, "bo")])
        let w = try waiting("p1.jpg")
        exchange()
        func onB() throws -> [(x: Double, name: String?, crop: String)] {
            try faces(b, media: w).map { f in
                let name = try b.store.db.read { db in try String?.fetchOne(db, sql: "SELECT name FROM person WHERE id = ?", arguments: [f.personId]) } ?? nil
                return (f.x, name, String(decoding: (try? Data(contentsOf: b.store.faceCropURL(f.id!))) ?? Data(), as: UTF8.self))
            }
        }
        XCTAssertEqual(try onB().map(\.name), ["An", "Bo"])
        try redetect(m, [(0.6, bo, "bo2"), (0.1, an, "an2")])
        try a.store.db.write { db in try db.execute(sql: "INSERT OR IGNORE INTO facePublish (mediaId) VALUES (?)", arguments: [m]) }
        exchange()
        let after = try onB()
        XCTAssertEqual(after.map(\.x), [0.6, 0.1], "B has the faces as found now")
        XCTAssertEqual(after.map(\.name), ["Bo", "An"], "each with its own person")
        XCTAssertEqual(after.map(\.crop), ["bo2", "an2"], "and its own picture")
    }

    /// Whatever emptied a queue (the role changing hands mid-pass, an edited folder dropping faces), the processing
    /// Mac notices the file no longer matches what it published and sends it again.
    func testAFileThatDriftedWithoutBeingQueuedIsPublishedAgain() throws {
        // Every pass goes round (the processing Mac rests between rounds).
        TeamSync.faceSweepRest = 0
        defer { TeamSync.faceSweepRest = 600 }
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An")
        let (m, _) = try processed("p1.jpg", person: an, vector: vector(1))
        try processed("p2.jpg", person: an, vector: vector(2))
        let w = try waiting("p1.jpg")
        exchange()
        XCTAssertEqual(try faces(b, media: w).count, 1)
        let before = records()
        // The face moved to Bo on A, and the queues were emptied.
        let bo = try a.person("Bo")
        try a.store.db.write { db in
            try db.execute(sql: "UPDATE face SET personId = ? WHERE mediaId = ?", arguments: [bo, m])
            try db.execute(sql: "DELETE FROM facePublish")
            try db.execute(sql: "DELETE FROM faceChange")
        }
        exchange()
        XCTAssertEqual(try faces(b, media: w)[0].personId, try b.personId(named: "Bo"), "B follows anyway")
        XCTAssertEqual(records(), before + 1, "only the file that drifted went again")
        // Faces gone without the file being processed again: not sent (it would take good faces off B).
        try a.store.db.write { db in try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [m]) }
        exchange()
        XCTAssertEqual(records(), before + 1)
        XCTAssertEqual(try faces(b, media: w).count, 1)
        // A library from before: it learns what it published by reading its records back, and sends nothing more.
        try a.store.db.write { db in
            try db.execute(sql: "DELETE FROM facePublished")
            try db.execute(sql: "DELETE FROM syncState WHERE key LIKE 'pubseed%' OR key = 'pubsweep'")
        }
        exchange()
        XCTAssertEqual(records(), before + 1)
        XCTAssertEqual(try a.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facePublished WHERE fromShare") }, 2)
        XCTAssertEqual(try a.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facePublish") }, 0)
    }

    /// The comparison with the team folder rests between rounds: a drifted file is caught by the next round, not
    /// on every pass.
    func testTheDriftCheckRestsBetweenRounds() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An")
        let (m, _) = try processed("p1.jpg", person: an, vector: vector(1))
        let w = try waiting("p1.jpg")
        exchange()
        let bo = try a.person("Bo")
        try a.store.db.write { db in
            try db.execute(sql: "UPDATE face SET personId = ? WHERE mediaId = ?", arguments: [bo, m])
            try db.execute(sql: "DELETE FROM facePublish")
            try db.execute(sql: "DELETE FROM faceChange")
        }
        exchange()
        XCTAssertEqual(try faces(b, media: w)[0].personId, try b.personId(named: "An"), "a round just went by: resting")
        TeamSync.faceSweepRest = 0
        defer { TeamSync.faceSweepRest = 600 }
        exchange()
        XCTAssertEqual(try faces(b, media: w)[0].personId, try b.personId(named: "Bo"), "the next round catches it")
    }

    /// A Mac that took a laptop's ungrouped record after the processing Mac's (logs read in any order) keeps the
    /// processing Mac's people.
    func testAnUngroupedRecordReadLaterDoesntUndoTheGrouping() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An")
        let (m, _) = try processed("p1.jpg", person: an, vector: vector(1))
        let w = try waiting("p1.jpg")
        exchange()
        // A third Mac's ungrouped record of the same file, in the team folder after A's.
        let other = TeamSync.facesURL(shared, device: "zz-copier")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var (payload, _) = try XCTUnwrap(try a.sync.payload(for: m))
        payload.faces = payload.faces.map { var f = $0; f.p = nil; f.a = "none"; return f }
        try (try JSONEncoder().encode(payload) + Data("\n".utf8)).write(to: other.appendingPathComponent("media-0001.jsonl"))
        exchange()
        XCTAssertEqual(try faces(b, media: w)[0].personId, try b.personId(named: "An"))
        let teamId = try XCTUnwrap(try b.sync.teams().first?.id)
        XCTAssertEqual(try b.store.db.read { db in try String.fetchOne(db, sql: "SELECT deviceId FROM faceIndex WHERE teamId = ?", arguments: [teamId]) },
                       a.sync.deviceId)
    }

    func testPinsTravelBothWays() throws {
        let an = try a.person("An")
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        func pinned(_ mac: TeamSyncTests.Mac, _ pid: Int64) throws -> Bool {
            try mac.store.db.read { db in try Bool.fetchOne(db, sql: "SELECT pinnedAt IS NOT NULL FROM person WHERE id = ?", arguments: [pid]) } ?? false
        }
        try a.store.db.write { db in try PersonGroups.pin([an], true, db: db) }
        exchange()
        XCTAssertTrue(try pinned(b, bAn))
        Thread.sleep(forTimeInterval: 0.01)
        try b.store.db.write { db in try PersonGroups.pin([bAn], false, db: db) }
        exchange()
        XCTAssertFalse(try pinned(a, an), "unpinned on B, unpinned on A")
        XCTAssertFalse(try pinned(b, bAn))
    }

    func testNotesOnPeopleTravelBothWays() throws {
        let an = try a.person("An")
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        func bio(_ mac: TeamSyncTests.Mac, _ pid: Int64) throws -> String? {
            try mac.store.db.read { db in try String.fetchOne(db, sql: "SELECT bio FROM person WHERE id = ?", arguments: [pid]) }
        }
        try a.store.db.write { db in try PersonGroups.setBio(an, "  Singer ", db: db) }
        XCTAssertEqual(try bio(a, an), "Singer")
        exchange()
        XCTAssertEqual(try bio(b, bAn), "Singer")
        Thread.sleep(forTimeInterval: 0.01)
        try b.store.db.write { db in try PersonGroups.setBio(bAn, "Singer, actress", db: db) }
        exchange()
        XCTAssertEqual(try bio(a, an), "Singer, actress", "edited on B, edited on A")
        Thread.sleep(forTimeInterval: 0.01)
        try a.store.db.write { db in try PersonGroups.setBio(an, "", db: db) }
        exchange()
        XCTAssertNil(try bio(b, bAn), "cleared on A, cleared on B")
    }

    /// A list is one project's: the same name in another project is another list, and stays on this Mac when only
    /// the other project is the team's.
    func testAListBelongsToOneProject() throws {
        let an = try a.person("An")
        var other = ProjectRecord(name: "Next event")
        try a.store.db.write { db in try other.insert(db) }
        let (gala, next) = try a.store.db.write { db -> (Int64, Int64) in
            let gala = try PersonGroups.create("Cast", project: a.project, db: db)
            let next = try PersonGroups.create("cast", project: other.id!, db: db)
            try PersonGroups.set(gala, people: [an], member: true, db: db)
            return (gala, next)
        }
        XCTAssertNotEqual(gala, next)
        exchange()
        let onB = try b.store.db.read { db in try Row.fetchAll(db, sql: "SELECT name, projectId FROM personGroup") }
        XCTAssertEqual(onB.count, 1, "the other project isn't the team's")
        XCTAssertEqual(onB.first?["projectId"] as Int64?, b.project)
    }

    /// Lists from before lists were a project's go to the projects their people appear in, with the same id on
    /// every Mac, so the team ends with one copy of each.
    func testOldListsSplitIntoProjectsTheSameOnEveryMac() throws {
        let an = try a.person("An")
        try processed("p1.jpg", person: an, vector: vector(1))
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        let uuid = SyncIds.new()
        for (mac, person) in [(a!, an), (b!, bAn)] {
            try mac.store.db.write { db in
                try db.execute(sql: "INSERT INTO personGroup (name, sortOrder, createdAt, uuid, updatedAt) VALUES ('VIP', 0, ?, ?, 1)", arguments: [Date(), uuid])
                try db.execute(sql: "INSERT INTO personGroupMember (groupId, personId, at) VALUES (?, ?, 1)", arguments: [db.lastInsertedRowID, person])
                try PersonGroups.splitByProject(db: db)
            }
        }
        exchange()
        for (mac, project) in [(a!, a.project), (b!, b.project)] {
            let lists = try mac.store.db.read { db in try Row.fetchAll(db, sql: "SELECT id, uuid, projectId FROM personGroup") }
            XCTAssertEqual(lists.count, 1)
            XCTAssertEqual(lists.first?["projectId"] as Int64?, project)
            XCTAssertEqual(lists.first?["uuid"] as String?, "\(uuid):\(try a.projectUuid())")
        }
        XCTAssertEqual(try a.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personGroupMember WHERE personId = ?", arguments: [an]) }, 1)
    }

    func testTagsAreReusedAndTravelBothWays() throws {
        let an = try a.person("An"), binh = try a.person("Bình")
        try a.store.db.write { db in
            try PersonTags.set("KOL", people: [an], on: true, db: db)
            try PersonTags.set(" kol ", people: [binh], on: true, db: db)
            try PersonTags.set("Singer", people: [an], on: true, db: db)
        }
        XCTAssertEqual(try a.store.db.read { db in try PersonTags.of(binh, db: db) }, ["KOL"], "a tag in use keeps its spelling")
        XCTAssertEqual(try a.store.db.read { db in try PersonTags.all(db: db) }, ["KOL", "Singer"], "the most used first")
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        XCTAssertEqual(try b.store.db.read { db in try PersonTags.of(bAn, db: db) }, ["KOL", "Singer"])
        Thread.sleep(forTimeInterval: 0.01)
        try b.store.db.write { db in try PersonTags.set("Singer", people: [bAn], on: false, db: db) }
        exchange()
        XCTAssertEqual(try a.store.db.read { db in try PersonTags.of(an, db: db) }, ["KOL"], "taken off on B, taken off on A")
        Thread.sleep(forTimeInterval: 0.01)
        try a.store.db.write { db in try PersonTags.set("Singer", people: [an], on: true, db: db) }
        exchange()
        XCTAssertEqual(try b.store.db.read { db in try PersonTags.of(bAn, db: db) }, ["KOL", "Singer"], "and back on")
    }

    func testAMergedPersonKeepsEveryTag() throws {
        let an = try a.person("An"), other = try a.person("Other")
        try a.store.db.write { db in
            try PersonTags.set("Actor", people: [an], on: true, db: db)
            try PersonTags.set("Model", people: [other], on: true, db: db)
            try PersonTags.set("Actor", people: [other], on: true, db: db)
            try PersonNames.merge([other], into: an, db: db)
        }
        XCTAssertEqual(Set(try a.store.db.read { db in try PersonTags.of(an, db: db) }), ["Actor", "Model"])
        XCTAssertEqual(try a.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personTag WHERE personId = ?", arguments: [other]) }, 0)
    }

    func testAMergedPersonKeepsANote() throws {
        let an = try a.person("An"), other = try a.person("Other")
        try a.store.db.write { db in
            try PersonGroups.setBio(other, "Model", db: db)
            try PersonNames.merge([other], into: an, db: db)
        }
        XCTAssertEqual(try a.store.db.read { db in try String.fetchOne(db, sql: "SELECT bio FROM person WHERE id = ?", arguments: [an]) }, "Model")
        let kol = try a.person("Kol")
        try a.store.db.write { db in
            try PersonGroups.setBio(kol, "KOL", db: db)
            try PersonNames.merge([an], into: kol, db: db)
        }
        XCTAssertEqual(try a.store.db.read { db in try String.fetchOne(db, sql: "SELECT bio FROM person WHERE id = ?", arguments: [kol]) }, "KOL",
                       "the survivor's own note stays")
    }

    /// A picture picked on a file whose content key wasn't known yet used to travel as "back to automatic".
    func testAPictureOnAFileWithoutAKeyYetTravels() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An")
        try processed("p1.jpg", person: an, vector: vector(1))
        let (m2, f2) = try processed("p2.jpg", person: an, vector: vector(1))
        try waiting("p1.jpg"); let w2 = try waiting("p2.jpg")
        exchange()
        try a.store.db.write { db in
            try db.execute(sql: "UPDATE media SET contentKey = NULL WHERE id = ?", arguments: [m2])
            try db.execute(sql: "UPDATE person SET coverFaceId = ?, coverAt = ? WHERE id = ?", arguments: [f2, 1_700_000_100, an])
        }
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        XCTAssertEqual(try b.store.db.read { db in try Int64?.fetchOne(db, sql: "SELECT coverFaceId FROM person WHERE id = ?", arguments: [bAn]) } ?? nil,
                       try faces(b, media: w2)[0].id)
    }

    func testSavedWatermarksTravelWithTheirLogos() throws {
        let logo = tmp.appendingPathComponent("A/logo.png")
        try Data("png bytes".utf8).write(to: logo)
        var spec = WatermarkSpec(logoPath: logo.path)
        spec.portraitLogoPath = ""
        let w = SavedWatermark(name: "SuZu", spec: spec)
        try a.store.db.write { db in try SavedWatermarks.save(w, db: db) }
        exchange()
        var onB = try b.store.db.read { db in try SavedWatermarks.all(db) }
        XCTAssertEqual(onB.map(\.name), ["SuZu"])
        XCTAssertNotEqual(onB[0].spec.logoPath, logo.path, "B's own copy of the logo")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: onB[0].spec.logoPath)), Data("png bytes".utf8))
        XCTAssertEqual(onB[0].spec.position, spec.position)

        // Renamed on B: A follows, and the logo isn't copied again under another name.
        Thread.sleep(forTimeInterval: 0.01)
        try b.store.db.write { db in try SavedWatermarks.save(SavedWatermark(id: w.id, name: "SuZu Media", spec: onB[0].spec), db: db) }
        exchange()
        let onA = try a.store.db.read { db in try SavedWatermarks.all(db) }
        XCTAssertEqual(onA.map(\.name), ["SuZu Media"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: TeamSync.assetsURL(shared).path).count, 1)

        // Deleted on A: gone on B, and an old copy doesn't bring it back.
        Thread.sleep(forTimeInterval: 0.01)
        try a.store.db.write { db in try SavedWatermarks.delete(w.id, db: db) }
        exchange()
        onB = try b.store.db.read { db in try SavedWatermarks.all(db) }
        XCTAssertTrue(onB.isEmpty)
    }

    func testSavedLooksTravel() throws {
        var a1 = Adjustments(); a1.exposure = 0.4; a1.sharpness = -0.3; a1.clarity = -0.5; a1.tone = [0, 0.3, 0.55, 0.8, 1]
        let l = SavedLook(name: "Gala warm", autoTone: true, adjustments: a1)
        try a.store.db.write { db in try SavedLooks.save(l, db: db) }
        exchange()
        var onB = try b.store.db.read { db in try SavedLooks.all(db) }
        XCTAssertEqual(onB, [l])

        // Retuned on B: A follows.
        Thread.sleep(forTimeInterval: 0.01)
        var a2 = a1; a2.temperature = 0.3
        try b.store.db.write { db in try SavedLooks.save(SavedLook(id: l.id, name: "Gala warmer", autoTone: false, adjustments: a2), db: db) }
        exchange()
        let onA = try a.store.db.read { db in try SavedLooks.all(db) }
        XCTAssertEqual(onA, [SavedLook(id: l.id, name: "Gala warmer", autoTone: false, adjustments: a2)])

        // Deleted on A: gone on B, and an old copy doesn't bring it back.
        Thread.sleep(forTimeInterval: 0.01)
        try a.store.db.write { db in try SavedLooks.delete(l.id, db: db) }
        exchange()
        onB = try b.store.db.read { db in try SavedLooks.all(db) }
        XCTAssertTrue(onB.isEmpty)
        try b.store.db.write { db in try SavedLooks.save(SavedLook(id: l.id, name: "Gala warm", adjustments: a1), db: db, at: 1) }
        exchange()
        XCTAssertTrue(try a.store.db.read { db in try SavedLooks.all(db) }.isEmpty)
    }

    func testListsTravelWithWhoIsOnThem() throws {
        let an = try a.person("An"), bo = try a.person("Bo")
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An")), bBo = try XCTUnwrap(try b.personId(named: "Bo"))
        func lists(_ mac: TeamSyncTests.Mac) throws -> [String: Set<String>] {
            try mac.store.db.read { db in
                var out: [String: Set<String>] = [:]
                for g in try Row.fetchAll(db, sql: "SELECT id, name FROM personGroup") {
                    out[g["name"]] = Set(try String.fetchAll(db, sql: """
                        SELECT p.name FROM personGroupMember m JOIN person p ON p.id = m.personId WHERE m.groupId = ?
                        """, arguments: [g["id"] as Int64]))
                }
                return out
            }
        }
        // Made on A with An on it.
        let vip = try a.store.db.write { db -> Int64 in
            let id = try PersonGroups.create("VIP", project: a.project, db: db)
            try PersonGroups.set(id, people: [an], member: true, db: db)
            return id
        }
        exchange()
        XCTAssertEqual(try lists(b), ["VIP": ["An"]])
        // Bo added on B, An taken off on B: A follows.
        Thread.sleep(forTimeInterval: 0.01)
        try b.store.db.write { db in
            let id = try XCTUnwrap(try PersonGroups.find("VIP", project: b.project, db: db))
            try PersonGroups.set(id, people: [bBo], member: true, db: db)
            try PersonGroups.set(id, people: [bAn], member: false, db: db)
        }
        exchange()
        XCTAssertEqual(try lists(a), ["VIP": ["Bo"]])
        // "Cast" made on both Macs apart: one list everywhere, with everyone put on either.
        try a.store.db.write { db in try PersonGroups.set(try PersonGroups.create("Cast", project: a.project, db: db), people: [bo], member: true, db: db) }
        try b.store.db.write { db in try PersonGroups.set(try PersonGroups.create("Cast", project: b.project, db: db), people: [bAn], member: true, db: db) }
        exchange()
        XCTAssertEqual(try lists(a), ["VIP": ["Bo"], "Cast": ["An", "Bo"]])
        XCTAssertEqual(try lists(b), ["VIP": ["Bo"], "Cast": ["An", "Bo"]])
        // Deleted on A: gone on B, for good.
        Thread.sleep(forTimeInterval: 0.01)
        try a.store.db.write { db in try PersonGroups.delete(vip, db: db) }
        exchange(); exchange()
        XCTAssertEqual(try lists(b), ["Cast": ["An", "Bo"]])
        XCTAssertEqual(try lists(a), ["Cast": ["An", "Bo"]])
    }

    func testWithoutAChosenMacEveryoneProcessesAndNothingIsPublished() throws {
        let an = try a.person("An")
        try processed("p1.jpg", person: an, vector: vector(1))
        try waiting("p1.jpg")
        exchange()
        XCTAssertTrue(b.sync.processesLocally(project: b.project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TeamSync.facesURL(shared, device: a.sync.deviceId).path), "no records without a processing Mac")
        XCTAssertEqual(try b.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facePublish") }, 0, "queues don't pile up")
        XCTAssertEqual(try a.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facePublish") }, 0)
    }
}
