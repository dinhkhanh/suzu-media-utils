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
        timer?.cancel()
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
    }

    public func scanSoon(after delay: Double = 0) {
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

    func scan() {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            isOnline = false  // unmounted or offline: keep everything, look again on the next tick
            return
        }
        isOnline = true
        let files = list()
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

        var newPending = false
        var affected: Set<Int64> = []
        do {
            try store.db.write { db in
                var missingByKey: [String: (String, Known)] = [:]
                for (p, k) in missing { if let key = k.contentKey { missingByKey[key] = (p, k) } }

                for (path, info) in settledNew {
                    let key = ContentKey.compute(URL(fileURLWithPath: path), size: info.size)
                    if let key, let (oldPath, k) = missingByKey[key] {
                        // Moved or renamed outside the app: keep its faces and people.
                        try db.execute(sql: "UPDATE media SET path = ?, size = ?, mtime = ? WHERE id = ?",
                                       arguments: [path, info.size, info.mtime, k.id])
                        missing[oldPath] = nil
                        missingByKey[key] = nil
                        continue
                    }
                    let kind: MediaKind = MediaAnalyzer.isVideo(URL(fileURLWithPath: path)) ? .video : .photo
                    var m = MediaRecord(sourceId: sourceId, path: path, kind: kind, size: info.size, mtime: info.mtime, contentKey: key)
                    // Duplicates are only matched among folders of the same kind: a reference photo copied from
                    // an event folder must still be processed to teach the person's name.
                    if let key, let original = try Int64.fetchOne(db, sql: """
                        SELECT m.id FROM media m JOIN source s ON s.id = m.sourceId
                        WHERE m.contentKey = ? AND m.duplicateOf IS NULL
                          AND s.kind = (SELECT kind FROM source WHERE id = ?) LIMIT 1
                        """, arguments: [key, sourceId]) {
                        m.duplicateOf = original
                        m.status = .done
                    } else {
                        newPending = true
                    }
                    try m.insert(db)
                }

                for (path, info, id) in settledChanged {
                    affected.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId = ? AND personId IS NOT NULL", arguments: [id]))
                    try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [id])
                    let key = ContentKey.compute(URL(fileURLWithPath: path), size: info.size)
                    try db.execute(sql: "UPDATE media SET size = ?, mtime = ?, contentKey = ?, status = 'pending', duplicateOf = NULL WHERE id = ?",
                                   arguments: [info.size, info.mtime, key, id])
                    newPending = true
                }

                for (_, k) in missing {
                    affected.formUnion(try Self.remove(mediaId: k.id, db: db))
                }
            }
        } catch {
            NSLog("scan \(root.path) failed: \(error)")
        }
        if newPending || !affected.isEmpty { onChange(newPending, affected) }
        if needFollowUp { scanSoon(after: settleInterval) }
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
