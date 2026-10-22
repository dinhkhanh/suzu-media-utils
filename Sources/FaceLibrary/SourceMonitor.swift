import CoreServices
import FaceCore
import Foundation
import GRDB

/// Keeps one source folder in sync with the library: finds new, changed, moved, copied and deleted files.
///
/// Local volumes are watched with FSEvents. Network volumes (SMB/AFP/NFS) get no FSEvents, so they are polled every
/// 5 s; each poll only re-lists folders whose modification time changed.
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
    /// Unsettled files: last seen size/mtime and when.
    var candidates: [String: (info: FileInfo, seen: Date)] = [:]
    var stream: FSEventStreamRef?
    var timer: DispatchSourceTimer?
    var scanScheduled = false

    var settleInterval: Double { isNetwork ? 3 : 1 }
    /// Files untouched for this long are treated as complete without waiting for a second look.
    var settledAge: Double { isNetwork ? 30 : 10 }

    public init(source: SourceRecord, store: LibraryStore,
                onChange: @escaping (_ newPending: Bool, _ affectedPeople: Set<Int64>) -> Void) {
        sourceId = source.id!
        root = source.url
        self.store = store
        self.onChange = onChange
        queue = DispatchQueue(label: "source.\(source.id!)")
    }

    public func start() {
        let values = try? root.resourceValues(forKeys: [.volumeIsLocalKey])
        isNetwork = values?.volumeIsLocal == false
        if !isNetwork { startFSEvents() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Network: the poll is the watcher. Local: a slow safety net (missed events, remounted drives).
        t.schedule(deadline: .now() + (isNetwork ? 5 : 60), repeating: isNetwork ? 5 : 60)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
        queue.async { [weak self] in self?.scan() }
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

    /// All media files under root. Folders whose mtime is unchanged reuse their cached listing.
    func list() -> [String: FileInfo] {
        var out: [String: FileInfo] = [:]
        var seenDirs: Set<String> = []
        var stack = [root.path]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        while let dir = stack.popLast() {
            if cancelled { return [:] }
            seenDirs.insert(dir)
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            let mtime = (try? dirURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            var entry: DirEntry
            if let cached = dirCache[dir], cached.mtime == mtime {
                entry = cached
            } else {
                entry = DirEntry(mtime: mtime, files: [:], subdirs: [])
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: dirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
                for u in items {
                    guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
                    if v.isDirectory == true {
                        entry.subdirs.append(u.path)
                    } else if Self.isMedia(u.lastPathComponent) {
                        entry.files[u.path] = FileInfo(size: Int64(v.fileSize ?? 0),
                                                       mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                    }
                }
                dirCache[dir] = entry
            }
            out.merge(entry.files) { a, _ in a }
            foundCount = out.count
            stack += entry.subdirs
        }
        dirCache = dirCache.filter { seenDirs.contains($0.key) }
        // A file still being written grows without touching its folder's mtime: re-stat unsettled ones.
        for path in candidates.keys where out[path] != nil {
            if let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                out[path] = FileInfo(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return out
    }

    // MARK: - Scan

    struct Known { var id: Int64; var info: FileInfo; var contentKey: String?; var duplicateOf: Int64? }

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
        isOnline = true
        isScanning = true
        defer { isScanning = false }
        let files = list()
        if cancelled { return }
        guard let known = try? store.db.read({ db in
            try Row.fetchAll(db, sql: "SELECT id, path, size, mtime, contentKey, duplicateOf FROM media WHERE sourceId = ?",
                             arguments: [sourceId])
        }).reduce(into: [String: Known](), { m, r in
            m[r["path"]] = Known(id: r["id"], info: FileInfo(size: r["size"], mtime: r["mtime"]),
                                 contentKey: r["contentKey"], duplicateOf: r["duplicateOf"])
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
            let old = now.timeIntervalSince1970 - info.mtime > settledAge
            let stable = candidates[path].map { $0.info == info && now.timeIntervalSince($0.seen) >= settleInterval } ?? false
            if old || stable {
                candidates[path] = nil
                if let k { settledChanged.append((path, info, k.id)) } else { settledNew.append((path, info)) }
            } else {
                if candidates[path]?.info != info { candidates[path] = (info, now) }
                needFollowUp = true
            }
        }
        candidates = candidates.filter { files[$0.key] != nil }
        var missing = known.filter { files[$0.key] == nil && !FileManager.default.fileExists(atPath: $0.key) }
        settledNew.sort { $0.0 < $1.0 }

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
                if let olds = missingBySize[info.size], let key = ContentKey.compute(URL(fileURLWithPath: path), size: info.size),
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

            // Copies: likewise only files whose size matches an existing original of the same kind of folder.
            let sameKindSizes = Set(try store.db.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT m.size FROM media m JOIN source s ON s.id = m.sourceId
                    WHERE m.duplicateOf IS NULL AND s.kind = (SELECT kind FROM source WHERE id = ?)
                    """, arguments: [sourceId])
            })
            var start = 0
            while start < remaining.count {
                if cancelled { return }
                let batch = remaining[start..<min(start + Self.batchSize, remaining.count)]
                start += batch.count
                var rows: [MediaRecord] = []
                for (path, info) in batch {
                    let url = URL(fileURLWithPath: path)
                    var m = MediaRecord(sourceId: sourceId, path: path, kind: MediaAnalyzer.isVideo(url) ? .video : .photo,
                                        size: info.size, mtime: info.mtime, contentKey: nil)
                    if sameKindSizes.contains(info.size), let key = ContentKey.compute(url, size: info.size),
                       let original = try originalWithKey(key, size: info.size) {
                        m.contentKey = key
                        m.duplicateOf = original
                        m.status = .done
                    }
                    rows.append(m)
                }
                try store.db.write { db in
                    for var m in rows { try m.insert(db, onConflict: .ignore) }
                }
                if rows.contains(where: { $0.status == .pending }) { onChange(true, []) }
            }

            for chunk in stride(from: 0, to: settledChanged.count, by: Self.batchSize).map({ Array(settledChanged[$0..<min($0 + Self.batchSize, settledChanged.count)]) }) {
                if cancelled { return }
                try store.db.write { db in
                    for (_, info, id) in chunk {
                        affected.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId = ? AND personId IS NOT NULL", arguments: [id]))
                        try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [id])
                        try db.execute(sql: "UPDATE media SET size = ?, mtime = ?, contentKey = NULL, status = 'pending', duplicateOf = NULL WHERE id = ?",
                                       arguments: [info.size, info.mtime, id])
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

    /// An original (not a copy) in a folder of this source's kind with this fingerprint, fingerprinting same-size
    /// candidates on demand.
    func originalWithKey(_ key: String, size: Int64) throws -> Int64? {
        let cands = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.contentKey FROM media m JOIN source s ON s.id = m.sourceId
                WHERE m.size = ? AND m.duplicateOf IS NULL AND s.kind = (SELECT kind FROM source WHERE id = ?)
                """, arguments: [size, sourceId])
        }
        for c in cands {
            var ck: String? = c["contentKey"]
            if ck == nil, let computed = ContentKey.compute(URL(fileURLWithPath: c["path"]), size: size) {
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
        let copies = try MediaRecord.fetchAll(db, sql: "SELECT * FROM media WHERE duplicateOf = ?", arguments: [mediaId])
        if let heir = copies.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            try db.execute(sql: "UPDATE face SET mediaId = ? WHERE mediaId = ?", arguments: [heir.id, mediaId])
            try db.execute(sql: """
                UPDATE media SET duplicateOf = NULL, status = old.status, error = old.error, width = old.width,
                    height = old.height, duration = old.duration
                FROM (SELECT * FROM media WHERE id = ?) AS old WHERE media.id = ?
                """, arguments: [mediaId, heir.id])
            try db.execute(sql: "UPDATE media SET duplicateOf = ? WHERE duplicateOf = ?", arguments: [heir.id, mediaId])
            try db.execute(sql: "DELETE FROM media WHERE id = ?", arguments: [mediaId])
            return []
        }
        let people = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId = ? AND personId IS NOT NULL", arguments: [mediaId]))
        try db.execute(sql: "DELETE FROM media WHERE id = ?", arguments: [mediaId])
        return people
    }
}
