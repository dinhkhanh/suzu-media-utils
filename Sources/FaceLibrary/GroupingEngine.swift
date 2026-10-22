import FaceCore
import Foundation
import GRDB

/// Thresholds picked in Phase 0 (see PLAN.md).
public struct GroupingSettings: Sendable {
    /// Average-linkage threshold for forming new groups.
    public var clusterThreshold: Float = 0.45
    /// Mean similarity to a person's faces needed to name a new face automatically.
    public var assignThreshold: Float = 0.50
    /// Stricter bar for low-quality faces, which are never clustered but may join an existing person.
    public var lowQualityAssignThreshold: Float = 0.55
    public var minQuality = 0.3
    /// Minimum face width in detection pixels (1500 px long side).
    public var minFacePixels = 40.0
    public var minGroupFaces = 3
    /// Upper bound on faces clustered in one pass (memory is n^2).
    public var maxReclusterUnits = 6000
    public init() {}
}

/// Assigns faces to people. Known people are matched as soon as a file is processed; faces that match nobody
/// wait in a pending pool that is clustered into new people once ingest goes quiet.
///
/// A "unit" is what gets matched: one photo face, or all faces of one person within one video (a track), so a long
/// clip counts once instead of once per frame.
public final class GroupingEngine: @unchecked Sendable {
    public let store: LibraryStore
    public var settings = GroupingSettings()
    let queue = DispatchQueue(label: "grouping")
    /// Sum of member unit vectors and unit count per person; sum . u / count is u's mean similarity to them.
    var people: [Int64: (sum: [Float], count: Int)] = [:]
    var reclusterWork: DispatchWorkItem?

    struct Unit {
        var faceIds: [Int64]
        var vector: [Float]
        var rejected: Set<Int64>
    }

    struct FaceRow {
        var face: FaceRecord
        var mediaWidth: Int
    }

    public init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - Public API (all work runs on the engine's serial queue)

    public func start() {
        queue.async { [self] in
            try? rebuildAll()
            try? recluster()
        }
    }

    /// Call after a media's faces were written.
    public func mediaProcessed(_ mediaId: Int64) {
        queue.async { [self] in
            try? assignPending(mediaIds: [mediaId])
            scheduleRecluster()
        }
    }

    /// Call after faces were removed from or added to people outside the engine (user edits, deleted files).
    public func peopleChanged(_ ids: Set<Int64>) {
        queue.async { [self] in try? rebuild(personIds: ids) }
    }

    /// A reference photo was added for this person: re-match waiting faces and name matching groups.
    public func referenceChanged(_ pid: Int64) {
        queue.async { [self] in
            try? rebuild(personIds: [pid])
            try? assignAllPending()
            try? autoName()
        }
    }

    public func reclusterNow() {
        queue.async { [self] in try? recluster() }
    }

    /// Blocks until queued engine work is done (tests, shutdown).
    public func waitUntilIdle() { queue.sync {} }

    // MARK: - Units

    func loadRows(_ request: String, _ args: StatementArguments = []) throws -> [FaceRow] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT face.*, COALESCE(media.width, 0) AS mediaWidth FROM face
                JOIN media ON media.id = face.mediaId WHERE \(request)
                """, arguments: args).map { row in
                FaceRow(face: try FaceRecord(row: row), mediaWidth: row["mediaWidth"])
            }
        }
    }

    func qualifies(_ r: FaceRow) -> Bool {
        r.face.embedding != nil && (r.face.quality ?? 0) >= settings.minQuality
            && r.face.w * Double(r.mediaWidth) >= settings.minFacePixels
    }

    /// Groups qualifying faces into units; video faces sharing a media and track become one unit.
    func units(_ rows: [FaceRow]) -> [Unit] {
        var order: [String] = []
        var byKey: [String: [FaceRow]] = [:]
        for r in rows where qualifies(r) {
            let key = r.face.track.map { "\(r.face.mediaId)/t\($0)/p\(r.face.personId ?? 0)" } ?? "f\(r.face.id!)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(r)
        }
        return order.map { key in
            let rs = byKey[key]!
            var sum = [Float](repeating: 0, count: 512)
            for r in rs { for (i, v) in r.face.vector!.enumerated() { sum[i] += v } }
            return Unit(faceIds: rs.map { $0.face.id! }, vector: Vector.normalized(sum),
                        rejected: Set(rs.compactMap(\.face.rejectedPersonId)))
        }
    }

    func bestPerson(for v: [Float], excluding: Set<Int64>) -> (Int64, Float)? {
        var best: (Int64, Float)?
        for (pid, p) in people where p.count > 0 && !excluding.contains(pid) {
            let s = Vector.dot(v, p.sum) / Float(p.count)
            if s > (best?.1 ?? -1) { best = (pid, s) }
        }
        return best
    }

    func add(_ v: [Float], to pid: Int64) {
        var p = people[pid] ?? ([Float](repeating: 0, count: v.count), 0)
        for i in 0..<v.count { p.sum[i] += v[i] }
        p.count += 1
        people[pid] = p
    }

    // MARK: - Rebuilding person vectors

    func rebuildAll() throws {
        people = [:]
        let rows = try loadRows("face.personId IS NOT NULL")
        for (pid, rs) in Dictionary(grouping: rows, by: { $0.face.personId! }) {
            for u in units(rs) { add(u.vector, to: pid) }
        }
    }

    func rebuild(personIds: Set<Int64>) throws {
        for pid in personIds {
            people[pid] = nil
            for u in units(try loadRows("face.personId = ?", [pid])) { add(u.vector, to: pid) }
        }
    }

    // MARK: - Assignment

    func assignPending(mediaIds: [Int64]) throws {
        for mid in mediaIds {
            let rows = try loadRows("face.mediaId = ? AND face.assignment = 'none'", [mid])
            var updates: [(Int64, [Int64])] = []
            for u in units(rows) {
                if let (pid, s) = bestPerson(for: u.vector, excluding: u.rejected), s >= settings.assignThreshold {
                    add(u.vector, to: pid)
                    updates.append((pid, u.faceIds))
                }
            }
            updates += lowQualityMatches(rows.filter { !qualifies($0) && $0.face.embedding != nil })
            try write(updates)
        }
    }

    func assignAllPending() throws {
        let ids = try store.db.read { db in
            try Int64.fetchAll(db, sql: "SELECT DISTINCT mediaId FROM face WHERE assignment = 'none' AND embedding IS NOT NULL")
        }
        try assignPending(mediaIds: ids)
    }

    /// Merges each unnamed group into the named person it matches (mean pairwise similarity of their faces at or
    /// above the assign threshold). This is how reference photos and earlier naming carry over to new groups.
    func autoName() throws {
        let named = Set(try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM person WHERE name IS NOT NULL") })
        var merges: [(from: Int64, into: Int64)] = []
        for (pid, p) in people where !named.contains(pid) && p.count > 0 {
            var best: (Int64, Float)?
            for nid in named {
                guard let n = people[nid], n.count > 0 else { continue }
                let s = Vector.dot(p.sum, n.sum) / Float(p.count * n.count)
                if s > (best?.1 ?? -1) { best = (nid, s) }
            }
            if let (nid, s) = best, s >= settings.assignThreshold { merges.append((pid, nid)) }
        }
        guard !merges.isEmpty else { return }
        try store.db.write { db in
            for m in merges {
                try db.execute(sql: "UPDATE face SET personId = ? WHERE personId = ?", arguments: [m.into, m.from])
                try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [m.from])
            }
        }
        for m in merges {
            if let p = people.removeValue(forKey: m.from), var n = people[m.into] {
                for i in 0..<n.sum.count { n.sum[i] += p.sum[i] }
                n.count += p.count
                people[m.into] = n
            }
        }
    }

    func lowQualityMatches(_ rows: [FaceRow]) -> [(Int64, [Int64])] {
        rows.compactMap { r in
            let excl: Set<Int64> = r.face.rejectedPersonId.map { [$0] } ?? []
            guard let (pid, s) = bestPerson(for: r.face.vector!, excluding: excl), s >= settings.lowQualityAssignThreshold
            else { return nil }
            return (pid, [r.face.id!])
        }
    }

    func write(_ updates: [(Int64, [Int64])]) throws {
        guard !updates.isEmpty else { return }
        try store.db.write { db in
            for (pid, ids) in updates {
                try db.execute(sql: "UPDATE face SET personId = ?, assignment = 'auto' WHERE id IN (\(ids.map(String.init).joined(separator: ",")))",
                               arguments: [pid])
            }
        }
    }

    // MARK: - Clustering the pending pool

    func scheduleRecluster() {
        reclusterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in try? self?.recluster() }
        reclusterWork = work
        let pending = (try? store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face WHERE assignment = 'none' AND embedding IS NOT NULL")
        }) ?? 0
        // Quiet period lets a batch finish arriving; a large backlog is clustered right away in chunks.
        queue.asyncAfter(deadline: .now() + (pending >= settings.maxReclusterUnits ? 0 : 30), execute: work)
    }

    /// Clusters waiting faces into new people, one project at a time (most recently active first): new groups form
    /// within an event, while names carry across projects through assignment and autoName. Per project also keeps
    /// the n^2 pool small, and a backlog of old leftovers can't crowd out a new event's faces.
    func recluster() throws {
        let projects = try store.db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT COALESCE(s.projectId, 0) FROM face JOIN media ON media.id = face.mediaId LEFT JOIN source s ON s.id = media.sourceId
                WHERE face.assignment = 'none' AND face.embedding IS NOT NULL
                GROUP BY 1 ORDER BY MAX(face.id) DESC
                """)
        }
        var more = false
        for p in projects { more = try recluster(project: p) || more }
        // Leftovers in one project may match a group just formed in another (the same artist at two events).
        if !projects.isEmpty { try assignAllPending() }
        try autoName()
        if more { scheduleRecluster() }
    }

    /// Returns true when the pool was capped and produced groups, so another pass may find more.
    func recluster(project: Int64) throws -> Bool {
        let rows = try loadRows("""
            face.assignment = 'none' AND face.embedding IS NOT NULL
              AND COALESCE((SELECT projectId FROM source WHERE source.id = media.sourceId), 0) = ?
            ORDER BY face.id DESC
            """, [project])
        // Newest first, so a fresh event is clustered even when older leftovers fill the pool.
        let pool = Array(units(rows).prefix(settings.maxReclusterUnits))
        var updates: [(Int64, [Int64])] = []
        if pool.count >= 2 {
            let sim = Clustering.similarityMatrix(pool.map(\.vector))
            let labels = Clustering.averageLinkage(similarity: sim, count: pool.count, threshold: settings.clusterThreshold)
            for (_, members) in Dictionary(grouping: pool.indices, by: { labels[$0] }) {
                let faceIds = members.flatMap { pool[$0].faceIds }
                guard faceIds.count >= settings.minGroupFaces else { continue }
                var person = PersonRecord()
                try store.db.write { db in try person.insert(db) }
                for m in members { add(pool[m].vector, to: person.id!) }
                updates.append((person.id!, faceIds))
            }
            try write(updates)
        }
        // Low-quality faces can join people created above.
        try write(lowQualityMatches(rows.filter { !qualifies($0) }))
        return pool.count == settings.maxReclusterUnits && !updates.isEmpty
    }
}
