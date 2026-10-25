import Foundation
import GRDB
import MediaKit
import XCTest
@testable import FaceLibrary

final class CardCopierTests: XCTestCase {
    var tmp: URL!
    var card: URL!
    var dest: URL!
    var store: LibraryStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        card = tmp.appendingPathComponent("CARD", isDirectory: true)
        dest = tmp.appendingPathComponent("Event", isDirectory: true)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM/100CANON"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    func shoot(_ name: String, bytes: Int = 3000, seed: UInt8 = 1, mtime: Date = Date(timeIntervalSinceNow: -600)) throws -> URL {
        let url = card.appendingPathComponent("DCIM/100CANON/\(name)")
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* Int(seed) &+ Int(seed)) }).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    func plan() throws -> CardCopier.Plan {
        try CardCopier.plan(try XCTUnwrap(CardCopier.identify(card)), store: store)
    }

    func options(perHandover: Bool = true, keepLayout: Bool = false) -> CardCopier.Options {
        var o = CardCopier.Options(destination: dest)
        o.perHandover = perHandover
        o.keepLayout = keepLayout
        return o
    }

    func testAFolderIsKnownByItsMarkerAndKeepsItsIdentity() throws {
        let a = try XCTUnwrap(CardCopier.identify(card))
        let b = try XCTUnwrap(CardCopier.identify(card))
        XCTAssertEqual(a.uuid, b.uuid)
        XCTAssertEqual(a.volumeName, "CARD")
        XCTAssertTrue(FileManager.default.fileExists(atPath: card.appendingPathComponent(".suzu-card").path))
        XCTAssertTrue(CardCopier.looksLikeCard(card))
        XCTAssertFalse(CardCopier.looksLikeCard(dest))
    }

    /// Each file is reported the moment it lands (the library takes it up from the card right away), with what the
    /// copy knows of it; a RAW that came with its JPEG is flagged, sidecars are not reported.
    func testEachLandedFileIsReportedAtOnce() throws {
        try shoot("IMG_0001.JPG", seed: 1)
        try shoot("IMG_0001.CR2", bytes: 9000, seed: 2)
        try shoot("IMG_0002.CR2", bytes: 9000, seed: 3)
        try shoot("IMG_0001.xmp", bytes: 200, seed: 4)
        final class Seen: @unchecked Sendable { var landed: [CardCopier.Landed] = [] }
        let seen = Seen()
        var o = options()
        o.onCopied = { seen.landed.append($0) }
        let out = CardCopier.copy(try plan(), options: o, store: store)
        XCTAssertEqual(out.copied.count, 4)
        XCTAssertEqual(seen.landed.map { $0.landed.lastPathComponent }, ["IMG_0001.CR2", "IMG_0001.JPG", "IMG_0002.CR2"])
        XCTAssertEqual(seen.landed.map(\.rawWithJPEG), [true, false, false])
        for l in seen.landed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: l.landed.path), "reported after it is in place")
            XCTAssertEqual(l.onCard.lastPathComponent, l.landed.lastPathComponent)
            XCTAssertTrue(l.onCard.path.hasPrefix(card.path))
            XCTAssertEqual(ContentKey.compute(l.landed, size: l.size), l.contentKey)
        }
    }

    /// A teammate's copy that arrives after the plan was made is found by planning again from the earlier plan:
    /// files unchanged since keep the fingerprints read then (they are not read again), new ones are read, and the
    /// card's record is the current one.
    func testAPlanMadeAgainReusesItsFingerprintsAndReadsOnlyWhatChanged() throws {
        try shoot("IMG_0001.JPG", seed: 1)
        try shoot("IMG_0002.JPG", seed: 2)
        let p = try plan()
        XCTAssertEqual(p.new.map(\.name), ["IMG_0001.JPG", "IMG_0002.JPG"])
        // The team's ledger says another Mac copied IMG_0002 (same contents, under another name there), and a
        // teammate named the card.
        let key = try XCTUnwrap(p.keys["DCIM/100CANON/IMG_0002.JPG"])
        try store.db.write { db in
            try db.execute(sql: """
                INSERT INTO cardFile (cardId, relPath, size, mtime, contentKey, copiedAt, copiedTo, device) VALUES (?, 'DCIM/100CANON/DSC_9.JPG', 3000, 0, ?, ?, '/Volumes/NAS/Gala/DSC_9.JPG', 'other-mac')
                """, arguments: [p.card.id, key, Date()])
            try db.execute(sql: "UPDATE card SET label = 'Nam R5 card 1' WHERE id = ?", arguments: [p.card.id])
        }
        // IMG_0002's bytes change under the same size and time: a plan made from the earlier one must not notice
        // (it does not read the file again), a plan from scratch does.
        let mtime = try XCTUnwrap(p.files.first { $0.name == "IMG_0002.JPG" }).mtime
        try shoot("IMG_0002.JPG", seed: 7, mtime: mtime)
        try shoot("IMG_0003.JPG", seed: 3)
        let r = try CardCopier.plan(try XCTUnwrap(CardCopier.identify(card)), store: store, previous: p)
        XCTAssertEqual(r.new.map(\.name), ["IMG_0001.JPG", "IMG_0003.JPG"])
        XCTAssertEqual(r.copiedBefore.map(\.name), ["IMG_0002.JPG"])
        XCTAssertEqual(r.copiedElsewhere, 1)
        XCTAssertEqual(r.matched.count, 1)
        XCTAssertEqual(r.keys["DCIM/100CANON/IMG_0002.JPG"], key)
        XCTAssertNotNil(r.keys["DCIM/100CANON/IMG_0003.JPG"])
        XCTAssertEqual(r.card.label, "Nam R5 card 1")
        let fresh = try plan()
        XCTAssertEqual(fresh.new.map(\.name), ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.JPG"])
    }

    func testOnlyNewFilesAreCopiedAtTheNextHandOver() throws {
        let shot = Date(timeIntervalSince1970: 1_800_000_000)
        try shoot("IMG_0001.JPG", seed: 1, mtime: shot)
        try shoot("IMG_0002.JPG", seed: 2)
        try shoot("notes.txt", seed: 3)  // not media: never copied

        var p = try plan()
        XCTAssertEqual(p.new.map(\.name), ["IMG_0001.JPG", "IMG_0002.JPG"])
        XCTAssertEqual(p.newBytes, 6000)
        let first = CardCopier.copy(p, options: options(), store: store)
        XCTAssertEqual(first.copied.count, 2)
        XCTAssertTrue(first.failed.isEmpty)
        XCTAssertEqual(first.cardFolder.lastPathComponent, "CARD")
        XCTAssertEqual(first.folder.deletingLastPathComponent(), first.cardFolder)
        let copy1 = first.folder.appendingPathComponent("IMG_0001.JPG")
        XCTAssertEqual(try Data(contentsOf: copy1), try Data(contentsOf: card.appendingPathComponent("DCIM/100CANON/IMG_0001.JPG")))
        // The copy keeps when the photo was shot (videos are put in sessions by this).
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copy1.path)[.modificationDate] as? Date)
        XCTAssertEqual(mtime.timeIntervalSince1970, shot.timeIntervalSince1970, accuracy: 1)

        // The copies are moved away, filtered, edited: the card doesn't care.
        try FileManager.default.removeItem(at: first.folder)
        p = try plan()
        XCTAssertTrue(p.new.isEmpty)
        XCTAssertEqual(p.copiedBefore.count, 2)

        // The photographer keeps shooting; the card comes back.
        try shoot("IMG_0003.JPG", seed: 4)
        p = try plan()
        XCTAssertEqual(p.new.map(\.name), ["IMG_0003.JPG"])
        XCTAssertEqual(p.copiedBefore.count, 2)
        let second = CardCopier.copy(p, options: options(), store: store)
        XCTAssertEqual(second.copied, ["DCIM/100CANON/IMG_0003.JPG"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.folder.appendingPathComponent("IMG_0003.JPG").path))

        let known = try CardCopier.knownCards(store: store)
        XCTAssertEqual(known.count, 1)
        XCTAssertEqual(known[0].files, 3)
        XCTAssertNotNil(known[0].card.lastCopiedAt)
        XCTAssertEqual(known[0].card.lastCopiedTo, second.folder.path)
        let sha = try store.db.read { db in try String.fetchOne(db, sql: "SELECT sha256 FROM cardFile WHERE relPath LIKE '%0003%'") }
        XCTAssertEqual(sha, FolderVerifier.sha256(second.folder.appendingPathComponent("IMG_0003.JPG")))
    }

    func testARenamedOrHandCopiedFileIsNotCopiedTwice() throws {
        try shoot("IMG_0001.JPG", seed: 1)
        try shoot("IMG_0002.JPG", seed: 2)
        _ = CardCopier.copy(try plan(), options: options(), store: store)
        // The camera's counter rolled over: a new folder, same photo.
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM/101CANON"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: card.appendingPathComponent("DCIM/100CANON/IMG_0001.JPG"), to: card.appendingPathComponent("DCIM/101CANON/IMG_0001.JPG"))
        // A file copied by hand into a project folder earlier.
        let byHand = try shoot("IMG_0009.JPG", seed: 9)
        var m = MediaRecord(sourceId: nil, path: dest.appendingPathComponent("IMG_0009.JPG").path, kind: .photo, size: 3000, mtime: 0,
                            contentKey: ContentKey.compute(byHand, size: 3000))
        try store.db.write { db in try m.insert(db) }

        var p = try plan()
        XCTAssertTrue(p.new.isEmpty)
        XCTAssertEqual(p.copiedBefore.count, 2)
        XCTAssertEqual(p.inLibrary.map(\.name), ["IMG_0009.JPG"])
        let o = CardCopier.copy(p, options: options(), store: store)
        XCTAssertTrue(o.copied.isEmpty)
        // Recorded by their new paths: the next look needs no reading.
        p = try plan()
        XCTAssertTrue(p.keys.isEmpty)
        XCTAssertEqual(p.copiedBefore.count, 3)
    }

    func testAChangedFileWithAnOldNameGetsANumberedName() throws {
        try shoot("IMG_0001.JPG", seed: 1)
        let o1 = CardCopier.copy(try plan(), options: options(perHandover: false), store: store)
        XCTAssertEqual(o1.copied.count, 1)
        // Formatted and shot again: a new IMG_0001 next to the old copy, in the same folder.
        try FileManager.default.removeItem(at: card.appendingPathComponent(".suzu-card"))
        try shoot("IMG_0001.JPG", seed: 7)
        let p = try plan()
        XCTAssertEqual(p.new.count, 1)
        let o2 = CardCopier.copy(p, options: options(perHandover: false), store: store)
        XCTAssertEqual(o2.copied.count, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: o2.folder.path).sorted()
        XCTAssertEqual(names, ["IMG_0001.JPG", "IMG_0001_1.JPG"])
        XCTAssertEqual(try CardCopier.knownCards(store: store).count, 2)

        // Formatted once more: the file is known from the other card's ledger, so nothing is copied.
        try FileManager.default.removeItem(at: card.appendingPathComponent(".suzu-card"))
        let p3 = try plan()
        XCTAssertTrue(p3.new.isEmpty)
        XCTAssertEqual(p3.copiedBefore.count, 1)
        // Every card forgotten, the copy still sits at the destination: recorded, not duplicated.
        for k in try CardCopier.knownCards(store: store) { try CardCopier.forget(card: k.id, store: store) }
        let p4 = try plan()
        XCTAssertEqual(p4.new.count, 1)
        let o4 = CardCopier.copy(p4, options: options(perHandover: false), store: store)
        XCTAssertTrue(o4.copied.isEmpty)
        XCTAssertEqual(o4.skipped.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: o4.folder.path).count, 2)
        XCTAssertTrue(try plan().new.isEmpty)
    }

    func testKeepingTheCardsLayoutAndForgettingACard() throws {
        try shoot("IMG_0001.JPG")
        let o = CardCopier.copy(try plan(), options: options(keepLayout: true), store: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: o.folder.appendingPathComponent("DCIM/100CANON/IMG_0001.JPG").path))
        let id = try XCTUnwrap(try CardCopier.knownCards(store: store).first?.id)
        try CardCopier.setLabel("Nam R5", card: id, store: store)
        XCTAssertEqual(try CardCopier.knownCards(store: store).first?.card.displayName, "Nam R5")
        XCTAssertEqual(try plan().new.count, 0)
        try CardCopier.forget(card: id, store: store)
        XCTAssertEqual(try CardCopier.knownCards(store: store).count, 0)
        XCTAssertEqual(try plan().new.count, 1)
    }

    func testCancellingStopsBetweenFilesAndLeavesNoHalfCopies() throws {
        for i in 1...5 { try shoot("IMG_000\(i).JPG", seed: UInt8(i)) }
        var calls = 0
        let o = CardCopier.copy(try plan(), options: options(), store: store, isCancelled: { calls += 1; return calls > 2 })
        XCTAssertTrue(o.cancelled)
        XCTAssertLessThan(o.copied.count, 5)
        let left = try FileManager.default.contentsOfDirectory(atPath: o.folder.path)
        XCTAssertFalse(left.contains { $0.hasPrefix(".copying") })
        XCTAssertEqual(left.count, o.copied.count)
        XCTAssertEqual(try plan().new.count, 5 - o.copied.count)
    }
    func testACardPulledInTheMiddleStopsTheCopyAndTheRestGoesOnInTheSameFolderLater() throws {
        for i in 1...5 { try shoot("IMG_000\(i).JPG", seed: UInt8(i)) }
        let parked = tmp.appendingPathComponent("PARKED")
        let first = CardCopier.copy(try plan(), options: options(), store: store, progress: { p in
            // Pulled after the second file landed.
            if p.done == 2, FileManager.default.fileExists(atPath: card.path) { try? FileManager.default.moveItem(at: card, to: parked) }
        })
        XCTAssertEqual(first.interruption, .cardRemoved)
        XCTAssertFalse(first.cancelled)
        XCTAssertEqual(first.copied.count, 2)
        XCTAssertTrue(first.failed.isEmpty, "a missing card is not a list of failed files")
        let left = try FileManager.default.contentsOfDirectory(atPath: first.folder.path)
        XCTAssertEqual(left.sorted(), ["IMG_0001.JPG", "IMG_0002.JPG"])
        XCTAssertEqual(try CardCopier.knownCards(store: store).first?.files, 2)

        // Back in the reader: the rest is new, and goes on in the same hand-over's folder.
        try FileManager.default.moveItem(at: parked, to: card)
        let again = try plan()
        XCTAssertEqual(again.new.map(\.name), ["IMG_0003.JPG", "IMG_0004.JPG", "IMG_0005.JPG"])
        var o = options()
        o.folder = first.folder
        let second = CardCopier.copy(again, options: o, store: store)
        XCTAssertNil(second.interruption)
        XCTAssertEqual(second.folder, first.folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.folder.path).count, 5)
        XCTAssertTrue(try plan().new.isEmpty)
    }

    func testADestinationThatGoesAwayStopsTheCopy() throws {
        for i in 1...3 { try shoot("IMG_000\(i).JPG", seed: UInt8(i)) }
        let o = CardCopier.copy(try plan(), options: options(), store: store, progress: { p in
            if p.done == 1 { try? FileManager.default.removeItem(at: dest) }
        })
        XCTAssertEqual(o.interruption, .destinationLost)
        XCTAssertEqual(o.copied.count, 1)
        XCTAssertTrue(o.failed.isEmpty)
        XCTAssertEqual(try plan().new.count, 2)
    }
    func testPhotosAndVideosAreCountedApartAndVideosCanGoToTheirOwnPlace() throws {
        try shoot("IMG_0001.JPG", seed: 1)
        try shoot("IMG_0001.xmp", bytes: 300, seed: 2)      // the photo's sidecar
        try shoot("IMG_0002.CR3", seed: 3)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP"), withIntermediateDirectories: true)
        for (name, seed) in [("C0001.MP4", 4), ("C0001M01.XML", 5), ("MEDIAPRO.XML", 6)] {
            let u = card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/\(name)")
            try Data((0..<500).map { UInt8(truncatingIfNeeded: $0 &* seed) }).write(to: u)
        }
        let p = try plan()
        XCTAssertEqual(p.newPhotos, 2)
        XCTAssertEqual(p.newVideos, 1)
        XCTAssertEqual(p.new.count, 5, "two photos, a clip, and their two sidecars; MEDIAPRO.XML belongs to no clip")
        XCTAssertEqual(p.new.first { $0.name == "C0001M01.XML" }?.kind, .video)
        XCTAssertEqual(p.new.first { $0.name == "IMG_0001.xmp" }?.kind, .photo)
        XCTAssertEqual(p.newBytes(.video), 1000)

        var o = options(perHandover: false)
        o.videoDestination = tmp.appendingPathComponent("Videos", isDirectory: true)
        let out = CardCopier.copy(p, options: o, store: store)
        XCTAssertEqual(out.copied.count, 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.folder.path).sorted(), ["IMG_0001.JPG", "IMG_0001.xmp", "IMG_0002.CR3"])
        let videos = try XCTUnwrap(out.videoFolder)
        XCTAssertEqual(videos.deletingLastPathComponent(), o.videoDestination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: videos.path).sorted(), ["C0001.MP4", "C0001M01.XML"])
        XCTAssertTrue(try plan().new.isEmpty)
    }
}
