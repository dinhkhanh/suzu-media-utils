import CryptoKit
import FaceCore
import Foundation

/// Edit & Export's body-parts model (Sapiens, tools/convert_sapiens.py): about 600 MB, too big to come with every
/// update, so it's downloaded once into Application Support and kept there across updates. Until then Apple Vision
/// finds the parts, more roughly.
@MainActor final class BodyPartsModel: ObservableObject {
    static let shared = BodyPartsModel()

    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }
    @Published private(set) var state: State
    private var task: Task<Void, Never>?

    /// A release of its own on GitHub (never marked latest: the update feed is at releases/latest). A new model
    /// gets a new number, so it never clashes with one already downloaded.
    nonisolated static let source = URL(string: "https://github.com/dinhkhanh/suzu-media-utils/releases/download/models-bodyparts-1/BodyParts-1.zip")!
    nonisolated static let sha256 = "ab1657670aed2138c4911309a8fcb0caadc4ac4b9c1cfe0812652eb1ce46069c"
    nonisolated static let downloadSize: Int64 = 626_598_001

    nonisolated static var installed: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuZu Media Utils/Models/BodyParts-1.mlmodelc", isDirectory: true)
    }

    /// The downloaded model, else one inside the app or in models/compiled (development).
    nonisolated static var located: URL? {
        FileManager.default.fileExists(atPath: installed.appendingPathComponent("coremldata.bin").path)
            ? installed : locateModel(named: "BodyParts")
    }

    private init() {
        let url = Self.located
        BodyParts.modelURL = url
        state = url == nil ? .missing : .ready
    }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task {
            do {
                let url = try await Self.fetch { p in Task { @MainActor in self.progressed(p) } }
                BodyParts.use(modelAt: url)
                state = .ready
            } catch is CancellationError {
                state = .missing
            } catch {
                state = (error as? URLError)?.code == .cancelled ? .missing : .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    private func progressed(_ p: Double) {
        // Whole percents only: a redraw per network packet would be thousands.
        guard case .downloading(let was) = state, Int(p * 100) > Int(was * 100) else { return }
        state = .downloading(p)
    }

    /// Downloads, checks and unpacks the model into `installed`.
    nonisolated static func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let zip = try await downloadFile(progress: progress)
        defer { try? FileManager.default.removeItem(at: zip) }
        try Task.checkCancellation()
        guard try digest(of: zip) == sha256 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The downloaded model is damaged. Try again."])
        }
        let fm = FileManager.default
        let dir = installed.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let unpacked = dir.appendingPathComponent(".unpacking-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: unpacked) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        let model = unpacked.appendingPathComponent("BodyParts.mlmodelc", isDirectory: true)
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: model.appendingPathComponent("coremldata.bin").path) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The downloaded model couldn't be unpacked."])
        }
        try? fm.removeItem(at: installed)
        try fm.moveItem(at: model, to: installed)
        return installed
    }

    private nonisolated static func downloadFile(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        final class Box: @unchecked Sendable { var task: URLSessionDownloadTask?; var watch: NSKeyValueObservation? }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: source) { file, response, error in
                    box.watch?.invalidate()
                    do {
                        guard let file else { throw error ?? URLError(.unknown) }
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        // The file is gone once this returns.
                        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("BodyParts-\(UUID().uuidString).zip")
                        try FileManager.default.moveItem(at: file, to: kept)
                        done.resume(returning: kept)
                    } catch {
                        done.resume(throwing: error)
                    }
                }
                box.task = task
                box.watch = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private nonisolated static func digest(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
