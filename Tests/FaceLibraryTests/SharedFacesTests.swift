import FaceCore
import GRDB
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
