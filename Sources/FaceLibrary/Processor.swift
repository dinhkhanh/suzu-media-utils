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
    /// Whether a file of this source is processed on this Mac (shared processing: another Mac may do a team's
    /// face work; see SharedFaces). nil = everything.
    public var processesLocally: (@Sendable (Int64?) -> Bool)?
    /// Seconds a fresh file of this source waits for a teammate's record before this Mac reads it itself (the
    /// processing Mac, while copying Macs are sending the faces of the cards they copy); 0 = none.
    public var graceFor: (@Sendable (Int64?) -> Double)?

    /// Progress for the UI: files processed since launch and timestamps for the rate.
    public private(set) var processedCount = 0
    /// Where to read a file from instead of its library path, while that is faster: a file just copied off a card
    /// is read from the card (local, USB) rather than back from the NAS it landed on. By canonical library path.
    var preferredSources: [String: URL] = [:]
    /// Workers when nothing else is going on, and while a copy or export the user is waiting for runs.
    let fullWorkers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    let sharedWorkers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

    public init(store: LibraryStore, engine: GroupingEngine, modelURL: URL) throws {
        self.store = store
        self.engine = engine
        batcher = EmbeddingBatcher(embedder: try Embedder(name: "ArcFaceR50", compiledModel: modelURL))
        workQueue.maxConcurrentOperationCount = fullWorkers
        workQueue.qualityOfService = .utility
        backgroundQueue.maxConcurrentOperationCount = 2
        backgroundQueue.qualityOfService = .background
    }

    /// Embeddings for 112x112 aligned crops, through the same Neural Engine batches as the files being processed.
    public func embed(_ crops: [[UInt8]]) -> [[Float]] { batcher.embed(crops) }

    public var queuedCount: Int { lock.withLock { queued.count } }
    public var backgroundCount: Int { lock.withLock { backgroundQueued.count } }

    /// A copy or export the user is waiting for is under way (or no longer): face work keeps going on fewer
    /// workers, so the transfer gets the disk and the network first. Takes effect as running operations finish.
    public func setForeground(_ active: Bool) {
        workQueue.maxConcurrentOperationCount = active ? sharedWorkers : fullWorkers
    }

    /// Reads the file at `path` from `url` when it comes up for processing (as long as that is still there): the
    /// card a file was just copied from, instead of the share it was copied to.
    public func prefer(_ url: URL, for path: String) {
        lock.withLock {
            preferredSources[path] = url
            // Entries of cards long pulled: forgotten once there are many.
            if preferredSources.count > 20_000 {
                let fm = FileManager.default
                preferredSources = preferredSources.filter { fm.fileExists(atPath: $0.value.path) }
            }
        }
    }

    func takePreferred(_ path: String) -> URL? {
        let url = lock.withLock { preferredSources.removeValue(forKey: path) }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Queues every pending media in the library (call at launch and after scans).
    public func enqueuePending() {
        let rows = (try? store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, sourceId, localWork FROM media WHERE status = 'pending' AND duplicateOf IS NULL
                  AND sourceId NOT IN (\(SourceShare.editedIds)) ORDER BY path
                """)
        }) ?? []
        for r in rows where (r["localWork"] as Bool) || processesLocally?(r["sourceId"]) ?? true { enqueue(r["id"], first: r["localWork"]) }
    }

    /// `first`: ahead of everything waiting (a file just copied off a card, while the card is still in).
    public func enqueue(_ mediaId: Int64, first: Bool = false) {
        let isNew = lock.withLock { queued.insert(mediaId).inserted }
        guard isNew else { return }
        let op = BlockOperation { [self] in
            let worked = autoreleasepool { process(mediaId) }
            lock.withLock {
                queued.remove(mediaId)
                if worked { processedCount += 1 }
            }
        }
        // New files always go before background extras (upgrades, burst fingerprints).
        op.queuePriority = first ? .veryHigh : .high
        workQueue.addOperation(op)
    }

    /// Returns whether the file was worked on (false: not this Mac's to do, or put off for a moment).
    @discardableResult
    func process(_ mediaId: Int64) -> Bool {
        guard let (media, edited) = try? store.db.read({ db in
            try MediaRecord.fetchOne(db, key: mediaId).map { ($0, try Bool.fetchOne(db, sql: "SELECT share = 'edited' FROM source WHERE id = ?", arguments: [$0.sourceId]) ?? false) }
        }), media.status == .pending, !edited else { return false }
        let mine = processesLocally?(media.sourceId) ?? true
        guard media.localWork || mine else { return false }
        // A fresh file of a team whose copying Macs send the faces of the cards they copy: their record saves
        // reading the file back from the share, so give it a moment to arrive.
        if !media.localWork, media.importedFrom == nil, let seen = media.seenAt, let grace = graceFor?(media.sourceId), grace > 0 {
            let left = seen + grace - Date().timeIntervalSince1970
            if left > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(1, left)) { [weak self] in self?.enqueue(mediaId) }
                return false
            }
        }
        do {
            // The same bytes from a faster place when there is one (the card it was just copied from); the
            // library's own copy when that fails (card pulled) or there is none.
            let preferred = takePreferred(media.path)
            var analyzed: AnalyzedMedia
            var readFrom = media.url
            if let preferred, let a = try? MediaAnalyzer.analyze(preferred) {
                analyzed = a
                readFrom = preferred
            } else {
                analyzed = try MediaAnalyzer.analyze(media.url)
            }
            // Fingerprint for move/copy detection, deferred from the folder scan to here.
            let key = media.contentKey ?? ContentKey.compute(readFrom, size: media.size)
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
            // The thumbnail, from the decode already made (videos get theirs in the idle-time pass); written before
            // the commit so the file's whole result is one transaction.
            var thumbAt: Double?
            if let t = analyzed.thumbnail {
                ImageLoader.writeJPEG(t, to: store.thumbnailURL(mediaId), quality: 0.8)
                thumbAt = Date().timeIntervalSince1970
            }
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [mediaId])
                for i in faces.indices { try faces[i].insert(db) }
                try db.execute(sql: """
                    UPDATE media SET status = 'done', error = NULL, width = ?, height = ?, duration = ?, contentKey = ?,
                        takenAt = ?, analysisVersion = ?, importedFrom = NULL, thumbAt = COALESCE(?, thumbAt) WHERE id = ?
                    """, arguments: [analyzed.width, analyzed.height, analyzed.duration, key,
                                     (analyzed.takenAt ?? Date(timeIntervalSince1970: media.mtime)).timeIntervalSince1970,
                                     BestShot.analysisVersion, thumbAt, mediaId])
                // For the team, when this Mac does its face work (see SharedFaces).
                try db.execute(sql: "INSERT OR IGNORE INTO facePublish (mediaId) VALUES (?)", arguments: [mediaId])
            }
            for (f, p) in zip(faces, previews) {
                if let p { ImageLoader.writeJPEG(p, to: store.faceCropURL(f.id!), quality: 0.8) }
            }
            if let pid = try enrollReference(media, faces: faces) {
                engine.referenceChanged(pid)
                onReferenceEnrolled?(pid)
            } else if mine {
                engine.mediaProcessed(mediaId)
            }
            // Else (a card's file processed here for a team another Mac groups for): the faces go to that Mac as
            // they are; its grouping comes back and is taken as the truth here, so the two never disagree.
        } catch {
            try? store.db.write { db in
                try db.execute(sql: "UPDATE media SET status = 'failed', error = ? WHERE id = ?",
                               arguments: ["\(error)", mediaId])
            }
        }
        return true
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

    /// Files without a thumbnail yet (older libraries, videos, files whose faces came from another Mac without
    /// one), made when the queue is idle: the embedded preview or a reduced decode, never a full one.
    public func enqueueThumbnails(limit: Int = 100) {
        guard queuedCount == 0, backgroundCount == 0, !extrasPaused else { return }
        let rows = (try? store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path FROM media WHERE status = 'done' AND duplicateOf IS NULL AND thumbAt IS NULL ORDER BY id DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []
        for r in rows {
            let id: Int64 = r["id"], path: String = r["path"]
            addBackground(id) { [self] in
                let url = URL(fileURLWithPath: path, isDirectory: false)
                var at = 0.0  // 0 = tried, couldn't (offline, unreadable): not retried forever
                if let t = MediaAnalyzer.thumbnail(url) {
                    ImageLoader.writeJPEG(t, to: store.thumbnailURL(id), quality: 0.8)
                    at = Date().timeIntervalSince1970
                }
                try? store.db.write { db in try db.execute(sql: "UPDATE media SET thumbAt = ? WHERE id = ?", arguments: [at, id]) }
            }
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
