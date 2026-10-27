import GRDB
import XCTest
@testable import FaceLibrary

/// Two Macs that must end up showing the same thing, whatever order or clock their changes had.
final class SyncConvergenceTests: XCTestCase {
    var tmp: URL!
    var shared: URL!
    var a: TeamSyncTests.Mac!
    var b: TeamSyncTests.Mac!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("converge-\(UUID().uuidString)")
        shared = tmp.appendingPathComponent("NAS/Gala Team", isDirectory: true)
        a = try TeamSyncTests.Mac(tmp.appendingPathComponent("A"), name: "Studio")
        b = try TeamSyncTests.Mac(tmp.appendingPathComponent("B"), name: "Laptop")
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        _ = try b.sync.join(folder: shared)
        exchange()
        let uuid = try a.projectUuid()
        let bp = try XCTUnwrap(try b.store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM project WHERE uuid = ?", arguments: [uuid]) })
        try b.store.db.write { db in try db.execute(sql: "UPDATE source SET projectId = ? WHERE id = ?", arguments: [bp, b.source]) }
        b.project = bp
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

    func names(_ m: TeamSyncTests.Mac) throws -> [String?] { try m.people().map(\.name) }

    /// A rename as the app does it, on a Mac whose clock says `now`.
    func rename(_ m: TeamSyncTests.Mac, _ pid: Int64, _ name: String?, now: Double) throws {
        try m.store.db.write { db in
            try db.execute(sql: "UPDATE person SET name = ?, nameAt = \(SyncIds.stampSQL("nameAt")) WHERE id = ?", arguments: [name, now, pid])
        }
    }

    func testAnEditOnAMacWhoseClockIsBehindStillWinsEverywhere() throws {
        let an = try a.person("An", at: 1000)
        try a.photo("a1.jpg", person: an, vector: vector(1))
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        try b.photo("b1.jpg", person: bAn, vector: vector(1))
        // B's clock is 50 s behind A's: its "now" is older than the name it replaces.
        try rename(b, bAn, "Nguyễn An", now: 950)
        exchange()
        XCTAssertEqual(try names(a), ["Nguyễn An"], "the last edit, on any Mac, wins")
        XCTAssertEqual(try names(b), ["Nguyễn An"])
        // And A's later edit wins again, even though A's clock reads earlier than B's stamp would.
        try rename(a, an, "An Nguyễn", now: 960)
        exchange()
        XCTAssertEqual(try names(a), ["An Nguyễn"])
        XCTAssertEqual(try names(b), ["An Nguyễn"])
    }

    func testTakingANameAwayTravels() throws {
        let an = try a.person("An", at: 100)
        try a.photo("a1.jpg", person: an, vector: vector(1))
        exchange()
        XCTAssertEqual(try names(b), ["An"])
        try rename(a, an, nil, now: 200)
        exchange()
        XCTAssertEqual(try names(a), [nil])
        XCTAssertEqual(try names(b), [nil])
        // Named again later: B follows.
        try rename(a, an, "An Lê", now: 300)
        exchange()
        XCTAssertEqual(try names(b), ["An Lê"])
    }

    func testANameGivenBeforeNamesHadATimeReachesAnUnnamedCopy() throws {
        let an = try a.person("An")
        try a.store.db.write { db in try db.execute(sql: "UPDATE person SET nameAt = NULL WHERE id = ?", arguments: [an]) }
        try a.photo("a1.jpg", person: an, vector: vector(1))
        // B already knows the group by its id, unnamed (as it would from the processing Mac's records).
        let uuid = try a.uuid(an)
        try b.store.db.write { db in var p = PersonRecord(name: nil, uuid: uuid); try p.insert(db) }
        exchange()
        XCTAssertEqual(try names(b), ["An"])
    }

    func testOppositeMergesSettleOnOnePersonWithOneName() throws {
        let an = try a.person("An", at: 100), binh = try a.person("Bình", at: 100)
        try a.photo("a1.jpg", person: an, vector: vector(1))
        try a.photo("a2.jpg", person: binh, vector: vector(4))
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An")), bBinh = try XCTUnwrap(try b.personId(named: "Bình"))
        try b.photo("b1.jpg", person: bBinh, vector: vector(4))
        // At the same moment, A decides Bình is An; B decides An is Bình.
        try a.store.db.write { db in try PersonNames.merge([binh], into: an, db: db) }
        try b.store.db.write { db in try PersonNames.merge([bAn], into: bBinh, db: db) }
        a.engine.peopleChanged([an, binh]); b.engine.peopleChanged([bAn, bBinh])
        exchange()
        let pa = try a.people(), pb = try b.people()
        XCTAssertEqual(pa.count, 1); XCTAssertEqual(pb.count, 1)
        XCTAssertEqual(pa.first?.name, pb.first?.name, "one name on both Macs")
        XCTAssertEqual(pa.first?.uuid, pb.first?.uuid, "the same person on both Macs")
        XCTAssertEqual(pa.first?.faces, 2); XCTAssertEqual(pb.first?.faces, 1)
    }

    func testAGroupMergedIntoTwoDifferentlyNamedPeopleKeepsBoth() throws {
        let an = try a.person("An", at: 100), binh = try a.person("Bình", at: 100), g = try a.person(nil)
        try a.photo("a1.jpg", person: an, vector: vector(1))
        try a.photo("a2.jpg", person: binh, vector: vector(4))
        try a.photo("a3.jpg", person: g, vector: vector(7))
        exchange()
        let gUuid = try a.uuid(g)
        let bg = try b.store.db.write { db -> Int64 in var p = PersonRecord(name: nil, uuid: gUuid); try p.insert(db); return p.id! }
        try b.photo("b3.jpg", person: bg, vector: vector(7))
        let bAn = try XCTUnwrap(try b.personId(named: "An")), bBinh = try XCTUnwrap(try b.personId(named: "Bình"))
        try a.store.db.write { db in try PersonNames.merge([g], into: an, db: db) }
        try b.store.db.write { db in try PersonNames.merge([bg], into: bBinh, db: db) }
        a.engine.peopleChanged([an, g]); b.engine.peopleChanged([bAn, bBinh, bg])
        exchange()
        // Two users told An and Bình apart: neither Mac folds them into one.
        XCTAssertEqual(try names(a), ["An", "Bình"])
        XCTAssertEqual(try names(b), ["An", "Bình"])
    }

    func testAGroupMergedIntoANamedPersonHereAndAnUnnamedOneThereBecomesTheNamedOne() throws {
        let an = try a.person("An", at: 100), g = try a.person(nil), h = try a.person(nil)
        try a.photo("a1.jpg", person: an, vector: vector(1))
        try a.photo("a3.jpg", person: g, vector: vector(7))
        try a.photo("a4.jpg", person: h, vector: vector(8))
        exchange()
        let gUuid = try a.uuid(g), hUuid = try a.uuid(h)
        let (bg, bh) = try b.store.db.write { db -> (Int64, Int64) in
            var p = PersonRecord(name: nil, uuid: gUuid); try p.insert(db)
            var q = PersonRecord(name: nil, uuid: hUuid); try q.insert(db)
            return (p.id!, q.id!)
        }
        try b.photo("b3.jpg", person: bg, vector: vector(7))
        try b.photo("b4.jpg", person: bh, vector: vector(8))
        // A: the group is An. B: the group is the other unnamed group.
        try a.store.db.write { db in try PersonNames.merge([g], into: an, db: db) }
        try b.store.db.write { db in try PersonNames.merge([bg], into: bh, db: db) }
        a.engine.peopleChanged([an, g]); b.engine.peopleChanged([bg, bh])
        exchange()
        XCTAssertEqual(try names(a), ["An"])
        XCTAssertEqual(try names(b), ["An"])
        XCTAssertEqual(try b.people().first?.faces, 2, "both of B's photos are An's now")
    }

    /// Shared processing: a crop that couldn't be copied when the record was taken is fetched on a later pass.
    func testAMissedCropIsFetchedLater() throws {
        let team = try XCTUnwrap(try a.sync.teams().first)
        try a.sync.setProcessor(team.id!, thisMac: true)
        let an = try a.person("An", at: 100)
        let (m, f) = try a.photo("p1.jpg", person: an, vector: vector(1), assignment: .auto)
        try Data("crop".utf8).write(to: a.store.faceCropURL(f))
        var d = Data(); while d.count < 2048 { d += Data("p1.jpg".utf8) }
        try d.prefix(2048).write(to: a.root.appendingPathComponent("p1.jpg"))
        let key = try XCTUnwrap(ContentKey.compute(a.root.appendingPathComponent("p1.jpg"), size: 2048))
        try a.store.db.write { db in
            try db.execute(sql: "UPDATE media SET contentKey = ? WHERE id = ?", arguments: [key, m])
            try db.execute(sql: "INSERT OR IGNORE INTO facePublish (mediaId) VALUES (?)", arguments: [m])
        }
        a.sync.pushSoon(); a.sync.syncNow()
        // The crops' folder can't be seen for a moment (the share away, A still writing it).
        let (payload, _) = try XCTUnwrap(try a.sync.payload(for: m))
        let cropDir = TeamSync.cropFolder(TeamSync.facesURL(shared, device: a.sync.deviceId), key: key, boxes: TeamSync.signature(payload.faces).boxes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cropDir.appendingPathComponent("0.jpg").path), "published as a whole folder")
        let aside = tmp.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.moveItem(at: cropDir, to: aside)
        let url = b.root.appendingPathComponent("p1.jpg")
        try d.prefix(2048).write(to: url)
        var w = MediaRecord(sourceId: b.source, path: url.path, kind: .photo, size: 2048, mtime: 0, contentKey: nil)
        try b.store.db.write { db in try w.insert(db) }
        b.sync.syncNow(); b.settle(); b.sync.syncNow()
        let bf = try b.store.db.read { db in try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ?", arguments: [w.id!]) }
        XCTAssertEqual(bf.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.store.faceCropURL(bf[0].id!).path), "no crop yet")
        // It is back: the next pass brings it, with nothing republished.
        try FileManager.default.moveItem(at: aside, to: cropDir)
        b.sync.syncNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.store.faceCropURL(bf[0].id!).path))
        XCTAssertEqual(try b.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cropRetry") }, 0)
    }

    func testAHalfWrittenLineDoesNotSwallowTheNextChange() throws {
        let an = try a.person("An", at: 100)
        try a.photo("a1.jpg", person: an, vector: vector(1))
        exchange()
        // A's log ends in a half line (the share went away mid-append).
        let log = TeamSync.devicesURL(shared).appendingPathComponent("\(a.sync.deviceId).jsonl")
        let h = try FileHandle(forWritingTo: log)
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"t\":\"person\",\"at\":1".utf8)); try h.close()
        try rename(a, an, "An Lê", now: 200)
        exchange()
        XCTAssertEqual(try names(b), ["An Lê"])
    }
}
