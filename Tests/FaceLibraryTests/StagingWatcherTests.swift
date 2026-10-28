import Foundation
import XCTest
@testable import FaceLibrary

/// The staging folder's watcher: what lands in an event folder is reported once it has been quiet, as the unit
/// it belongs to, and what was there before is not reported again.
final class StagingWatcherTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Old Card/2026-10-20 10.00"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("Old Card/2026-10-20 10.00/IMG_1.JPG"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    final class Seen: @unchecked Sendable {
        let lock = NSLock(); var units: [[StagingWatcher.Unit]] = []
        func add(_ u: [StagingWatcher.Unit]) { lock.lock(); units.append(u); lock.unlock() }
        var all: [[StagingWatcher.Unit]] { lock.lock(); defer { lock.unlock() }; return units }
    }

    func testUnits() {
        let u = StagingWatcher.Unit(root: root, folder: "Nam R5 card 1")
        XCTAssertEqual(u.remotePath, "Nam R5 card 1")
        XCTAssertEqual(u.local, root.appendingPathComponent("Nam R5 card 1", isDirectory: true))
        XCTAssertFalse(u.filesOnly)
        let loose = StagingWatcher.Unit(root: root, folder: nil)
        XCTAssertEqual(loose.remotePath, "", "the folder on the NAS itself")
        XCTAssertEqual(loose.local, root)
        XCTAssertTrue(loose.filesOnly)
        let c = NASConnection(host: "h", user: "u", basePath: "/volume1/photo/Event")
        XCTAssertEqual(c.remotePath(loose.remotePath), "/volume1/photo/Event")
        XCTAssertEqual(c.remotePath(u.remotePath), "/volume1/photo/Event/Nam R5 card 1")
    }

    func testNewFolderAndLooseFilesAreReportedOnceQuiet() throws {
        let seen = Seen()
        let w = StagingWatcher(root: root, settle: 1.5) { seen.add($0) }
        w.start()
        Thread.sleep(forTimeInterval: 0.5)
        // A card lands, and a file is dropped at the top of the staging folder.
        let card = root.appendingPathComponent("Nam R5 card 1/2026-10-29 10.00", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: card.appendingPathComponent("IMG_0001.JPG"))
        try Data(repeating: 2, count: 10).write(to: root.appendingPathComponent("notes.txt"))
        let deadline = Date(timeIntervalSinceNow: 8)
        while seen.all.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        let reported = seen.all.flatMap { $0 }
        XCTAssertEqual(Set(reported.map(\.remotePath)), ["", "Nam R5 card 1"])
        XCTAssertFalse(reported.contains { $0.folder == "Old Card" }, "what was there at start is known, not sent again")
        // Nothing more happens: nothing more is reported.
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(seen.all.flatMap { $0 }.count, 2)
        // More files in the card: the card is reported again.
        try Data(repeating: 3, count: 100).write(to: card.appendingPathComponent("IMG_0002.JPG"))
        let deadline2 = Date(timeIntervalSinceNow: 8)
        while seen.all.flatMap({ $0 }).count < 3, Date() < deadline2 { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(seen.all.last?.map(\.remotePath), ["Nam R5 card 1"])
        w.stop()
    }

    func testReportAllSendsEverything() {
        let seen = Seen()
        let w = StagingWatcher(root: root, settle: 60) { seen.add($0) }
        w.reportAll()
        let deadline = Date(timeIntervalSinceNow: 3)
        while seen.all.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(seen.all.first?.map(\.remotePath), ["Old Card"])
    }
}
