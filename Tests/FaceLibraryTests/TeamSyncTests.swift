import GRDB
import XCTest
@testable import FaceLibrary

/// Two Macs (two libraries) sharing one project through a folder.
final class TeamSyncTests: XCTestCase {
    var tmp: URL!
    var shared: URL!

    /// One Mac: a library, its grouping engine and sync, with a project and a folder in it.
    final class Mac {
        let store: LibraryStore
        let engine: GroupingEngine
        let sync: TeamSync
        var project: Int64
        let source: Int64
        let root: URL

        init(_ dir: URL, name: String) throws {
            store = try LibraryStore(directory: dir.appendingPathComponent("lib"))
            engine = GroupingEngine(store: store)
            sync = TeamSync(store: store, engine: engine)
            sync.deviceName = name
            var p = ProjectRecord(name: "Gala")
            try store.db.write { db in try p.insert(db) }
            project = p.id!
            root = dir.appendingPathComponent("Event", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var s = SourceRecord(path: root.path, projectId: project)
            try store.db.write { db in try s.insert(db) }
            source = s.id!
            engine.start()
            engine.waitUntilIdle()
        }

        /// A processed photo with one face; `person` nil = waiting to be grouped.
        @discardableResult
        func photo(_ name: String, person: Int64?, vector: [Float], assignment: Assignment = .user) throws -> (media: Int64, face: Int64) {
            let url = root.appendingPathComponent(name)
            try Data(repeating: UInt8(name.utf8.first ?? 1), count: 2048).write(to: url)
            var m = MediaRecord(sourceId: source, path: url.path, kind: .photo, size: 2048, mtime: 0, contentKey: name)
            m.status = .done; m.width = 1500; m.height = 1000; m.takenAt = 1_700_000_000 + Double(name.hashValue % 1000)
            try store.db.write { db in try m.insert(db) }
            var f = FaceRecord(id: nil, mediaId: m.id!, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                               embedding: Vector.encode(Vector.normalized(vector)), track: nil, personId: person,
                               assignment: person == nil ? .none : assignment, rejectedPersonId: nil)
            f.score = 0.9
            try store.db.write { db in try f.insert(db) }
            return (m.id!, f.id!)
        }

        func person(_ name: String?, at: Double? = nil) throws -> Int64 {
            var p = PersonRecord(name: name)
            if let at { p.nameAt = at }
            try store.db.write { db in try p.insert(db) }
            return p.id!
        }

        func rename(_ pid: Int64, _ name: String, at: Double) throws {
            try store.db.write { db in
                try db.execute(sql: "UPDATE person SET name = ?, nameAt = ? WHERE id = ?", arguments: [name, at, pid])
            }
        }

        func people() throws -> [(name: String?, uuid: String, faces: Int)] {
            try store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT p.name, p.uuid, (SELECT COUNT(*) FROM face f WHERE f.personId = p.id) AS faces FROM person p ORDER BY p.name, p.uuid
                    """).map { ($0["name"], $0["uuid"], $0["faces"]) }
            }
        }

        func personId(named name: String) throws -> Int64? {
            try store.db.read { db in try PersonNames.find(name, db: db) }
        }

        func uuid(_ pid: Int64) throws -> String {
            try store.db.read { db in try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [pid])! }
        }

        func faceOwner(_ faceId: Int64) throws -> Int64? {
            try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT personId FROM face WHERE id = ?", arguments: [faceId]) }
        }

        func settle() {
            engine.waitUntilIdle()
            engine.waitUntilIdle()
        }

        func projectUuid() throws -> String {
            try store.db.read { db in try String.fetchOne(db, sql: "SELECT uuid FROM project WHERE id = ?", arguments: [project])! }
        }
    }

    /// B joins the team and works in the project A shared (its photo folder moves there), as a teammate would.
    @discardableResult
    func joinAsTeammate() throws -> TeamRecord {
        let team = try b.sync.join(folder: shared)
        exchange()
        let uuid = try a.projectUuid()
        let shared = try XCTUnwrap(try b.store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM project WHERE uuid = ?", arguments: [uuid]) },
                                   "A's project appears on B after joining")
        try b.store.db.write { db in try db.execute(sql: "UPDATE source SET projectId = ? WHERE id = ?", arguments: [shared, b.source]) }
        b.project = shared
        return team
    }

    var a: Mac!
    var b: Mac!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("team-\(UUID().uuidString)")
        shared = tmp.appendingPathComponent("NAS/Gala Team", isDirectory: true)
        a = try Mac(tmp.appendingPathComponent("A"), name: "A's Mac")
        b = try Mac(tmp.appendingPathComponent("B"), name: "B's Mac")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func vector(_ seed: Int) -> [Float] {
        var g = SystemRandomNumberGenerator()
        _ = g
        var x = UInt64(seed &* 2654435761)
        return (0..<512).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: x >> 11) % 1000) / 1000 - 0.5
        }
    }

    /// Round trips until nothing moves: every Mac pushes and pulls.
    func exchange() {
        for _ in 0..<4 {
            a.sync.pushSoon(); b.sync.pushSoon()
            a.sync.syncNow(); b.sync.syncNow()
            a.settle(); b.settle()
        }
    }

    func testCreateAndJoinBringTheTeamsProjects() throws {
        let team = try a.sync.create(name: "SuZu", folder: shared, project: a.project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("team.json").path))
        XCTAssertThrowsError(try a.sync.create(name: "Again", folder: shared, project: a.project))
        XCTAssertEqual(try a.sync.team(forProject: a.project)?.id, team.id)
        let joined = try b.sync.join(folder: shared)
        XCTAssertEqual(joined.uuid, team.uuid)
        XCTAssertEqual(joined.name, "SuZu")
        XCTAssertThrowsError(try b.sync.join(folder: tmp.appendingPathComponent("NAS"))) { e in
            XCTAssertTrue("\(e.localizedDescription)".contains("no team"))
        }
        exchange()
        // A's "Gala" is now on B too, in the team; B's own "Gala" stays B's.
        let onB = try b.store.db.read { db in try ProjectRecord.order(Column("id")).fetchAll(db) }
        XCTAssertEqual(onB.map(\.name), ["Gala", "Gala"])
        XCTAssertEqual(onB.map(\.teamId), [nil, joined.id])
        XCTAssertEqual(onB[1].uuid, try a.projectUuid())
        // A second event shared with the same team reaches B as well; renames follow.
        var next = ProjectRecord(name: "Next event")
        try a.store.db.write { db in try next.insert(db) }
        try a.sync.share(project: next.id!, team: team.id!)
        exchange()
        XCTAssertEqual(try b.sync.projects(in: joined.id!).map(\.name).sorted(), ["Gala", "Next event"])
        try a.store.db.write { db in
            try db.execute(sql: "UPDATE project SET name = 'Gala 2026', updatedAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970 + 5, a.project])
        }
        exchange()
        XCTAssertEqual(try b.sync.projects(in: joined.id!).map(\.name).sorted(), ["Gala 2026", "Next event"])
        let status = try XCTUnwrap(a.sync.status(team.id!))
        XCTAssertTrue(status.reachable)
        XCTAssertEqual(Set(status.devices.map(\.name)), ["A's Mac", "B's Mac"])
        XCTAssertEqual(status.devices.first?.isThisMac, true)
        // Stop sharing on B: B keeps the project, A keeps its own.
        try b.sync.unshare(project: b.store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM project WHERE uuid = ?", arguments: [try a.projectUuid()])! })
        XCTAssertEqual(try b.sync.projects(in: joined.id!).map(\.name), ["Next event"])
    }

    func testNameTravelsAndTeammatesFacesRecogniseThePerson() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        try joinAsTeammate()
        let an = try a.person("An")
        let v = vector(1)
        try a.photo("a1.jpg", person: an, vector: v)
        try a.photo("a2.jpg", person: an, vector: v)
        a.engine.peopleChanged([an]); a.settle()
        exchange()

        let people = try b.people()
        XCTAssertEqual(people.map(\.name), ["An"])
        XCTAssertEqual(people[0].uuid, try a.uuid(an), "the same person has the same id on both Macs")
        XCTAssertEqual(people[0].faces, 0, "only the name and a summary of the faces travel, not the photos")
        let remote = try b.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personRemote") }
        XCTAssertEqual(remote, 1)

        // A new face on B's Mac that looks like An is named without anyone typing.
        let (_, face) = try b.photo("b1.jpg", person: nil, vector: v)
        b.engine.mediaProcessed(try b.store.db.read { db in try Int64.fetchOne(db, sql: "SELECT mediaId FROM face WHERE id = ?", arguments: [face])! })
        b.settle()
        let owner = try XCTUnwrap(try b.faceOwner(face))
        XCTAssertEqual(try b.personId(named: "An"), owner)

        // A different face stays unknown.
        let (m2, other) = try b.photo("b2.jpg", person: nil, vector: vector(2))
        b.engine.mediaProcessed(m2); b.settle()
        XCTAssertNil(try b.faceOwner(other))
    }

    func testKnownPeopleFolderNamesTeammatesGroups() throws {
        // Mac A knows An only from a Known-People folder (no event photos yet); Mac B has already grouped An's
        // faces as an unnamed person. Joining names that group at once.
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        var ref = SourceRecord(path: tmp.appendingPathComponent("A/Known").path, kind: .reference, projectId: nil)
        try a.store.db.write { db in try ref.insert(db) }
        let an = try a.person("An")
        let v = vector(7)
        var m = MediaRecord(sourceId: ref.id, path: tmp.appendingPathComponent("A/Known/An/1.jpg").path, kind: .photo, size: 10, mtime: 0, contentKey: "ref1")
        m.status = .done; m.width = 1500; m.height = 1000
        try a.store.db.write { db in try m.insert(db) }
        var f = FaceRecord(id: nil, mediaId: m.id!, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                           embedding: Vector.encode(Vector.normalized(v)), track: nil, personId: an, assignment: .user, rejectedPersonId: nil)
        try a.store.db.write { db in try f.insert(db) }
        a.engine.peopleChanged([an]); a.settle()

        for i in 1...3 { try b.photo("b\(i).jpg", person: nil, vector: v) }
        b.engine.reclusterNow(); b.settle()
        XCTAssertEqual(try b.people().map(\.name), [nil], "grouped before any name arrived")
        try joinAsTeammate()
        exchange()
        XCTAssertEqual(try b.people().map(\.name), ["An"], "the group takes the name from A's Known-People folder")
        XCTAssertEqual(try b.people().first?.faces, 3)
    }

    func testNewestNameWinsOnEveryMac() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        try joinAsTeammate()
        let an = try a.person("An", at: 100)
        try a.photo("a1.jpg", person: an, vector: vector(1))
        exchange()
        let bAn = try XCTUnwrap(try b.personId(named: "An"))
        try b.photo("b1.jpg", person: bAn, vector: vector(1))  // B has faces of An too, so B publishes An
        try b.rename(bAn, "Nguyễn An", at: 200)
        exchange()
        XCTAssertEqual(try a.people().map(\.name), ["Nguyễn An"])
        // An older name from A doesn't undo B's newer one, even if it is written later.
        try a.rename(an, "An", at: 150)
        exchange()
        XCTAssertEqual(try a.people().map(\.name), ["An"], "A keeps what A typed")
        XCTAssertEqual(try b.people().map(\.name), ["Nguyễn An"], "B's name is newer")
        try a.rename(an, "An Nguyễn", at: 300)
        exchange()
        XCTAssertEqual(try b.people().map(\.name), ["An Nguyễn"])
    }

    func testTheSameNameGivenOnTwoMacsBecomesOnePerson() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        try joinAsTeammate()
        let minhA = try a.person("Minh", at: 100)
        try a.photo("a1.jpg", person: minhA, vector: vector(3))
        let minhB = try b.person("Minh", at: 110)
        try b.photo("b1.jpg", person: minhB, vector: vector(3))
        exchange()
        let pa = try a.people(), pb = try b.people()
        XCTAssertEqual(pa.map(\.name), ["Minh"])
        XCTAssertEqual(pb.map(\.name), ["Minh"])
        XCTAssertEqual(pa[0].uuid, pb[0].uuid, "both Macs settle on the same id")
        XCTAssertEqual(pa[0].uuid, min(try a.uuid(minhA), try b.uuid(minhB)))
        XCTAssertEqual(pa[0].faces, 1); XCTAssertEqual(pb[0].faces, 1)
        // Each Mac has the other's summary of Minh's faces.
        let remote = try a.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personRemote") }
        XCTAssertEqual(remote, 1)
    }

    func testMergeTravels() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        try joinAsTeammate()
        let an = try a.person("An"), binh = try a.person("Bình")
        try a.photo("a1.jpg", person: an, vector: vector(1))
        try a.photo("a2.jpg", person: binh, vector: vector(4))
        exchange()
        XCTAssertEqual(try b.people().map(\.name), ["An", "Bình"])
        let bBinh = try XCTUnwrap(try b.personId(named: "Bình"))
        let (_, face) = try b.photo("b1.jpg", person: bBinh, vector: vector(4))
        // A finds out Bình was An all along.
        try a.store.db.write { db in try PersonNames.merge([binh], into: an, db: db) }
        a.engine.peopleChanged([an, binh])
        exchange()
        XCTAssertEqual(try b.people().map(\.name), ["An"])
        XCTAssertEqual(try b.faceOwner(face), try b.personId(named: "An"), "B's photo of Bình now belongs to An")
        // A later rename of the merged-away id still lands on the survivor.
        let aAn = try XCTUnwrap(try a.personId(named: "An"))
        XCTAssertEqual(aAn, an)
    }

    func testSessionNamesAndRulesTravel() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        try joinAsTeammate()
        let an = try a.person("An")
        try a.photo("a1.jpg", person: an, vector: vector(1))
        let session = EventSession(index: 0, start: 1_700_000_000, end: 1_700_000_900, photos: 1, videos: 0)
        try EventSessions.setName(a.store, project: a.project, session: session, name: "Awards")
        var q = MediaQuery()
        q.people = [an]; q.bestOnly = true; q.crowd = .solo
        let out = tmp.appendingPathComponent("Out")
        let rule = try DeliveryService(store: a.store).add(DeliveryRule(name: "Best of An", query: q, folder: out.path, layout: .flat, recipe: nil, writeNames: true, projectId: a.project), includeExisting: false)
        exchange()

        let labels = try b.store.db.read { db in try Row.fetchAll(db, sql: "SELECT projectId, at, name FROM sessionLabel") }
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0]["projectId"] as Int64, b.project)
        XCTAssertEqual(labels[0]["name"] as String, "Awards")

        let rules = try b.store.db.read { db in try DeliveryService.rules(db) }
        XCTAssertEqual(rules.count, 1)
        let r = rules[0]
        XCTAssertEqual(r.uuid, rule.uuid)
        XCTAssertEqual(r.name, "Best of An")
        XCTAssertEqual(r.projectId, b.project)
        XCTAssertEqual(r.layout, .flat)
        XCTAssertEqual(r.folder, out.path)
        XCTAssertEqual(r.mediaQuery.people, [try XCTUnwrap(try b.personId(named: "An"))], "the rule's people are B's own ids for the same people")
        XCTAssertTrue(r.mediaQuery.bestOnly)
        XCTAssertEqual(r.mediaQuery.crowd, .solo)
        XCTAssertEqual(r.mediaQuery.project, b.project)

        // Clearing the session name and deleting the rule travel too.
        try EventSessions.setName(a.store, project: a.project, session: session, name: "")
        try DeliveryService(store: a.store).delete(rule)
        exchange()
        XCTAssertEqual(try b.store.db.read { db in try EventSessions.list(db, project: b.project) }.compactMap(\.name), [])
        XCTAssertEqual(try b.store.db.read { db in try DeliveryService.rules(db) }.count, 0)
    }

    func testRuleWaitsForItsPeople() throws {
        // A rule naming someone whose name hasn't arrived yet is held back, not applied half-way.
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        try joinAsTeammate()
        let an = try a.person("An")
        var q = MediaQuery(); q.people = [an]
        try DeliveryService(store: a.store).add(DeliveryRule(name: "An", query: q, folder: nil, layout: .person, recipe: nil, writeNames: false, projectId: a.project), includeExisting: true)
        exchange()
        // An has no faces in the project but the rule names them, so An travels with the rule.
        XCTAssertEqual(try b.people().map(\.name), ["An"])
        XCTAssertEqual(try b.store.db.read { db in try DeliveryService.rules(db) }.count, 1)
        XCTAssertEqual(try b.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncDeferred") }, 0)
    }

    func testOfflineFolderIsReportedAndResumes() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        let team = try joinAsTeammate()
        let an = try a.person("An")
        try a.photo("a1.jpg", person: an, vector: vector(1))
        exchange()
        XCTAssertEqual(try b.people().map(\.name), ["An"])
        // The share goes away: no crash, a status, and everything catches up once it is back.
        let hidden = tmp.appendingPathComponent("NAS-hidden")
        try FileManager.default.moveItem(at: tmp.appendingPathComponent("NAS"), to: hidden)
        try a.rename(an, "An Lê", at: Date().timeIntervalSince1970 + 10)
        exchange()
        XCTAssertEqual(try b.sync.status(team.id!)?.reachable, false)
        XCTAssertEqual(try b.people().map(\.name), ["An"])
        try FileManager.default.moveItem(at: hidden, to: tmp.appendingPathComponent("NAS"))
        exchange()
        XCTAssertEqual(try b.sync.status(team.id!)?.reachable, true)
        XCTAssertEqual(try b.people().map(\.name), ["An Lê"])
    }

    func testTeamFolderCanMoveAndIsOneEventsOnly() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        let team = try joinAsTeammate()
        let an = try a.person("An")
        try a.photo("a1.jpg", person: an, vector: vector(1))
        exchange()
        // The NAS got a new address: the folder is the same, its path is not.
        let moved = tmp.appendingPathComponent("NAS2/Gala Team", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: shared, to: moved)
        try a.rename(an, "An Lê", at: Date().timeIntervalSince1970 + 10)
        exchange()
        XCTAssertEqual(try b.sync.status(team.id!)?.reachable, false)
        // A folder that holds another team is refused; the right one is accepted and nothing is re-read.
        let other = tmp.appendingPathComponent("NAS2/Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try JSONEncoder().encode(TeamSync.Info(uuid: "zzz", name: "Other", createdAt: 0, createdBy: "X")).write(to: TeamSync.infoURL(other))
        XCTAssertThrowsError(try b.sync.relocate(team.id!, to: other))
        try a.sync.relocate(try XCTUnwrap(try a.sync.team(forProject: a.project)).id!, to: moved)
        try b.sync.relocate(team.id!, to: moved)
        exchange()
        XCTAssertEqual(try b.sync.status(team.id!)?.reachable, true)
        XCTAssertEqual(try b.people().map(\.name), ["An Lê"])
        XCTAssertEqual(try b.sync.teams().first?.folder, canonicalPath(moved))
        // Joining the same folder again just relinks it.
        XCTAssertEqual(try b.sync.join(folder: moved).id, team.id)
    }

    func testEveryNamedPersonTravelsSoTheNextEventKnowsThem() throws {
        // An was named at an earlier event (no faces in this project); B still learns An on joining.
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        var old = ProjectRecord(name: "Last year")
        try a.store.db.write { db in try old.insert(db) }
        var src = SourceRecord(path: tmp.appendingPathComponent("A/Old").path, projectId: old.id)
        try a.store.db.write { db in try src.insert(db) }
        let an = try a.person("An")
        var m = MediaRecord(sourceId: src.id, path: tmp.appendingPathComponent("A/Old/1.jpg").path, kind: .photo, size: 10, mtime: 0, contentKey: "old1")
        m.status = .done; m.width = 1500; m.height = 1000
        try a.store.db.write { db in try m.insert(db) }
        var f = FaceRecord(id: nil, mediaId: m.id!, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                           embedding: Vector.encode(Vector.normalized(vector(9))), track: nil, personId: an, assignment: .user, rejectedPersonId: nil)
        try a.store.db.write { db in try f.insert(db) }
        try joinAsTeammate()
        exchange()
        XCTAssertEqual(try b.people().map(\.name), ["An"])
        XCTAssertEqual(try b.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personRemote") }, 1, "with An's faces, so B recognises them")
    }

    func testOlderTeamFoldersKeepTheirFirstProject() throws {
        // A change logged without a project (0.6.x logs) lands in the team's first project on every Mac.
        let team = try a.sync.create(name: "Gala", folder: shared, project: a.project)
        try a.store.db.write { db in
            try db.execute(sql: "UPDATE project SET uuid = ? WHERE id = ?", arguments: [TeamSync.legacyProjectUuid(team.uuid), a.project])
        }
        let legacy = "{\"t\":\"session\",\"at\":5,\"name\":\"Awards\",\"moment\":1700000000}\n"
        try legacy.write(to: TeamSync.devicesURL(shared).appendingPathComponent("old-mac.jsonl"), atomically: true, encoding: .utf8)
        try joinAsTeammate()
        for mac in [a!, b!] {
            let labels = try mac.store.db.read { db in try Row.fetchAll(db, sql: "SELECT projectId, name FROM sessionLabel") }
            XCTAssertEqual(labels.map { $0["name"] as String }, ["Awards"])
            XCTAssertEqual(labels.first?["projectId"] as Int64?, mac.project)
        }
    }

    func testRenamingTheTeamReachesEveryMac() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        let team = try joinAsTeammate()
        try b.sync.rename(team.id!, to: "  Gala 2026 – Hà Nội ")
        XCTAssertEqual(try b.sync.teams().first?.name, "Gala 2026 – Hà Nội")
        XCTAssertEqual(TeamSync.readInfo(shared)?.name, "Gala 2026 – Hà Nội")
        exchange()
        XCTAssertEqual(try a.sync.teams().first?.name, "Gala 2026 – Hà Nội")
        try b.sync.rename(team.id!, to: "   ")
        XCTAssertEqual(try b.sync.teams().first?.name, "Gala 2026 – Hà Nội", "an empty name changes nothing")
    }

    func testLeavingKeepsNamesAndForgetsSummaries() throws {
        try a.sync.create(name: "Gala", folder: shared, project: a.project)
        let team = try joinAsTeammate()
        let an = try a.person("An")
        try a.photo("a1.jpg", person: an, vector: vector(1))
        exchange()
        try b.sync.leave(team.id!)
        XCTAssertEqual(try b.people().map(\.name), ["An"])
        XCTAssertEqual(try b.store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personRemote") }, 0)
        XCTAssertEqual(try b.sync.teams().count, 0)
    }
}

/// Rules with smart-album triggers (any file, solo shots, best shots…) and flat or per-person folders.
final class RuleTests: XCTestCase {
    var tmp: URL!
    var store: LibraryStore!
    var project: Int64!
    var source: Int64!
    var root: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("rules-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("Event", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
        var p = ProjectRecord(name: "Gala")
        try store.db.write { db in try p.insert(db) }
        project = p.id!
        var s = SourceRecord(path: root.path, projectId: project)
        try store.db.write { db in try s.insert(db) }
        source = s.id!
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func person(_ name: String) throws -> Int64 {
        var p = PersonRecord(name: name)
        try store.db.write { db in try p.insert(db) }
        return p.id!
    }

    /// A photo with faces of `people` (score per face); nil = an unnamed face.
    @discardableResult
    func photo(_ name: String, faces: [(person: Int64?, score: Double)]) throws -> Int64 {
        let url = root.appendingPathComponent(name)
        try Data(repeating: UInt8(truncatingIfNeeded: name.hashValue), count: 1024).write(to: url)
        var m = MediaRecord(sourceId: source, path: url.path, kind: .photo, size: 1024, mtime: 0, contentKey: name)
        m.status = .done; m.width = 1500; m.height = 1000; m.takenAt = 1_700_000_000
        try store.db.write { db in try m.insert(db) }
        for (i, f) in faces.enumerated() {
            var face = FaceRecord(id: nil, mediaId: m.id!, x: 0.1 + Double(i) * 0.2, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                                  embedding: nil, track: nil, personId: f.person, assignment: f.person == nil ? .none : .user, rejectedPersonId: nil)
            face.score = f.score
            try store.db.write { db in try face.insert(db) }
        }
        return m.id!
    }

    func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A target folder the user chose (rules wait for one that isn't mounted; they never create it).
    func folder(_ name: String) throws -> URL {
        let u = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testFlatRuleCopiesEveryBestSoloShotOnce() throws {
        let an = try person("An"), binh = try person("Bình")
        try photo("solo-good.jpg", faces: [(an, 0.9)])
        try photo("solo-bad.jpg", faces: [(an, 0.2)])
        try photo("pair.jpg", faces: [(an, 0.9), (binh, 0.9)])
        try photo("stranger.jpg", faces: [(nil, 0.9)])
        var q = MediaQuery()
        q.crowd = .solo; q.bestOnly = true
        let out = try folder("Best")
        let service = DeliveryService(store: store)
        let rule = try service.add(DeliveryRule(name: "Best solo", query: q, folder: out.path, layout: .flat, recipe: nil, writeNames: false, projectId: project), includeExisting: true)
        XCTAssertEqual(rule.displayName { _ in nil }, "Best solo")
        let report = try service.run()
        XCTAssertEqual(report.copied, 2)
        XCTAssertEqual(files(out), ["solo-good.jpg", "stranger.jpg"], "straight into the folder, no per-person subfolders; the solo filter doesn't need a name")
        XCTAssertEqual(report.newFiles["Best solo"], 2)
        // Nothing is sent twice.
        XCTAssertEqual(try service.run().copied, 0)
        // A new matching file is picked up.
        try photo("later.jpg", faces: [(binh, 0.95)])
        XCTAssertEqual(try service.run().copied, 1)
        XCTAssertEqual(files(out), ["later.jpg", "solo-good.jpg", "stranger.jpg"])
    }

    func testPersonRuleUsesAFolderPerPersonAndOnlyTheSearchedPeople() throws {
        let an = try person("An"), binh = try person("Bình")
        try photo("pair.jpg", faces: [(an, 0.9), (binh, 0.9)])
        try photo("binh.jpg", faces: [(binh, 0.9)])
        var q = MediaQuery()
        q.people = [an]
        let out = try folder("People")
        let service = DeliveryService(store: store)
        try service.add(DeliveryRule(name: nil, query: q, folder: out.path, layout: .person, recipe: nil, writeNames: false, projectId: project), includeExisting: true)
        XCTAssertEqual(try service.run().copied, 1)
        XCTAssertEqual(files(out), ["An", "An/pair.jpg"], "Bình is in the photo but the rule is about An")
        // Everyone with a name: both people's folders.
        let all = try folder("All")
        try service.add(DeliveryRule(personId: nil, folder: all.path, recipe: nil, writeNames: false, projectId: project), includeExisting: true)
        XCTAssertEqual(try service.run().copied, 3)
        XCTAssertEqual(files(all), ["An", "An/pair.jpg", "Bình", "Bình/binh.jpg", "Bình/pair.jpg"])
    }

    func testNewRuleSkipsExistingFilesUnlessAsked() throws {
        let an = try person("An")
        try photo("old.jpg", faces: [(an, 0.9)])
        let service = DeliveryService(store: store)
        let out = try folder("Out")
        let rule = try service.add(DeliveryRule(personId: an, folder: out.path, recipe: nil, writeNames: false, projectId: project), includeExisting: false)
        XCTAssertEqual(try service.run().copied, 0)
        try photo("new.jpg", faces: [(an, 0.9)])
        XCTAssertEqual(try service.run().copied, 1)
        XCTAssertEqual(files(out), ["An", "An/new.jpg"])
        try service.delete(rule)
        XCTAssertEqual(try store.db.read { db in try DeliveryService.rules(db) }.count, 0)
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deliveryRule") }, 1, "kept for teammates' Macs to learn of the deletion")
        try photo("after.jpg", faces: [(an, 0.9)])
        XCTAssertEqual(try service.run().copied, 0, "a deleted rule no longer runs")
    }
}
