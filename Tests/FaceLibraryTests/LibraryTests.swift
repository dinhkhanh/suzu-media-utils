import FaceCore
import GRDB
import ImageIO
import MediaKit
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

    /// A folder is looked at every 30 s when quiet, every 5 s while files arrive (or a card copies in), and goes
    /// back to 30 s after six quiet looks in a row.
    func testAFolderIsLookedAtFasterWhileFilesArriveAndSlowerWhenQuiet() throws {
        try makeFile("a.jpg")
        let m = monitor()
        m.start()
        defer { m.stop() }
        m.queue.sync {}  // the first look has run: it found a.jpg, so files are arriving
        XCTAssertEqual(m.pollInterval, SourceMonitor.fastPoll)
        m.queue.sync { for _ in 0..<SourceMonitor.quietPassesBeforeSlow { m.scan() } }
        XCTAssertEqual(m.pollInterval, SourceMonitor.slowPoll, "six quiet looks in a row")
        m.expectFiles()
        m.queue.sync {}
        XCTAssertEqual(m.pollInterval, SourceMonitor.fastPoll, "a card copying in")
        m.queue.sync { for _ in 1..<SourceMonitor.quietPassesBeforeSlow { m.pace(busy: false) } }
        XCTAssertEqual(m.pollInterval, SourceMonitor.fastPoll, "not quiet for long enough yet")
        try makeFile("b.jpg", seed: 2)
        m.queue.sync { m.scan() }
        XCTAssertEqual(m.pollInterval, SourceMonitor.fastPoll, "a look that found a new file keeps the fast pace")
        m.queue.sync { for _ in 1..<SourceMonitor.quietPassesBeforeSlow { m.pace(busy: false) } }
        XCTAssertEqual(m.pollInterval, SourceMonitor.fastPoll, "the count started over with the new file")
        m.queue.sync { m.pace(busy: false) }
        XCTAssertEqual(m.pollInterval, SourceMonitor.slowPoll)
    }

    /// A folder of a project that isn't open is looked at at its own pace when quiet, or not at all; opening the
    /// project looks at once and brings the open project's pace back.
    func testAnotherProjectsFolderIsLookedAtAtItsOwnPaceOrNotAtAll() throws {
        try makeFile("a.jpg")
        let m = monitor()
        m.setIdlePoll(nil)
        m.start()
        defer { m.stop() }
        m.queue.sync {}
        XCTAssertEqual(try media().count, 0, "not looked at while its project is closed")
        XCTAssertNil(m.pollInterval)

        m.setIdlePoll(SourceMonitor.slowPoll)
        m.queue.sync {}
        XCTAssertEqual(try media().map(\.url.lastPathComponent), ["a.jpg"], "opening the project looks at once")
        m.queue.sync { for _ in 0..<SourceMonitor.quietPassesBeforeSlow { m.scan() } }
        XCTAssertEqual(m.pollInterval, SourceMonitor.slowPoll)

        m.setIdlePoll(300)
        m.queue.sync {}
        XCTAssertEqual(m.pollInterval, 300, "closed again: every 5 minutes")
        XCTAssertFalse(m.followsEvents, "FSEvents wait for the next look")
        m.expectFiles()
        m.queue.sync {}
        XCTAssertEqual(m.pollInterval, SourceMonitor.fastPoll, "a card copying in is still followed closely")
        m.queue.sync { for _ in 0..<SourceMonitor.quietPassesBeforeSlow { m.pace(busy: false) } }
        XCTAssertEqual(m.pollInterval, 300, "and the folder's own pace comes back once it is quiet")
    }

    /// The open project's folders and the known-people folders keep the open pace; other projects' take the setting.
    func testOnlyOtherProjectsFoldersTakeTheirPace() throws {
        XCTAssertEqual(LibraryService.idlePoll(project: 1, kind: .media, open: 1, others: nil), SourceMonitor.slowPoll)
        XCTAssertEqual(LibraryService.idlePoll(project: 2, kind: .media, open: 1, others: nil), nil)
        XCTAssertEqual(LibraryService.idlePoll(project: 2, kind: .media, open: 1, others: 900), 900)
        XCTAssertEqual(LibraryService.idlePoll(project: nil, kind: .reference, open: 1, others: nil), SourceMonitor.slowPoll)
        XCTAssertEqual(LibraryService.idlePoll(project: 2, kind: .media, open: nil, others: nil), SourceMonitor.slowPoll, "All Projects")
    }

    func media() throws -> [MediaRecord] {
        try store.db.read { db in try MediaRecord.fetchAll(db, sql: "SELECT * FROM media ORDER BY path") }
    }

    func addFace(mediaId: Int64, personId: Int64?, vector: [Float] = [Float](repeating: 0.1, count: 512)) throws -> Int64 {
        var f = FaceRecord(id: nil, mediaId: mediaId, x: 0.4, y: 0.4, w: 0.1, h: 0.1, quality: 0.8, time: nil,
                           embedding: Vector.encode(Vector.normalized(vector)), track: nil, personId: personId,
                           assignment: personId == nil ? .none : .auto, rejectedPersonId: nil)
        // Simulates the processor: marks the file done and stores its fingerprint.
        try store.db.write { db in
            let m = try MediaRecord.fetchOne(db, key: mediaId)!
            try db.execute(sql: "UPDATE media SET status = 'done', width = 1500, height = 1000, contentKey = COALESCE(contentKey, ?) WHERE id = ?",
                           arguments: [ContentKey.compute(m.url, size: m.size), mediaId])
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
        XCTAssertTrue(all.allSatisfy { $0.status == .pending && $0.contentKey == nil }, "fingerprints are deferred to processing")

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

    /// Ratings written into a photo change its bytes; the library must still see the same file (no reprocessing,
    /// which would drop its faces), and a later scan must not take it for a changed file either.
    func testWritingMarksIntoAPhotoKeepsItsFaces() throws {
        let url = root.appendingPathComponent("a.jpg")
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
        let m = monitor()
        m.scan()
        let id = try XCTUnwrap(try store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM media") })
        try store.db.write { db in
            try db.execute(sql: "UPDATE media SET status = 'done' WHERE id = ?", arguments: [id])
            var f = FaceRecord(id: nil, mediaId: id, x: 0.4, y: 0.4, w: 0.2, h: 0.2, quality: 0.8, time: nil, embedding: nil, track: nil,
                               personId: nil, assignment: .none, rejectedPersonId: nil)
            try f.insert(db)
            try Marks.apply(.rating(4), to: [id], db: db)
            try Marks.apply(.label(.green), to: [id], db: db)
        }

        XCTAssertEqual(try Marks.writeToFiles([id], store: store).written, 1)
        XCTAssertEqual(Metadata.rating(in: url).rating, 4)
        XCTAssertEqual(Metadata.rating(in: url).label, "Green")
        m.scan()
        m.scan()
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face WHERE mediaId = ?", arguments: [id]) }, 1)
        XCTAssertEqual(try store.db.read { db in try String.fetchOne(db, sql: "SELECT status FROM media WHERE id = ?", arguments: [id]) }, "done")

        // A reject is written as rating -1, as Bridge does; no label clears the old one.
        try store.db.write { db in
            try Marks.apply(.flag(.reject), to: [id], db: db)
            try Marks.apply(.label(nil), to: [id], db: db)
        }
        XCTAssertEqual(try Marks.writeToFiles([id], store: store).written, 1)
        XCTAssertEqual(Metadata.rating(in: url).rating, -1)
        XCTAssertEqual(Metadata.rating(in: url).label ?? "", "")
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

    func testLargeFolderIsRegisteredInBatchesAndStopsWhenCancelled() throws {
        for i in 0..<(SourceMonitor.batchSize * 2 + 10) { try makeFile("big/\(i).jpg", bytes: 64 + i, seed: UInt8(i % 250 + 1)) }
        var batches = 0
        let s = try store.db.read { db in try SourceRecord.fetchOne(db, key: sourceId)! }
        let m = SourceMonitor(source: s, store: store) { newPending, _ in if newPending { batches += 1 } }
        m.scan()
        XCTAssertEqual(try media().count, SourceMonitor.batchSize * 2 + 10)
        XCTAssertEqual(batches, 3, "processing is told after every batch, not once at the end")
        XCTAssertEqual(m.foundCount, SourceMonitor.batchSize * 2 + 10)

        try makeFile("big/late.jpg", bytes: 9999)
        m.stop()
        m.scan()
        XCTAssertFalse(try media().contains { $0.path.hasSuffix("late.jpg") }, "a stopped monitor scans nothing")
    }

    /// Files read while the share was dropping are marked unreadable; unchanged, a scan alone never looked at them
    /// again. Rescan, and the folder coming back online, give them another go.
    func testUnreadableFilesAreRetriedOnRescanAndWhenTheFolderIsBack() throws {
        try makeFile("a.jpg", seed: 1)
        try makeFile("b.jpg", seed: 2)
        var told = 0
        let s = try store.db.read { db in try SourceRecord.fetchOne(db, key: sourceId)! }
        let m = SourceMonitor(source: s, store: store) { newPending, _ in if newPending { told += 1 } }
        m.scan()
        func failAll() throws { try store.db.write { db in try db.execute(sql: "UPDATE media SET status = 'failed', error = 'gone'") } }
        try failAll()
        told = 0
        m.scan()
        XCTAssertTrue(try media().allSatisfy { $0.status == .failed }, "a plain look leaves them")

        m.queue.suspend()  // a look already under way: the Rescan waits for it
        m.rescan()
        XCTAssertTrue(m.isRescanning, "shown from the click, not only once it starts")
        m.queue.resume()
        m.queue.sync {}
        XCTAssertFalse(m.isRescanning)
        XCTAssertEqual(m.retriedCount, 2)
        XCTAssertTrue(try media().allSatisfy { $0.status == .pending && $0.error == nil })
        XCTAssertEqual(told, 1, "processing is told")

        try failAll()
        let away = tmp.appendingPathComponent("away")
        try FileManager.default.moveItem(at: root, to: away)
        m.scan()
        XCTAssertFalse(m.isOnline)
        try FileManager.default.moveItem(at: away, to: root)
        m.scan()
        XCTAssertTrue(m.isOnline)
        XCTAssertTrue(try media().allSatisfy { $0.status == .pending }, "back online: retried")

        try failAll()
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.jpg"))
        m.rescan()
        m.queue.sync {}
        XCTAssertEqual(try media().map(\.status), [.pending], "a file that is gone is not retried (the scan drops it)")
    }

    /// Photos coming in go ahead of a backlog (thousands of unreadable files a Rescan put back): a card this Mac
    /// copies first, then files that just turned up, then the rest.
    func testFilesThatJustTurnedUpAreProcessedBeforeTheBacklog() {
        let now = 1_000_000.0
        XCTAssertEqual(Processor.priority(localWork: true, seenAt: now - 86_400, now: now), .veryHigh)
        XCTAssertEqual(Processor.priority(localWork: false, seenAt: now - 5, now: now), .high)
        XCTAssertEqual(Processor.priority(localWork: false, seenAt: now - Processor.freshFor - 1, now: now), .normal)
        XCTAssertEqual(Processor.priority(localWork: false, seenAt: nil, now: now), .normal, "libraries from before seenAt")
    }

    /// A folder that can't be read for a moment (the share dropping half-way through a look) is not an empty one:
    /// its files used to be dropped from the library with their faces, and read again from scratch once it was back.
    func testAFolderThatCantBeReadKeepsItsFilesAndFaces() throws {
        try makeFile("a.jpg", seed: 1)
        try makeFile("sub/b.jpg", seed: 2)
        try makeFile("sub/deeper/c.jpg", seed: 3)
        let m = monitor()
        m.scan()
        let pid = try newPerson("An")
        for r in try media() { _ = try addFace(mediaId: r.id!, personId: pid) }
        let before = try media()

        let sub = root.appendingPathComponent("sub")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sub.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.appendingPathComponent("b.jpg").path), "looks gone, as on a dropped share")
        m.dirCache = [:]  // not even a listing to fall back on, as after Rescan
        m.scan()
        XCTAssertEqual(try media().map(\.id), before.map(\.id), "nothing dropped")
        XCTAssertEqual(try store.db.read { db in try FaceRecord.fetchCount(db) }, 3)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path)
        m.scan()
        XCTAssertEqual(try media().map(\.id), before.map(\.id), "back: the same records, nothing to read again")
        XCTAssertTrue(try media().allSatisfy { $0.status == .done })

        // A whole listing still notices a file deleted for real.
        try FileManager.default.removeItem(at: sub.appendingPathComponent("b.jpg"))
        m.scan()
        XCTAssertEqual(try media().map(\.url.lastPathComponent), ["a.jpg", "c.jpg"])
    }

    func testRemoveSourceDeletesEverythingInBatches() throws {
        for i in 0..<1200 { try makeFile("r/\(i).jpg", bytes: 64 + i) }
        let service = LibraryServiceStub(store: store)
        monitor().scan()
        XCTAssertEqual(try media().count, 1200)
        try service.removeSource(sourceId)
        XCTAssertEqual(try media().count, 0)
        XCTAssertEqual(try store.db.read { db in try SourceRecord.fetchCount(db) }, 0)
    }

    func testRemovedFolderLeavesNamesThatAreRecognisedAgain() throws {
        var rng = SplitMix(seed: 7)
        let ids = identities(2, seed: 3)
        for i in 0..<4 { try makeFile("a/\(i).jpg", bytes: 100 + i) }
        monitor().scan()
        let named = try newPerson("Chi Pu"), group = try newPerson(nil)
        for (i, m) in try media().enumerated() { _ = try addFace(mediaId: m.id!, personId: i < 3 ? named : group, vector: jitter(ids[0], &rng, amount: 0.2)) }
        try LibraryServiceStub(store: store).removeSource(sourceId)
        let remembered = try store.db.read { db in try Int.fetchOne(db, sql: "SELECT count FROM personMemory WHERE personId = ?", arguments: [named]) }
        XCTAssertEqual(remembered, 3, "only the named person's faces are remembered")

        var s = SourceRecord(path: root.path)
        try store.db.write { db in try s.insert(db) }
        sourceId = s.id
        for i in 0..<2 { try makeFile("b/\(i).jpg", bytes: 200 + i) }
        monitor().scan()
        let again = try media()
        _ = try addFace(mediaId: again[0].id!, personId: nil, vector: jitter(ids[0], &rng, amount: 0.2))
        _ = try addFace(mediaId: again[1].id!, personId: nil, vector: jitter(ids[1], &rng, amount: 0.2))
        let engine = GroupingEngine(store: store)
        try engine.rebuildAll()
        try engine.assignPending(mediaIds: again.map { $0.id! })
        let back = try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT personId FROM face WHERE personId IS NOT NULL") }
        XCTAssertEqual(back, [named], "the same person's new photo gets the kept name; someone else doesn't")
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

    /// Copies run several at a time; two cameras' 1.jpg for the same person still land as two files (or one is
    /// skipped), never on top of each other.
    func testParallelExportKeepsCollidingNamesApart() throws {
        for i in 0..<6 {
            try makeFile("cam\(i)/1.jpg", seed: UInt8(i + 1))
            try makeFile("cam\(i)/2.jpg", seed: UInt8(i + 10))
        }
        let m = monitor()
        m.scan()
        let an = try newPerson("An")
        for r in try media() { _ = try addFace(mediaId: r.id!, personId: an) }
        let exporter = Exporter(store: store)
        let out = tmp.appendingPathComponent("Out", isDirectory: true)
        let both = exporter.run(try exporter.plan(personId: an, name: "An", base: out), policy: .keepBoth, workers: 4)
        XCTAssertEqual(both.done, 12)
        XCTAssertTrue(both.failed.isEmpty, "\(both.failed)")
        let names = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("An").path).sorted()
        XCTAssertEqual(names.count, 12)
        var expected: Set<String> = ["1.jpg", "2.jpg"]
        for n in 2...6 { expected.insert("1 (\(n)).jpg"); expected.insert("2 (\(n)).jpg") }
        XCTAssertEqual(Set(names), expected)
        // Skip policy: one of each name is written, the others wait for nobody and are skipped.
        let out2 = tmp.appendingPathComponent("Out2", isDirectory: true)
        let skip = exporter.run(try exporter.plan(personId: an, name: "An", base: out2), policy: .skip, workers: 4)
        XCTAssertEqual(skip.done, 2)
        XCTAssertEqual(skip.skippedExisting, 10)
        XCTAssertEqual(skip.handled.count, 12)
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

    /// Photos and videos in two folders inside the person's folder, or each in a folder of its own; a kind without
    /// a folder is left out.
    func testPhotosAndVideosGoWhereTheyAreSent() throws {
        try makeFile("a.jpg", seed: 1)
        try makeFile("b.mp4", seed: 2)
        monitor().scan()
        let an = try newPerson("An")
        for m in try media() { _ = try addFace(mediaId: m.id!, personId: an) }
        let exporter = Exporter(store: store)
        func targets(_ kinds: Exporter.KindFolders, base: URL? = nil) throws -> [String] {
            var o = Exporter.Options(); o.kinds = kinds
            return try exporter.plan(personId: an, name: "An", base: base, options: o).items.map(\.to.path).sorted()
        }
        XCTAssertEqual(try targets(.subfolders(photos: "Photos", videos: "Videos")),
                       [root.appendingPathComponent("An/Photos/a.jpg").path, root.appendingPathComponent("An/Videos/b.mp4").path])
        XCTAssertEqual(try targets(.subfolders(photos: "Photos", videos: "")), [root.appendingPathComponent("An/Photos/a.jpg").path], "videos left out")
        let p = tmp.appendingPathComponent("P"), v = tmp.appendingPathComponent("V")
        XCTAssertEqual(try targets(.folders(photos: p, videos: v)),
                       [p.appendingPathComponent("An/a.jpg").path, v.appendingPathComponent("An/b.mp4").path])
        XCTAssertEqual(try targets(.folders(photos: nil, videos: v)), [v.appendingPathComponent("An/b.mp4").path], "photos left out")

        // Move All into the two folders, then again: already in place, nothing moves out of them.
        var o = Exporter.Options(); o.kinds = .subfolders(photos: "Photos", videos: "Videos")
        let r = exporter.run(try exporter.planAll(people: [(an, "An")], base: nil, mode: .move, options: o))
        XCTAssertEqual(r.done, 2, "\(r.failed)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("An/Videos/b.mp4").path))
        let again = try exporter.planAll(people: [(an, "An")], base: nil, mode: .move, options: o)
        XCTAssertTrue(again.items.isEmpty)
        XCTAssertEqual(again.alreadyThere, 2)
    }

    /// Stop: the file under way finishes, no new one starts, and running it again does the rest.
    func testACopyCanBeStoppedAndFinishedLater() throws {
        for i in 0..<6 { try makeFile("s/\(i).jpg", seed: UInt8(i + 1)) }
        monitor().scan()
        let an = try newPerson("An")
        for m in try media() { _ = try addFace(mediaId: m.id!, personId: an) }
        let exporter = Exporter(store: store)
        let out = tmp.appendingPathComponent("out")
        let plan = try exporter.plan(personId: an, name: "An", base: out)
        var finished = 0
        let r = exporter.run(plan, workers: 1, isCancelled: { finished >= 2 }) { finished = $0 }
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.done, 2)
        XCTAssertEqual(r.notStarted, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("An").path).count, 2, "nothing half-written")

        let rest = exporter.run(try exporter.plan(personId: an, name: "An", base: out), workers: 4)
        XCTAssertFalse(rest.cancelled)
        XCTAssertEqual(rest.done, 4)
        XCTAssertEqual(rest.skippedExisting, 2, "the first two are already there")
    }

    /// Off a network share the copy is the ordinary one; it never replaces a file.
    func testCopyOnALocalDiskIsAnOrdinaryCopy() throws {
        let a = try makeFile("a.jpg", seed: 3)
        let dest = root.appendingPathComponent("copy.jpg")
        XCTAssertFalse(try Exporter.copy(a, to: dest))
        XCTAssertEqual(try Data(contentsOf: dest), try Data(contentsOf: a))
        try Data("mine".utf8).write(to: dest)
        XCTAssertThrowsError(try Exporter.copy(a, to: dest))
        XCTAssertEqual(try Data(contentsOf: dest), Data("mine".utf8))
    }

    /// On a share (SUZU_SHARE_TEST_DIR, a writable folder on an SMB share), the server copies the file: same bytes,
    /// the original's date, nothing through this Mac.
    func testCopyWithinAShareIsDoneByTheServer() throws {
        guard let dir = ProcessInfo.processInfo.environment["SUZU_SHARE_TEST_DIR"] else { throw XCTSkip("no share to try") }
        let folder = URL(fileURLWithPath: dir).appendingPathComponent("suzu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.bin"), b = folder.appendingPathComponent("b.bin")
        try Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: a)
        Thread.sleep(forTimeInterval: 2)  // a share settles a fresh file's date a moment after it is written
        XCTAssertTrue(try Exporter.copy(a, to: b), "the server copied it")
        XCTAssertEqual(try Data(contentsOf: b), try Data(contentsOf: a))
        func date(_ u: URL) throws -> Double { try (FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0 }
        XCTAssertEqual(try date(b), try date(a), accuracy: 1, "the original's date, not the copy's (to the second: a share keeps less)")
    }

    func makeRealJPEG(_ rel: String, seed: Int) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: Double(seed % 7) / 7, green: 0.4, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
        return url
    }

    func testExportTopNBestOfBurstEditsAndNames() throws {
        for i in 0..<4 { try makeRealJPEG("e/\(i).png.jpg", seed: i) }
        monitor().scan()
        let all = try media()
        let an = try newPerson("An")
        var faceIds: [Int64] = []
        for m in all { faceIds.append(try addFace(mediaId: m.id!, personId: an)) }
        // Scores: photo 2 best, 0 next; photos 0 and 1 are one burst.
        try store.db.write { db in
            for (i, s) in [0.8, 0.5, 0.9, 0.3].enumerated() {
                try db.execute(sql: "UPDATE face SET score = ? WHERE id = ?", arguments: [s, faceIds[i]])
            }
            try db.execute(sql: "UPDATE media SET burstId = ? WHERE id IN (?, ?)", arguments: [all[0].id, all[0].id, all[1].id])
        }
        let exporter = Exporter(store: store)
        var opts = Exporter.Options()
        opts.bestOfBurst = true
        opts.topN = 2
        var plan = try exporter.plan(personId: an, name: "An", base: nil, options: opts)
        XCTAssertEqual(Set(plan.items.map(\.mediaId)), [all[2].id!, all[0].id!], "top 2 after dropping the weaker burst shot")

        opts.recipe = EditRecipe()
        opts.recipe!.aspect = .square
        opts.recipe!.maxLongSide = 300
        plan = try exporter.plan(personId: an, name: "An", base: nil, mode: .move, options: opts)
        XCTAssertTrue(plan.items.allSatisfy { $0.operation == .copy && $0.to.pathExtension == "jpg" }, "edits never move originals")
        let r = exporter.run(plan)
        XCTAssertEqual(r.done, 2, "\(r.failed)")
        let out = plan.items[0].to
        XCTAssertEqual(Metadata.people(in: out), ["An"])
        let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 300)
        // Edited copies are known to the library, so a rescan adds nothing to process.
        monitor().scan()
        XCTAssertEqual(try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") }, 0)

        var tag = Exporter.Options()
        tag.writeNames = true
        let tagged = try exporter.plan(personId: an, name: "An tagged", base: nil, options: tag)
        _ = exporter.run(tagged)
        XCTAssertEqual(Metadata.people(in: tagged.items[0].to), ["An"])
        XCTAssertTrue(Metadata.people(in: all[0].url).isEmpty, "originals untouched")
    }

    func testSearchAllAnySoloAndSmartAlbum() throws {
        for i in 0..<4 { try makeFile("s/\(i).jpg", seed: UInt8(i + 1)) }
        monitor().scan()
        let m = try media()
        let an = try newPerson("An"), binh = try newPerson("Bình")
        _ = try addFace(mediaId: m[0].id!, personId: an)          // An solo
        _ = try addFace(mediaId: m[1].id!, personId: an)          // An + Bình
        _ = try addFace(mediaId: m[1].id!, personId: binh)
        _ = try addFace(mediaId: m[2].id!, personId: binh)        // Bình solo
        var q = MediaQuery()
        q.people = [an, binh]
        XCTAssertEqual(try q.run(store).map(\.id), [m[1].id!])
        q.match = .any
        XCTAssertEqual(Set(try q.run(store).map(\.id)), [m[0].id!, m[1].id!, m[2].id!])
        q.crowd = .solo
        XCTAssertEqual(Set(try q.run(store).map(\.id)), [m[0].id!, m[2].id!])

        var album = SmartAlbum(name: "Solo shots", query: q)
        try store.db.write { db in try album.insert(db) }
        let loaded = try store.db.read { db in try SmartAlbum.fetchOne(db, key: album.id!)! }
        XCTAssertEqual(loaded.mediaQuery, q)
    }

    func testDeliveryRuleCopiesNewFilesOnceAndNotifyOnly() throws {
        try makeFile("d/old.jpg", seed: 1)
        monitor().scan()
        let an = try newPerson("An")
        _ = try addFace(mediaId: try media()[0].id!, personId: an)
        let out = tmp.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let service = DeliveryService(store: store)
        try service.add(DeliveryRule(personId: an, folder: out.path, recipe: nil, writeNames: false), includeExisting: false)
        try service.add(DeliveryRule(personId: nil, folder: nil, recipe: nil, writeNames: false), includeExisting: false)
        XCTAssertTrue(try service.run().newFiles.isEmpty, "existing files are not delivered unless asked")

        try makeFile("d/new.jpg", seed: 2)
        monitor().scan()
        let newMedia = try media().first { $0.path.hasSuffix("new.jpg") }!
        _ = try addFace(mediaId: newMedia.id!, personId: an)
        let r = try service.run()
        XCTAssertEqual(r.copied, 1)
        XCTAssertEqual(r.newFiles["An"], 2, "one from the copy rule, one from the notify-only rule")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("An/new.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("An/old.jpg").path))
        XCTAssertTrue(try service.run().newFiles.isEmpty, "nothing is delivered twice")
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

extension LibraryTests {
    /// An edited folder's files are finished work (edits of photos already here): never read for faces. Faces they
    /// had go to an identical copy outside the folder when there is one, else they are dropped; a folder that is no
    /// longer an edited one is processed again.
    func testEditedFoldersAreNeverReadForFaces() throws {
        let editedRoot = URL(fileURLWithPath: canonicalPath(tmp), isDirectory: true).appendingPathComponent("Edited", isDirectory: true)
        try FileManager.default.createDirectory(at: editedRoot, withIntermediateDirectories: true)
        var edited = SourceRecord(path: editedRoot.path)
        try store.db.write { db in try edited.insert(db) }
        func write(_ url: URL, seed: UInt8) throws {
            try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* Int(seed)) }).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
        }
        func scanEdited() throws {
            let s = try store.db.read { db in try SourceRecord.fetchOne(db, key: edited.id!)! }
            SourceMonitor(source: s, store: store) { _, _ in }.scan()
        }
        func row(_ url: URL) throws -> MediaRecord { try media().first { $0.path == url.path }! }
        func faces(_ url: URL) throws -> Int {
            let id = try row(url).id!
            return try store.db.read { db in try FaceRecord.filter(Column("mediaId") == id).fetchCount(db) }
        }
        func setEdited(_ on: Bool) throws {
            try store.db.write { db in try db.execute(sql: "UPDATE source SET share = ? WHERE id = ?", arguments: [on ? "edited" : "mac", edited.id!]) }
        }

        // Processed while still an ordinary folder; the event folder has a copy of one of its files.
        let x = editedRoot.appendingPathComponent("x.jpg"), y = editedRoot.appendingPathComponent("y.jpg")
        try write(x, seed: 5)
        try write(y, seed: 6)
        try scanEdited()
        let an = try newPerson("An")
        _ = try addFace(mediaId: try row(x).id!, personId: an)
        _ = try addFace(mediaId: try row(y).id!, personId: an)
        let yCopy = root.appendingPathComponent("y.jpg")
        try FileManager.default.copyItem(at: y, to: yCopy)
        monitor().scan()
        XCTAssertEqual(try row(yCopy).duplicateOf, try row(y).id)

        try setEdited(true)
        var (affected, reopened) = try LibraryService.settleEditedFolders(store: store)
        XCTAssertEqual(affected, [an])
        XCTAssertFalse(reopened)
        XCTAssertEqual(try faces(x), 0)
        XCTAssertTrue(try row(x).skippedAsEdited)
        XCTAssertEqual(try row(x).status, .done)
        XCTAssertEqual(try faces(yCopy), 1, "the copy outside the edited folder keeps the face")
        XCTAssertNil(try row(yCopy).duplicateOf)
        XCTAssertEqual(try row(y).duplicateOf, try row(yCopy).id)
        let remembered = try store.db.read { db in try Int.fetchOne(db, sql: "SELECT count FROM personMemory WHERE personId = ?", arguments: [an]) }
        XCTAssertEqual(remembered, 1, "the named face dropped from x is remembered")

        // A new file there is listed, not processed; a copy of a skipped file elsewhere is its own original.
        let z = editedRoot.appendingPathComponent("z.jpg")
        try write(z, seed: 7)
        try scanEdited()
        XCTAssertEqual(try row(z).status, .pending)
        (affected, _) = try LibraryService.settleEditedFolders(store: store)
        XCTAssertTrue(affected.isEmpty)
        XCTAssertEqual(try row(z).status, .done)
        XCTAssertTrue(try row(z).skippedAsEdited)
        let xCopy = root.appendingPathComponent("x.jpg")
        try FileManager.default.copyItem(at: x, to: xCopy)
        monitor().scan()
        XCTAssertNil(try row(xCopy).duplicateOf)
        XCTAssertEqual(try row(xCopy).status, .pending)

        // An edited file saved again over itself is skipped again, not left waiting (the processor never takes it).
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 9) }).write(to: z)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1800)], ofItemAtPath: z.path)
        try scanEdited()
        XCTAssertEqual(try row(z).status, .pending)
        _ = try LibraryService.settleEditedFolders(store: store)
        XCTAssertEqual(try row(z).status, .done)
        XCTAssertTrue(try row(z).skippedAsEdited)
        // One already stuck that way (an older version kept the skip when the file changed) is finished too.
        try store.db.write { db in try db.execute(sql: "UPDATE media SET status = 'pending' WHERE id = ?", arguments: [try row(z).id!]) }
        _ = try LibraryService.settleEditedFolders(store: store)
        XCTAssertEqual(try row(z).status, .done)

        // No longer an edited folder: its files are processed.
        try setEdited(false)
        (_, reopened) = try LibraryService.settleEditedFolders(store: store)
        XCTAssertTrue(reopened)
        XCTAssertEqual(try [x, z].map { try row($0).status }, [.pending, .pending])
        XCTAssertFalse(try row(x).skippedAsEdited)
        XCTAssertEqual(try row(y).duplicateOf, try row(yCopy).id, "a copy stays a copy")
    }
}

/// Removal logic without the model-dependent processor.
struct LibraryServiceStub {
    let store: LibraryStore
    func removeSource(_ id: Int64) throws {
        try LibraryService.deleteSourceContents(id, store: store)
    }
}

extension LibraryTests {
    func testExportSkipsBlurryMainFacesAndMeasuresKnownFiles() throws {
        for i in 0..<3 { try makeFile("b/\(i).jpg", seed: UInt8(i + 1)) }
        monitor().scan()
        let all = try media()
        let an = try newPerson("An")
        var faceIds: [Int64] = []
        for m in all { faceIds.append(try addFace(mediaId: m.id!, personId: an)) }
        // Photo 0: soft main face. Photo 1: a tiny soft face in the background plus a crisp main face. Photo 2: crisp.
        let small = try addFace(mediaId: all[1].id!, personId: nil)
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET sharpness = 20 WHERE id = ?", arguments: [faceIds[0]])
            try db.execute(sql: "UPDATE face SET sharpness = 500, score = 0.7 WHERE id = ?", arguments: [faceIds[1]])
            try db.execute(sql: "UPDATE face SET sharpness = 10, w = 0.02, h = 0.02 WHERE id = ?", arguments: [small])
            try db.execute(sql: "UPDATE face SET sharpness = 400 WHERE id = ?", arguments: [faceIds[2]])
            try db.execute(sql: "UPDATE media SET takenAt = 1000, featurePrint = ? WHERE id = ?", arguments: [Vector.encode([1, 0]), all[2].id])
        }
        var opts = Exporter.Options()
        opts.skipBlurry = true
        let plan = try Exporter(store: store).plan(personId: an, name: "An", base: nil, options: opts)
        XCTAssertEqual(Set(plan.items.map(\.mediaId)), [all[1].id!, all[2].id!], "only the photo whose main face is soft is left out")
        let flat = try Exporter(store: store).planFlat(all.map { $0.id! }, base: tmp.appendingPathComponent("out"), options: opts)
        XCTAssertEqual(Set(flat.items.map(\.mediaId)), [all[1].id!, all[2].id!])

        let measures = try Selection.measures(store, urls: all.map(\.url) + [root.appendingPathComponent("unknown.jpg")])
        XCTAssertEqual(measures.count, 3, "files the library never saw are left to the caller")
        XCTAssertEqual(measures[all[0].url]?.faceSharpness, 20)
        XCTAssertEqual(measures[all[1].url]?.faceSharpness, 500, "the biggest face, not the tiny soft one")
        XCTAssertEqual(measures[all[1].url]?.faceScore, 0.7)
        XCTAssertEqual(measures[all[2].url]?.featurePrint, [1, 0])
        XCTAssertEqual(measures[all[2].url]?.takenAt, Date(timeIntervalSince1970: 1000))
        XCTAssertNil(measures[all[0].url]?.featurePrint, "no print before the idle pass")
    }
}

extension LibraryTests {
    func testRawFilesPairWithTheirJPEGs() throws {
        // Camera shooting RAW+JPEG: listed in either order, the RAW follows its JPEG. A lone RAW is a photo of its own.
        try makeFile("r/IMG_0001.CR2", seed: 1)
        try makeFile("r/IMG_0001.JPG", seed: 2)
        try makeFile("r/zz_0002.jpg", seed: 3)
        try makeFile("r/aa_0002.arw", seed: 4)   // different name: not a pair
        try makeFile("r/DSC_0003.nef", seed: 5)  // RAW only
        monitor().scan()
        var all = try media()
        XCTAssertEqual(all.map(\.url.lastPathComponent), ["DSC_0003.nef", "IMG_0001.CR2", "IMG_0001.JPG", "aa_0002.arw", "zz_0002.jpg"])
        let jpg = all[2], raw = all[1]
        XCTAssertEqual(raw.duplicateOf, jpg.id)
        XCTAssertEqual(raw.status, .done, "a companion is never processed on its own")
        XCTAssertEqual(jpg.status, .pending)
        XCTAssertTrue([all[0], all[3], all[4]].allSatisfy { $0.duplicateOf == nil && $0.status == .pending })

        // The RAW arrives first and waits; its JPEG arrives a moment later.
        try makeFile("r/IMG_0004.cr3", seed: 6)
        monitor().scan()
        try makeFile("r/IMG_0004.jpg", seed: 7)
        monitor().scan()
        all = try media()
        let late = all.first { $0.url.lastPathComponent == "IMG_0004.cr3" }!, lateJpg = all.first { $0.url.lastPathComponent == "IMG_0004.jpg" }!
        XCTAssertEqual(late.duplicateOf, lateJpg.id)
        XCTAssertEqual(late.status, .done)

        // The RAW was already processed when its JPEG came: both stay as they are.
        try makeFile("r/IMG_0005.dng", seed: 8)
        monitor().scan()
        let dng = try media().first { $0.url.lastPathComponent == "IMG_0005.dng" }!
        _ = try addFace(mediaId: dng.id!, personId: nil)
        try makeFile("r/IMG_0005.jpg", seed: 9)
        monitor().scan()
        all = try media()
        XCTAssertNil(all.first { $0.url.lastPathComponent == "IMG_0005.dng" }!.duplicateOf)
        XCTAssertEqual(all.first { $0.url.lastPathComponent == "IMG_0005.jpg" }!.status, .pending)

        // Edit & Export starts from a pair's RAW: found by the JPEG's id; nothing for a lone JPEG or RAW.
        let lone = all.first { $0.url.lastPathComponent == "zz_0002.jpg" }!, nef = all.first { $0.url.lastPathComponent == "DSC_0003.nef" }!
        let partners = try store.db.read { db in try Selection.rawPartners(db, mediaIds: [jpg.id!, lateJpg.id!, lone.id!, nef.id!]) }
        XCTAssertEqual(partners.mapValues(\.lastPathComponent), [jpg.id!: "IMG_0001.CR2", lateJpg.id!: "IMG_0004.cr3"])

        // Companions are left out of exports and searches, like copies.
        XCTAssertTrue(ImageLoader.isRaw(raw.url))
        XCTAssertEqual(ImageLoader.pairKey("/a/B/IMG_0001.CR2"), ImageLoader.pairKey("/a/B/img_0001.jpg"))
        XCTAssertNotEqual(ImageLoader.pairKey("/a/IMG_0001.CR2"), ImageLoader.pairKey("/b/IMG_0001.jpg"))
    }

    func testQuerySkipsBlurryMainFacesAndReadsOldQueries() throws {
        for i in 0..<3 { try makeFile("q/\(i).jpg", seed: UInt8(i + 1)) }
        monitor().scan()
        let all = try media()
        let an = try newPerson("An")
        var faces: [Int64] = []
        for m in all { faces.append(try addFace(mediaId: m.id!, personId: an)) }
        let tiny = try addFace(mediaId: all[1].id!, personId: nil)
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET sharpness = 20 WHERE id = ?", arguments: [faces[0]])      // soft main face
            try db.execute(sql: "UPDATE face SET sharpness = 500 WHERE id = ?", arguments: [faces[1]])     // crisp main face…
            try db.execute(sql: "UPDATE face SET sharpness = 5, w = 0.02, h = 0.02 WHERE id = ?", arguments: [tiny])  // …with a soft tiny one behind
            // faces[2]: no measurement
        }
        var q = MediaQuery()
        q.people = [an]
        XCTAssertEqual(try q.run(store).count, 3)
        q.skipBlurry = true
        XCTAssertEqual(Set(try q.run(store).map(\.id)), [all[1].id!, all[2].id!])

        let old = try JSONDecoder().decode(MediaQuery.self, from: Data(#"{"people":[1],"match":"any","bestOnly":true,"bestThreshold":0.6,"crowd":"solo"}"#.utf8))
        XCTAssertEqual(old.people, [1]); XCTAssertEqual(old.match, .any); XCTAssertTrue(old.bestOnly); XCTAssertEqual(old.crowd, .solo)
        XCTAssertFalse(old.collapseBursts); XCTAssertFalse(old.skipBlurry)
        let round = try JSONDecoder().decode(MediaQuery.self, from: try JSONEncoder().encode(q))
        XCTAssertEqual(round, q)
    }
}

/// Copies and RAW companions keep the photo's faces when its original leaves (0.8.15 and before left a copy done
/// and faceless when the original's folder was removed, and its RAW then stood for the photo).
extension LibraryTests {
    /// A second folder of the same kind and project as `root`, with the same bytes as `root/rel` at `rel`.
    func otherFolder(copying rel: String, raw: String? = nil) throws -> (source: Int64, copy: URL, raw: URL?) {
        let dir = URL(fileURLWithPath: canonicalPath(tmp), isDirectory: true).appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = SourceRecord(path: dir.path)
        try store.db.write { db in try s.insert(db) }
        let copy = dir.appendingPathComponent((rel as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: root.appendingPathComponent(rel), to: copy)
        var rawURL: URL?
        if let raw {
            rawURL = dir.appendingPathComponent(raw)
            try Data(repeating: 9, count: 9000).write(to: rawURL!)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: rawURL!.path)
        }
        return (s.id!, copy, rawURL)
    }

    func record(_ url: URL) throws -> MediaRecord { try media().first { $0.path == url.path }! }

    func testRemovingAFolderHandsTheFacesToACopyElsewhere() throws {
        try makeFile("a.jpg", seed: 3)
        monitor().scan()
        let original = try media()[0]
        let an = try newPerson("An")
        let face = try addFace(mediaId: original.id!, personId: an)
        try store.db.write { db in try db.execute(sql: "UPDATE media SET takenAt = 1700000000 WHERE id = ?", arguments: [original.id]) }
        let other = try otherFolder(copying: "a.jpg", raw: "a.arw")
        let s = try store.db.read { db in try SourceRecord.fetchOne(db, key: other.source)! }
        SourceMonitor(source: s, store: store) { _, _ in }.scan()
        XCTAssertEqual(try record(other.copy).duplicateOf, original.id, "a copy")
        XCTAssertEqual(try record(other.raw!).duplicateOf, original.id, "the copy's RAW goes with the photo's original, not on its own")

        try LibraryServiceStub(store: store).removeSource(sourceId)
        let copy = try record(other.copy)
        XCTAssertNil(copy.duplicateOf)
        XCTAssertEqual(copy.status, .done)
        XCTAssertEqual(copy.takenAt, 1_700_000_000)
        XCTAssertEqual(try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM face WHERE mediaId = ?", arguments: [copy.id]) }, [face],
                       "the same face, with its person")
        XCTAssertEqual(try record(other.raw!).duplicateOf, copy.id, "the RAW follows")
    }

    func testACopyLeftWithoutItsOriginalIsReadAgain() throws {
        try makeFile("a.jpg", seed: 3)
        monitor().scan()
        let original = try media()[0]
        _ = try addFace(mediaId: original.id!, personId: try newPerson("An"))
        let other = try otherFolder(copying: "a.jpg")
        let s = try store.db.read { db in try SourceRecord.fetchOne(db, key: other.source)! }
        SourceMonitor(source: s, store: store) { _, _ in }.scan()
        // Any way the original goes without handing over (here: a plain delete).
        try store.db.write { db in try db.execute(sql: "DELETE FROM media WHERE id = ?", arguments: [original.id]) }
        let copy = try record(other.copy)
        XCTAssertNil(copy.duplicateOf)
        XCTAssertEqual(copy.status, .pending, "not done and faceless for good")
    }

    func testRawPairsThatBecameTwoPhotosAreMadeOneAgain() throws {
        let an = try newPerson("An"), bo = try newPerson("Bo")
        func photo(_ rel: String, seed: UInt8, takenAt: Double?) throws -> Int64 {
            try makeFile(rel, seed: seed)
            var m = MediaRecord(sourceId: sourceId, path: root.appendingPathComponent(rel).path, kind: .photo, size: 4096, mtime: 0, contentKey: rel)
            m.status = .done; m.takenAt = takenAt
            try store.db.write { db in try m.insert(db) }
            return m.id!
        }
        func faces(_ m: Int64) throws -> [FaceRecord] {
            try store.db.read { db in try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ? ORDER BY id", arguments: [m]) }
        }
        // 1. The JPEG left faceless (a copy whose original went), the RAW processed on its own.
        let j1 = try photo("p/KHI00191.JPG", seed: 1, takenAt: nil), r1 = try photo("p/KHI00191.ARW", seed: 2, takenAt: 1_700_000_000)
        let rf1 = try addFace(mediaId: r1, personId: an)
        try store.db.write { db in try db.execute(sql: "UPDATE media SET takenAt = NULL WHERE id = ?", arguments: [j1]) }
        try store.db.write { db in try db.execute(sql: "UPDATE person SET coverFaceId = ? WHERE id = ?", arguments: [rf1, an]) }
        // 2. Both processed (before pairing existed): every face twice. The RAW's face was named by hand.
        let j2 = try photo("p/IMG_0002.jpg", seed: 3, takenAt: 1), r2 = try photo("p/IMG_0002.CR2", seed: 4, takenAt: 1)
        let jf2 = try addFace(mediaId: j2, personId: nil)
        let rf2 = try addFace(mediaId: r2, personId: bo)
        try store.db.write { db in
            try db.execute(sql: "UPDATE face SET assignment = 'user' WHERE id = ?", arguments: [rf2])
            try db.execute(sql: "UPDATE person SET coverFaceId = ? WHERE id = ?", arguments: [rf2, bo])
        }
        // 3. A copy that lost its original, alone: read again.
        let lone = try photo("p/lonely.jpg", seed: 5, takenAt: nil)

        try store.db.write { db in try RawPairs.repair(db) }

        XCTAssertEqual(try faces(j1).map(\.id), [rf1], "the RAW's face is the JPEG's now")
        XCTAssertEqual(try record(root.appendingPathComponent("p/KHI00191.JPG")).takenAt, 1_700_000_000)
        XCTAssertEqual(try record(root.appendingPathComponent("p/KHI00191.ARW")).duplicateOf, j1)
        XCTAssertEqual(try record(root.appendingPathComponent("p/KHI00191.JPG")).status, .done)
        XCTAssertEqual(try faces(j2).map(\.id), [jf2], "the JPEG's own face stays")
        XCTAssertEqual(try faces(j2)[0].personId, bo, "with the name given on the RAW")
        XCTAssertEqual(try faces(j2)[0].assignment, .user)
        XCTAssertEqual(try faces(r2).count, 0, "counted once")
        XCTAssertEqual(try record(root.appendingPathComponent("p/IMG_0002.CR2")).duplicateOf, j2)
        XCTAssertEqual(try store.db.read { db in try Int64?.fetchOne(db, sql: "SELECT coverFaceId FROM person WHERE id = ?", arguments: [bo]) }, jf2,
                       "the picture picked on the RAW is the JPEG's face")
        XCTAssertEqual(try store.db.read { db in try Int64?.fetchOne(db, sql: "SELECT coverFaceId FROM person WHERE id = ?", arguments: [an]) }, rf1)
        XCTAssertEqual(try record(root.appendingPathComponent("p/lonely.jpg")).status, .pending)
        _ = lone
    }
}
