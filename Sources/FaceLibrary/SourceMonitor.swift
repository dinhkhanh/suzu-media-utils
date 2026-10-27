import CoreServices
import FaceCore
import Foundation
import GRDB

/// Keeps one source folder in sync with the library: finds new, changed, moved, copied and deleted files.
///
/// Local volumes are watched with FSEvents. Network volumes (SMB/AFP/NFS) get no FSEvents, so they are polled: every
/// 30 s when nothing is happening, every 5 s while files are arriving (a card copying in, a look that found new
/// files) and for a short while after; each poll only re-lists folders whose modification time changed.
public final class SourceMonitor: @unchecked Sendable {
    public let sourceId: Int64
    public let root: URL
    let store: LibraryStore
    /// Called on the monitor's queue after a scan inserted pending media or removed faces from people.
    let onChange: (_ newPending: Bool, _ affectedPeople: Set<Int64>) -> Void
    let queue: DispatchQueue
    public private(set) var isOnline = true
    public private(set) var isNetwork = false
    /// True while a scan is listing or registering files; `foundCount` is the files listed so far.
    public private(set) var isScanning = false
    public private(set) var foundCount = 0
    /// Set by `stop()`; a running scan stops at the next folder or batch.
    private(set) var cancelled = false

    struct FileInfo: Equatable { var size: Int64; var mtime: Double }
    struct DirEntry { var mtime: Double; var files: [String: FileInfo]; var subdirs: [String] }
    var dirCache: [String: DirEntry] = [:]
    /// Unsettled files: last seen size/mtime, when it last changed, and whether it was seen growing.
    var candidates: [String: (info: FileInfo, seen: Date, grew: Bool)] = [:]
    var stream: FSEventStreamRef?
    var timer: DispatchSourceTimer?
    var scanScheduled = false
    /// Set once the folder was reachable and its volume (local or network) known.
    var watchConfigured = false

    var settleInterval: Double { isNetwork ? 3 : 1 }
    /// Files untouched for this long are treated as complete without waiting for a second look.
    var settledAge: Double { isNetwork ? 30 : 10 }

    /// Between looks at the folder: `slowPoll` when nothing is happening, `fastPoll` while files are arriving and
    /// until `quietPassesBeforeSlow` looks in a row found nothing (30 s of quiet), so new files are taken up within
    /// seconds without listing a quiet share all night. Local folders have FSEvents and poll as a safety net at
    /// the same pace.
    public static let slowPoll: Double = 30
    public static let fastPoll: Double = 5
    public static let quietPassesBeforeSlow = 6
    public private(set) var pollInterval: Double = 5
    var quietPasses = 0

    public init(source: SourceRecord, store: LibraryStore,
                onChange: @escaping (_ newPending: Bool, _ affectedPeople: Set<Int64>) -> Void) {
        sourceId = source.id!
        root = source.url
        self.store = store
        self.onChange = onChange
        queue = DispatchQueue(label: "source.\(source.id!)")
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Every 5 s until the folder's volume is known (a NAS not mounted yet is picked up as soon as it appears).
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
        queue.async { [weak self] in self?.scan() }
    }

    /// Network volumes get no FSEvents: the poll is the watcher. Local ones use FSEvents, with the poll as a safety
    /// net (missed events, remounted drives). Runs on `queue` once the folder is reachable.
    func configureWatching() {
        guard !watchConfigured, timer != nil else { return }  // a scan on its own (tests, headless) watches nothing
        watchConfigured = true
        isNetwork = (try? root.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
        if !isNetwork { startFSEvents() }
        setPoll(Self.slowPoll)
    }

    func setPoll(_ interval: Double) {
        guard watchConfigured, interval != pollInterval else { return }
        pollInterval = interval
        timer?.schedule(deadline: .now() + interval, repeating: interval)
    }

    /// Files are on their way into this folder (a card copying in): look every few seconds until they stop coming.
    public func expectFiles() {
        queue.async { [weak self] in self?.speedUp() }
    }

    func speedUp() {
        quietPasses = 0
        setPoll(Self.fastPoll)
    }

    /// After a look: files arriving keep the fast pace; quiet looks in a row bring the slow one back.
    func pace(busy: Bool) {
        if busy { speedUp(); return }
        guard pollInterval == Self.fastPoll else { return }
        quietPasses += 1
        if quietPasses >= Self.quietPassesBeforeSlow { setPoll(Self.slowPoll) }
    }

    public func stop() {
        cancelled = true
        timer?.cancel()
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
    }

    public func scanSoon(after delay: Double = 0) {
        guard !cancelled else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
    }

    /// Rescan: every folder listed afresh, and another go at the files that could not be read (most often read
    /// while the share was dropping; unchanged since, a scan alone left them unreadable for good).
    public func rescan() {
        guard !cancelled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            dirCache = [:]
            scan()
            retryFailed()
        }
    }

    /// Files marked unreadable that are there to read go back in the queue. Runs on `queue`.
    func retryFailed() {
        guard isOnline, !cancelled else { return }
        let rows = (try? store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path FROM media WHERE sourceId = ? AND status = 'failed'", arguments: [sourceId])
        }) ?? []
        let ids = rows.filter { FileManager.default.fileExists(atPath: $0["path"]) }.map { $0["id"] as Int64 }
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: Self.batchSize).map({ ids[$0..<min($0 + Self.batchSize, ids.count)] }) {
            try? store.db.write { db in
                try db.execute(sql: "UPDATE media SET status = 'pending', error = NULL WHERE status = 'failed' AND id IN (\(chunk.map(String.init).joined(separator: ",")))")
            }
        }
        onChange(true, [])
    }

    func startFSEvents() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let me = Unmanaged<SourceMonitor>.fromOpaque(info!).takeUnretainedValue()
            me.scheduleScanOnce()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Coalesces bursts of FSEvents into one scan (runs on `queue`).
    func scheduleScanOnce() {
        guard !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.scanScheduled = false
            self?.scan()
        }
    }

    // MARK: - Listing

    static func isMedia(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !name.hasPrefix(".") && !name.hasPrefix("._") && !name.hasPrefix("~$")
            && (ImageLoader.extensions.contains(ext) || VideoSampler.extensions.contains(ext))
    }

    /// All media files under root. Folders whose mtime is unchanged reuse their cached listing. `complete` is false
    /// when a folder or an entry in it could not be read (a share dropping half-way through the listing): such a
    /// folder keeps its last listing, and what is missing from this one is not taken for deleted.
    func list() -> (files: [String: FileInfo], complete: Bool) {
        var out: [String: FileInfo] = [:]
        var complete = true
        var seenDirs: Set<String> = []
        var stack = [root.path]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        while let dir = stack.popLast() {
            if cancelled { return ([:], false) }
            seenDirs.insert(dir)
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            let mtime = (try? dirURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
            var entry: DirEntry
            if let mtime, let cached = dirCache[dir], cached.mtime == mtime {
                entry = cached
            } else if let mtime, let items = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                entry = DirEntry(mtime: mtime, files: [:], subdirs: [])
                var whole = true
                for u in items {
                    // Not known whether it is a file or a folder: this listing of the folder can't be trusted.
                    guard let v = try? u.resourceValues(forKeys: Set(keys)) else { whole = false; continue }
                    if v.isDirectory == true {
                        entry.subdirs.append(u.path)
                    } else if Self.isMedia(u.lastPathComponent) {
                        entry.files[u.path] = FileInfo(size: Int64(v.fileSize ?? 0),
                                                       mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                    }
                }
                if whole { dirCache[dir] = entry } else { complete = false }
            } else {
                // Unreadable (it used to count as empty, and every file in it was dropped from the library with its
                // faces, then read again from scratch once the share was back): the last listing stands in.
                complete = false
                entry = dirCache[dir] ?? DirEntry(mtime: 0, files: [:], subdirs: [])
            }
            out.merge(entry.files) { a, _ in a }
            foundCount = out.count
            stack += entry.subdirs
        }
        if complete { dirCache = dirCache.filter { seenDirs.contains($0.key) } }
        // A file still being written grows without touching its folder's mtime: re-stat unsettled ones.
        for path in candidates.keys where out[path] != nil {
            if let v = try? URL(fileURLWithPath: path, isDirectory: false).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                out[path] = FileInfo(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return (out, complete)
    }

    // MARK: - Scan

    struct Known { var id: Int64; var info: FileInfo; var contentKey: String?; var duplicateOf: Int64?; var status: String }

    /// Files registered per transaction: keeps the database writer free for the UI and the processor, and lets
    /// processing start while a big folder is still being registered.
    static let batchSize = 500

    func scan() {
        guard !cancelled else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            isOnline = false  // unmounted or offline: keep everything, look again on the next tick
            return
        }
        // Back after being offline: what was read while the share was going away gets another go.
        if !isOnline { isOnline = true; retryFailed() }
        configureWatching()
        isScanning = true
        defer { isScanning = false }
        let (files, complete) = list()
        if cancelled { return }
        guard let known = try? store.db.read({ db in
            try Row.fetchAll(db, sql: "SELECT id, path, size, mtime, contentKey, duplicateOf, status FROM media WHERE sourceId = ?",
                             arguments: [sourceId])
        }).reduce(into: [String: Known](), { m, r in
            m[r["path"]] = Known(id: r["id"], info: FileInfo(size: r["size"], mtime: r["mtime"]),
                                 contentKey: r["contentKey"], duplicateOf: r["duplicateOf"], status: r["status"])
        }) else { return }
        // An empty listing of a non-empty source is almost always a share hiccup, not a mass delete.
        if files.isEmpty && !known.isEmpty { return }

        let now = Date()
        var settledNew: [(String, FileInfo)] = []
        var settledChanged: [(String, FileInfo, Int64)] = []
        var needFollowUp = false
        for (path, info) in files {
            let k = known[path]
            if let k, k.info == info { candidates[path] = nil; continue }
            let c = candidates[path]
            // Untouched for a while when first seen: complete. A file seen growing must sit still for longer, so a
            // copy that pauses for a moment isn't processed half-written.
            let old = c == nil && now.timeIntervalSince1970 - info.mtime > settledAge
            let wait = c?.grew == true ? settledAge / 2 : settleInterval
            let stable = c.map { $0.info == info && now.timeIntervalSince($0.seen) >= wait } ?? false
            if old || stable {
                candidates[path] = nil
                if let k { settledChanged.append((path, info, k.id)) } else { settledNew.append((path, info)) }
            } else {
                if let c, c.info != info { candidates[path] = (info, now, true) } else if c == nil { candidates[path] = (info, now, false) }
                needFollowUp = true
            }
        }
        candidates = candidates.filter { files[$0.key] != nil }
        // Only a whole listing says what is gone (the next look, once the share answers again, will).
        var missing = complete ? known.filter { files[$0.key] == nil && !FileManager.default.fileExists(atPath: $0.key) } : [:]
        settledNew.sort { $0.0 < $1.0 }
        pace(busy: !settledNew.isEmpty || !settledChanged.isEmpty || !missing.isEmpty || needFollowUp)

        var affected: Set<Int64> = []
        do {
            // Moves: a new file can only be a moved one if its size matches a missing file's. Only those are
            // fingerprinted here; everything else gets its fingerprint later, while it is processed anyway.
            // (A missing file that was never processed has no fingerprint and is treated as deleted.)
            var missingBySize: [Int64: [String]] = [:]
            for (p, k) in missing { missingBySize[k.info.size, default: []].append(p) }
            var remaining: [(String, FileInfo)] = []
            var moves: [(path: String, info: FileInfo, id: Int64, oldPath: String)] = []
            for (path, info) in settledNew {
                if let olds = missingBySize[info.size], let key = ContentKey.compute(URL(fileURLWithPath: path, isDirectory: false), size: info.size),
                   let oldPath = olds.first(where: { missing[$0]?.contentKey == key }) {
                    moves.append((path, info, missing[oldPath]!.id, oldPath))
                    missing[oldPath] = nil
                    missingBySize[info.size]?.removeAll { $0 == oldPath }
                } else {
                    remaining.append((path, info))
                }
            }
            if !moves.isEmpty {
                try store.db.write { db in
                    for m in moves {
                        try db.execute(sql: "UPDATE media SET path = ?, size = ?, mtime = ? WHERE id = ?",
                                       arguments: [m.path, m.info.size, m.info.mtime, m.id])
                    }
                }
            }

            // Copies: likewise only files whose size matches an existing original of the same kind of folder in
            // the same project (a copy in another event's folder is that event's file).
            let sameKindSizes = Set(try store.db.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT m.size FROM media m JOIN source s ON s.id = m.sourceId
                    WHERE m.duplicateOf IS NULL AND NOT m.skippedAsEdited AND \(Self.sameGroup)
                    """, arguments: [sourceId, sourceId])
            })
            // A camera shooting RAW+JPEG: the RAW file is its JPEG's companion (shown with the JPEG's faces, never
            // processed or exported on its own), like a byte-identical copy. JPEGs go in first so a RAW finds its
            // JPEG whichever order the files were listed in; a RAW whose JPEG arrives later is paired then, as long
            // as it hasn't been processed on its own meanwhile. A JPEG that is itself a copy of a file elsewhere
            // pairs its RAW with that original, which holds the faces (the RAW used to be processed on its own then,
            // and the photo's faces counted twice).
            var jpegByPair: [String: Int64] = [:]
            var rawByPair: [String: Known] = [:]
            for (path, k) in known {
                let url = URL(fileURLWithPath: path, isDirectory: false)
                guard !MediaAnalyzer.isVideo(url) else { continue }
                if ImageLoader.isRaw(url) {
                    if k.duplicateOf == nil { rawByPair[ImageLoader.pairKey(path)] = k }
                } else {
                    jpegByPair[ImageLoader.pairKey(path)] = k.duplicateOf ?? k.id
                }
            }
            let ordered = remaining.filter { !ImageLoader.isRaw(URL(fileURLWithPath: $0.0)) } + remaining.filter { ImageLoader.isRaw(URL(fileURLWithPath: $0.0)) }
            var start = 0
            while start < ordered.count {
                if cancelled { return }
                let batch = ordered[start..<min(start + Self.batchSize, ordered.count)]
                start += batch.count
                var rows: [MediaRecord] = []
                var pairRaws: [(raw: Known, jpegPath: String)] = []
                for (path, info) in batch {
                    let url = URL(fileURLWithPath: path, isDirectory: false)
                    var m = MediaRecord(sourceId: sourceId, path: path, kind: MediaAnalyzer.isVideo(url) ? .video : .photo,
                                        size: info.size, mtime: info.mtime, contentKey: nil)
                    if sameKindSizes.contains(info.size), let key = ContentKey.compute(url, size: info.size),
                       let original = try originalWithKey(key, size: info.size) {
                        m.contentKey = key
                        m.duplicateOf = original
                        m.status = .done
                    }
                    if m.kind == .photo, !ImageLoader.isRaw(url), let raw = rawByPair[ImageLoader.pairKey(path)], raw.status == MediaStatus.pending.rawValue {
                        pairRaws.append((raw, path))
                    }
                    rows.append(m)
                }
                var paired = 0
                try store.db.write { db in
                    for var m in rows { try m.insert(db, onConflict: .ignore) }
                    // New JPEGs by pair key (ids known now), then the batch's RAWs and the waiting RAWs find theirs.
                    for m in rows where m.kind == .photo && !ImageLoader.isRaw(m.url) {
                        if let id = try Int64.fetchOne(db, sql: "SELECT COALESCE(duplicateOf, id) FROM media WHERE path = ?", arguments: [m.path]) {
                            jpegByPair[ImageLoader.pairKey(m.path)] = id
                        }
                    }
                    for m in rows where m.kind == .photo && m.duplicateOf == nil && ImageLoader.isRaw(m.url) {
                        guard let jpeg = jpegByPair[ImageLoader.pairKey(m.path)] else { continue }
                        try db.execute(sql: "UPDATE media SET duplicateOf = ?, status = 'done' WHERE path = ? AND status = 'pending' AND duplicateOf IS NULL",
                                       arguments: [jpeg, m.path])
                        paired += 1
                    }
                    for (raw, jpegPath) in pairRaws {
                        guard let jpegId = try Int64.fetchOne(db, sql: "SELECT COALESCE(duplicateOf, id) FROM media WHERE path = ?", arguments: [jpegPath]) else { continue }
                        try db.execute(sql: "UPDATE media SET duplicateOf = ?, status = 'done' WHERE id = ? AND status = 'pending' AND duplicateOf IS NULL",
                                       arguments: [jpegId, raw.id])
                    }
                }
                if rows.filter({ $0.status == .pending }).count > paired { onChange(true, []) }
            }

            for chunk in stride(from: 0, to: settledChanged.count, by: Self.batchSize).map({ Array(settledChanged[$0..<min($0 + Self.batchSize, settledChanged.count)]) }) {
                if cancelled { return }
                try store.db.write { db in
                    for (_, info, id) in chunk {
                        affected.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId = ? AND personId IS NOT NULL", arguments: [id]))
                        try PersonMemory.remember("face.mediaId = ?", [id], db: db)
                        try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [id])
                        // Read again from scratch: in an edited folder that means skipped again (settleEditedFolders).
                        try db.execute(sql: """
                            UPDATE media SET size = ?, mtime = ?, contentKey = NULL, status = 'pending', duplicateOf = NULL, thumbAt = NULL,
                                skippedAsEdited = 0 WHERE id = ?
                            """, arguments: [info.size, info.mtime, id])
                    }
                }
                onChange(true, [])
            }

            let gone = Array(missing.values)
            for chunk in stride(from: 0, to: gone.count, by: Self.batchSize).map({ Array(gone[$0..<min($0 + Self.batchSize, gone.count)]) }) {
                if cancelled { return }
                try store.db.write { db in
                    for k in chunk { affected.formUnion(try Self.remove(mediaId: k.id, db: db)) }
                }
            }
        } catch {
            NSLog("scan \(root.path) failed: \(error)")
        }
        if !affected.isEmpty { onChange(false, affected) }
        if needFollowUp { scanSoon(after: settleInterval) }
    }

    /// Folders whose files can be copies of each other: same kind, same project (two `?` for this source's id).
    static let sameGroup = "s.kind = (SELECT kind FROM source WHERE id = ?) AND s.projectId IS (SELECT projectId FROM source WHERE id = ?)"

    /// An original (not a copy) in a folder of this source's kind with this fingerprint, fingerprinting same-size
    /// candidates on demand. Never an edited folder's file: it has no faces to share with its copies.
    func originalWithKey(_ key: String, size: Int64) throws -> Int64? {
        let cands = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.contentKey FROM media m JOIN source s ON s.id = m.sourceId
                WHERE m.size = ? AND m.duplicateOf IS NULL AND NOT m.skippedAsEdited AND \(Self.sameGroup)
                """, arguments: [size, sourceId, sourceId])
        }
        for c in cands {
            var ck: String? = c["contentKey"]
            if ck == nil, let computed = ContentKey.compute(URL(fileURLWithPath: c["path"], isDirectory: false), size: size) {
                ck = computed
                try store.db.write { db in
                    try db.execute(sql: "UPDATE media SET contentKey = ? WHERE id = ?", arguments: [computed, c["id"] as Int64])
                }
            }
            if ck == key { return c["id"] }
        }
        return nil
    }

    /// Deletes a media whose file is gone. If a byte-identical copy still exists, that copy inherits the faces.
    /// Returns the people who lost faces.
    static func remove(mediaId: Int64, db: Database) throws -> Set<Int64> {
        if try handOver(mediaId, db: db) {
            try db.execute(sql: "DELETE FROM media WHERE id = ?", arguments: [mediaId])
            return []
        }
        let people = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId = ? AND personId IS NOT NULL", arguments: [mediaId]))
        try PersonMemory.remember("face.mediaId = ?", [mediaId], db: db)
        try db.execute(sql: "DELETE FROM media WHERE id = ?", arguments: [mediaId])
        return people
    }

    /// A file about to leave the library gives its faces and its analysis to a copy of it that is still on disk
    /// (outside `excludingSource`, a folder leaving too), which becomes the original; its other copies (and a
    /// paired RAW) follow it. Returns whether there was such a copy.
    static func handOver(_ mediaId: Int64, excludingSource: Int64? = nil, db: Database) throws -> Bool {
        let copies = try MediaRecord.fetchAll(db, sql: "SELECT * FROM media WHERE duplicateOf = ? AND sourceId IS NOT ? ORDER BY id",
                                              arguments: [mediaId, excludingSource])
        // A RAW paired with this JPEG is a companion, not a copy: it never stands for the photo.
        guard let heir = copies.first(where: { !ImageLoader.isRaw($0.url) && FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        try db.execute(sql: "UPDATE face SET mediaId = ? WHERE mediaId = ?", arguments: [heir.id, mediaId])
        try db.execute(sql: """
            UPDATE media SET duplicateOf = NULL, status = old.status, error = old.error, width = old.width, height = old.height,
                duration = old.duration, takenAt = old.takenAt, featurePrint = old.featurePrint, burstId = old.burstId,
                analysisVersion = old.analysisVersion, importedFrom = old.importedFrom
            FROM (SELECT * FROM media WHERE id = ?) AS old WHERE media.id = ?
            """, arguments: [mediaId, heir.id])
        try db.execute(sql: "UPDATE media SET duplicateOf = ? WHERE duplicateOf = ?", arguments: [heir.id, mediaId])
        return true
    }
}
