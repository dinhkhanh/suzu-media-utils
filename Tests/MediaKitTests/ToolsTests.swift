import XCTest
@testable import MediaKit

final class ToolsTests: XCTestCase {
    func testSegmentsMergePadAndDropBlips() {
        let s = VideoTools.segments(times: [3, 4, 5, 6, 20, 40, 41, 42], duration: 43)
        XCTAssertEqual(s, [.init(start: 2, end: 7), .init(start: 19, end: 21), .init(start: 39, end: 43)])
    }

    func testRenamePatternTokensAndUniqueness() {
        let d = ISO8601DateFormatter().date(from: "2026-09-27T08:15:30Z")!
        var p = RenamePattern(pattern: "{event}_{date}_{person}_{seq:3}", event: "SOLINA")
        p.start = 9
        let dir = URL(fileURLWithPath: "/tmp/x")
        let items = [RenamePattern.Item(url: dir.appendingPathComponent("AEP1.jpg"), date: d, people: ["Mỹ Tâm"]),
                     RenamePattern.Item(url: dir.appendingPathComponent("AEP2.JPG"), date: d, people: []),
                     RenamePattern.Item(url: dir.appendingPathComponent("AEP3.jpg"), date: d, people: ["A/B"])]
        let names = p.names(for: items)
        XCTAssertEqual(names[0], "SOLINA_2026-09-27_Mỹ Tâm_009.jpg")
        XCTAssertEqual(names[1], "SOLINA_2026-09-27_010.JPG", "empty token leaves no double separator")
        XCTAssertEqual(names[2], "SOLINA_2026-09-27_A-B_011.jpg")
    }

    func testRenameApplyHandlesSwaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("b.jpg"))
        let items = ["a.jpg", "b.jpg"].map { RenamePattern.Item(url: dir.appendingPathComponent($0)) }
        let done = try RenamePattern.apply(items, names: ["b.jpg", "a.jpg"])
        XCTAssertEqual(done.count, 2)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.jpg"), encoding: .utf8), "b")
    }

    func testVerifierFindsMissingBrokenAndRepairs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-\(UUID().uuidString)")
        let src = root.appendingPathComponent("card"), dst = root.appendingPathComponent("nas")
        defer { try? FileManager.default.removeItem(at: root) }
        for d in [src.appendingPathComponent("sub"), dst.appendingPathComponent("sub")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 100).write(to: src.appendingPathComponent("ok.jpg"))
        try Data(repeating: 1, count: 100).write(to: dst.appendingPathComponent("ok.jpg"))
        try Data(repeating: 2, count: 100).write(to: src.appendingPathComponent("sub/cut.jpg"))
        try Data(repeating: 2, count: 40).write(to: dst.appendingPathComponent("sub/cut.jpg"))
        try Data(repeating: 3, count: 100).write(to: src.appendingPathComponent("flip.jpg"))
        try Data(repeating: 4, count: 100).write(to: dst.appendingPathComponent("flip.jpg"))
        try Data(repeating: 5, count: 10).write(to: src.appendingPathComponent("missing.jpg"))
        try Data(repeating: 6, count: 10).write(to: dst.appendingPathComponent("extra.jpg"))

        var r = FolderVerifier.verify(source: src, destination: dst, checksums: false)
        XCTAssertEqual(r.missing, ["missing.jpg"])
        XCTAssertEqual(r.sizeMismatch, ["sub/cut.jpg"])
        XCTAssertEqual(r.extra, ["extra.jpg"])
        XCTAssertEqual(r.matched, 2, "without checksums the same-size corrupt file passes")
        r = FolderVerifier.verify(source: src, destination: dst, checksums: true)
        XCTAssertEqual(r.contentMismatch, ["flip.jpg"])
        XCTAssertTrue(FolderVerifier.repair(r, source: src, destination: dst).isEmpty)
        XCTAssertTrue(FolderVerifier.verify(source: src, destination: dst, checksums: true).isComplete)
    }
}

final class VideoExportTests: XCTestCase {
    /// Real export on a short generated movie (AVAssetWriter), cut without re-encoding.
    func testClipAndStillFromGeneratedMovie() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("m.mov")
        try await TestMovie.write(to: movie, seconds: 6)
        let clip = dir.appendingPathComponent("clip.mov")
        try await VideoTools.exportClip(movie, segment: .init(start: 1, end: 4), to: clip)
        let d = try await AVURLAsset(url: clip).load(.duration).seconds
        XCTAssertEqual(d, 3, accuracy: 1.1)
        let still = dir.appendingPathComponent("still.jpg")
        var r = EditRecipe(); r.aspect = .square
        try VideoTools.still(movie, at: 2, recipe: r, focus: nil, people: ["An"], to: still)
        XCTAssertEqual(Metadata.people(in: still), ["An"])
        let sheet = dir.appendingPathComponent("sheet.jpg")
        try VideoTools.contactSheet(movie, columns: 3, rows: 2, width: 900, to: sheet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheet.path))
    }
}

import AVFoundation
import CoreVideo

enum TestMovie {
    static func write(to url: URL, seconds: Int, fps: Int32 = 10) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 3 % 255), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
