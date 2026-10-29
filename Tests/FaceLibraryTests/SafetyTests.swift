import GRDB
import MediaKit
import XCTest
@testable import FaceLibrary

/// Regressions from the v0.5.1 review: nothing lost, overwritten, crashed or shown outside its project.
final class SafetyTests: XCTestCase {
    var tmp: URL!
    var root: URL!
    var store: LibraryStore!
    var sourceId: Int64!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("safe-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("Gala", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
        sourceId = try source(root, project: try project("Gala"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func project(_ name: String) throws -> Int64 {
        var p = ProjectRecord(name: name)
        try store.db.write { db in try p.insert(db) }
        return p.id!
    }

    func source(_ url: URL, project: Int64?, kind: SourceKind = .media) throws -> Int64 {
        var s = SourceRecord(path: url.path, kind: kind, projectId: project)
        try store.db.write { db in try s.insert(db) }
        return s.id!
    }

    @discardableResult
    func makeFile(_ rel: String, in dir: URL? = nil, seed: UInt8 = 1) throws -> URL {
        let url = (dir ?? root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* Int(seed)) }).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
        return url
    }

    func scan(_ source: Int64? = nil) {
        let s = try! store.db.read { db in try SourceRecord.fetchOne(db, key: source ?? sourceId)! }
        SourceMonitor(source: s, store: store) { _, _ in }.scan()
    }

    func mediaId(_ url: URL) throws -> Int64? {
        try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM media WHERE path = ?", arguments: [url.path]) }
    }

    @discardableResult
    func face(_ media: Int64, person: Int64?, quality: Double = 0.8, x: Double = 0.4, size: Double = 0.1) throws -> Int64 {
        var f = FaceRecord(id: nil, mediaId: media, x: x, y: 0.4, w: size, h: size, quality: quality, time: nil,
                           embedding: Vector.encode(Vector.normalized([Float](repeating: 0.1, count: 512))), track: nil,
                           personId: person, assignment: person == nil ? .none : .user, rejectedPersonId: nil)
        try store.db.write { db in
            let m = try MediaRecord.fetchOne(db, key: media)!
            try db.execute(sql: "UPDATE media SET status = 'done', width = 1500, height = 1000, contentKey = COALESCE(contentKey, ?) WHERE id = ?",
                           arguments: [ContentKey.compute(m.url, size: m.size), media])
            try f.insert(db)
        }
        return f.id!
    }

    func person(_ name: String?) throws -> Int64 {
        var p = PersonRecord(name: name)
        try store.db.write { db in try p.insert(db) }
        return p.id!
    }

    func faceCount(_ media: Int64) throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face WHERE mediaId = ?", arguments: [media]) ?? 0 }
    }

    // MARK: - Batch Rename

    func testRenameSwapsAndShiftsKeepFaces() throws {
        let urls = try ["1.jpg", "2.jpg", "3.jpg"].enumerated().map { try makeFile($0.element, seed: UInt8($0.offset + 1)) }
        scan()
        let an = try person("An")
        let ids = try urls.map { try mediaId($0)! }
        for id in ids { try face(id, person: an) }

        // Shift (1->2, 2->3, 3->4) as after a new photo arrives in the middle; then swap 2 and 3 back and forth.
        let shift = RenamePattern.apply(urls.map { RenamePattern.Item(url: $0) }, names: ["2.jpg", "3.jpg", "4.jpg"])
        XCTAssertEqual(shift.renamed.count, 3)
        XCTAssertTrue(try LibraryService.recordRenames(shift.renamed.map { ($0.0.path, $0.1.lastPathComponent) }, store: store).isEmpty)
        let now = ["2.jpg", "3.jpg", "4.jpg"].map { root.appendingPathComponent($0) }
        let swap = RenamePattern.apply([RenamePattern.Item(url: now[0]), RenamePattern.Item(url: now[1])], names: ["3.jpg", "2.jpg"])
        _ = try LibraryService.recordRenames(swap.renamed.map { ($0.0.path, $0.1.lastPathComponent) }, store: store)

        scan()  // the watcher must see nothing new, changed or gone
        XCTAssertEqual(try mediaId(root.appendingPathComponent("3.jpg")), ids[0])
        XCTAssertEqual(try mediaId(root.appendingPathComponent("2.jpg")), ids[1])
        XCTAssertEqual(try mediaId(root.appendingPathComponent("4.jpg")), ids[2])
        for id in ids { XCTAssertEqual(try faceCount(id), 1, "faces stay with their file") }
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") }, 0)
    }

    func testRenameThatCannotHappenLeavesTheFileAlone() throws {
        let a = try makeFile("a.jpg", seed: 1)
        try makeFile("taken.jpg", seed: 2)
        let r = RenamePattern.apply([RenamePattern.Item(url: a)], names: ["taken.jpg"])
        XCTAssertTrue(r.renamed.isEmpty)
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "back under its old name, not a hidden temporary file")
    }

    // MARK: - Folder renamed in Finder

    func testRenamedFolderIsRelinkedWithItsFaces() throws {
        let photo = try makeFile("a.jpg", seed: 3)
        scan()
        let an = try person("An")
        let id = try mediaId(photo)!
        try face(id, person: an)

        let renamed = tmp.appendingPathComponent("Gala 2026", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: renamed)
        // Another event's card with the same file names but other photos is not mistaken for it.
        let other = tmp.appendingPathComponent("Cup", isDirectory: true)
        try makeFile("a.jpg", in: other, seed: 9)
        XCTAssertNil(try LibraryService.offlineSource(matching: other.path, kind: .media, store: store))

        XCTAssertEqual(try LibraryService.offlineSource(matching: renamed.path, kind: .media, store: store), sourceId)
        try LibraryService.relinkPaths(sourceId, from: root.path, to: renamed.path, store: store)
        scan()
        XCTAssertEqual(try mediaId(renamed.appendingPathComponent("a.jpg")), id)
        XCTAssertEqual(try faceCount(id), 1)
    }

    // MARK: - Names

    func testOneNameIsOnePersonInAnyCaseOrUnicodeForm() throws {
        let typed = try person("Hưng")
        try store.db.write { db in
            XCTAssertEqual(try PersonNames.find("Hưng".decomposedStringWithCanonicalMapping, db: db), typed, "Finder folder names are decomposed")
            XCTAssertEqual(try PersonNames.find(" hƯNG ", db: db), typed)
            XCTAssertNil(try PersonNames.find("Hùng", db: db), "different tone mark, different person")
        }
    }

    // MARK: - Lists and pins

    func testListsAndPinsSurviveAMerge() throws {
        let an = try person("An"), twin = try person(nil), other = try person("Bình")
        try store.db.write { db in
            var gala = ProjectRecord(name: "Gala")
            try gala.insert(db)
            let cast = try PersonGroups.create("Cast", project: gala.id!, db: db)
            XCTAssertEqual(try PersonGroups.create(" cast ", project: gala.id!, db: db), cast, "one list per name, any case")
            let vip = try PersonGroups.create("VIP", project: gala.id!, db: db)
            try PersonGroups.set(cast, people: [twin, other], member: true, db: db)
            try PersonGroups.set(vip, people: [an], member: true, db: db)
            try PersonGroups.pin([twin], true, db: db)
            try PersonNames.merge([twin], into: an, db: db)
            let lists = try Int64.fetchAll(db, sql: "SELECT groupId FROM personGroupMember WHERE personId = ? ORDER BY groupId", arguments: [an])
            XCTAssertEqual(lists, [cast, vip], "the survivor keeps both people's lists")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personGroupMember WHERE personId = ?", arguments: [twin]), 0)
            XCTAssertNotNil(try Double.fetchOne(db, sql: "SELECT pinnedAt FROM person WHERE id = ?", arguments: [an]), "and the pin")
            try PersonGroups.pin([an], false, db: db)
            XCTAssertNil(try Double.fetchOne(db, sql: "SELECT pinnedAt FROM person WHERE id = ?", arguments: [an]) ?? nil)
            try PersonGroups.delete(cast, db: db)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personGroupMember WHERE personId = ?", arguments: [other]), 0, "members go with the list")
        }
    }

    func testDuplicateNamesAreMergedWithTheirRulesAndAlbums() throws {
        let photo = try makeFile("a.jpg")
        scan()
        let a = try person("Đức"), b = try person("đức".decomposedStringWithCanonicalMapping)
        try face(try mediaId(photo)!, person: b)
        var q = MediaQuery(); q.people = [a, b]
        var album = SmartAlbum(name: "Đức", query: q)
        try store.db.write { db in try album.insert(db) }
        try DeliveryService(store: store).add(DeliveryRule(personId: b, folder: nil, recipe: nil, writeNames: false), includeExisting: true)

        let merged = try store.db.write { db in try PersonNames.mergeDuplicates(db: db) }
        XCTAssertEqual(merged, [a])
        try store.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT personId FROM face"), a)
            XCTAssertEqual(try DeliveryRule.fetchOne(db)!.mediaQuery.people, [a], "the rule follows the person")
            XCTAssertEqual(try SmartAlbum.fetchOne(db)!.mediaQuery.people, [a])
        }
    }

    func testExportWithTwoPeopleOfTheSameNameDoesNotCrash() throws {
        let photo = try makeFile("a.jpg")
        scan()
        let id = try mediaId(photo)!
        let a = try person("An"), b = try person("An")
        try face(id, person: a, x: 0.1)
        try face(id, person: b, x: 0.6)
        let plan = try Exporter(store: store).planAll(people: [(a, "An"), (b, "An")], base: tmp.appendingPathComponent("out"), mode: .copy)
        XCTAssertEqual(plan.items.count, 2)
    }

    func testTopNRanksByThePersonEvenWhenRenamedInTheDialog() throws {
        let urls = try (1...3).map { try makeFile("\($0).jpg", seed: UInt8($0)) }
        scan()
        let an = try person(nil)
        for (i, u) in urls.enumerated() { try face(try mediaId(u)!, person: an, quality: [0.2, 0.9, 0.5][i]) }
        var opts = Exporter.Options(); opts.topN = 1
        let plan = try Exporter(store: store).plan(personId: an, name: "Typed Just Now", base: tmp, options: opts)
        XCTAssertEqual(plan.items.map(\.from.lastPathComponent), ["2.jpg"])
        XCTAssertNotNil(plan.items[0].focus?.primary, "the crop still knows where their face is")
    }

    // MARK: - Move All

    func testMoveAllRerunNeverTakesAPhotoOutOfSomeonesFolder() throws {
        let photo = try makeFile("group.jpg")
        scan()
        let id = try mediaId(photo)!
        let big = try person("Big"), small = try person("Small")
        try face(id, person: big, size: 0.3)
        try face(id, person: small, x: 0.7, size: 0.1)
        let exporter = Exporter(store: store)
        // First Small alone is moved into their own folder (the photo leaves the event root)...
        let first = try exporter.plan(personId: small, name: "Small", base: nil, mode: .move)
        XCTAssertEqual(exporter.run(first).done, 1)
        // ...then Move All: Big is the main subject, but the photo must stay in Small's folder.
        let all = try exporter.planAll(people: [(big, "Big"), (small, "Small")], base: nil, mode: .move)
        XCTAssertEqual(all.moves, 0)
        XCTAssertEqual(exporter.run(all).done, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Small/group.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Big/group.jpg").path))
    }

    // MARK: - Delivery

    func testDeliveryWaitsForAMissingFolderAndKeepsSameNamedFiles() throws {
        let one = try makeFile("cam1/IMG_0001.JPG", seed: 1), two = try makeFile("cam2/IMG_0001.JPG", seed: 2)
        scan()
        let an = try person("An")
        try face(try mediaId(one)!, person: an)
        try face(try mediaId(two)!, person: an)
        let out = tmp.appendingPathComponent("Drive", isDirectory: true)
        let service = DeliveryService(store: store)
        try service.add(DeliveryRule(personId: an, folder: out.path, recipe: nil, writeNames: false), includeExisting: true)

        let offline = try service.run()
        XCTAssertTrue(offline.newFiles.isEmpty, "an unmounted folder delivers nothing and marks nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "and never creates the path on the Mac's own disk")

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = try service.run()
        XCTAssertEqual(r.copied, 2)
        XCTAssertEqual(r.newFiles["An"], 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("An/IMG_0001.JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("An/IMG_0001 (2).JPG").path), "two cameras: both kept")
        XCTAssertTrue(try service.run().newFiles.isEmpty)
    }

    // MARK: - Gallery

    func testGalleryServesOnlyTheShownProjectsEventFiles() throws {
        let cup = try project("Cup")
        let cupRoot = tmp.appendingPathComponent("Cup", isDirectory: true)
        let cupSource = try source(cupRoot, project: cup)
        let known = tmp.appendingPathComponent("Known", isDirectory: true)
        let knownSource = try source(known, project: nil, kind: .reference)
        let gala = try makeFile("a.jpg"), cupFile = try makeFile("b.jpg", in: cupRoot, seed: 2), ref = try makeFile("An/1.jpg", in: known, seed: 3)
        scan(); scan(cupSource); scan(knownSource)
        let an = try person("An")
        let galaFace = try face(try mediaId(gala)!, person: an)
        let cupFace = try face(try mediaId(cupFile)!, person: an)
        let refFace = try face(try mediaId(ref)!, person: an)
        let galaProject = try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT projectId FROM source WHERE id = ?", arguments: [sourceId]) }

        let data = GalleryData(store: store, project: galaProject)
        XCTAssertNoThrow(try data.mediaPath(try mediaId(gala)!))
        XCTAssertThrowsError(try data.mediaPath(try mediaId(cupFile)!), "another project's file")
        XCTAssertThrowsError(try data.mediaPath(try mediaId(ref)!), "a known-people reference photo")
        XCTAssertTrue(try data.showsFace(galaFace))
        XCTAssertFalse(try data.showsFace(cupFace))
        XCTAssertFalse(try GalleryData(store: store, project: nil).showsFace(refFace))
    }

    func testGalleryFoldersOfNamesThatDifferOnlyByAccents() throws {
        let a = try makeFile("a.jpg", seed: 1), b = try makeFile("b.jpg", seed: 2)
        scan()
        try face(try mediaId(a)!, person: try person("Hùng"))
        try face(try mediaId(b)!, person: try person("Hưng"))
        let out = tmp.appendingPathComponent("site", isDirectory: true)
        let html = try GalleryExporter(store: store).export(title: "Gala", personIds: nil, options: .init(), to: out)
        let index = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(index.contains("hung/index.html"))
        XCTAssertTrue(index.contains("hung-2/index.html"), "each person keeps a page of their own")
    }

    // MARK: - Search

    func testSearchFiltersEverythingBeforeAnyLimit() throws {
        let urls = try (1...4).map { try makeFile("\($0).jpg", seed: UInt8($0)) }
        scan()
        let an = try person("An")
        for (i, u) in urls.enumerated() {
            let id = try mediaId(u)!
            try face(id, person: an, quality: [0.1, 0.2, 0.9, 0.95][i])
            try store.db.write { db in
                try db.execute(sql: "UPDATE media SET takenAt = ?, burstId = ? WHERE id = ?", arguments: [Double(i), i >= 2 ? 7 : nil, id])
            }
        }
        var q = MediaQuery(); q.people = [an]; q.bestOnly = true; q.bestThreshold = 0.5; q.collapseBursts = true
        XCTAssertEqual(try q.run(store, limit: 1).map { ($0.path as NSString).lastPathComponent }, ["4.jpg"],
                       "the early weak shots don't use up the limit; the burst keeps its best")
        q.bestOnly = false
        XCTAssertEqual(try q.run(store).count, 3, "no cap by default")
    }

    // MARK: - Projects

    func testACopyInAnotherProjectIsThatProjectsFile() throws {
        let original = try makeFile("a.jpg")
        scan()
        try face(try mediaId(original)!, person: try person("An"))
        let cupRoot = tmp.appendingPathComponent("Cup", isDirectory: true)
        let cupSource = try source(cupRoot, project: try project("Cup"))
        let copy = try makeFile("a.jpg", in: cupRoot)
        scan(cupSource)
        let m = try store.db.read { db in try MediaRecord.fetchOne(db, sql: "SELECT * FROM media WHERE path = ?", arguments: [copy.path])! }
        XCTAssertNil(m.duplicateOf)
        XCTAssertEqual(m.status, .pending, "processed as the Cup's own photo")
    }
}
