import FaceCore
import XCTest

final class VideoSamplerTests: XCTestCase {
    /// Many more synchronous frame grabs than cores, all from Swift's cooperative pool (a grid of video thumbnails,
    /// a celebrity lookup, a gallery export). Built on Tasks, these deadlocked the whole pool and froze the app.
    func testSyncFrameGrabsFromCooperativePoolDoNotDeadlock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("m.mov")
        try await TestMovie.write(to: movie, seconds: 3)

        let n = ProcessInfo.processInfo.activeProcessorCount * 3
        let got = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<n {
                group.addTask {
                    switch i % 3 {
                    case 0: return VideoSampler.frameSync(movie, at: 1, maxPixel: 160) != nil
                    case 1: return VideoSampler.duration(movie) > 2.5
                    default: return ((try? VideoSampler.framesSync(movie, interval: 1, maxPixel: 160).frames.count) ?? 0) >= 2
                    }
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(got, n)
        XCTAssertNotNil(VideoSampler.recordingDate(movie))
    }
}
