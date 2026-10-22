import GRDB
import XCTest
@testable import FaceLibrary

final class LibraryTests: XCTestCase {
    var tmp: URL!
    var root: URL!
    var store: LibraryStore!
    var sourceId: Int64!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("Event", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: canonicalPath(root), isDirectory: true)
        store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
        var s = SourceRecord(path: root.path)
        try store.db.write { db in try s.insert(db) }
        sourceId = s.id
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Writes a fake photo with an old mtime so scans treat it as settled immediately.
    @discardableResult
    func makeFile(_ rel: String, bytes: Int = 4096, seed: UInt8 = 1) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* Int(seed)) }).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
        return url
    }

    func monitor() -> SourceMonitor {
        let s = try! store.db.read { db in try SourceRecord.fetchOne(db, key: sourceId)! }
        return SourceMonitor(source: s, store: store) { _, _ in }
    }

    func media() throws -> [MediaRecord] {
        try store.db.read { db in try MediaRecord.fetchAll(db, sql: "SELECT * FROM media ORDER BY path") }
    }

    func addFace(mediaId: Int64, personId: Int64?, vector: [Float] = [Float](repeating: 0.1, count: 512)) throws -> Int64 {
        var f = FaceRecord(id: nil, mediaId: mediaId, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                           embedding: Vector.encode(Vector.normalized(vector)), track: nil, personId: personId,
                           assignment: personId == nil ? .none : .auto, rejectedPersonId: nil)
        try store.db.write { db in
            try db.execute(sql: "UPDATE media SET status = 'done', width = 1500, height = 1000 WHERE id = ?", arguments: [mediaId])
            try f.insert(db)
        }
        return f.id!
    }

    func newPerson(_ name: String?) throws -> Int64 {
        var p = PersonRecord(name: name)
        try store.db.write { db in try p.insert(db) }
        return p.id!
    }

    // MARK: - Scanning

    func testScanFindsMovesCopiesAndDeletes() throws {
        let a = try makeFile("a.jpg", seed: 1)
        let b = try makeFile("b.jpg", seed: 2)
        try makeFile("._b.jpg", seed: 3)          // AppleDouble: ignored
        try makeFile("notes.txt", seed: 4)        // not media: ignored
        let m = monitor()
        m.scan()
        var all = try media()
        XCTAssertEqual(all.map(\.url.lastPathComponent), ["a.jpg", "b.jpg"])
        XCTAssertTrue(all.allSatisfy { $0.status == .pending && $0.contentKey != nil })

        let pid = try newPerson("An")
        let faceA = try addFace(mediaId: all[0].id!, personId: pid)
        let faceB = try addFace(mediaId: all[1].id!, personId: pid)

        // Moved in Finder: same record, new path, faces kept.
        let moved = root.appendingPathComponent("sub/a-renamed.jpg")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: moved)
        m.scan()
        all = try media()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.path == moved.path && $0.status == .done })
        XCTAssertNotNil(try store.db.read { db in try FaceRecord.fetchOne(db, key: faceA) })

        // Copied: recorded as a duplicate, never processed.
        let copy = root.appendingPathComponent("copy of b.jpg")
        try FileManager.default.copyItem(at: b, to: copy)
        m.scan()
        let bId = try media().first { $0.path == b.path }!.id!
        let dup = try media().first { $0.path == copy.path }!
        XCTAssertEqual(dup.duplicateOf, bId)
        XCTAssertEqual(dup.status, .done)

        // Original deleted while its copy exists: the copy inherits the faces.
        try FileManager.default.removeItem(at: b)
        m.scan()
        let heir = try media().first { $0.path == copy.path }!
        XCTAssertNil(heir.duplicateOf)
        let face = try store.db.read { db in try FaceRecord.fetchOne(db, key: faceB)! }
        XCTAssertEqual(face.mediaId, heir.id)

        // Deleted with no copy: gone, faces too.
        try FileManager.default.removeItem(at: moved)
        m.scan()
        XCTAssertEqual(try media().map(\.path), [copy.path])
        XCTAssertNil(try store.db.read { db in try FaceRecord.fetchOne(db, key: faceA) })
    }

    func testFileStillBeingWrittenWaitsUntilStable() throws {
        let url = root.appendingPathComponent("incoming.jpg")
        try Data(count: 1000).write(to: url)  // fresh mtime: not settled by age
        let m = monitor()
        m.scan()
        XCTAssertTrue(try media().isEmpty, "a brand-new file must not be picked up on first sight")
        // Same size on a later look after the settle interval: picked up.
        m.candidates[url.path]!.seen = Date(timeIntervalSinceNow: -5)
        m.scan()
        XCTAssertEqual(try media().count, 1)
    }

    func testEmptyListingOfNonEmptySourceDeletesNothing() throws {
        try makeFile("a.jpg")
        let m = monitor()
        m.scan()
        // Simulate a share that briefly lists nothing.
        let hidden = tmp.appendingPathComponent("hidden-a.jpg")
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.jpg"), to: hidden)
        m.scan()
        XCTAssertEqual(try media().count, 1)
    }

    // MARK: - Export

    func testCopyToPersonFolder() throws {
        try makeFile("x/1.jpg", seed: 1)
        try makeFile("x/2.jpg", seed: 2)
        try makeFile("x/3.jpg", seed: 3)
        let m = monitor()
        m.scan()
        let all = try media()
        let an = try newPerson("An"), binh = try newPerson("Bình")
        _ = try addFace(mediaId: all[0].id!, personId: an)
        _ = try addFace(mediaId: all[1].id!, personId: an)
        _ = try addFace(mediaId: all[1].id!, personId: binh)  // group photo
        _ = try addFace(mediaId: all[2].id!, personId: binh)

        let exporter = Exporter(store: store)
        let plan = try exporter.plan(personId: an, name: "An", base: nil)
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.sharedCount, 1)
        XCTAssertEqual(plan.items[0].to.deletingLastPathComponent().path, root.appendingPathComponent("An").path)

        let result = exporter.run(plan)
        XCTAssertEqual(result.done, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("An/1.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("x/1.jpg").path), "copy keeps originals")

        // The copies are known duplicates: a rescan neither adds pending work nor double-counts the person.
        m.scan()
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") }, 0)
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE duplicateOf IS NOT NULL") }, 2)

        // Running it again: everything is already there with the same size, so nothing is duplicated.
        let again = exporter.run(try exporter.plan(personId: an, name: "An", base: nil))
        XCTAssertEqual(again.done, 0)
        XCTAssertEqual(again.skippedExisting, 2)
    }

    func testMoveToPersonFolderKeepsLibraryInSync() throws {
        try makeFile("1.jpg", seed: 1)
        try makeFile("Bình/1.jpg", seed: 9)  // name collision with different content
        let m = monitor()
        m.scan()
        let one = try media().first { $0.url.lastPathComponent == "1.jpg" && !$0.path.contains("Bình") }!
        let binh = try newPerson("Bình")
        let face = try addFace(mediaId: one.id!, personId: binh)

        let exporter = Exporter(store: store)
        let result = exporter.run(try exporter.plan(personId: binh, name: "Bình", base: nil, mode: .move), policy: .keepBoth)
        XCTAssertEqual(result.done, 1)
        let dest = root.appendingPathComponent("Bình/1 (2).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.path))
        XCTAssertEqual(try store.db.read { db in try MediaRecord.fetchOne(db, key: one.id!)!.path }, dest.path)

        m.scan()
        XCTAssertEqual(try store.db.read { db in try FaceRecord.fetchOne(db, key: face)!.personId }, binh)
        XCTAssertEqual(try media().count, 2)
    }

    func testExportToChosenBaseFolder() throws {
        try makeFile("1.jpg")
        monitor().scan()
        let p = try newPerson("Chi")
        _ = try addFace(mediaId: try media()[0].id!, personId: p)
        let out = tmp.appendingPathComponent("Out", isDirectory: true)
        let exporter = Exporter(store: store)
        _ = exporter.run(try exporter.plan(personId: p, name: "Chi/Pham", base: out))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Chi-Pham/1.jpg").path))
    }

    func testSkipPolicyNeverOverwrites() throws {
        try makeFile("1.jpg", seed: 1)
        let existing = try makeFile("Bình/1.jpg", seed: 9)
        let before = try Data(contentsOf: existing)
        monitor().scan()
        let one = try media().first { !$0.path.contains("Bình") }!
        let p = try newPerson("Bình")
        _ = try addFace(mediaId: one.id!, personId: p)
        let exporter = Exporter(store: store)
        let r = exporter.run(try exporter.plan(personId: p, name: "Bình", base: nil, mode: .move))
        XCTAssertEqual(r.skippedExisting, 1)
        XCTAssertEqual(try Data(contentsOf: existing), before, "existing file untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.path), "skipped file stays where it was")
    }

    func testMoveAllPutsGroupPhotoInMainSubjectsFolderAndCopiesToOthers() throws {
        try makeFile("solo.jpg", seed: 1)
        try makeFile("group.jpg", seed: 2)
        monitor().scan()
        let solo = try media().first { $0.path.hasSuffix("solo.jpg") }!
        let group = try media().first { $0.path.hasSuffix("group.jpg") }!
        let an = try newPerson("An"), binh = try newPerson("Bình")
        _ = try addFace(mediaId: solo.id!, personId: an)
        _ = try addFace(mediaId: group.id!, personId: an)
        // Bình's face is bigger in the group photo: Bình is the main subject.
        var big = FaceRecord(id: nil, mediaId: group.id!, x: 0.1, y: 0.1, w: 0.3, h: 0.3, quality: 0.9, time: nil,
                             embedding: nil, track: nil, personId: binh, assignment: .auto, rejectedPersonId: nil)
        try store.db.write { db in try big.insert(db) }

        let exporter = Exporter(store: store)
        let plan = try exporter.planAll(people: [(an, "An"), (binh, "Bình")], base: nil, mode: .move)
        XCTAssertEqual(plan.moves, 2)
        XCTAssertEqual(plan.copies, 1)
        let r = exporter.run(plan)
        XCTAssertEqual(r.done, 3)
        XCTAssertTrue(r.failed.isEmpty, "\(r.failed)")
        for p in ["An/solo.jpg", "An/group.jpg", "Bình/group.jpg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path), p)
        }
        XCTAssertEqual(try store.db.read { db in try MediaRecord.fetchOne(db, key: group.id!)!.path },
                       root.appendingPathComponent("Bình/group.jpg").path)

        // Running it again changes nothing: everything is already in place.
        let again = try exporter.planAll(people: [(an, "An"), (binh, "Bình")], base: nil, mode: .move)
        XCTAssertEqual(exporter.run(again).done, 0)
    }

    // MARK: - Grouping

    /// Three synthetic identities: random direction plus small per-face noise.
    func identities(_ n: Int, seed: UInt64) -> [[Float]] {
        var rng = SplitMix(seed: seed)
        return (0..<n).map { _ in Vector.normalized((0..<512).map { _ in Float(rng.gaussian()) }) }
    }

    func jitter(_ v: [Float], _ rng: inout SplitMix, amount: Float = 0.6) -> [Float] {
        Vector.normalized(v.enumerated().map { $0.element + amount * Float(rng.gaussian()) / Float(512).squareRoot() })
    }

    func testGroupingClustersAssignsAndAutoNames() throws {
        let ids = identities(3, seed: 7)
        var rng = SplitMix(seed: 1)
        // 4 photos per identity, plus one blurry face that must not seed a group.
        for (k, base) in ids.enumerated() {
            for j in 0..<4 {
                try makeFile("p\(k)_\(j).jpg", seed: UInt8(10 * k + j + 1))
            }
            _ = base
        }
        monitor().scan()
        let all = try media()
        for (i, m) in all.enumerated() {
            _ = try addFace(mediaId: m.id!, personId: nil, vector: jitter(ids[i / 4], &rng))
        }
        let engine = GroupingEngine(store: store)
        try engine.rebuildAll()
        try engine.recluster()
        let people = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT personId, COUNT(*) AS n FROM face GROUP BY personId ORDER BY personId")
        }
        XCTAssertEqual(people.count, 3)
        XCTAssertTrue(people.allSatisfy { ($0["n"] as Int) == 4 && ($0["personId"] as Int64?) != nil })

        // A new photo of identity 0 is named instantly, no recluster needed.
        try makeFile("new.jpg", seed: 200)
        monitor().scan()
        let newMedia = try media().first { $0.url.lastPathComponent == "new.jpg" }!
        let newFace = try addFace(mediaId: newMedia.id!, personId: nil, vector: jitter(ids[0], &rng))
        try engine.assignPending(mediaIds: [newMedia.id!])
        let p0 = try store.db.read { db in try FaceRecord.fetchOne(db, key: newFace)!.personId }
        let firstOf0 = try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT personId FROM face WHERE mediaId = ?", arguments: [all[0].id!]) }
        XCTAssertEqual(p0, firstOf0)

        // Name identity 1 via a reference-style named person; a later unnamed group of identity 1 merges into it.
        let named = try newPerson("Mỹ Tâm")
        let p1 = try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT personId FROM face WHERE mediaId = ?", arguments: [all[4].id!])! }
        try store.db.write { db in try db.execute(sql: "UPDATE face SET personId = ? WHERE personId = ?", arguments: [named, p1]) }
        try store.db.write { db in try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [p1]) }
        try engine.rebuildAll()
        var later: [Int64] = []
        for j in 0..<3 {
            try makeFile("later\(j).jpg", seed: UInt8(150 + j))
        }
        monitor().scan()
        for m in try media() where m.url.lastPathComponent.hasPrefix("later") {
            later.append(try addFace(mediaId: m.id!, personId: nil, vector: jitter(ids[1], &rng, amount: 0.9)))
        }
        engine.settings.assignThreshold = 0.99  // force these through clustering instead of instant assignment
        try engine.recluster()
        engine.settings.assignThreshold = 0.5
        try engine.autoName()
        for f in later {
            XCTAssertEqual(try store.db.read { db in try FaceRecord.fetchOne(db, key: f)!.personId }, named)
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double { (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform()) }
}

final class ReferenceTests: XCTestCase {
    func testReferenceCopyOfEventPhotoIsNotADuplicate() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let event = tmp.appendingPathComponent("Event"), ref = tmp.appendingPathComponent("Known/Mỹ Tâm")
        try FileManager.default.createDirectory(at: event, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ref, withIntermediateDirectories: true)
        let photo = event.appendingPathComponent("a.jpg")
        try Data(repeating: 7, count: 5000).write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: photo.path)
        try FileManager.default.copyItem(at: photo, to: ref.appendingPathComponent("a.jpg"))

        let store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
        var s1 = SourceRecord(path: canonicalPath(event)), s2 = SourceRecord(path: canonicalPath(tmp.appendingPathComponent("Known")), kind: .reference)
        try store.db.write { db in try s1.insert(db); try s2.insert(db) }
        SourceMonitor(source: s1, store: store) { _, _ in }.scan()
        SourceMonitor(source: s2, store: store) { _, _ in }.scan()
        let rows = try store.db.read { db in try MediaRecord.fetchAll(db) }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.duplicateOf == nil && $0.status == .pending })
    }
}
