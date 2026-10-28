import FaceCore
import GRDB
import XCTest
@testable import FaceLibrary

/// The grouping engine on synthetic identities: a person is a random direction in embedding space, a "look" of
/// them (profile, make-up, hat) a fixed offset from it, and each face a jittered copy.
final class GroupingTests: XCTestCase {
    var tmp: URL!
    var root: URL!
    var store: LibraryStore!
    var engine: GroupingEngine!
    var rng = SplitMix(seed: 42)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("Event", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: canonicalPath(root), isDirectory: true)
        store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
        var s = SourceRecord(path: root.path, projectId: 1)
        try store.db.write { db in
            var p = ProjectRecord(name: "Event")
            try p.insert(db)
            s.projectId = p.id
            try s.insert(db)
        }
        engine = GroupingEngine(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func direction() -> [Float] { Vector.normalized((0..<512).map { _ in Float(rng.gaussian()) }) }

    /// `base` plus a little noise: the same person, another shot.
    func face(_ base: [Float], jitter: Float = 0.6) -> [Float] {
        Vector.normalized(base.enumerated().map { $0.element + jitter * Float(rng.gaussian()) / Float(512).squareRoot() })
    }

    /// A look of a person: their direction pulled towards `offset`. At 2.0 the look's faces sit at cosine ~0.45
    /// to the person's plain faces (below the centroid bar) while being ~0.9 similar to each other.
    func look(_ base: [Float], _ offset: [Float], amount: Float = 2.0) -> [Float] {
        Vector.normalized(zip(base, offset).map { $0 + amount * $1 })
    }

    var fileCount = 0
    /// One photo with one face; returns the face id.
    @discardableResult
    func photo(_ vector: [Float], personId: Int64? = nil, quality: Double = 0.8) throws -> Int64 {
        fileCount += 1
        let url = root.appendingPathComponent("p\(fileCount).jpg")
        try Data(repeating: UInt8(fileCount & 0xff), count: 2048).write(to: url)
        return try store.db.write { db in
            var m = MediaRecord(sourceId: 1, path: url.path, kind: .photo, size: 2048, mtime: 0, contentKey: "k\(fileCount)")
            m.status = .done; m.width = 1500; m.height = 1000
            try m.insert(db)
            var f = FaceRecord(id: nil, mediaId: m.id!, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: quality, time: nil,
                               embedding: Vector.encode(vector), track: nil, personId: personId,
                               assignment: personId == nil ? .none : .auto, rejectedPersonId: nil)
            try f.insert(db)
            return f.id!
        }
    }

    func person(of faceId: Int64) throws -> Int64? {
        try store.db.read { db in try FaceRecord.fetchOne(db, key: faceId)!.personId }
    }

    func personCount() throws -> Int { try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person")! } }

    /// A photo brought to find someone (see PhotoLookup): its face ranks the person it shows first and says so, a
    /// stranger's face ranks somebody first without claiming them.
    func testAFaceFromOutsideFindsItsPerson() throws {
        let an = direction(), bo = direction()
        var ids: [Int64] = []
        try store.db.write { db in
            for _ in 0..<2 { var p = PersonRecord(name: ids.isEmpty ? "An" : "Bo"); try p.insert(db); ids.append(p.id!) }
        }
        for _ in 0..<5 { try photo(face(an), personId: ids[0]); try photo(face(bo), personId: ids[1]) }
        engine.start()
        engine.waitUntilIdle()
        let found = engine.nearestPeople(to: face(an), limit: 5)
        XCTAssertEqual(found.map(\.personId), [ids[0], ids[1]])
        XCTAssertTrue(found[0].likely)
        XCTAssertFalse(found[1].likely)
        let stranger = engine.nearestPeople(to: direction(), limit: 1)
        XCTAssertEqual(stranger.count, 1)
        XCTAssertFalse(stranger[0].likely)

        // Files being processed queue grouping work: a lookup doesn't wait for it to drain.
        let started = DispatchSemaphore(value: 0)
        engine.queue.async { started.signal(); Thread.sleep(forTimeInterval: 3) }  // a backlog's worth, not holding the people
        started.wait()
        engine.mediaProcessed(-1)  // queued behind it
        let t = Date()
        XCTAssertEqual(engine.nearestPeople(to: face(an), limit: 1).first?.personId, ids[0])
        XCTAssertLessThan(Date().timeIntervalSince(t), 1, "answered at once, not after the queued work")
        engine.waitUntilIdle()

        // Nor for a clustering pass under way: it lets go of the people while it reads and clusters.
        let clustering = DispatchSemaphore(value: 0)
        engine.work { [engine] in engine!.unlocked { clustering.signal(); Thread.sleep(forTimeInterval: 3) } }
        clustering.wait()
        let t2 = Date()
        XCTAssertEqual(engine.nearestPeople(to: face(an), limit: 1).first?.personId, ids[0])
        XCTAssertLessThan(Date().timeIntervalSince(t2), 1, "answered while the pass clusters")
        engine.waitUntilIdle()
    }

    /// A clustering pass split around its reads and clustering still forms the groups, and a person rebuilt after
    /// an edit keeps their faces.
    func testSplitPassesStillGroupAndRebuild() throws {
        let an = direction()
        for _ in 0..<6 { try photo(face(an), personId: nil) }
        engine.start()
        engine.waitUntilIdle()
        let pid = try XCTUnwrap(try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT DISTINCT personId FROM face WHERE personId IS NOT NULL") })
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face WHERE personId = ?", arguments: [pid]) }, 6)
        engine.peopleChanged([pid])
        engine.waitUntilIdle()
        XCTAssertEqual(engine.nearestPeople(to: face(an), limit: 1).first?.personId, pid)
        XCTAssertTrue(engine.nearestPeople(to: face(an), limit: 1).first?.likely ?? false)
    }

    /// A face from outside finds every file it is in: grouped with its person or not, a video once (at its best
    /// frame); a shot too far from it (a profile) only through the person, and nobody else's.
    func testAFaceFromOutsideFindsItsFiles() throws {
        let an = direction(), bo = direction(), profile = look(an, direction(), amount: 3)
        let anId = try store.db.write { db in var p = PersonRecord(name: "An"); try p.insert(db); return p.id! }
        let grouped = try (0..<4).map { _ in try photo(face(an), personId: anId) }
        let ungrouped = try (0..<3).map { _ in try photo(face(an)) }
        let side = try photo(face(profile), personId: anId)
        let other = try photo(face(bo))
        // A video: three frames of An (the middle one closest), one of Bo.
        let video = try store.db.write { db -> Int64 in
            var m = MediaRecord(sourceId: 1, path: root.appendingPathComponent("v.mov").path, kind: .video, size: 1, mtime: 0, contentKey: "kv")
            m.status = .done
            try m.insert(db)
            for (t, v) in [(1.0, face(an, jitter: 1.2)), (2.0, face(an, jitter: 0.3)), (3.0, face(an, jitter: 1.2)), (4.0, face(bo))] {
                var f = FaceRecord(id: nil, mediaId: m.id!, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: t, embedding: Vector.encode(v),
                                   track: nil, personId: nil, assignment: .none, rejectedPersonId: nil)
                try f.insert(db)
            }
            return m.id!
        }
        func media(_ faceIds: [Int64]) throws -> Set<Int64> {
            try store.db.read { db in Set(try Int64.fetchAll(db, sql: "SELECT mediaId FROM face WHERE id IN (\(faceIds.map(String.init).joined(separator: ",")))")) }
        }
        let query = face(an)
        let found = try store.files(like: query, project: nil)
        XCTAssertEqual(Set(found.map(\.id)), try media(grouped + ungrouped).union([video]))
        XCTAssertTrue(found.allSatisfy { !$0.throughPerson })
        let v = try XCTUnwrap(found.first { $0.id == video })
        XCTAssertEqual(v.kind, .video)
        XCTAssertEqual(v.faces, 3)
        XCTAssertEqual(v.time, 2.0)
        // With the person: their profile shot too, marked as found through them, and last.
        let withAn = try store.files(like: query, person: anId, project: nil)
        let profileFile = try XCTUnwrap(try media([side]).first)
        XCTAssertEqual(withAn.count, found.count + 1)
        XCTAssertEqual(withAn.last?.id, profileFile)
        XCTAssertEqual(withAn.last?.throughPerson, true)
        XCTAssertFalse(withAn.map(\.id).contains(try media([other]).first!))
        // Best match first.
        XCTAssertEqual(found.map(\.similarity), found.map(\.similarity).sorted(by: >))
        // Another project's files are not looked at.
        XCTAssertTrue(try store.files(like: query, project: 999).isEmpty)
    }

    /// Faces that only resemble some of a person's earlier shots (a profile, a new hairstyle) join them through
    /// their nearest exemplars, where the mean of every shot would have turned them away.
    func testNewLookJoinsThroughNearestExemplars() throws {
        let a = direction(), hat = direction()
        var plain: [Int64] = []
        for _ in 0..<6 { plain.append(try photo(face(a))) }
        try engine.recluster()
        let pid = try XCTUnwrap(try person(of: plain[0]))
        XCTAssertEqual(try personCount(), 1)

        // Three shots in the new look arrive: nothing of the person looks like them yet (cosine ~0.35 to their
        // faces and centroid), so they are not assigned, and the group they cluster into is not merged either.
        let withHat = look(a, hat)
        let hatted = [try photo(face(withHat)), try photo(face(withHat)), try photo(face(withHat))]
        let fresh = try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT DISTINCT mediaId FROM face WHERE assignment = 'none'") }
        try engine.assignPending(mediaIds: fresh)
        XCTAssertNil(try person(of: hatted[0]), "a new look is not the centroid's match")
        try engine.recluster()
        XCTAssertNotEqual(try person(of: hatted[0]), pid)
        XCTAssertEqual(try personCount(), 2)

        // Another shot of the plain look is assigned by the centroid as before.
        let more = try photo(face(a))
        try engine.assignPending(mediaIds: [try store.db.read { db in try FaceRecord.fetchOne(db, key: more)!.mediaId }])
        XCTAssertEqual(try person(of: more), pid)

        // Now the user merges the hatted faces into the person: the hat becomes one of their exemplars, and the
        // next hatted shot joins them through it (cosine ~0.7 to those exemplars, ~0.4 to the centroid).
        let hatGroup = try XCTUnwrap(try person(of: hatted[2]))
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET personId = ?, assignment = 'user' WHERE id IN (?, ?, ?)", arguments: [pid, hatted[0], hatted[1], hatted[2]])
        }
        try engine.rebuild(personIds: [pid, hatGroup])
        let another = try photo(face(withHat))
        let mid = try store.db.read { db in try FaceRecord.fetchOne(db, key: another)!.mediaId }
        try engine.assignPending(mediaIds: [mid])
        XCTAssertEqual(try person(of: another), pid)
        let (c, n) = engine.scores(try store.db.read { db in try FaceRecord.fetchOne(db, key: another)!.vector! }, engine.people[pid]!)
        XCTAssertLessThan(c, engine.settings.assignThreshold, "the centroid alone would have refused it")
        XCTAssertGreaterThanOrEqual(n, engine.settings.nearestThreshold)
    }

    /// Two groups of one person that formed from different batches are merged once the second one exists.
    func testGroupsFormedApartAreMerged() throws {
        let a = direction(), b = direction()
        var first: [Int64] = [], second: [Int64] = [], other: [Int64] = []
        for _ in 0..<4 { first.append(try photo(face(a, jitter: 1.0))) }
        for _ in 0..<4 { other.append(try photo(face(b))) }
        try engine.recluster()
        XCTAssertEqual(try personCount(), 2)
        let pa = try XCTUnwrap(try person(of: first[0]))

        // The next batch of the same person is far enough from the first (wide jitter) that none assigns, so it
        // clusters into a group of its own...
        for _ in 0..<4 { second.append(try photo(face(a, jitter: 1.0))) }
        var strict = engine.settings
        strict.assignThreshold = 0.99; strict.nearestThreshold = 0.99
        let relaxed = engine.settings
        engine.settings = strict
        try engine.assignAllPending()
        XCTAssertNil(try person(of: second[0]))
        try engine.recluster(project: 1)
        XCTAssertEqual(try personCount(), 3)
        XCTAssertNotEqual(try person(of: second[0]), pa)

        // ...and consolidation folds it into the first group, leaving the other person alone.
        engine.settings = relaxed
        try engine.consolidate()
        XCTAssertEqual(try personCount(), 2)
        XCTAssertEqual(try person(of: second[0]), pa)
        XCTAssertEqual(try person(of: second[3]), pa)
        XCTAssertNotEqual(try person(of: other[0]), pa)
    }

    /// Two named people are never merged automatically, nor two groups the user told apart.
    func testUserDecisionsAreKept() throws {
        let a = direction()
        var x: [Int64] = [], y: [Int64] = []
        for _ in 0..<4 { x.append(try photo(face(a))) }
        try engine.recluster()
        let px = try XCTUnwrap(try person(of: x[0]))
        var strict = engine.settings
        strict.assignThreshold = 0.99; strict.nearestThreshold = 0.99
        let relaxed = engine.settings
        engine.settings = strict
        for _ in 0..<4 { y.append(try photo(face(a))) }
        try engine.recluster(project: 1)
        let py = try XCTUnwrap(try person(of: y[0]))
        XCTAssertNotEqual(px, py)
        engine.settings = relaxed

        // Same face space, but the user named them differently: kept apart.
        try store.db.write { db in
            try db.execute(sql: "UPDATE person SET name = 'Anh' WHERE id = ?", arguments: [px])
            try db.execute(sql: "UPDATE person SET name = 'Em' WHERE id = ?", arguments: [py])
        }
        try engine.consolidate()
        XCTAssertEqual(try personCount(), 2)

        // One unnamed again, but a face of it was rejected from the other ("Not this person"): kept apart.
        try store.db.write { db in
            try db.execute(sql: "UPDATE person SET name = NULL WHERE id = ?", arguments: [py])
            try db.execute(sql: "UPDATE face SET rejectedPersonId = ? WHERE id = ?", arguments: [px, y[0]])
        }
        try engine.rebuild(personIds: [px, py])
        try engine.consolidate()
        XCTAssertEqual(try personCount(), 2)

        // Without that mark, the unnamed group joins the named person.
        try store.db.write { db in try db.execute(sql: "UPDATE face SET rejectedPersonId = NULL WHERE id = ?", arguments: [y[0]]) }
        try engine.rebuild(personIds: [px, py])
        try engine.consolidate()
        XCTAssertEqual(try personCount(), 1)
        XCTAssertEqual(try person(of: y[0]), px)
        XCTAssertEqual(try store.db.read { db in try String.fetchOne(db, sql: "SELECT name FROM person") }, "Anh")
    }

    /// Two people merged by mistake: after moving a few faces to each right name, "Regroup" on everything left
    /// sends each face to the person it looks like. Faces placed by hand stay put.
    func testRegroupAfterAWrongMergeSendsEachFaceToTheRightPerson() throws {
        let a = direction(), b = direction()
        let (anh, binh) = try store.db.write { db -> (Int64, Int64) in
            var p = PersonRecord(name: "Anh"), q = PersonRecord(name: "Bình")
            try p.insert(db); try q.insert(db)
            return (p.id!, q.id!)
        }
        // The wrong merge: both people's faces under Anh.
        var aFaces: [Int64] = [], bFaces: [Int64] = []
        for _ in 0..<6 { aFaces.append(try photo(face(a), personId: anh)) }
        for _ in 0..<6 { bFaces.append(try photo(face(b), personId: anh)) }
        // A couple of faces moved to each right name by hand (as Move to… does).
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET assignment = 'user' WHERE id IN (\(aFaces[0]), \(aFaces[1]))")
            try db.execute(sql: "UPDATE face SET personId = ?, assignment = 'user', rejectedPersonId = ? WHERE id IN (\(bFaces[0]), \(bFaces[1]))",
                           arguments: [binh, anh])
        }
        try engine.rebuild(personIds: [anh, binh])

        // Regroup everything still under Anh.
        let all = try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM face WHERE personId = ?", arguments: [anh]) }
        let released = try store.db.write { db in try LibraryService.letGo(all, db: db) }
        XCTAssertEqual(released.count, 8, "the two faces placed by hand stay")
        try engine.rebuild(personIds: released.people)
        try engine.assignPending(mediaIds: Array(released.media))

        XCTAssertEqual(try aFaces.map { try person(of: $0) }, Array(repeating: anh, count: 6))
        XCTAssertEqual(try bFaces.map { try person(of: $0) }, Array(repeating: binh, count: 6))
        let handPlaced = try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face WHERE assignment = 'user'") }
        XCTAssertEqual(handPlaced, 4)
    }

    /// Two look-alikes grouped as one person. "Not this person" on a few of the other's faces teaches the person:
    /// the rest of those faces leave too, their own faces stay, a new face of the look-alike stays away and is not
    /// a likely match, and the group the look-alike's faces then form is not merged back.
    func testFacesTakenFromAPersonTakeTheirLookAlikesAlong() throws {
        let a = direction(), b = look(a, direction(), amount: 1.2)  // ~0.64 to a: alike enough to be grouped together
        let anh = try store.db.write { db in var p = PersonRecord(name: "Anh"); try p.insert(db); return p.id! }
        let aFaces = try (0..<6).map { _ in try photo(face(a), personId: anh) }
        let bFaces = try (0..<5).map { _ in try photo(face(b), personId: anh) }
        try engine.rebuildAll()
        XCTAssertTrue(engine.nearestPeople(to: face(b), limit: 1).first?.likely ?? false, "before: the look-alike passes for Anh")

        // "Not Anh" on two of the look-alike's faces (as LibraryService.reject writes it).
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET personId = NULL, assignment = 'user', rejectedPersonId = ? WHERE id IN (\(bFaces[0]), \(bFaces[1]))",
                           arguments: [anh])
        }
        try engine.rebuild(personIds: [anh])
        XCTAssertEqual(engine.people[anh]?.counterRows.count, 2, "the rejected faces stand against Anh")
        try engine.review(from: [anh], to: [])
        XCTAssertEqual(try aFaces.map { try person(of: $0) }, Array(repeating: anh, count: 6), "Anh's own faces stay")
        XCTAssertEqual(try bFaces.map { try person(of: $0) }, Array(repeating: nil, count: 5), "the look-alike's faces all left")
        let waiting = try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face WHERE assignment = 'none'") }
        XCTAssertEqual(waiting, 3, "the three the app had placed wait to be grouped again")

        // A new face of the look-alike is neither placed with Anh nor shown as likely to be Anh.
        let fresh = try photo(face(b))
        let mid = try store.db.read { db in try FaceRecord.fetchOne(db, key: fresh)!.mediaId }
        try engine.assignPending(mediaIds: [mid])
        XCTAssertNil(try person(of: fresh))
        XCTAssertFalse(engine.nearestPeople(to: face(b), limit: 1).first?.likely ?? true)
        XCTAssertTrue(engine.nearestPeople(to: face(a), limit: 1).first?.likely ?? false, "Anh is still found")

        // Grouped, the look-alike's faces are their own person, kept apart from Anh.
        try engine.recluster()
        let other = try XCTUnwrap(try person(of: fresh))
        XCTAssertNotEqual(other, anh)
        XCTAssertEqual(try bFaces.dropFirst(2).map { try person(of: $0) }, Array(repeating: other, count: 3))
        XCTAssertEqual(try personCount(), 2)
    }

    /// Two look-alikes grouped as one person. Moving a few of the other's faces to their own name teaches both:
    /// the rest of those faces follow, and a new face of theirs goes to them. Through the service's path
    /// (`corrected`), as "Move to…" runs it.
    func testFacesMovedToANameTakeTheirLookAlikesAlong() throws {
        let a = direction(), b = look(a, direction(), amount: 1.2)
        let (anh, binh) = try store.db.write { db -> (Int64, Int64) in
            var p = PersonRecord(name: "Anh"), q = PersonRecord(name: "Bình")
            try p.insert(db); try q.insert(db)
            return (p.id!, q.id!)
        }
        let aFaces = try (0..<6).map { _ in try photo(face(a), personId: anh) }
        let bFaces = try (0..<5).map { _ in try photo(face(b), personId: anh) }
        engine.start()
        engine.waitUntilIdle()
        // "Move to Bình" on two of them (as LibraryService.assign writes it).
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET personId = ?, assignment = 'user', rejectedPersonId = ? WHERE id IN (\(bFaces[0]), \(bFaces[1]))",
                           arguments: [binh, anh])
        }
        engine.corrected(from: [anh], to: [binh])
        engine.waitUntilIdle()
        XCTAssertEqual(try aFaces.map { try person(of: $0) }, Array(repeating: anh, count: 6))
        XCTAssertEqual(try bFaces.map { try person(of: $0) }, Array(repeating: binh, count: 5), "the rest of the look-alike's faces followed")
        XCTAssertEqual(engine.people[binh]?.confirmedRows.count, 2, "the moved faces are Bình's confirmed faces")
        XCTAssertEqual(engine.people[anh]?.counterRows.count, 2, "and stand against Anh")
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face WHERE assignment = 'user'") }, 2, "only the two placed by hand are locked")

        let fresh = try photo(face(b)), own = try photo(face(a))
        let mids = try store.db.read { db in try [fresh, own].map { try FaceRecord.fetchOne(db, key: $0)!.mediaId } }
        try engine.assignPending(mediaIds: mids)
        XCTAssertEqual(try person(of: fresh), binh)
        XCTAssertEqual(try person(of: own), anh)
        XCTAssertEqual(try personCount(), 2, "not merged back: each looks like what the user took from the other")
        try engine.consolidate()
        XCTAssertEqual(try personCount(), 2)
    }

    /// Exemplars cover a person's looks: near-duplicates of a look are not kept, a new look is.
    func testExemplarsCoverLooks() throws {
        let a = direction(), glasses = direction()
        for _ in 0..<10 { engine.add(face(a, jitter: 0.3), to: 1) }
        XCTAssertEqual(engine.people[1]!.exemplarRows.count, 1, "ten near-identical shots are one exemplar")
        engine.add(face(look(a, glasses), jitter: 0.3), to: 1)
        XCTAssertEqual(engine.people[1]!.exemplarRows.count, 2, "a new look is kept")
        engine.settings.maxExemplars = 2
        engine.add(direction(), to: 1)
        XCTAssertEqual(engine.people[1]!.exemplarRows.count, 2, "capped")
        XCTAssertEqual(engine.people[1]!.count, 12)
        // Rebuilding a person frees their rows; a merge carries exemplars over.
        engine.add(direction(), to: 2)
        engine.remove(1)
        XCTAssertEqual(engine.exemplars.dead, 2)
        XCTAssertNil(engine.people[1])
        XCTAssertEqual(engine.exemplars.owner[engine.people[2]!.exemplarRows[0]], 2)
    }
}
