import FaceCore
import Foundation
import GRDB

/// Runs pending media through detect -> align -> embed and writes faces to the library.
public final class Processor: @unchecked Sendable {
    let store: LibraryStore
    let engine: GroupingEngine
    let batcher: EmbeddingBatcher
    let settings = GroupingSettings()
    let workQueue = OperationQueue()
    let lock = NSLock()
    var queued: Set<Int64> = []

    /// Progress for the UI: files processed since launch and timestamps for the rate.
    public private(set) var processedCount = 0

    public init(store: LibraryStore, engine: GroupingEngine, modelURL: URL) throws {
        self.store = store
        self.engine = engine
        batcher = EmbeddingBatcher(embedder: try Embedder(name: "ArcFaceR50", compiledModel: modelURL))
        workQueue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        workQueue.qualityOfService = .utility
    }

    public var queuedCount: Int { lock.withLock { queued.count } }

    /// Queues every pending media in the library (call at launch and after scans).
    public func enqueuePending() {
        let ids = (try? store.db.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM media WHERE status = 'pending' AND duplicateOf IS NULL ORDER BY path")
        }) ?? []
        for id in ids { enqueue(id) }
    }

    public func enqueue(_ mediaId: Int64) {
        let isNew = lock.withLock { queued.insert(mediaId).inserted }
        guard isNew else { return }
        workQueue.addOperation { [self] in
            autoreleasepool { process(mediaId) }
            lock.withLock {
                queued.remove(mediaId)
                processedCount += 1
            }
        }
    }

    func process(_ mediaId: Int64) {
        guard let media = try? store.db.read({ db in try MediaRecord.fetchOne(db, key: mediaId) }),
              media.status == .pending else { return }
        do {
            // Fingerprint for move/copy detection, deferred from the folder scan to here.
            let key = media.contentKey ?? ContentKey.compute(media.url, size: media.size)
            let analyzed = try MediaAnalyzer.analyze(media.url)
            let crops = analyzed.faces.compactMap(\.aligned)
            let vectors = crops.isEmpty ? [] : batcher.embed(crops)
            var faces: [FaceRecord] = []
            var k = 0
            for af in analyzed.faces {
                var vec: [Float]?
                if af.aligned != nil { vec = k < vectors.count ? vectors[k] : nil; k += 1 }
                let W = Double(analyzed.width), H = Double(analyzed.height)
                faces.append(FaceRecord(
                    id: nil, mediaId: mediaId, x: af.face.x / W, y: af.face.y / H, w: af.face.w / W, h: af.face.h / H,
                    quality: af.face.quality.map(Double.init), time: af.time, embedding: vec.map(Vector.encode),
                    track: nil, personId: nil, assignment: .none, rejectedPersonId: nil))
            }
            if media.kind == .video { assignTracks(&faces, width: analyzed.width) }

            let previews = analyzed.faces.map(\.preview)
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [mediaId])
                for i in faces.indices { try faces[i].insert(db) }
                try db.execute(sql: """
                    UPDATE media SET status = 'done', error = NULL, width = ?, height = ?, duration = ?, contentKey = ? WHERE id = ?
                    """, arguments: [analyzed.width, analyzed.height, analyzed.duration, key, mediaId])
            }
            for (f, p) in zip(faces, previews) {
                if let p { ImageLoader.writeJPEG(p, to: store.faceCropURL(f.id!), quality: 0.8) }
            }
            if let pid = try enrollReference(media, faces: faces) {
                engine.referenceChanged(pid)
            } else {
                engine.mediaProcessed(mediaId)
            }
        } catch {
            try? store.db.write { db in
                try db.execute(sql: "UPDATE media SET status = 'failed', error = ? WHERE id = ?",
                               arguments: ["\(error)", mediaId])
            }
        }
    }

    /// In a reference source, the largest face of each photo is the person named by its top-level subfolder.
    /// Returns that person's id, or nil when the media is not a reference photo.
    func enrollReference(_ media: MediaRecord, faces: [FaceRecord]) throws -> Int64? {
        try store.db.write { db -> Int64? in
            guard let sid = media.sourceId, let source = try SourceRecord.fetchOne(db, key: sid), source.kind == .reference
            else { return nil }
            let rel = media.path.dropFirst(source.path.count).split(separator: "/")
            guard rel.count >= 2 else { return nil }  // photos directly in the reference root have no name
            let name = String(rel[0])
            try db.execute(sql: "UPDATE face SET assignment = 'user' WHERE mediaId = ?", arguments: [media.id])
            guard let face = faces.filter({ $0.embedding != nil }).max(by: { $0.w * $0.h < $1.w * $1.h }) else { return nil }
            var pid = try Int64.fetchOne(db, sql: "SELECT id FROM person WHERE name = ? COLLATE NOCASE", arguments: [name])
            if pid == nil {
                var p = PersonRecord(name: name)
                try p.insert(db)
                pid = p.id
            }
            try db.execute(sql: "UPDATE face SET personId = ? WHERE id = ?", arguments: [pid, face.id])
            return pid
        }
    }

    /// Collapses the same person's faces across frames of one video into numbered tracks.
    func assignTracks(_ faces: inout [FaceRecord], width: Int) {
        let idx = faces.indices.filter {
            faces[$0].embedding != nil && (faces[$0].quality ?? 0) >= settings.minQuality
                && faces[$0].w * Double(width) >= settings.minFacePixels
        }
        guard !idx.isEmpty else { return }
        let vecs = idx.map { faces[$0].vector! }
        let labels = idx.count == 1 ? [0] : Clustering.averageLinkage(
            similarity: Clustering.similarityMatrix(vecs), count: idx.count, threshold: settings.clusterThreshold)
        for (k, i) in idx.enumerated() { faces[i].track = labels[k] }
    }
}

/// Funnels embedding requests from all workers into Neural Engine batches of up to 16 faces.
final class EmbeddingBatcher: @unchecked Sendable {
    let embedder: Embedder
    let cond = NSCondition()
    var requests: [(crops: [[UInt8]], done: ([[Float]]) -> Void)] = []

    init(embedder: Embedder) {
        self.embedder = embedder
        let t = Thread { [unowned self] in loop() }
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// Blocks the calling worker until its crops are embedded. Returns [] if the model failed.
    func embed(_ crops: [[UInt8]]) -> [[Float]] {
        let sem = DispatchSemaphore(value: 0)
        var out: [[Float]] = []
        cond.lock()
        requests.append((crops, { out = $0; sem.signal() }))
        cond.signal()
        cond.unlock()
        sem.wait()
        return out
    }

    func loop() {
        while true {
            cond.lock()
            while requests.isEmpty { cond.wait() }
            var batch = [requests.removeFirst()]
            var n = batch[0].crops.count
            while let next = requests.first, n + next.crops.count <= 16 {
                batch.append(requests.removeFirst())
                n += next.crops.count
            }
            cond.unlock()

            let all = batch.flatMap(\.crops)
            let vectors = (try? embedder.embed(all)) ?? []
            var k = 0
            for r in batch {
                let c = r.crops.count
                r.done(vectors.count == all.count ? Array(vectors[k..<k + c]) : [])
                k += c
            }
        }
    }
}
