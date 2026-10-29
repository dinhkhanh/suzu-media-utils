import CryptoKit
import FaceCore
import Foundation
import GRDB

/// One Mac does a team's face work, the others take its results. At an event one strong Mac recognises faces while
/// the Macs that copy cards and edit photos only read what it found, through the team folder.
///
/// The processing Mac writes a record per file it processed to `faces/<its id>/media-NNN.jsonl` (the faces: box,
/// quality, embedding, who they are) and the face crops to `faces/<its id>/crops/<content key>/<n>.jpg`. Whenever
/// a face's person changes there (grouping, a merge, "not this person"), the file's record is written again. The
/// other Macs read the records in order and, for every file they have waiting whose content key matches, take the
/// faces as their own; records for files they don't have yet are remembered by key (`faceIndex`) and used when the
/// file turns up. Their own edits (a face rejected or moved) travel back as `face` changes in their log, keyed by
/// content key and the face's position in the file, which the processing Mac applies and publishes again.
///
/// The role lives in `team.json` (`processor`), set from the team menu; with none set every Mac processes its own
/// files as before.
///
/// The processing Mac remembers what it published for each file (`facePublished`: the faces' boxes and people) and
/// keeps comparing that with the file's faces now, a slice per pass, publishing again whatever drifted: a queue
/// emptied while the role changed hands, faces dropped or found again, a person's stable id changed. Queues make
/// changes travel fast; the comparison makes sure none is lost.
///
/// Hybrid: a Mac copying cards processes the files it copies itself (`media.localWork`), from the card while it is
/// still in, and publishes the faces as they are, ungrouped. The processing Mac takes those records for the files
/// it has waiting (sparing itself the read from the share), groups the faces, and publishes the files again with
/// the people; every other Mac, the copier included, takes the processing Mac's record as the truth. The
/// processing Mac gives a fresh file a moment (`processingGrace`) for a copier's record to arrive before reading it
/// itself, while copiers are sending.
extension TeamSync {
    public struct Processor: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var at: Double
    }

    static func facesURL(_ folder: URL) -> URL { folder.appendingPathComponent("faces", isDirectory: true) }
    static func facesURL(_ folder: URL, device: String) -> URL { facesURL(folder).appendingPathComponent(device, isDirectory: true) }
    /// A record file grows to about this before the next one starts.
    static let faceFileLimit = 64 << 20
    /// Files published per pass, so a pass stays short while a backlog drains.
    static let facePublishBatch = 150
    /// Seconds one pass spends publishing before it leaves the rest to the next pass.
    static let facePublishTimeBox: TimeInterval = 20
    /// Crop files written to the share at once.
    static let cropCopyLanes = 8

    /// Copies small files (face crops, thumbnails) to the team folder: their bytes only, `cropCopyLanes` at a
    /// time. A missing source is skipped; a failed write leaves no partial file under the final name.
    static func copyCrops(_ copies: [(from: URL, to: URL)]) {
        guard !copies.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: min(cropCopyLanes, copies.count)) { lane in
            var i = lane
            while i < copies.count {
                let c = copies[i]
                if let data = try? Data(contentsOf: c.from) { try? data.write(to: c.to, options: .atomic) }
                i += cropCopyLanes
            }
        }
    }
    /// Content keys computed per pass for waiting files (one read of 1 MB each).
    static let faceKeyBatch = 300
    /// A file's record is written again at most this often while its faces keep changing.
    static let faceRepublishInterval: Double = 20
    /// Records of a teammate's applied per transaction (see pullFaces).
    static let faceApplyChunk = 100
    /// Files compared per pass with what the team folder holds for them (see reconcilePublished).
    static let faceSweepBatch = 2000
    /// Bytes of this Mac's own records read back per pass to learn what the team folder holds (once per library).
    static let faceSeedBytes = 48 << 20

    /// One processed file as published.
    struct MediaPayload: Codable {
        var key: String
        var project: String
        var kind: String
        var w: Int
        var h: Int
        var dur: Double?
        var taken: Double?
        var fp: String?
        var v: Int
        var faces: [FacePayload]
    }

    struct FacePayload: Codable {
        var x: Double, y: Double, w: Double, h: Double
        var q: Double?
        var t: Double?
        var tr: Int?
        var e: String?
        var ey: Double?, sm: Double?, sh: Double?, yaw: Double?, pitch: Double?, sc: Double?
        /// The person's stable id, how the face got there (auto/user), and the person it is not.
        var p: String?
        var a: String
        var r: String?
    }

    /// What a record says about a file's faces: `boxes` changes when the faces themselves do (the crops go again),
    /// `sig` also when who they are does. The same for a record read back from the team folder and for the faces
    /// in the library, so the two can be compared.
    static func signature(_ faces: [FacePayload]) -> (sig: String, boxes: String) {
        func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
        let boxes = faces.map { "\($0.x),\($0.y),\($0.w),\($0.h),\($0.t ?? -1)" }.joined(separator: ";")
        let people = faces.map { "\($0.p ?? "")/\($0.a)/\($0.r ?? "")" }.joined(separator: ";")
        return (hash(boxes + "|" + people), hash(boxes))
    }

    // MARK: - The role

    /// Who does this team's face work, if a Mac was chosen.
    public func processor(of teamId: Int64) -> Processor? {
        guard let t = try? store.db.read({ db in try TeamRecord.fetchOne(db, key: teamId) }), let id = t.processorId else { return nil }
        return Processor(id: id, name: t.processorName ?? "A teammate's Mac", at: 0)
    }

    /// Makes this Mac the one that processes faces for the team (or, `thisMac` false, lets every Mac process its
    /// own files again). Written to `team.json`, which every Mac re-reads on its next pass.
    public func setProcessor(_ teamId: Int64, thisMac: Bool) throws {
        guard let team = try store.db.read({ db in try TeamRecord.fetchOne(db, key: teamId) }) else { return }
        guard var info = Self.readInfo(team.url) else { throw TeamError.folderUnreachable }
        info.processor = thisMac ? Processor(id: deviceId, name: deviceName, at: Date().timeIntervalSince1970) : nil
        try Self.writeInfo(info, to: team.url)
        try applyProcessor(info.processor, team: team)
        // Everything already processed here should be there for the others at once.
        if thisMac { try queueAllForPublishing(teamId) }
        syncSoon()
    }

    static func writeInfo(_ info: Info, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = infoURL(folder).appendingPathExtension("tmp")
        try encoder.encode(info).write(to: tmp)
        guard Darwin.rename(tmp.path, infoURL(folder).path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Records a (changed) role read from `team.json`; tells the app so processing and grouping follow it.
    func applyProcessor(_ p: Processor?, team: TeamRecord) throws {
        guard p?.id != team.processorId || p?.name != team.processorName else { return }
        try store.db.write { db in
            try db.execute(sql: "UPDATE team SET processorId = ?, processorName = ? WHERE id = ?", arguments: [p?.id, p?.name, team.id])
        }
        lock.withLock { rolesVersion += 1 }
        onRolesChanged?()
    }

    /// Whether files of this project are processed on this Mac: its own projects always, a team's only when the
    /// team has no processing Mac or this is it.
    public func processesLocally(project: Int64?) -> Bool {
        guard let project else { return true }
        let p = try? store.db.read { db in
            try String?.fetchOne(db, sql: "SELECT t.processorId FROM project p LEFT JOIN team t ON t.id = p.teamId WHERE p.id = ?", arguments: [project])
        }
        guard let pid = p ?? nil else { return true }
        return pid == deviceId
    }

    public func processesLocally(sourceId: Int64?) -> Bool {
        guard let sourceId else { return true }
        let project = try? store.db.read { db in try Int64?.fetchOne(db, sql: "SELECT projectId FROM source WHERE id = ?", arguments: [sourceId]) }
        return processesLocally(project: project ?? nil)
    }

    /// Projects whose faces come from another Mac.
    public func passiveProjects() -> Set<Int64> {
        Set((try? store.db.read { db in
            try Int64.fetchAll(db, sql: "SELECT p.id FROM project p JOIN team t ON t.id = p.teamId WHERE t.processorId IS NOT NULL AND t.processorId != ?",
                               arguments: [deviceId])
        }) ?? [])
    }

    func isProcessor(_ team: TeamRecord) -> Bool { team.processorId == deviceId }

    /// A fresh file of this source waits this long for a copying Mac's record before this Mac reads it from the
    /// share: only on the team's processing Mac, and only while some other Mac sent face records lately.
    public static let copierGrace: Double = 30
    public static let copierRecent: Double = 600
    public func processingGrace(sourceId: Int64?) -> Double {
        guard let sourceId else { return 0 }
        guard let team = try? store.db.read({ db in
            try TeamRecord.fetchOne(db, sql: "SELECT t.* FROM source s JOIN project p ON p.id = s.projectId JOIN team t ON t.id = p.teamId WHERE s.id = ?", arguments: [sourceId])
        }), isProcessor(team), let last = lock.withLock({ foreignFacesAt[team.id!] }) else { return 0 }
        return Date().timeIntervalSince(last) < Self.copierRecent ? Self.copierGrace : 0
    }

    func queueAllForPublishing(_ teamId: Int64) throws {
        try store.db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO facePublish (mediaId)
                SELECT m.id FROM media m JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                WHERE p.teamId = ? AND m.status = 'done' AND m.duplicateOf IS NULL AND m.importedFrom IS NULL AND NOT m.skippedAsEdited
                """, arguments: [teamId])
        }
    }

    // MARK: - Publishing what this Mac found

    /// Writes face records for the team. The processing Mac writes the files it processed and those whose faces
    /// changed since (its own and the ones it took from copying Macs, now grouped). Any other Mac writes, once, the
    /// files it processed itself off a card (`localWork`); its edits travel as `face` changes instead. With no
    /// processing Mac nothing is written and the queues are emptied.
    func publishFaces(_ passTeam: TeamRecord) throws -> Bool {
        let teamId = passTeam.id!
        // The role as it is now, not as the pass found it: the role can change hands while a pass is under way, and
        // a stale "not the processing Mac" used to throw away the whole queue the new processor had just filled.
        guard let team = try store.db.read({ db in try TeamRecord.fetchOne(db, key: teamId) }) else { return false }
        guard team.processorId != nil else {
            if try teams().allSatisfy({ $0.processorId == nil }) {
                try store.db.write { db in
                    try db.execute(sql: "DELETE FROM facePublish")
                    try db.execute(sql: "DELETE FROM faceChange")
                }
            }
            return false
        }
        let now = Date().timeIntervalSince1970
        let ids: [Int64]
        if isProcessor(team) {
            try reconcilePublished(team)
            let (fresh, changed) = try store.db.read { db -> ([Int64], [Int64]) in
                (try Int64.fetchAll(db, sql: """
                    SELECT m.id FROM facePublish q JOIN media m ON m.id = q.mediaId JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                    WHERE p.teamId = ? AND m.status = 'done' AND m.importedFrom IS NULL ORDER BY m.id LIMIT ?
                    """, arguments: [teamId, Self.facePublishBatch]),
                 try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT m.id FROM faceChange c JOIN face f ON f.id = c.faceId JOIN media m ON m.id = f.mediaId
                    JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                    WHERE p.teamId = ? AND m.status = 'done' ORDER BY m.id LIMIT ?
                    """, arguments: [teamId, Self.facePublishBatch]))
            }
            let published = lock.withLock { facesPublishedAt }
            let due = changed.filter { now - (published[$0] ?? 0) >= Self.faceRepublishInterval }
            ids = Array(Set(fresh + due)).sorted()
            // Changes to files that aren't this team's (or already published moments ago) wait for a later pass;
            // those of files no longer here are dropped.
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM faceChange WHERE faceId NOT IN (SELECT id FROM face)")
                try db.execute(sql: "DELETE FROM facePublish WHERE mediaId NOT IN (SELECT id FROM media WHERE status = 'done' AND importedFrom IS NULL)")
            }
        } else {
            // A copying Mac: the cards' files it processed, as they are; the processing Mac groups them.
            ids = try store.db.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT m.id FROM facePublish q JOIN media m ON m.id = q.mediaId JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                    WHERE p.teamId = ? AND m.status = 'done' AND m.importedFrom IS NULL AND m.localWork ORDER BY m.id LIMIT ?
                    """, arguments: [teamId, Self.facePublishBatch])
            }
            try store.db.write { db in
                // Only while this Mac still isn't the processing one (checked in the same transaction).
                let processor = try String?.fetchOne(db, sql: "SELECT processorId FROM team WHERE id = ?", arguments: [teamId]) ?? nil
                guard let processor, processor != deviceId else { return }
                let mine = "SELECT m.id FROM media m JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId WHERE p.teamId = \(teamId)"
                try db.execute(sql: "DELETE FROM faceChange WHERE faceId IN (SELECT id FROM face WHERE mediaId IN (\(mine)))")
                try db.execute(sql: "DELETE FROM facePublish WHERE mediaId IN (\(mine) AND NOT (m.status = 'done' AND m.importedFrom IS NULL AND m.localWork))")
            }
        }
        guard !ids.isEmpty else { return false }

        let dir = Self.facesURL(team.url, device: deviceId)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("crops", isDirectory: true), withIntermediateDirectories: true)
        var lines = Data()
        let encoder = JSONEncoder()
        var written: [Int64] = []
        var signatures: [(mediaId: Int64, sig: String, boxes: String)] = []
        var handled: [Int64] = []
        var copies: [(from: URL, to: URL)] = []
        var finals: [(tmp: URL, dir: URL)] = []
        var stale: [URL] = []
        let started = Date()
        for mid in ids {
            // A backlog is published over several passes: one pass never holds the team's queue (and every other
            // team change behind it) for minutes.
            if !handled.isEmpty, Date().timeIntervalSince(started) > Self.facePublishTimeBox { break }
            handled.append(mid)
            guard let (payload, faceIds) = try payload(for: mid) else { continue }
            if try store.db.read({ db in try Bool.fetchOne(db, sql: "SELECT \(Self.laterCopy) FROM media m WHERE m.id = ?", arguments: [mid]) }) == true { continue }
            lines += try encoder.encode(payload)
            lines += Data("\n".utf8)
            written.append(mid)
            let sig = Self.signature(payload.faces)
            signatures.append((mid, sig.sig, sig.boxes))
            // Crops: a folder per file and per set of faces (named by the boxes, which a reader computes from
            // the record), faces numbered as in the record. Faces found again (dropped, in another order) get a
            // folder of their own, so a teammate taking an older record never numbers new pictures onto old
            // faces, and nothing is deleted under a reader's feet; the older sets go once the new one is there.
            let cropDir = Self.cropFolder(dir, key: payload.key, boxes: sig.boxes)
            if !fm.fileExists(atPath: cropDir.path) {
                // Filled under a temporary name and renamed into place once whole: a reader that sees the folder
                // has all of it, and one that doesn't tries again later.
                let tmp = cropDir.appendingPathExtension("tmp")
                try? fm.removeItem(at: tmp)
                try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                for (i, fid) in faceIds.enumerated() {
                    copies.append((store.faceCropURL(fid), tmp.appendingPathComponent("\(i).jpg")))
                }
                // The file's thumbnail too, so the other Macs never read the file for their grids.
                copies.append((store.thumbnailURL(mid), tmp.appendingPathComponent("thumb.jpg")))
                finals.append((tmp, cropDir))
                stale += (try? fm.contentsOfDirectory(at: cropDir.deletingLastPathComponent(), includingPropertiesForKeys: nil))?
                    .filter { $0.lastPathComponent != sig.boxes && $0.lastPathComponent != tmp.lastPathComponent } ?? []
            }
        }
        // Before the records that name them. Plain bytes, several at a time: a Finder-style copy also sets owner,
        // mode, flags and extended attributes, each a round trip to the NAS, and copying them one by one made a
        // pass take minutes.
        Self.copyCrops(copies)
        for f in finals { try? fm.moveItem(at: f.tmp, to: f.dir) }
        for s in stale { try? fm.removeItem(at: s) }
        if !lines.isEmpty {
            let file = try Self.currentRecordFile(dir)
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            let h = try FileHandle(forUpdating: file)
            defer { try? h.close() }
            try Self.appendLines(lines, to: h)
        }
        guard !handled.isEmpty else { return false }
        let done = handled.map(String.init).joined(separator: ",")
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM facePublish WHERE mediaId IN (\(done))")
            try db.execute(sql: "DELETE FROM faceChange WHERE faceId IN (SELECT id FROM face WHERE mediaId IN (\(done)))")
            for s in signatures {
                try db.execute(sql: "INSERT OR REPLACE INTO facePublished (mediaId, sig, boxes, fromShare) VALUES (?, ?, ?, 0)", arguments: [s.mediaId, s.sig, s.boxes])
            }
        }
        lock.withLock { for mid in written { facesPublishedAt[mid] = now } }
        return !written.isEmpty
    }

    /// Where a file's crops sit for one set of faces: `crops/<content key>/<boxes>/`. Records from before 0.8.31
    /// kept them in `crops/<content key>/` itself; a reader falls back to that.
    static func cropFolder(_ deviceDir: URL, key: String, boxes: String) -> URL {
        deviceDir.appendingPathComponent("crops", isDirectory: true).appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(boxes, isDirectory: true)
    }

    /// The folder a reader takes a record's crops from: the record's own set, else the old flat layout.
    static func cropSource(_ deviceDir: URL, key: String, boxes: String) -> URL {
        let versioned = cropFolder(deviceDir, key: key, boxes: boxes)
        if FileManager.default.fileExists(atPath: versioned.path) { return versioned }
        return versioned.deletingLastPathComponent()
    }

    /// The newest `media-NNN.jsonl`, or the next one when it is full.
    static func currentRecordFile(_ dir: URL) throws -> URL {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("media-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let last = files.last, ((try? last.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) < faceFileLimit { return last }
        return dir.appendingPathComponent(String(format: "media-%04d.jsonl", files.count + 1))
    }

    /// SQL on `media m`: the same bytes are also an earlier file here (one file in two folders, not marked as a
    /// copy). Only the first is published: two records for one content key, read in either order, left teammates
    /// with whichever came last.
    static let laterCopy = """
        EXISTS (SELECT 1 FROM media o WHERE o.contentKey = m.contentKey AND +o.id < m.id AND o.duplicateOf IS NULL
                AND +o.status = 'done' AND o.importedFrom IS NULL AND NOT o.skippedAsEdited)
        """  // `+`: by content key (the status index made it a scan per file)

    /// Queues the team's files whose faces are no longer what the team folder holds for them: a slice of the
    /// library per pass, from where the last pass stopped, round and round. A library from before `facePublished`
    /// first learns what it published by reading its own records back (`seedPublished`), so only the files that
    /// really drifted go again.
    func reconcilePublished(_ team: TeamRecord) throws {
        let teamId = team.id!
        let state = try state(teamId)
        guard state["pubseed"] == "done" else { return try seedPublished(team, state: state) }
        let cursor = Int64(state["pubsweep"] ?? "0") ?? 0
        // Edited folders' files are left out: they have no faces by design, and no teammate takes faces for them.
        let (mids, rows, published) = try store.db.read { db -> ([Int64], [Row], [Int64: (sig: String, boxes: String)]) in
            let mids = try Int64.fetchAll(db, sql: """
                SELECT m.id FROM media m JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                WHERE p.teamId = ? AND m.status = 'done' AND m.importedFrom IS NULL AND m.duplicateOf IS NULL AND NOT m.skippedAsEdited
                  AND m.id > ? AND NOT \(Self.laterCopy) ORDER BY m.id LIMIT ?
                """, arguments: [teamId, cursor, Self.faceSweepBatch])
            guard let first = mids.first, let last = mids.last else { return ([], [], [:]) }
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.mediaId, f.x, f.y, f.w, f.h, f.time, f.assignment, p.uuid AS person, r.uuid AS rejected
                FROM face f LEFT JOIN person p ON p.id = f.personId LEFT JOIN person r ON r.id = f.rejectedPersonId
                WHERE f.mediaId BETWEEN ? AND ? ORDER BY f.mediaId, f.id
                """, arguments: [first, last])
            let published = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT mediaId, sig, boxes FROM facePublished WHERE mediaId BETWEEN ? AND ?",
                                                                              arguments: [first, last]).map { ($0["mediaId"] as Int64, (sig: $0["sig"] as String, boxes: $0["boxes"] as String)) })
            return (mids, rows, published)
        }
        guard let last = mids.last else {
            try setState(teamId, ["pubsweep": "0"])  // round again from the start
            return
        }
        var faces: [Int64: [FacePayload]] = [:]
        for r in rows {
            faces[r["mediaId"], default: []].append(FacePayload(x: r["x"], y: r["y"], w: r["w"], h: r["h"], t: r["time"],
                                                                p: r["person"], a: r["assignment"], r: r["rejected"]))
        }
        // A file never published goes too (its teammates' copies wait for it). One whose faces all went without
        // being processed again doesn't: no path empties a file's faces quietly on purpose, and sending that would
        // take good faces off every other Mac (a RAW+JPEG pair processed as two files lost the JPEG's, 0.8.13).
        let none = Self.signature([]).boxes
        let drifted = mids.filter { m in
            guard let was = published[m] else { return true }
            let now = faces[m] ?? []
            if now.isEmpty && was.boxes != none { return false }
            return was.sig != Self.signature(now).sig
        }
        try store.db.write { db in
            for mid in drifted { try db.execute(sql: "INSERT OR IGNORE INTO facePublish (mediaId) VALUES (?)", arguments: [mid]) }
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, 'pubsweep', ?)", arguments: [teamId, String(last)])
        }
    }

    /// Reads this Mac's own records back, a slice per pass, and remembers for each file what the team folder holds
    /// for it (the newest record wins). Only what was there when the reading began: records published since are
    /// remembered as they are written.
    func seedPublished(_ team: TeamRecord, state: [String: String]) throws {
        let teamId = team.id!
        let dir = Self.facesURL(team.url, device: deviceId)
        let fm = FileManager.default
        // The files and their sizes when the reading began, "name:size,…".
        var targets: [(name: String, size: Int)]
        if let t = state["pubseed"], !t.isEmpty {
            targets = t.split(separator: ",").compactMap { e in
                let parts = e.split(separator: ":")
                guard parts.count == 2, let n = Int(parts[1]) else { return nil }
                return (String(parts[0]), n)
            }
        } else {
            let listed = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            // There but unreadable for now: "nothing published" would send every file again.
            if listed == nil && fm.fileExists(atPath: dir.path) { return }
            targets = (listed ?? [])
                .filter { $0.lastPathComponent.hasPrefix("media-") && $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            try setState(teamId, ["pubseed": targets.isEmpty ? "done" : targets.map { "\($0.name):\($0.size)" }.joined(separator: ",")])
            if targets.isEmpty { return }
        }
        var budget = Self.faceSeedBytes
        let decoder = JSONDecoder()
        for t in targets {
            let key = "pubseed:\(t.name)"
            let cursor = Int(state[key] ?? "0") ?? 0
            guard cursor < t.size else { continue }
            guard budget > 0 else { return }
            guard let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent(t.name)) else { return }  // offline: next pass
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(cursor))
            let data = try h.read(upToCount: min(budget, t.size - cursor)) ?? Data()
            // Whole lines only; a line longer than the budget is read whole.
            var end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            var chunk = data[data.startIndex..<end]
            if end == 0 {
                try h.seek(toOffset: UInt64(cursor))
                let rest = try h.read(upToCount: t.size - cursor) ?? Data()
                end = rest.firstIndex(of: 0x0A).map { $0 + 1 } ?? rest.count
                chunk = rest[rest.startIndex..<end]
            }
            budget -= chunk.count
            try store.db.write { db in
                for line in chunk.split(separator: 0x0A) where !line.isEmpty {
                    guard let payload = try? decoder.decode(MediaPayload.self, from: line) else { continue }
                    let sig = Self.signature(payload.faces)
                    for mid in try Int64.fetchAll(db, sql: "SELECT id FROM media WHERE contentKey = ? AND duplicateOf IS NULL AND importedFrom IS NULL",
                                                  arguments: [payload.key]) {
                        try db.execute(sql: """
                            INSERT INTO facePublished (mediaId, sig, boxes, fromShare) VALUES (?, ?, ?, 1)
                            ON CONFLICT(mediaId) DO UPDATE SET sig = excluded.sig, boxes = excluded.boxes WHERE fromShare
                            """, arguments: [mid, sig.sig, sig.boxes])
                    }
                }
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)",
                               arguments: [teamId, key, String(cursor + chunk.count)])
            }
            if cursor + chunk.count < t.size { return }
        }
        try setState(teamId, ["pubseed": "done"])
    }

    /// The record of a file processed here, and its faces' ids in the record's order; nil when the file has no
    /// content key yet and can't get one (offline).
    func payload(for mediaId: Int64) throws -> (MediaPayload, [Int64])? {
        guard var media = try store.db.read({ db in try MediaRecord.fetchOne(db, key: mediaId) }) else { return nil }
        if media.contentKey == nil {
            guard let key = ContentKey.compute(media.url, size: media.size) else { return nil }
            media.contentKey = key
            try store.db.write { db in try db.execute(sql: "UPDATE media SET contentKey = ? WHERE id = ?", arguments: [key, mediaId]) }
        }
        let (project, faces, uuids) = try store.db.read { db -> (String, [FaceRecord], [Int64: String]) in
            let project = try String.fetchOne(db, sql: "SELECT p.uuid FROM media m JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId WHERE m.id = ?",
                                              arguments: [mediaId]) ?? ""
            let faces = try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ? ORDER BY id", arguments: [mediaId])
            let pids = Set(faces.compactMap(\.personId) + faces.compactMap(\.rejectedPersonId))
            var uuids: [Int64: String] = [:]
            if !pids.isEmpty {
                for r in try Row.fetchAll(db, sql: "SELECT id, uuid FROM person WHERE id IN (\(pids.map(String.init).joined(separator: ",")))") {
                    uuids[r["id"]] = r["uuid"]
                }
            }
            return (project, faces, uuids)
        }
        let payload = MediaPayload(
            key: media.contentKey!, project: project, kind: media.kind.rawValue, w: media.width ?? 0, h: media.height ?? 0,
            dur: media.duration, taken: media.takenAt, fp: media.featurePrint.map { $0.base64EncodedString() }, v: media.analysisVersion,
            faces: faces.map { f in
                FacePayload(x: f.x, y: f.y, w: f.w, h: f.h, q: f.quality, t: f.time, tr: f.track, e: f.embedding?.base64EncodedString(),
                            ey: f.eyesOpen, sm: f.smile, sh: f.sharpness, yaw: f.yaw, pitch: f.pitch, sc: f.score,
                            p: f.personId.flatMap { uuids[$0] }, a: f.assignment.rawValue, r: f.rejectedPersonId.flatMap { uuids[$0] })
            })
        return (payload, faces.map { $0.id! })
    }

    /// Faces the user moved or rejected here, as `face` changes for the log (the processing Mac applies them and
    /// publishes the files again).
    func faceEditOps() throws -> ([Op], [Int64]) {
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.faceId, f.mediaId, m.contentKey, m.path, m.size, f.assignment, p.uuid AS person, r.uuid AS rejected,
                       (SELECT COUNT(*) FROM face g WHERE g.mediaId = f.mediaId AND g.id < f.id) AS idx
                FROM faceEditPublish e JOIN face f ON f.id = e.faceId JOIN media m ON m.id = f.mediaId
                LEFT JOIN person p ON p.id = f.personId LEFT JOIN person r ON r.id = f.rejectedPersonId
                """)
        }
        var ops: [Op] = []
        var done: [Int64] = []
        let now = Date().timeIntervalSince1970
        for r in rows {
            let fid: Int64 = r["faceId"]
            // A file without a content key yet gets one now; one that can't be read (offline) waits for a later
            // pass. The edit used to be dropped unsent.
            var key: String? = r["contentKey"]
            if key == nil, let path: String = r["path"], let size: Int64 = r["size"] {
                key = ContentKey.compute(URL(fileURLWithPath: path, isDirectory: false), size: size)
                if let key { try store.db.write { db in try db.execute(sql: "UPDATE media SET contentKey = ? WHERE id = ?", arguments: [key, r["mediaId"] as Int64]) } }
            }
            guard let key else { continue }
            done.append(fid)
            var op = Op(t: "face", at: now, uuid: r["person"])
            op.key = key
            op.index = r["idx"]
            op.assign = r["assignment"]
            op.rejected = r["rejected"]
            ops.append(op)
        }
        return (ops, done)
    }

    // MARK: - Taking a teammate's results

    /// Reads new records from every other Mac's `faces/` folder, takes the ones for files waiting here, remembers
    /// the rest by content key, and gives waiting files their keys so remembered records can be matched.
    func pullFaces(_ team: TeamRecord) throws -> Bool {
        let teamId = team.id!
        let fm = FileManager.default
        var changed = false
        var affected: Set<Int64> = []
        let devices = (try? fm.contentsOfDirectory(at: Self.facesURL(team.url), includingPropertiesForKeys: nil)) ?? []
        for dev in devices where dev.hasDirectoryPath || (try? dev.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let device = dev.lastPathComponent
            guard device != deviceId else { continue }
            let files = ((try? fm.contentsOfDirectory(at: dev, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("media-") && $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in files {
                let name = f.lastPathComponent
                let state = try state(teamId)
                let cursor = Int(state["fcur:\(device):\(name)"] ?? "0") ?? 0
                let h = try FileHandle(forReadingFrom: f)
                defer { try? h.close() }
                guard try Self.size(of: h) > cursor else { continue }
                try h.seek(toOffset: UInt64(cursor))
                let data = try h.readToEnd() ?? Data()
                guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
                lock.withLock { foreignFacesAt[teamId] = Date() }
                let complete = data[data.startIndex...lastNewline]
                var offset = cursor
                let decoder = JSONDecoder()
                // A short transaction per chunk of records, the cursor moved with each: a backlog of thousands
                // (joining, catching up) never holds the writer for seconds, so a card copy or an export landing
                // files at the same time keeps recording them.
                let lines = complete.split(separator: 0x0A, omittingEmptySubsequences: false)
                for chunk in stride(from: 0, to: lines.count, by: Self.faceApplyChunk).map({ lines[$0..<min($0 + Self.faceApplyChunk, lines.count)] }) {
                    try store.db.write { db in
                        for line in chunk {
                            let length = line.count
                            defer { offset += length + 1 }
                            guard !line.isEmpty, let payload = try? decoder.decode(MediaPayload.self, from: line) else { continue }
                            // The processing Mac's record stays the one remembered for a file: a copying Mac's
                            // ungrouped record of it, read after, doesn't take its place.
                            try db.execute(sql: """
                                INSERT INTO faceIndex (teamId, contentKey, deviceId, file, offset, length) VALUES (?, ?, ?, ?, ?, ?)
                                ON CONFLICT(teamId, contentKey) DO UPDATE SET deviceId = excluded.deviceId, file = excluded.file,
                                    offset = excluded.offset, length = excluded.length
                                WHERE excluded.deviceId IS ? OR faceIndex.deviceId IS NOT ?
                                """, arguments: [teamId, payload.key, device, name, offset, length, team.processorId, team.processorId])
                            affected.formUnion(try take(payload, from: device, team: team, db: db))
                        }
                        try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)",
                                       arguments: [teamId, "fcur:\(device):\(name)", String(min(offset, cursor + complete.count))])
                    }
                }
                changed = true
            }
        }
        // Waiting files: give them content keys, then look them up in the teammates' records. On the Macs that
        // don't process, every waiting file; on the processing Mac only fresh ones (a copier's record may be on its
        // way for those), since it reads the rest itself anyway.
        let processorHere = team.processorId == deviceId
        let waiting = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.size, m.contentKey FROM media m JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                WHERE p.teamId = ? AND m.status = 'pending' AND m.duplicateOf IS NULL AND NOT m.localWork AND s.share != 'edited'
                  AND (m.contentKey IS NULL OR m.contentKey IN (SELECT contentKey FROM faceIndex WHERE teamId = ?))
                  AND (NOT ? OR m.contentKey IS NOT NULL OR m.seenAt > ?)
                ORDER BY m.id LIMIT ?
                """, arguments: [teamId, teamId, processorHere, Date().timeIntervalSince1970 - Self.copierRecent, Self.faceKeyBatch])
        }
        defer {
            // Files taken from copying Macs' records here on the processing Mac: grouped now, as if processed here.
            let toGroup = lock.withLock { let t = takenToGroup; takenToGroup = []; return t }
            for mid in toGroup { engine.mediaProcessed(mid) }
        }
        guard !waiting.isEmpty, team.processorId != nil, !(processorHere && lock.withLock({ foreignFacesAt[teamId] }) == nil) else {
            if !affected.isEmpty { engine.peopleChanged(affected) }
            return changed
        }
        for r in waiting {
            let mid: Int64 = r["id"]
            var key: String? = r["contentKey"]
            if key == nil {
                guard let k = ContentKey.compute(URL(fileURLWithPath: r["path"], isDirectory: false), size: r["size"]) else { continue }
                key = k
                try store.db.write { db in try db.execute(sql: "UPDATE media SET contentKey = ? WHERE id = ?", arguments: [k, mid]) }
            }
            guard let key, let entry = try store.db.read({ db in
                try Row.fetchOne(db, sql: "SELECT deviceId, file, offset, length FROM faceIndex WHERE teamId = ? AND contentKey = ?", arguments: [teamId, key])
            }) else { continue }
            let url = Self.facesURL(team.url, device: entry["deviceId"]).appendingPathComponent(entry["file"] as String)
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(entry["offset"] as Int))
            guard let line = try h.read(upToCount: entry["length"] as Int), let payload = try? JSONDecoder().decode(MediaPayload.self, from: line) else { continue }
            let device: String = entry["deviceId"]
            try store.db.write { db in affected.formUnion(try take(payload, from: device, team: team, db: db)) }
            changed = true
        }
        if !affected.isEmpty { engine.peopleChanged(affected) }
        return changed
    }

    /// Takes a published record for a file waiting here (or already taken from a teammate: then its faces' people
    /// are brought up to date). The processing Mac's record is the truth for everyone else, even for a file this
    /// Mac processed itself off a card; the processing Mac keeps what it processed itself and takes copying Macs'
    /// records for files it has waiting. Returns the people whose faces changed.
    func take(_ payload: MediaPayload, from device: String, team: TeamRecord, db: Database) throws -> Set<Int64> {
        guard let processorId = team.processorId else { return [] }
        let authoritative = device == processorId
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id, m.status, m.importedFrom FROM media m JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
            WHERE m.contentKey = ? AND m.duplicateOf IS NULL AND p.teamId = ? AND s.share != 'edited' AND NOT m.skippedAsEdited
            """, arguments: [payload.key, team.id])
        var affected: Set<Int64> = []
        for r in rows {
            let mid: Int64 = r["id"], status: String = r["status"], from: String? = r["importedFrom"]
            let ownWork = status == MediaStatus.done.rawValue && from == nil
            // Processed here: kept, unless this is the processing Mac's grouping of a card's file processed here.
            if ownWork && (!authoritative || processorId == deviceId) { continue }
            // Already the processing Mac's: a copying Mac's ungrouped record of the file (read later) changes nothing.
            if from == processorId && !authoritative { continue }
            let existing = try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ? ORDER BY id", arguments: [mid])
            var people: [String: Int64] = [:]
            func person(_ uuid: String?) throws -> Int64? {
                guard let uuid else { return nil }
                if let id = people[uuid] { return id }
                if let id = try Self.resolve(uuid, db: db) { people[uuid] = id; return id }
                // Not named yet on the processing Mac: an unnamed group, the same group here.
                var p = PersonRecord(name: nil, uuid: uuid)
                try p.insert(db)
                people[uuid] = p.id!
                return p.id!
            }
            // The faces matched by position only when they are the very same faces: a file found again on the
            // processing Mac (or by another Mac's detector) can have as many faces in another order, and naming
            // them by position put people on the wrong faces.
            let sameFaces = existing.count == payload.faces.count && zip(existing, payload.faces).allSatisfy { f, pf in
                abs(f.x - pf.x) < 1e-9 && abs(f.y - pf.y) < 1e-9 && abs(f.w - pf.w) < 1e-9 && abs(f.h - pf.h) < 1e-9 && f.time == pf.t
            }
            if from == device || authoritative, sameFaces, !existing.isEmpty {
                // Same faces (the same file, the same detector), maybe different people now.
                for (f, pf) in zip(existing, payload.faces) {
                    let pid = try person(pf.p), rej = try person(pf.r)
                    guard f.personId != pid || f.assignment.rawValue != pf.a || f.rejectedPersonId != rej else { continue }
                    if let old = f.personId { affected.insert(old) }
                    if let pid { affected.insert(pid) }
                    try db.execute(sql: "UPDATE face SET personId = ?, assignment = ?, rejectedPersonId = ? WHERE id = ?", arguments: [pid, pf.a, rej, f.id])
                }
                if from != device { try db.execute(sql: "UPDATE media SET importedFrom = ? WHERE id = ?", arguments: [device, mid]) }
                continue
            }
            for f in existing { if let old = f.personId { affected.insert(old) } }
            // People whose picture is one of these faces keep it: the face at the same place in the new record.
            let covers = existing.isEmpty ? [] : try Row.fetchAll(db, sql: """
                SELECT id, coverFaceId FROM person WHERE coverFaceId IN (\(existing.map { String($0.id!) }.joined(separator: ",")))
                """)
            try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [mid])
            var ids: [Int64] = []
            for pf in payload.faces {
                let pid = try person(pf.p)
                var f = FaceRecord(id: nil, mediaId: mid, x: pf.x, y: pf.y, w: pf.w, h: pf.h, quality: pf.q, time: pf.t,
                                   embedding: pf.e.flatMap { Data(base64Encoded: $0) }, track: pf.tr, personId: pid,
                                   assignment: Assignment(rawValue: pf.a) ?? .auto, rejectedPersonId: try person(pf.r),
                                   eyesOpen: pf.ey, smile: pf.sm, sharpness: pf.sh, yaw: pf.yaw, pitch: pf.pitch, score: pf.sc)
                try f.insert(db)
                ids.append(f.id!)
                if let pid { affected.insert(pid) }
            }
            for c in covers {
                let old: Int64 = c["coverFaceId"]
                guard let i = existing.firstIndex(where: { $0.id == old }), i < ids.count else { continue }
                try db.execute(sql: "UPDATE person SET coverFaceId = ? WHERE id = ?", arguments: [ids[i], c["id"] as Int64])
            }
            try db.execute(sql: """
                UPDATE media SET status = 'done', error = NULL, width = ?, height = ?, duration = ?, takenAt = ?, featurePrint = COALESCE(?, featurePrint),
                    analysisVersion = ?, importedFrom = ? WHERE id = ?
                """, arguments: [payload.w, payload.h, payload.dur, payload.taken, payload.fp.flatMap { Data(base64Encoded: $0) }, payload.v, device, mid])
            // On the processing Mac, a copier's ungrouped faces are this Mac's to group (after the transaction).
            if processorId == deviceId, payload.faces.contains(where: { $0.p == nil }) { lock.withLock { takenToGroup.append(mid) } }
            // The crops, so the faces have pictures here too. Any that can't be copied now (the share rewriting
            // them, a hiccup) are fetched again on later passes (see fetchMissingCrops): a face without its picture
            // stayed that way, and the person's picture with it.
            for fid in ids { try? FileManager.default.removeItem(at: store.faceCropURL(fid)) }
            try? FileManager.default.removeItem(at: store.thumbnailURL(mid))
            try db.execute(sql: "INSERT OR REPLACE INTO cropRetry (mediaId, teamId, deviceId, contentKey, boxes) VALUES (?, ?, ?, ?, ?)",
                           arguments: [mid, team.id, device, payload.key, Self.signature(payload.faces).boxes])
            try fetchCrops(mid, from: device, team: team, key: payload.key, boxes: Self.signature(payload.faces).boxes, faceIds: ids, db: db)
        }
        return affected
    }

    /// Copies a file's crops and thumbnail from a teammate's folder for the faces that have none here. Done with
    /// the file when every one of them is there, or isn't in a folder that is (the teammate had none to give);
    /// tried again while the folder can't be seen (being written, the share away) or a copy fails.
    func fetchCrops(_ mid: Int64, from device: String, team: TeamRecord, key: String, boxes: String, faceIds: [Int64], db: Database) throws {
        let fm = FileManager.default
        let cropDir = Self.cropSource(Self.facesURL(team.url, device: device), key: key, boxes: boxes)
        // The old flat layout counts as there only when it holds something: the parent folder stays after a set
        // of crops moved out of it.
        let folderThere = cropDir.lastPathComponent == boxes
            ? fm.fileExists(atPath: cropDir.path)
            : !((try? fm.contentsOfDirectory(at: cropDir, includingPropertiesForKeys: nil))?.filter { !$0.hasDirectoryPath }.isEmpty ?? true)
        var complete = true
        func fetch(_ name: String, to dst: URL) -> Bool {
            guard !fm.fileExists(atPath: dst.path) else { return false }
            let src = cropDir.appendingPathComponent(name)
            guard folderThere, fm.fileExists(atPath: src.path) else {
                if !folderThere { complete = false }
                return false
            }
            if (try? fm.copyItem(at: src, to: dst)) == nil { complete = false; return false }
            return true
        }
        for (i, fid) in faceIds.enumerated() { _ = fetch("\(i).jpg", to: store.faceCropURL(fid)) }
        if fetch("thumb.jpg", to: store.thumbnailURL(mid)) {
            try db.execute(sql: "UPDATE media SET thumbAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, mid])
        }
        if complete { try db.execute(sql: "DELETE FROM cropRetry WHERE mediaId = ?", arguments: [mid]) }
    }

    /// Files taken from teammates whose faces have no picture here, queued for fetchMissingCrops: once per team each
    /// time the app starts. A Mac before 0.8.31 looked for a record's crops in `crops/<content key>/`, which the
    /// processing Mac had since moved into a folder per set of faces: it took the record, dropped the pictures of
    /// the faces it replaced, found none to copy, and nothing asked for them again, so people's pictures stayed
    /// blank (named or not) after updating too.
    func queueMissingCrops(_ team: TeamRecord) throws {
        let teamId = team.id!
        guard !lock.withLock({ cropsChecked.contains(teamId) }) else { return }
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, f.mediaId, f.x, f.y, f.w, f.h, f.time, m.importedFrom, m.contentKey
                FROM face f JOIN media m ON m.id = f.mediaId JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                WHERE p.teamId = ? AND m.importedFrom IS NOT NULL AND m.contentKey IS NOT NULL
                  AND m.id NOT IN (SELECT mediaId FROM cropRetry)
                ORDER BY f.mediaId, f.id
                """, arguments: [teamId])
        }
        var files: [Int64: (device: String, key: String, faces: [FacePayload], missing: Bool)] = [:]
        for r in rows {
            let mid: Int64 = r["mediaId"]
            var file = files[mid] ?? (r["importedFrom"] as String, r["contentKey"] as String, [], false)
            file.faces.append(FacePayload(x: r["x"], y: r["y"], w: r["w"], h: r["h"], t: r["time"], a: ""))
            if !file.missing, !FileManager.default.fileExists(atPath: store.faceCropURL(r["id"]).path) { file.missing = true }
            files[mid] = file
        }
        try store.db.write { db in
            for (mid, f) in files where f.missing {
                try db.execute(sql: "INSERT OR IGNORE INTO cropRetry (mediaId, teamId, deviceId, contentKey, boxes) VALUES (?, ?, ?, ?, ?)",
                               arguments: [mid, teamId, f.device, f.key, Self.signature(f.faces).boxes])
            }
        }
        lock.withLock { _ = cropsChecked.insert(teamId) }
    }

    /// Files taken from teammates whose crops or thumbnail couldn't all be copied: tried again, a batch per pass,
    /// going round the queue (files that can't be fetched yet don't keep the ones after them waiting).
    static let cropRetryBatch = 200
    func fetchMissingCrops(_ team: TeamRecord) throws -> Bool {
        let teamId = team.id!
        let after = lock.withLock { cropRetryCursor[teamId] ?? 0 }
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT mediaId, deviceId, contentKey, boxes FROM cropRetry WHERE teamId = ? AND mediaId > ? ORDER BY mediaId LIMIT ?",
                             arguments: [teamId, after, Self.cropRetryBatch])
        }
        lock.withLock { cropRetryCursor[teamId] = rows.count < Self.cropRetryBatch ? 0 : rows.last.map { $0["mediaId"] as Int64 } }
        guard !rows.isEmpty else { return false }
        var fetched = false
        try store.db.write { db in
            for r in rows {
                let mid: Int64 = r["mediaId"]
                let faceIds = try Int64.fetchAll(db, sql: "SELECT id FROM face WHERE mediaId = ? ORDER BY id", arguments: [mid])
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM media WHERE id = ?)", arguments: [mid]) == true else {
                    try db.execute(sql: "DELETE FROM cropRetry WHERE mediaId = ?", arguments: [mid]); continue
                }
                let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cropRetry WHERE mediaId = ?", arguments: [mid]) ?? 0
                try fetchCrops(mid, from: r["deviceId"], team: team, key: r["contentKey"], boxes: r["boxes"], faceIds: faceIds, db: db)
                let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cropRetry WHERE mediaId = ?", arguments: [mid]) ?? 0
                if after < before { fetched = true }
            }
        }
        return fetched
    }

    /// A teammate rejected or moved a face: the same face here (by content key and position) follows.
    func applyFaceOp(_ op: Op, team: TeamRecord, db: Database) throws -> Outcome {
        guard let key = op.key, let index = op.index, let assign = op.assign else { return .ignored }
        let faces = try Row.fetchAll(db, sql: """
            SELECT f.id, f.personId FROM face f JOIN media m ON m.id = f.mediaId JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
            WHERE m.contentKey = ? AND p.teamId = ? AND (SELECT COUNT(*) FROM face g WHERE g.mediaId = f.mediaId AND g.id < f.id) = ?
            """, arguments: [key, team.id, index])
        if faces.isEmpty {
            // Not processed here yet. The processing Mac keeps the edit for when it has read the file (a card's
            // file edited on the laptop right after the copy used to lose it, the Mac's own grouping winning);
            // so does a Mac that has the file waiting. A Mac without the file lets it go: the processing Mac's
            // record brings the result.
            let waiting = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM media m JOIN source s ON s.id = m.sourceId JOIN project p ON p.id = s.projectId
                               WHERE m.contentKey = ? AND p.teamId = ? AND m.status != 'done')
                """, arguments: [key, team.id]) ?? false
            return team.processorId == deviceId || waiting ? .deferred : .ignored
        }
        func person(_ uuid: String?) throws -> Int64? {
            guard let uuid else { return nil }
            if let id = try Self.resolve(uuid, db: db) { return id }
            var p = PersonRecord(name: nil, uuid: uuid)
            try p.insert(db)
            return p.id!
        }
        let pid = try person(op.uuid), rej = try person(op.rejected)
        var affected: Set<Int64> = []
        for f in faces {
            if let old: Int64 = f["personId"] { affected.insert(old) }
            if let pid { affected.insert(pid) }
            try db.execute(sql: "UPDATE face SET personId = ?, assignment = ?, rejectedPersonId = ? WHERE id = ?", arguments: [pid, assign, rej, f["id"] as Int64])
        }
        return .applied(people: affected, remote: [])
    }
}
