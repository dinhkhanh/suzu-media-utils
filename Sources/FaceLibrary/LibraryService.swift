import FaceCore
import Foundation
import GRDB
import MediaKit

/// Wires the library together: source monitors -> processor -> grouping engine, plus the user's people edits.
public final class LibraryService: @unchecked Sendable {
    public let store: LibraryStore
    public let engine: GroupingEngine
    public let processor: Processor
    public var exporter: Exporter { Exporter(store: store) }
    let lock = NSLock()
    var monitors: [Int64: SourceMonitor] = [:]
    /// The project open in the window (nil: all of them, every folder watched alike), and how often the photo &
    /// video folders of the other projects are looked at while quiet (nil: not until their project is opened).
    /// Known-people folders belong to every project. See `watch(openProject:othersEvery:)`.
    var openProject: Int64?
    var othersEvery: Double? = SourceMonitor.slowPoll
    var maintenance: DispatchSourceTimer?
    let maintenanceQueue = DispatchQueue(label: "maintenance", qos: .background)
    var burstsDirty = true
    /// Called (on a background queue) after delivery rules handled new files: person name -> count.
    public var onDelivered: (@Sendable (DeliveryService.Report) -> Void)?
    public var delivery: DeliveryService { DeliveryService(store: store) }
    /// Projects shared with other Macs through a folder (see TeamSync).
    public let teamSync: TeamSync

    public init(modelURL: URL, directory: URL = LibraryStore.defaultDirectory) throws {
        store = try LibraryStore(directory: directory)
        engine = GroupingEngine(store: store)
        processor = try Processor(store: store, engine: engine, modelURL: modelURL)
        teamSync = TeamSync(store: store, engine: engine)
        processor.onReferenceEnrolled = { [teamSync] _ in teamSync.pushSoon() }
        // Shared processing: another Mac may do a team's face work (see SharedFaces).
        processor.processesLocally = { [teamSync] sourceId in teamSync.processesLocally(sourceId: sourceId) }
        processor.graceFor = { [teamSync] sourceId in teamSync.processingGrace(sourceId: sourceId) }
        teamSync.onRolesChanged = { [weak self] in self?.applyRoles() }
        teamSync.onSourcesChanged = { [weak self] in
            self?.reconcileMonitorsSoon()
            self?.maintenanceQueue.async { self?.settleEditedFolders() }
        }
        applyRoles()
    }

    /// Follows who processes which project: the grouping engine leaves the other Mac's projects alone, and files
    /// that have become this Mac's to process are queued.
    func applyRoles() {
        let passive = teamSync.passiveProjects()
        let anything = (try? store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project WHERE id NOT IN (\(passive.isEmpty ? "-1" : passive.map(String.init).joined(separator: ",")))")
        }) ?? 1
        engine.queue.async { [engine] in
            engine.passiveProjects = passive
            engine.processesAnything = anything > 0 || passive.isEmpty
        }
        processor.enqueuePending()
    }

    public func start() {
        // Interrupted runs leave nothing half-written (faces and status change in one transaction); just requeue.
        engine.start()
        settleEditedFolders()
        processor.enqueuePending()
        teamSync.start()
        for s in (try? store.db.read { db in try SourceRecord.filter(Column("removedAt") == nil).fetchAll(db) }) ?? [] { startMonitor(s) }
        reconcileMonitorsSoon()  // folders a teammate took out of the team while the app was closed
        let t = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.maintain() }
        t.resume()
        maintenance = t
    }

    /// Background extras (best-shot upgrades of older analyses, burst fingerprints, burst grouping). Each step only
    /// runs while no new file is waiting, so face recognition and grouping are never delayed.
    /// Returns true when there is nothing left to do.
    @discardableResult
    public func maintain() -> Bool {
        settleEditedFolders()
        guard processor.queuedCount == 0, (try? pendingCount()) == 0 else { return false }
        if processor.backgroundCount > 0 { return false }
        let (old, noPrint, wantBursts, noThumb) = (try? store.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'done' AND duplicateOf IS NULL AND analysisVersion < ?",
                              arguments: [BestShot.analysisVersion]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'done' AND duplicateOf IS NULL AND kind = 'photo' AND featurePrint IS NULL") ?? 0,
             try DeliveryService.rules(db).contains { $0.enabled && $0.mediaQuery.collapseBursts },
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'done' AND duplicateOf IS NULL AND thumbAt IS NULL") ?? 0)
        }) ?? (0, 0, false, 0)
        // Deliveries first: they're what people are waiting for. Grouping settles ~30 s after a batch, so files
        // are only delivered once their faces are named. A rule that skips similar shots waits until the new
        // photos' bursts are known, or it would deliver every shot of a burst.
        engine.waitUntilIdle()
        if !(wantBursts && (noPrint > 0 || burstsDirty)), let report = try? delivery.run(), !report.newFiles.isEmpty {
            onDelivered?(report)
            if report.remaining > 0 { return false }
        }
        if processor.extrasPaused { return false }
        // Thumbnails first: they are what the grids wait for.
        if noThumb > 0 { processor.enqueueThumbnails(limit: 100); return false }
        if old > 0 { processor.enqueueUpgrades(limit: 40); burstsDirty = true; return false }
        if noPrint > 0 { processor.enqueueFeaturePrints(limit: 100); burstsDirty = true; return false }
        if burstsDirty {
            burstsDirty = false
            _ = try? BurstGrouper(store: store).regroup()
        }
        return true
    }

    func pendingCount() throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") ?? 0 }
    }

    func startMonitor(_ s: SourceRecord) {
        let m = SourceMonitor(source: s, store: store) { [weak self] newPending, affected in
            guard let self else { return }
            if newPending {
                settleEditedFolders()
                processor.enqueuePending()
            }
            if !affected.isEmpty {
                engine.peopleChanged(affected)
                deleteEmptyPeople()
            }
        }
        lock.withLock { monitors[s.id!] = m }
        m.setIdlePoll(idlePoll(project: s.projectId, kind: s.kind))
        m.start()
    }

    /// Watches the open project's folders (and the known-people folders) closely, the other projects' at
    /// `othersEvery`. Called again when a folder moves to another project.
    public func watch(openProject: Int64?, othersEvery: Double?) {
        let rows = (try? store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, projectId, kind FROM source WHERE removedAt IS NULL")
        }) ?? []
        lock.withLock { self.openProject = openProject; self.othersEvery = othersEvery }
        for r in rows {
            monitor(r["id"])?.setIdlePoll(idlePoll(project: r["projectId"], kind: SourceKind(rawValue: r["kind"]) ?? .media))
        }
    }

    func idlePoll(project: Int64?, kind: SourceKind) -> Double? {
        let (open, others) = lock.withLock { (openProject, othersEvery) }
        return Self.idlePoll(project: project, kind: kind, open: open, others: others)
    }

    static func idlePoll(project: Int64?, kind: SourceKind, open: Int64?, others: Double?) -> Double? {
        guard let open, kind == .media, let project, project != open else { return SourceMonitor.slowPoll }
        return others
    }

    public func monitor(_ sourceId: Int64) -> SourceMonitor? { lock.withLock { monitors[sourceId] } }

    /// Watches what the database says: a folder a teammate shared gets a watcher, one they took out of the team is
    /// forgotten (its files and faces too, in the background), one whose path changed is watched at the new place.
    func reconcileMonitorsSoon() { maintenanceQueue.async { [weak self] in self?.reconcileMonitors() } }

    func reconcileMonitors() {
        guard let sources = try? store.db.read({ db in try SourceRecord.fetchAll(db) }) else { return }
        for s in sources where s.removedAt != nil {
            try? removeSource(s.id!)
        }
        let live = sources.filter { $0.removedAt == nil }
        let ids = Set(live.map { $0.id! })
        for (id, m) in lock.withLock({ monitors }) where !ids.contains(id) {
            lock.withLock { monitors.removeValue(forKey: id) }
            m.stop()
        }
        for s in live {
            if let m = lock.withLock({ monitors[s.id!] }) {
                guard m.root.path != s.path else { continue }
                lock.withLock { monitors.removeValue(forKey: s.id!) }
                m.stop()
                m.queue.sync {}
            }
            startMonitor(s)
        }
    }

    public enum ProjectError: LocalizedError {
        case alreadyAdded(folder: String, project: String?)
        case overlaps(folder: String, other: String, project: String?)
        case noProject
        case notShared
        public var errorDescription: String? {
            switch self {
            case .alreadyAdded(let f, let p): "“\(f)” is already in \(p.map { "the project “\($0)”" } ?? "the library")."
            case .overlaps(let f, let o, let p):
                "“\(f)” overlaps “\(o)”\(p.map { " in the project “\($0)”" } ?? ""): a file can only belong to one folder. Add a different folder, or move that one."
            case .noProject: "Choose or create a project first."
            case .notShared: "Share the project with a team first: team folders and edited folders travel to the team's Macs."
            }
        }
    }

    /// Adds a folder. Photo & video folders belong to a project; known-people folders are shared by all projects.
    /// A team folder or edited folder (`share`) appears on every Mac of the project's team.
    @discardableResult
    public func addSource(_ url: URL, kind: SourceKind = .media, project: Int64? = nil, share: SourceShare = .mac) throws -> SourceRecord {
        let path = canonicalPath(url)
        if kind == .media && project == nil { throw ProjectError.noProject }
        if share != .mac { try requireTeam(project) }
        // The same event folder, renamed or moved in Finder: relink it rather than start over.
        if let old = try Self.offlineSource(matching: path, kind: kind, store: store) {
            try relinkSource(old, to: url)
            if kind == .media, let project { try moveSource(old, to: project) }
            if share != .mac { try setShare(old, share) }
            if let s = try store.db.read({ db in try SourceRecord.fetchOne(db, key: old) }) { return s }
        }
        try Self.checkNewFolder(path, store: store)
        var s = SourceRecord(path: path, kind: kind, projectId: kind == .media ? project : nil, share: kind == .media ? share : .mac)
        try store.db.write { db in try s.insert(db) }
        startMonitor(s)
        if s.share != .mac { teamSync.pushSoon() }
        return s
    }

    /// A file Copy from Cards just landed in one of the library's folders: registered and queued at once, ahead of
    /// everything else, to be read from the card while it is still in the slot. The folder scan finds the row
    /// already there (same size and time) and leaves it alone; a RAW whose JPEG came along is left to the scan,
    /// which pairs the two. When another Mac does this team's face work, the file is still processed here (its
    /// faces go to the team and that Mac groups them, see SharedFaces) rather than read back from the share there.
    public func fileLanded(_ f: CardCopier.Landed) {
        guard !f.rawWithJPEG else { return }
        let path = canonicalPath(f.landed)
        guard let source = (try? store.db.read { db in try SourceRecord.filter(Column("kind") == SourceKind.media.rawValue && Column("removedAt") == nil).fetchAll(db) })?
            .filter({ path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) else { return }
        let mine = processor.processesLocally?(source.id) ?? true
        // The time as the share stored it (its precision, not the card's), or the scan would take the file for changed.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path), let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        var m = MediaRecord(sourceId: source.id, path: path, kind: MediaAnalyzer.isVideo(url) ? .video : .photo, size: f.size, mtime: mtime, contentKey: f.contentKey)
        m.localWork = !mine
        let id = try? store.db.write { db -> Int64? in
            try m.insert(db, onConflict: .ignore)
            // The scan may have registered it first: it is this Mac's work all the same.
            if !mine { try db.execute(sql: "UPDATE media SET localWork = 1 WHERE path = ? AND status = 'pending'", arguments: [path]) }
            return try Int64.fetchOne(db, sql: "SELECT id FROM media WHERE path = ? AND status = 'pending' AND duplicateOf IS NULL", arguments: [path])
        }
        guard let id = id ?? nil else { return }
        processor.prefer(f.onCard, for: path)
        processor.enqueue(id, first: true)
        // Files are landing here: the folder's watcher looks every few seconds until they stop.
        if let sid = source.id { monitor(sid)?.expectFiles() }
    }

    func requireTeam(_ project: Int64?) throws {
        let team = try store.db.read { db in try Int64?.fetchOne(db, sql: "SELECT teamId FROM project WHERE id = ?", arguments: [project]) }
        guard team ?? nil != nil else { throw ProjectError.notShared }
    }

    /// Makes a folder the team's, the editing Mac's, or this Mac's own again. The team's Macs follow: they get the
    /// folder, or drop it if it only came to them through the team.
    public func setShare(_ sourceId: Int64, _ share: SourceShare) throws {
        guard let s = try store.db.read({ db in try SourceRecord.fetchOne(db, key: sourceId) }), s.kind == .media, s.share != share else { return }
        if share != .mac { try requireTeam(s.projectId) }
        try store.db.write { db in
            // Kept as this Mac's own from now on: a teammate dropping it later doesn't take it away here.
            try db.execute(sql: "UPDATE source SET share = ?, shareAt = \(SyncIds.stampSQL("shareAt")), fromDevice = CASE WHEN ? = 'mac' THEN NULL ELSE fromDevice END WHERE id = ?",
                           arguments: [share.rawValue, Date().timeIntervalSince1970, share.rawValue, sourceId])
        }
        if share == .edited || s.share == .edited { maintenanceQueue.async { [weak self] in self?.settleEditedFolders() } }
        teamSync.pushSoon()
    }

    /// Edited folders hold finished work, mostly edits of photos already in the library: their files are listed
    /// but never read for faces, or everyone in them would be found twice. A folder that has become an edited one
    /// loses its files' faces (to an identical copy outside it when there is one, which then stands for the file);
    /// one that is no longer an edited folder has its files processed.
    func settleEditedFolders() {
        let (affected, reopened): (Set<Int64>, Bool)
        do {
            (affected, reopened) = try Self.settleEditedFolders(store: store)
        } catch {
            NSLog("edited folders: \(error)")
            return
        }
        if !affected.isEmpty {
            engine.peopleChanged(affected)
            deleteEmptyPeople()
        }
        if reopened { processor.enqueuePending() }
    }

    /// The database side of `settleEditedFolders`: returns the people who lost faces, and whether files are
    /// waiting to be processed again.
    static func settleEditedFolders(store: LibraryStore) throws -> (affected: Set<Int64>, reopened: Bool) {
        var affected: Set<Int64> = []
        while true {
            let n = try store.db.write { db -> Int in
                // Also a skipped file waiting again: libraries before 0.8.13 put a changed file back to pending with
                // its skip kept, and the processor never takes an edited folder's file, so it waited for good.
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT id FROM media WHERE sourceId IN (\(SourceShare.editedIds)) AND duplicateOf IS NULL
                      AND (NOT skippedAsEdited OR status = 'pending') LIMIT 500
                    """)
                for id in ids { affected.formUnion(try skipAsEdited(id, db: db)) }
                return ids.count
            }
            if n == 0 { break }
        }
        let reopened = try store.db.write { db in
            try db.execute(sql: """
                UPDATE media SET status = 'pending', error = NULL, skippedAsEdited = 0, featurePrint = NULL
                WHERE skippedAsEdited AND sourceId NOT IN (\(SourceShare.editedIds))
                """)
            return db.changesCount > 0
        }
        return (affected, reopened)
    }

    /// Takes an edited folder's file out of face work. Its faces go to an identical copy outside edited folders,
    /// which becomes the original (this file its copy); without one they are forgotten (named people remembered,
    /// see PersonMemory). Returns the people who lost faces.
    static func skipAsEdited(_ id: Int64, db: Database) throws -> Set<Int64> {
        if let heir = try Int64.fetchOne(db, sql: """
            SELECT id FROM media WHERE duplicateOf = ? AND sourceId NOT IN (\(SourceShare.editedIds)) ORDER BY id LIMIT 1
            """, arguments: [id]) {
            try db.execute(sql: "UPDATE face SET mediaId = ? WHERE mediaId = ?", arguments: [heir, id])
            try db.execute(sql: """
                UPDATE media SET duplicateOf = NULL, status = old.status, error = old.error, width = old.width, height = old.height,
                    duration = old.duration, takenAt = old.takenAt, featurePrint = old.featurePrint, burstId = old.burstId,
                    analysisVersion = old.analysisVersion, importedFrom = old.importedFrom
                FROM (SELECT * FROM media WHERE id = ?) AS old WHERE media.id = ?
                """, arguments: [id, heir])
            try db.execute(sql: "UPDATE media SET duplicateOf = ? WHERE duplicateOf = ?", arguments: [heir, id])
            try db.execute(sql: "UPDATE media SET duplicateOf = ?, status = 'done', error = NULL WHERE id = ?", arguments: [heir, id])
            return []
        }
        let people = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId = ? AND personId IS NOT NULL", arguments: [id]))
        try PersonMemory.remember("face.mediaId = ?", [id], db: db)
        try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM facePublish WHERE mediaId = ?", arguments: [id])
        // Done as far as face work goes: no fingerprint for bursts either (an empty one is "nothing to do").
        try db.execute(sql: """
            UPDATE media SET status = 'done', error = NULL, skippedAsEdited = 1, importedFrom = NULL, featurePrint = X'',
                burstId = NULL, analysisVersion = ? WHERE id = ?
            """, arguments: [BestShot.analysisVersion, id])
        return people
    }

    /// Throws when the folder is already in the library, or inside / around one that is (its files would be listed
    /// twice).
    static func checkNewFolder(_ path: String, store: LibraryStore) throws {
        let existing = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT s.path, p.name FROM source s LEFT JOIN project p ON p.id = s.projectId")
        }
        let name = (path as NSString).lastPathComponent
        for r in existing {
            let other: String = r["path"]
            if other == path { throw ProjectError.alreadyAdded(folder: name, project: r["name"]) }
            if path.hasPrefix(other + "/") || other.hasPrefix(path + "/") {
                throw ProjectError.overlaps(folder: name, other: (other as NSString).lastPathComponent, project: r["name"])
            }
        }
    }

    // MARK: - Projects

    @discardableResult
    public func createProject(_ name: String) throws -> ProjectRecord {
        var p = ProjectRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Project" : name)
        try store.db.write { db in try p.insert(db) }
        return p
    }

    public func renameProject(_ id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try store.db.write { db in
            try db.execute(sql: "UPDATE project SET name = ?, updatedAt = \(SyncIds.stampSQL("updatedAt")) WHERE id = ?",
                           arguments: [trimmed, Date().timeIntervalSince1970, id])
        }
        teamSync.pushSoon()
    }

    /// Moves a folder (and everything found in it) to another project; nothing is re-scanned.
    public func moveSource(_ sourceId: Int64, to project: Int64) throws {
        try store.db.write { db in
            try db.execute(sql: "UPDATE source SET projectId = ? WHERE id = ? AND kind = 'media'", arguments: [project, sourceId])
        }
    }

    /// Forgets a project and its folders (files on disk are untouched). People keep their names, so they are still
    /// recognised in other projects. Slow for big projects: call it off the main thread.
    public func deleteProject(_ id: Int64) throws {
        let sources = try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM source WHERE projectId = ?", arguments: [id]) }
        for s in sources { try removeSource(s) }
        try store.db.write { db in
            // A shared project deleted here stays on teammates' Macs; their later changes to it are ignored here
            // rather than bringing it back.
            if let p = try ProjectRecord.fetchOne(db, key: id), let team = p.teamId {
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, '1')", arguments: [team, "gone:project:\(p.uuid)"])
            }
            _ = try ProjectRecord.deleteOne(db, key: id)
        }
    }

    /// Forgets a source and everything found in it. Files on disk are not touched. Named people stay, and what
    /// their faces looked like is remembered (PersonMemory), so they are recognised when the photos come back. Deletes in small batches so the
    /// database stays responsive; call it off the main thread for big folders.
    public func removeSource(_ id: Int64) throws {
        lock.withLock { monitors.removeValue(forKey: id) }?.stop()
        // A shared folder removed here leaves the team: the teammates' Macs drop it too (those that only had it
        // through the team). One a teammate already took out of the team (removedAt) just goes.
        let shared = try store.db.write { db -> Bool in
            guard let s = try SourceRecord.fetchOne(db, key: id), s.share != .mac, s.removedAt == nil else { return false }
            try db.execute(sql: "INSERT OR REPLACE INTO sourceGone (uuid, projectId, at) VALUES (?, ?, ?)",
                           arguments: [s.uuid, s.projectId, Date().timeIntervalSince1970])
            return true
        }
        let affected = try Self.deleteSourceContents(id, store: store)
        engine.peopleChanged(affected)
        deleteEmptyPeople()
        processor.enqueuePending()  // copies that lost their original without a face to take over
        if shared { teamSync.pushSoon() }
    }

    /// Deletes a source's media 500 at a time, then the source. Returns the people who lost faces.
    @discardableResult
    static func deleteSourceContents(_ id: Int64, store: LibraryStore) throws -> Set<Int64> {
        var affected: Set<Int64> = []
        while true {
            let n = try store.db.write { db -> Int in
                let ids = try Int64.fetchAll(db, sql: "SELECT id FROM media WHERE sourceId = ? LIMIT 500", arguments: [id])
                guard !ids.isEmpty else { return 0 }
                // An original with a copy in another folder: the copy carries on with its faces (it used to be left
                // done and faceless, and its RAW was then processed on its own).
                for mid in ids { _ = try SourceMonitor.handOver(mid, excludingSource: id, db: db) }
                let list = ids.map(String.init).joined(separator: ",")
                affected.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE mediaId IN (\(list)) AND personId IS NOT NULL"))
                try PersonMemory.remember("face.mediaId IN (\(list))", db: db)
                try db.execute(sql: "DELETE FROM media WHERE id IN (\(list))")
                return ids.count
            }
            if n == 0 { break }
        }
        try store.db.write { db in try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id]) }
        return affected
    }

    public func rescan(_ sourceId: Int64) { monitor(sourceId)?.rescan() }

    /// Runs `body` while every folder watcher waits, so no scan sees files half-way through being renamed or
    /// relinked (it would take them for deleted and new files and drop their faces). Call it off the main thread.
    func holdingMonitors<T>(_ body: () throws -> T) rethrows -> T {
        let queues = lock.withLock { monitors.sorted { $0.key < $1.key }.map(\.value.queue) }
        func hold(_ rest: ArraySlice<DispatchQueue>) throws -> T {
            guard let q = rest.first else { return try body() }
            return try q.sync { try hold(rest.dropFirst()) }
        }
        return try hold(queues[...])
    }

    /// Batch Rename: renames the files and their library records together, so faces, names and fixes stay with
    /// each file. Swaps and shifted numbers are fine; the database is updated in two steps for the same reason.
    public func renameFiles(_ items: [RenamePattern.Item], names: [String]) throws -> RenamePattern.Outcome {
        var affected: Set<Int64> = []
        let outcome = try holdingMonitors { () throws -> RenamePattern.Outcome in
            // Library paths are canonical; work them out while the old names still exist.
            let before = Dictionary(items.map { ($0.url, canonicalPath($0.url)) }, uniquingKeysWith: { a, _ in a })
            let outcome = RenamePattern.apply(items, names: names)
            affected = try Self.recordRenames(outcome.renamed.map { (before[$0.0] ?? canonicalPath($0.0), $0.1.lastPathComponent) }, store: store)
            return outcome
        }
        if !affected.isEmpty { engine.peopleChanged(affected); deleteEmptyPeople() }
        return outcome
    }

    /// Points library records at their files' new names: (old canonical path, new file name in the same folder).
    /// Two steps, so swaps and shifted numbers never collide with each other's old names. Returns the people who
    /// lost faces (only from leftover records of files no longer on disk).
    static func recordRenames(_ renames: [(path: String, newName: String)], store: LibraryStore) throws -> Set<Int64> {
        guard !renames.isEmpty else { return [] }
        return try store.db.write { db in
            var affected: Set<Int64> = []
            var moved: [(id: Int64, path: String)] = []
            for r in renames {
                let newPath = (r.path as NSString).deletingLastPathComponent + "/" + r.newName
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM media WHERE path = ?", arguments: [r.path]) { moved.append((id, newPath)) }
            }
            for m in moved {
                try db.execute(sql: "UPDATE media SET path = ? WHERE id = ?", arguments: ["\u{1}renaming/\(m.id)", m.id])
            }
            let ids = Set(moved.map(\.id))
            for m in moved {
                // A leftover record of a file that is no longer on disk under that name.
                if let stale = try Int64.fetchOne(db, sql: "SELECT id FROM media WHERE path = ?", arguments: [m.path]), !ids.contains(stale) {
                    affected.formUnion(try SourceMonitor.remove(mediaId: stale, db: db))
                }
                try db.execute(sql: "UPDATE media SET path = ? WHERE id = ?", arguments: [m.path, m.id])
            }
            return affected
        }
    }

    /// A folder renamed or moved in Finder: points the library at its new place, keeping every face and name.
    /// Throws if the new folder overlaps another one in the library.
    public func relinkSource(_ id: Int64, to url: URL) throws {
        let path = canonicalPath(url)
        guard let source = try store.db.read({ db in try SourceRecord.fetchOne(db, key: id) }) else { return }
        guard source.path != path else { return }
        let others = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT s.path, p.name FROM source s LEFT JOIN project p ON p.id = s.projectId WHERE s.id != ?", arguments: [id])
        }
        for r in others {
            let other: String = r["path"]
            if other == path || path.hasPrefix(other + "/") || other.hasPrefix(path + "/") {
                throw ProjectError.overlaps(folder: (path as NSString).lastPathComponent, other: (other as NSString).lastPathComponent, project: r["name"])
            }
        }
        if let m = lock.withLock({ monitors.removeValue(forKey: id) }) {
            m.stop()
            m.queue.sync {}  // let a scan already under way finish first
        }
        try Self.relinkPaths(id, from: source.path, to: path, store: store)
        if let s = try store.db.read({ db in try SourceRecord.fetchOne(db, key: id) }) { startMonitor(s) }
    }

    static func relinkPaths(_ id: Int64, from old: String, to new: String, store: LibraryStore) throws {
        try store.db.write { db in try relinkPaths(id, from: old, to: new, db: db) }
    }

    static func relinkPaths(_ id: Int64, from old: String, to new: String, db: Database) throws {
        let oldPrefix = old + "/"
        try db.execute(sql: "UPDATE source SET path = ? WHERE id = ?", arguments: [new, id])
        // substr counts code points from 1 (not Swift characters: "ư" may be two): keep what follows the old path.
        try db.execute(sql: "UPDATE media SET path = ? || substr(path, ?) WHERE sourceId = ? AND substr(path, 1, ?) = ?",
                       arguments: [new + "/", oldPrefix.unicodeScalars.count + 1, id, oldPrefix.unicodeScalars.count, oldPrefix])
    }

    /// An offline folder (renamed, moved, or its drive not mounted) whose files are all found under `path`.
    /// Adding that folder again relinks the old entry instead, so nothing is lost or processed twice.
    static func offlineSource(matching path: String, kind: SourceKind, store: LibraryStore) throws -> Int64? {
        let fm = FileManager.default
        let offline = try store.db.read { db in try SourceRecord.filter(Column("kind") == kind.rawValue).fetchAll(db) }
            .filter { !fm.fileExists(atPath: $0.path) }
        for s in offline {
            let sample = try store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT path, size, contentKey FROM media WHERE sourceId = ? AND duplicateOf IS NULL AND contentKey IS NOT NULL
                    ORDER BY random() LIMIT 12
                    """, arguments: [s.id])
            }
            guard !sample.isEmpty else { continue }
            let prefix = s.path + "/"
            // Same relative path is not enough (cameras restart at DSC_0001): the contents must match too.
            let found = sample.filter { r in
                let old: String = r["path"], size: Int64 = r["size"]
                guard old.hasPrefix(prefix) else { return false }
                let url = URL(fileURLWithPath: path + "/" + old.dropFirst(prefix.count), isDirectory: false)
                let actual = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
                return actual == size && ContentKey.compute(url, size: size) == r["contentKey"]
            }
            if found.count == sample.count { return s.id }
        }
        return nil
    }

    // MARK: - People

    /// Renames a person. If another person already has that name, the two are merged; returns the surviving id.
    @discardableResult
    public func rename(_ personId: Int64, to rawName: String) throws -> Int64 {
        let name = PersonNames.clean(rawName)
        let existing = try store.db.read { db in try PersonNames.find(name, excluding: personId, db: db) }
        if let existing, !name.isEmpty {
            try merge([personId], into: existing)
            return existing
        }
        try store.db.write { db in
            try db.execute(sql: "UPDATE person SET name = ?, nameAt = \(SyncIds.stampSQL("nameAt")) WHERE id = ?",
                           arguments: [name.isEmpty ? nil : name, Date().timeIntervalSince1970, personId])
        }
        engine.reclusterNow()  // runs autoName, so unnamed groups that match this person join it
        teamSync.pushSoon()
        return personId
    }

    public func merge(_ ids: [Int64], into target: Int64) throws {
        let others = ids.filter { $0 != target }
        guard !others.isEmpty else { return }
        try store.db.write { db in try PersonNames.merge(others, into: target, db: db) }
        // The user's call that these are one person: the merged person is rebuilt with what both were taught, and
        // its faces, the waiting faces and the other groups are looked at against it.
        engine.corrected(from: Set(ids).union([target]), to: [target])
        teamSync.pushSoon()
    }

    /// "Not this person": the faces leave the person and are never auto-assigned back to them. The person learns
    /// from it: faces that look like these more than like them leave too, and later ones stay away
    /// (`GroupingEngine.corrected`).
    public func reject(faceIds: [Int64], from personId: Int64) throws {
        let ids = faceIds.map(String.init).joined(separator: ",")
        try store.db.write { db in
            try db.execute(sql: """
                UPDATE face SET personId = NULL, assignment = 'user', rejectedPersonId = ?
                WHERE id IN (\(ids))
                """, arguments: [personId])
            try db.execute(sql: "INSERT OR IGNORE INTO faceEditPublish (faceId) SELECT id FROM face WHERE id IN (\(ids))")
        }
        engine.corrected(from: [personId])
        deleteEmptyPeople()
        teamSync.pushSoon()
    }

    /// "Regroup": the app places these faces again, each with whoever it looks most like (their person now too, when
    /// that is still the best match), else in a new group or among the unassigned. Faces placed by hand stay: they
    /// are what the people look like, so after a wrong merge the faces moved to the right names steer the rest.
    /// Returns how many faces were let go.
    @discardableResult
    public func regroup(faceIds: [Int64]) throws -> Int {
        guard !faceIds.isEmpty else { return 0 }
        let (people, media, count) = try store.db.write { db in try Self.letGo(faceIds, db: db) }
        guard count > 0 else { return 0 }
        // Their people first lose them (the engine's picture of each person is rebuilt), then they are placed.
        engine.peopleChanged(people)
        engine.regroup(mediaIds: Array(media))
        teamSync.pushSoon()
        return count
    }

    /// The database side of `regroup`: the faces not placed by hand leave their people and wait to be placed.
    /// Returns their people, their files and how many.
    static func letGo(_ faceIds: [Int64], db: Database) throws -> (people: Set<Int64>, media: Set<Int64>, count: Int) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, personId, mediaId FROM face
            WHERE id IN (\(faceIds.map(String.init).joined(separator: ","))) AND assignment != 'user' AND embedding IS NOT NULL
            """)
        guard !rows.isEmpty else { return ([], [], 0) }
        let ids = rows.map { String($0["id"] as Int64) }.joined(separator: ",")
        try db.execute(sql: "UPDATE face SET personId = NULL, assignment = 'none' WHERE id IN (\(ids))")
        try db.execute(sql: "INSERT OR IGNORE INTO faceEditPublish (faceId) SELECT id FROM face WHERE id IN (\(ids))")
        return (Set(rows.compactMap { $0["personId"] as Int64? }), Set(rows.map { $0["mediaId"] as Int64 }), rows.count)
    }

    /// Puts faces (and, for videos, nothing else) under a person and locks them there. A face moved out of another
    /// person is also marked as not theirs, so the two are never merged back together automatically; a face
    /// brought back to the person it was taken from is theirs again. Both people learn from it: faces left behind
    /// that look like the moved ones more than like the person they are with follow them, and waiting faces that
    /// look like them join the person they went to (`GroupingEngine.corrected`).
    public func assign(faceIds: [Int64], to personId: Int64) throws {
        let previous = try store.db.write { db -> Set<Int64> in
            let ids = faceIds.map(String.init).joined(separator: ",")
            let prev = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT personId FROM face WHERE id IN (\(ids)) AND personId IS NOT NULL"))
            try db.execute(sql: """
                UPDATE face SET rejectedPersonId = CASE WHEN personId IS NOT NULL AND personId != ? THEN personId
                                                        WHEN rejectedPersonId = ? THEN NULL ELSE rejectedPersonId END,
                    personId = ?, assignment = 'user' WHERE id IN (\(ids))
                """, arguments: [personId, personId, personId])
            try db.execute(sql: "INSERT OR IGNORE INTO faceEditPublish (faceId) SELECT id FROM face WHERE id IN (\(ids))")
            return prev
        }
        engine.corrected(from: previous.subtracting([personId]), to: [personId])
        deleteEmptyPeople()
        teamSync.pushSoon()
    }

    /// Creates a named person from faces (e.g. picked from "Unassigned"). A name someone already has adds the
    /// faces to that person instead.
    @discardableResult
    public func newPerson(name rawName: String?, faceIds: [Int64]) throws -> Int64 {
        let name = rawName.map(PersonNames.clean).flatMap { $0.isEmpty ? nil : $0 }
        let id = try store.db.write { db -> Int64 in
            if let name, let existing = try PersonNames.find(name, db: db) { return existing }
            var p = PersonRecord(name: name)
            try p.insert(db)
            return p.id!
        }
        try assign(faceIds: faceIds, to: id)
        return id
    }

    /// Picks the face used as a person's picture; nil goes back to the best shot automatically.
    public func setCover(_ personId: Int64, faceId: Int64?) throws {
        try store.db.write { db in
            try db.execute(sql: "UPDATE person SET coverFaceId = ?, coverAt = \(SyncIds.stampSQL("coverAt")) WHERE id = ?",
                           arguments: [faceId, Date().timeIntervalSince1970, personId])
        }
        teamSync.pushSoon()
    }

    // MARK: Lists and pins (see PersonGroups)

    public func pin(_ people: [Int64], _ on: Bool) throws {
        try store.db.write { db in try PersonGroups.pin(people, on, db: db) }
        teamSync.pushSoon()
    }

    /// Makes a list (or finds the one of that name) and puts `people` on it.
    @discardableResult
    public func createGroup(_ name: String, people: [Int64] = []) throws -> Int64 {
        try store.db.write { db in
            let id = try PersonGroups.create(name, db: db)
            try PersonGroups.set(id, people: people, member: true, db: db)
            teamSync.pushSoon()
            return id
        }
    }

    public func renameGroup(_ id: Int64, to name: String) throws {
        try store.db.write { db in try PersonGroups.rename(id, to: name, db: db) }
        teamSync.pushSoon()
    }

    public func deleteGroup(_ id: Int64) throws {
        try store.db.write { db in try PersonGroups.delete(id, db: db) }
        teamSync.pushSoon()
    }

    public func setGroup(_ id: Int64, people: [Int64], member: Bool) throws {
        try store.db.write { db in try PersonGroups.set(id, people: people, member: member, db: db) }
        teamSync.pushSoon()
    }

    /// Unnamed people with no faces left are clutter; named ones are kept so their name is not lost.
    public func deleteEmptyPeople() {
        try? store.db.write { db in
            try db.execute(sql: """
                DELETE FROM person WHERE name IS NULL AND id NOT IN (SELECT personId FROM face WHERE personId IS NOT NULL)
                """)
        }
    }
}
