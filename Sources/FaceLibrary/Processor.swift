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
    /// Idle-time extras (score upgrades, burst fingerprints): their own small queue at background priority, so they
    /// never take a worker from new files or make the app sluggish.
    let backgroundQueue = OperationQueue()
    let lock = NSLock()
    var queued: Set<Int64> = []
    var backgroundQueued: Set<Int64> = []
    /// Set while a batch tool or export is running: no new extras are started.
    public var extrasPaused = false
    /// Called (on a worker) after a Known-People photo named or extended a person, so teams hear of them at once.
    public var onReferenceEnrolled: (@Sendable (Int64) -> Void)?

    /// Progress for the UI: files processed since launch and timestamps for the rate.
    public private(set) var processedCount = 0

    public init(store: LibraryStore, engine: GroupingEngine, modelURL: URL) throws {
        self.store = store
        self.engine = engine
        batcher = EmbeddingBatcher(embedder: try Embedder(name: "ArcFaceR50", compiledModel: modelURL))
        workQueue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        workQueue.qualityOfService = .utility
        backgroundQueue.maxConcurrentOperationCount = 2
        backgroundQueue.qualityOfService = .background
    }

    public var queuedCount: Int { lock.withLock { queued.count } }
    public var backgroundCount: Int { lock.withLock { backgroundQueued.count } }

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
        let op = BlockOperation { [self] in
            autoreleasepool { process(mediaId) }
            lock.withLock {
                queued.remove(mediaId)
                processedCount += 1
            }
        }
        // New files always go before background extras (upgrades, burst fingerprints).
        op.queuePriority = .high
        workQueue.addOperation(op)
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
                faces.append(Self.faceRecord(af, mediaId: mediaId, width: analyzed.width, height: analyzed.height, vector: vec))
            }
            if media.kind == .video { assignTracks(&faces, width: analyzed.width) }

            let previews = analyzed.faces.map(\.preview)
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [mediaId])
                for i in faces.indices { try faces[i].insert(db) }
                try db.execute(sql: """
                    UPDATE media SET status = 'done', error = NULL, width = ?, height = ?, duration = ?, contentKey = ?,
                        takenAt = ?, analysisVersion = ? WHERE id = ?
                    """, arguments: [analyzed.width, analyzed.height, analyzed.duration, key,
                                     (analyzed.takenAt ?? Date(timeIntervalSince1970: media.mtime)).timeIntervalSince1970,
                                     BestShot.analysisVersion, mediaId])
            }
            for (f, p) in zip(faces, previews) {
                if let p { ImageLoader.writeJPEG(p, to: store.faceCropURL(f.id!), quality: 0.8) }
            }
            if let pid = try enrollReference(media, faces: faces) {
                engine.referenceChanged(pid)
                onReferenceEnrolled?(pid)
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

    static func faceRecord(_ af: AnalyzedFace, mediaId: Int64, width: Int, height: Int, vector: [Float]?) -> FaceRecord {
        let W = Double(width), H = Double(height)
        let q = af.face.quality.map(Double.init)
        return FaceRecord(
            id: nil, mediaId: mediaId, x: af.face.x / W, y: af.face.y / H, w: af.face.w / W, h: af.face.h / H,
            quality: q, time: af.time, embedding: vector.map(Vector.encode),
            track: nil, personId: nil, assignment: .none, rejectedPersonId: nil,
            eyesOpen: af.face.eyesOpen.map(Double.init), smile: af.face.smile.map(Double.init), sharpness: af.sharpness,
            yaw: af.face.yaw.map(Double.init), pitch: af.face.pitch.map(Double.init),
            score: BestShot.score(quality: q, sharpness: af.sharpness, eyesOpen: af.face.eyesOpen.map(Double.init),
                                  smile: af.face.smile.map(Double.init), yaw: af.face.yaw.map(Double.init),
                                  pitch: af.face.pitch.map(Double.init), widthPixels: af.face.w))
    }

    // MARK: - Upgrading older analyses

    /// Queues done media analysed by an older version (no best-shot scores yet). Run when the queue is idle.
    public func enqueueUpgrades(limit: Int = 200) {
        guard queuedCount == 0, backgroundCount == 0, !extrasPaused else { return }
        let ids = (try? store.db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM media WHERE status = 'done' AND duplicateOf IS NULL AND analysisVersion < ? ORDER BY id LIMIT ?
                """, arguments: [BestShot.analysisVersion, limit])
        }) ?? []
        for id in ids { addBackground(id) { [self] in upgrade(id) } }
    }

    /// Idle-time extras that must never delay new files: lowest priority, a handful at a time, and only when no
    /// new file is waiting.
    func addBackground(_ id: Int64, _ work: @escaping () -> Void) {
        let isNew = lock.withLock { backgroundQueued.insert(id).inserted }
        guard isNew else { return }
        backgroundQueue.addOperation { [self] in
            // A new file or a batch job arrived meanwhile: leave the rest for the next idle moment.
            if queuedCount == 0 && !extrasPaused { autoreleasepool(invoking: work) }
            lock.withLock { _ = backgroundQueued.remove(id) }
        }
    }

    /// Photos without a feature print (for burst detection), done when the queue is idle.
    public func enqueueFeaturePrints(limit: Int = 100) {
        guard queuedCount == 0, backgroundCount == 0, !extrasPaused else { return }
        let rows = (try? store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path FROM media WHERE status = 'done' AND duplicateOf IS NULL AND kind = 'photo'
                  AND featurePrint IS NULL ORDER BY id LIMIT ?
                """, arguments: [limit])
        }) ?? []
        for r in rows {
            let id: Int64 = r["id"], path: String = r["path"]
            addBackground(id) { [self] in
                // Empty blob = tried and unreadable, so it isn't retried forever.
                let fp = MediaAnalyzer.quickFeaturePrint(URL(fileURLWithPath: path, isDirectory: false)).map(Vector.encode) ?? Data()
                try? store.db.write { db in try db.execute(sql: "UPDATE media SET featurePrint = ? WHERE id = ?", arguments: [fp, id]) }
            }
        }
    }

    /// Re-analyses a file and adds the new measurements to its existing faces (matched by box overlap), leaving
    /// people, names and groups untouched.
    func upgrade(_ mediaId: Int64) {
        guard let media = try? store.db.read({ db in try MediaRecord.fetchOne(db, key: mediaId) }) else { return }
        let analyzed = try? MediaAnalyzer.analyze(media.url)
        try? store.db.write { db in
            if let analyzed {
                let existing = try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ?", arguments: [mediaId])
                for af in analyzed.faces {
                    let fresh = Self.faceRecord(af, mediaId: mediaId, width: analyzed.width, height: analyzed.height, vector: nil)
                    let box = CGRect(x: fresh.x, y: fresh.y, width: fresh.w, height: fresh.h)
                    guard let match = existing.filter({ $0.time == fresh.time }).max(by: {
                        Self.iou(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), box) < Self.iou(CGRect(x: $1.x, y: $1.y, width: $1.w, height: $1.h), box)
                    }), Self.iou(CGRect(x: match.x, y: match.y, width: match.w, height: match.h), box) > 0.4 else { continue }
                    try db.execute(sql: "UPDATE face SET eyesOpen = ?, smile = ?, sharpness = ?, yaw = ?, pitch = ?, score = ? WHERE id = ?",
                                   arguments: [fresh.eyesOpen, fresh.smile, fresh.sharpness, fresh.yaw, fresh.pitch, fresh.score, match.id])
                }
                try db.execute(sql: "UPDATE media SET takenAt = ? WHERE id = ?",
                               arguments: [(analyzed.takenAt ?? Date(timeIntervalSince1970: media.mtime)).timeIntervalSince1970, mediaId])
            }
            // Unreadable now (offline, deleted): don't retry forever.
            try db.execute(sql: "UPDATE media SET analysisVersion = ? WHERE id = ?", arguments: [BestShot.analysisVersion, mediaId])
        }
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    /// In a reference source, the largest face of each photo is the person named by its top-level subfolder.
    /// Returns that person's id, or nil when the media is not a reference photo.
    func enrollReference(_ media: MediaRecord, faces: [FaceRecord]) throws -> Int64? {
        try store.db.write { db -> Int64? in
            guard let sid = media.sourceId, let source = try SourceRecord.fetchOne(db, key: sid), source.kind == .reference
            else { return nil }
            let rel = media.path.dropFirst(source.path.count).split(separator: "/")
            guard rel.count >= 2 else { return nil }  // photos directly in the reference root have no name
            let name = PersonNames.clean(String(rel[0]))
            try db.execute(sql: "UPDATE face SET assignment = 'user' WHERE mediaId = ?", arguments: [media.id])
            guard let face = faces.filter({ $0.embedding != nil }).max(by: { $0.w * $0.h < $1.w * $1.h }) else { return nil }
            var pid = try PersonNames.find(name, db: db)
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
