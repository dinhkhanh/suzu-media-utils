import Accelerate
import FaceCore
import Foundation
import GRDB

/// Thresholds picked in Phase 0 and refined on real event libraries (see PLAN.md).
public struct GroupingSettings: Sendable {
    /// Average-linkage threshold for forming new groups, and for merging two groups (their mean pairwise
    /// similarity): continuing the same clustering across groups that formed at different times.
    public var clusterThreshold: Float = 0.45
    /// Mean similarity to a person's faces needed to name a new face automatically.
    public var assignThreshold: Float = 0.50
    /// Mean similarity to a person's two nearest exemplar faces needed to name a new face. This is what matches a
    /// profile, a new hairstyle or a hand over the mouth: the face only has to resemble the person's other shots
    /// taken that way, not the average of every shot of them.
    public var nearestThreshold: Float = 0.50
    /// Stricter bars for low-quality faces, which are never clustered but may join an existing person.
    public var lowQualityAssignThreshold: Float = 0.55
    public var lowQualityNearestThreshold: Float = 0.56
    /// Faces at least this good (Vision capture quality) are units: matched, clustered and counted. Profiles and
    /// faces half turned away sit at 0.2–0.3; blurred background faces and posters mostly below 0.2.
    public var minQuality = 0.2
    /// Only faces this good stand as exemplars (so a muddy profile can't become the thing other faces match).
    public var exemplarMinQuality = 0.3
    /// A new group made only of faces below `exemplarMinQuality` needs this mean similarity, not just
    /// `clusterThreshold`: such faces are alike in their blur as much as in their features.
    public var lowQualityGroupThreshold: Float = 0.55
    /// Minimum face width in detection pixels (1500 px long side).
    public var minFacePixels = 40.0
    public var minGroupFaces = 3
    /// Upper bound on faces clustered in one pass (memory is n^2).
    public var maxReclusterUnits = 6000
    /// Exemplars kept per person: a face joins them when it is at most this similar to every exemplar so far, so
    /// they cover the person's looks (angles, make-up, glasses, hats) rather than repeat the most common one.
    public var maxExemplars = 32
    public var exemplarNovelty: Float = 0.80
    public init() {}
}

/// Assigns faces to people. Known people are matched as soon as a file is processed; faces that match nobody
/// wait in a pending pool that is clustered into new people once ingest goes quiet. Groups that turn out to be the
/// same person (formed from different batches, or from different looks of them) are merged afterwards.
///
/// A "unit" is what gets matched: one photo face, or all faces of one person within one video (a track), so a long
/// clip counts once instead of once per frame.
///
/// Each person is known two ways: the mean of their units (the centroid, exact average linkage against the whole
/// group) and up to `maxExemplars` diverse unit vectors. A face joins when either the centroid or its two nearest
/// exemplars are similar enough. The centroid is strict with people photographed in many ways; the exemplars catch
/// the shots that only resemble some of their earlier ones.
public final class GroupingEngine: @unchecked Sendable {
    public let store: LibraryStore
    public var settings = GroupingSettings()
    let queue = DispatchQueue(label: "grouping")
    var people: [Int64: Person] = [:]
    var means = Rows()
    var exemplars = Rows()
    /// People that gained units or were created since the last consolidation: the only ones worth comparing.
    var touched: Set<Int64> = []
    /// Projects whose faces another Mac groups (shared processing): their waiting faces are left alone here, and
    /// with no project of its own to group, this Mac merges nobody either.
    public var passiveProjects: Set<Int64> = []
    public var processesAnything = true
    var reclusterWork: DispatchWorkItem?

    struct Person {
        /// Sum of member unit vectors; sum . u / count is u's mean similarity to them.
        var sum: [Float]
        var count: Int
        /// Row of sum / count in `means`.
        var meanRow: Int
        /// Rows in `exemplars` of this person's diverse unit vectors, see `GroupingSettings.maxExemplars`.
        var exemplarRows: [Int] = []
    }

    /// Every person's mean, and every exemplar, as rows of 512 floats so one BLAS call scores a face against all
    /// of them. Rows of people rebuilt or merged are dead until the next compaction.
    struct Rows {
        var data: [Float] = []
        var owner: [Int64] = []
        var dead = 0
        var count: Int { owner.count }

        mutating func append(_ v: [Float], _ pid: Int64) -> Int {
            data.append(contentsOf: v)
            owner.append(pid)
            return owner.count - 1
        }
        mutating func replace(_ row: Int, with v: [Float]) { data.replaceSubrange(row * 512..<(row + 1) * 512, with: v) }
        mutating func kill(_ row: Int) { if owner[row] >= 0 { owner[row] = -1; dead += 1 } }
        func vector(_ row: Int) -> ArraySlice<Float> { data[row * 512..<(row + 1) * 512] }

        /// Dot product of `v` with every row (dead rows included; check `owner`).
        func similarities(_ v: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: count)
            guard count > 0 else { return out }
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(count), 512, 1, data, 512, v, 1, 0, &out, 1)
            return out
        }

        /// Drops dead rows; returns the new row of each old one (-1 when dropped).
        mutating func compact() -> [Int] {
            var map = [Int](repeating: -1, count: count)
            var fresh = Rows()
            fresh.data.reserveCapacity((count - dead) * 512)
            for row in 0..<count where owner[row] >= 0 { map[row] = fresh.append(Array(vector(row)), owner[row]) }
            self = fresh
            return map
        }
    }

    struct Unit {
        var faceIds: [Int64]
        var vector: [Float]
        var rejected: Set<Int64>
        var quality: Double
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
            try? consolidate()
        }
    }

    public func reclusterNow() {
        queue.async { [self] in try? recluster() }
    }

    /// Teammates' summaries of these people arrived (team sync): re-match waiting faces and name matching groups.
    public func remoteChanged(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in
            try? rebuild(personIds: ids)
            try? assignAllPending()
            try? consolidate()
        }
    }

    /// The mean of a person's own faces on this Mac (teammates' summaries left out) and how many units it covers;
    /// nil when they have no usable face here. What this Mac publishes to its teams.
    public func localSummary(_ personId: Int64) -> (centroid: [Float], count: Int)? {
        queue.sync {
            guard let rows = try? loadRows("face.personId = ? AND media.importedFrom IS NULL", [personId]) else { return nil }
            let us = units(rows)
            guard !us.isEmpty else { return nil }
            var sum = [Float](repeating: 0, count: 512)
            for u in us { for i in 0..<min(512, u.vector.count) { sum[i] += u.vector[i] } }
            return (sum.map { $0 / Float(us.count) }, us.count)
        }
    }

    /// Up to `limit` of a person's exemplars from this Mac's own faces, for teammates (see TeamSync summaries).
    public func localExemplars(_ personId: Int64, limit: Int = 8) -> [[Float]] {
        queue.sync {
            guard let rows = try? loadRows("face.personId = ? AND media.importedFrom IS NULL", [personId]) else { return [] }
            var kept: [[Float]] = []
            for u in units(rows).sorted(by: { $0.quality > $1.quality }) where u.quality >= settings.exemplarMinQuality {
                if kept.count >= limit { break }
                if kept.allSatisfy({ Vector.dot(u.vector, $0) < settings.exemplarNovelty }) { kept.append(u.vector) }
            }
            return kept
        }
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
                        rejected: Set(rs.compactMap(\.face.rejectedPersonId)),
                        quality: rs.map { $0.face.quality ?? 0 }.max() ?? 0)
        }
    }

    // MARK: - Matching

    /// How well `v` fits a person: its mean similarity to all their units, and to their two nearest exemplars.
    func scores(_ v: [Float], _ p: Person) -> (centroid: Float, nearest: Float) {
        let c = Vector.dot(v, p.sum) / Float(p.count)
        guard !p.exemplarRows.isEmpty else { return (c, c) }
        var top1: Float = -1, top2: Float = -1
        for row in p.exemplarRows {
            let s = Vector.dot(v, exemplars.vector(row))
            if s > top1 { top2 = top1; top1 = s } else if s > top2 { top2 = s }
        }
        return (c, p.exemplarRows.count == 1 ? top1 : (top1 + top2) / 2)
    }

    /// The person `v` fits best, with how far it clears the bars (negative = nobody is close enough).
    func bestPerson(for v: [Float], excluding: Set<Int64>, centroidBar: Float, nearestBar: Float) -> (Int64, Float)? {
        let c = means.similarities(v), e = exemplars.similarities(v)
        var top: [Int64: (Float, Float)] = [:]
        for (row, pid) in exemplars.owner.enumerated() where pid >= 0 {
            let s = e[row]
            var t = top[pid] ?? (-1, -1)
            if s > t.0 { t = (s, t.0) } else if s > t.1 { t.1 = s }
            top[pid] = t
        }
        var best: (Int64, Float)?
        for (pid, p) in people where p.count > 0 && !excluding.contains(pid) {
            let centroid = c[p.meanRow]
            let nearest: Float
            if let t = top[pid] { nearest = p.exemplarRows.count == 1 ? t.0 : (t.0 + t.1) / 2 } else { nearest = centroid }
            let margin = max(centroid - centroidBar, nearest - nearestBar)
            if margin > (best?.1 ?? -.infinity) { best = (pid, margin) }
        }
        return best
    }

    func add(_ v: [Float], to pid: Int64, quality: Double = 1) {
        var p = people[pid] ?? Person(sum: [Float](repeating: 0, count: 512), count: 0, meanRow: means.append([Float](repeating: 0, count: 512), pid))
        for i in 0..<min(512, v.count) { p.sum[i] += v[i] }
        p.count += 1
        means.replace(p.meanRow, with: p.sum.map { $0 / Float(p.count) })
        if quality >= settings.exemplarMinQuality { addExemplar(v, to: &p, pid) }
        people[pid] = p
        touched.insert(pid)
    }

    func addExemplar(_ v: [Float], to p: inout Person, _ pid: Int64) {
        guard p.exemplarRows.count < settings.maxExemplars else { return }
        for row in p.exemplarRows where Vector.dot(v, exemplars.vector(row)) >= settings.exemplarNovelty { return }
        p.exemplarRows.append(exemplars.append(v, pid))
    }

    /// Forgets a person's vectors (their rows stay dead until a compaction).
    func remove(_ pid: Int64) {
        guard let p = people.removeValue(forKey: pid) else { return }
        means.kill(p.meanRow)
        for row in p.exemplarRows { exemplars.kill(row) }
        if exemplars.dead > 1024 && exemplars.dead * 2 > exemplars.count || means.dead > 1024 && means.dead * 2 > means.count {
            let em = exemplars.compact(), mm = means.compact()
            for (id, var q) in people {
                q.meanRow = mm[q.meanRow]
                q.exemplarRows = q.exemplarRows.map { em[$0] }
                people[id] = q
            }
        }
    }

    // MARK: - Rebuilding person vectors

    func rebuildAll() throws {
        people = [:]
        means = Rows()
        exemplars = Rows()
        touched = []
        let rows = try loadRows("face.personId IS NOT NULL")
        for (pid, rs) in Dictionary(grouping: rows, by: { $0.face.personId! }) {
            // Best faces first, so they are the exemplars when a person has more than fit.
            for u in units(rs).sorted(by: { $0.quality > $1.quality }) { add(u.vector, to: pid, quality: u.quality) }
        }
        try addRemote("1")
        try addMemory("1")
    }

    func rebuild(personIds: Set<Int64>) throws {
        for pid in personIds {
            remove(pid)
            for u in units(try loadRows("face.personId = ?", [pid])).sorted(by: { $0.quality > $1.quality }) { add(u.vector, to: pid, quality: u.quality) }
        }
        let list = personIds.map(String.init).joined(separator: ",")
        try addRemote("personId IN (\(list))")
        try addMemory("personId IN (\(list))")
    }

    /// Faces that left the library (PersonMemory) still count, the same way as a teammate's: a named person whose
    /// folder was removed is recognised when their photos come back, or at the next event.
    func addMemory(_ condition: String) throws {
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT personId, centroid, count FROM personMemory WHERE \(condition)")
        }
        for r in rows { addSummary(r["personId"], centroid: Vector.decode(r["centroid"]), count: r["count"]) }
    }

    /// Faces a teammate's Mac saw count as if they were here: the mean of their embeddings, weighted by how many
    /// (capped, so one Mac's thousands of faces never drown out what this Mac sees).
    func addRemote(_ condition: String) throws {
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT personId, centroid, count, exemplars FROM personRemote WHERE \(condition)")
        }
        for r in rows {
            addSummary(r["personId"], centroid: Vector.decode(r["centroid"]), count: Int(r["count"] as Int64),
                       exemplars: (r["exemplars"] as Data?).map(Vector.decodeHalfRows) ?? [])
        }
    }

    func addSummary(_ pid: Int64, centroid: [Float], count: Int, exemplars: [[Float]] = []) {
        let n = min(count, Self.remoteWeightCap)
        guard centroid.count == 512, n > 0 else { return }
        var p = people[pid] ?? Person(sum: [Float](repeating: 0, count: 512), count: 0, meanRow: means.append([Float](repeating: 0, count: 512), pid))
        for i in 0..<512 { p.sum[i] += centroid[i] * Float(n) }
        p.count += n
        means.replace(p.meanRow, with: p.sum.map { $0 / Float(p.count) })
        // The mean of their faces there stands in as an exemplar as well, as it is: a face scores against it what
        // it would score on average against those faces. (Normalizing it would inflate every score by the same
        // factor and made a diverse group on another Mac look like everyone's near match.)
        addExemplar(centroid, to: &p, pid)
        // Their exemplar faces too, when they sent them: a profile seen there matches a profile here.
        for e in exemplars where e.count == 512 { addExemplar(e, to: &p, pid) }
        people[pid] = p
        touched.insert(pid)
    }
    static let remoteWeightCap = 30

    // MARK: - Assignment

    func assignPending(mediaIds: [Int64]) throws {
        for mid in mediaIds {
            let rows = try loadRows("face.mediaId = ? AND face.assignment = 'none'", [mid])
            var updates: [(Int64, [Int64])] = []
            for u in units(rows) {
                if let (pid, margin) = bestPerson(for: u.vector, excluding: u.rejected, centroidBar: settings.assignThreshold,
                                                  nearestBar: settings.nearestThreshold), margin >= 0 {
                    add(u.vector, to: pid, quality: u.quality)
                    updates.append((pid, u.faceIds))
                }
            }
            updates += lowQualityMatches(rows.filter { !qualifies($0) && $0.face.embedding != nil })
            try write(updates)
        }
    }

    func assignAllPending() throws {
        guard processesAnything else { return }
        let passive = passiveProjects.map(String.init).joined(separator: ",")
        let ids = try store.db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT face.mediaId FROM face JOIN media ON media.id = face.mediaId LEFT JOIN source s ON s.id = media.sourceId
                WHERE face.assignment = 'none' AND face.embedding IS NOT NULL AND COALESCE(s.projectId, 0) NOT IN (\(passive.isEmpty ? "-1" : passive))
                """)
        }
        try assignPending(mediaIds: ids)
    }

    /// Kept for callers of the old name: merging groups is now `consolidate`.
    func autoName() throws { try consolidate() }

    func lowQualityMatches(_ rows: [FaceRow]) -> [(Int64, [Int64])] {
        rows.compactMap { r in
            let excl: Set<Int64> = r.face.rejectedPersonId.map { [$0] } ?? []
            guard let (pid, margin) = bestPerson(for: r.face.vector!, excluding: excl, centroidBar: settings.lowQualityAssignThreshold,
                                                 nearestBar: settings.lowQualityNearestThreshold), margin >= 0
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

    // MARK: - Merging groups that are one person

    /// Merges groups that are the same person: an unnamed group into the named person it matches (how reference
    /// photos and earlier naming carry over), and two unnamed groups into one. Two groups match when the mean
    /// similarity between their units reaches the clustering threshold (the clustering they would have formed
    /// together), or when most of the smaller group's exemplars have a near match among the other's exemplars
    /// (the same person in a look the other group is only partly made of).
    ///
    /// Never merged: two people with different names (the user's call), and people the user has told apart
    /// ("Not this person", or faces moved from one to the other).
    func consolidate() throws {
        guard processesAnything else { touched = []; return }
        let candidates = touched.filter { people[$0]?.count ?? 0 > 0 }
        touched = []
        guard !candidates.isEmpty, people.count >= 2 else { return }
        let (names, kept) = try store.db.read { db in
            (Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, name FROM person").map { ($0["id"] as Int64, $0["name"] as String?) }),
             Set(try Row.fetchAll(db, sql: "SELECT DISTINCT personId, rejectedPersonId FROM face WHERE personId IS NOT NULL AND rejectedPersonId IS NOT NULL")
                .map { Pair($0["personId"] as Int64, $0["rejectedPersonId"] as Int64) }))
        }
        func named(_ id: Int64) -> Bool { (names[id] ?? nil) != nil }
        let ids = people.keys.filter { people[$0]!.count > 0 && names[$0] != nil }.sorted()
        guard ids.count >= 2 else { return }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        // Mean vectors: their dot product is the mean pairwise similarity of the two groups (average linkage).
        let meanRows = ids.flatMap { pid in people[pid]!.sum.map { $0 / Float(people[pid]!.count) } }
        let cands = candidates.filter { index[$0] != nil }.sorted()
        guard !cands.isEmpty else { return }
        // Pairs worth a look, best first, each decided against the people as they stand after earlier merges.
        // Candidates go through in chunks: at launch every person is one, and a whole-library matrix would be
        // people² floats.
        var pairs: [(a: Int64, b: Int64, link: Float)] = []
        var link = [Float](repeating: 0, count: Self.consolidateChunk * ids.count)
        for start in stride(from: 0, to: cands.count, by: Self.consolidateChunk) {
            let chunk = Array(cands[start..<min(start + Self.consolidateChunk, cands.count)])
            let q = chunk.flatMap { pid in people[pid]!.sum.map { $0 / Float(people[pid]!.count) } }
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(chunk.count), Int32(ids.count), 512,
                        1, q, 512, meanRows, 512, 0, &link, Int32(ids.count))
            for (ci, a) in chunk.enumerated() {
                for (bi, b) in ids.enumerated() where b != a {
                    let l = link[ci * ids.count + bi]
                    if l >= Self.linkPrefilter { pairs.append((a, b, l)) }
                }
            }
        }
        pairs.sort { $0.link > $1.link }
        var alias: [Int64: Int64] = [:]
        func resolve(_ id: Int64) -> Int64 { var id = id; while let n = alias[id] { id = n }; return id }
        var merges: [(from: Int64, into: Int64)] = []
        for pair in pairs {
            let a = resolve(pair.a), b = resolve(pair.b)
            guard a != b, let pa = people[a], let pb = people[b] else { continue }
            if named(a) && named(b) { continue }  // two named people: the user's decision
            if kept.contains(Pair(a, b)) || kept.contains(Pair(b, a)) { continue }
            guard samePerson(pa, pb) else { continue }
            // The named one survives; else the larger; else the older (lower id, the one the user has seen longer).
            let (from, into): (Int64, Int64)
            if named(a) { (from, into) = (b, a) }
            else if named(b) { (from, into) = (a, b) }
            else if pa.count != pb.count { (from, into) = pa.count < pb.count ? (a, b) : (b, a) }
            else { (from, into) = a < b ? (b, a) : (a, b) }
            merges.append((from, into))
            alias[from] = into
            let other = people[from]!
            let keep = other.exemplarRows.map { Array(exemplars.vector($0)) }
            remove(from)
            var merged = people[into]!
            for i in 0..<merged.sum.count { merged.sum[i] += other.sum[i] }
            merged.count += other.count
            means.replace(merged.meanRow, with: merged.sum.map { $0 / Float(merged.count) })
            for e in keep { addExemplar(e, to: &merged, into) }
            people[into] = merged
            touched.insert(into)
        }
        guard !merges.isEmpty else { return }
        try store.db.write { db in
            for m in merges { try PersonNames.merge([m.from], into: m.into, db: db) }
        }
        // A merged person may now match further groups; those are checked on the next pass.
        if !touched.isEmpty { try consolidate() }
    }

    /// Mean similarity below this can't be the same person by either rule, so the exemplars are not compared.
    static let linkPrefilter: Float = 0.25
    static let consolidateChunk = 256

    func samePerson(_ a: Person, _ b: Person) -> Bool {
        let link = Vector.dot(a.sum, b.sum) / Float(a.count * b.count)
        if link >= settings.clusterThreshold { return true }
        // The smaller group's exemplars against the larger's: at least two, and most of them, must have a
        // near match (the bar a single face needs to join).
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        guard small.exemplarRows.count >= 2, !large.exemplarRows.isEmpty else { return false }
        var matched = 0
        for row in small.exemplarRows where scores(Array(exemplars.vector(row)), large).nearest >= settings.nearestThreshold { matched += 1 }
        return matched >= 2 && matched * 2 >= small.exemplarRows.count
    }

    struct Pair: Hashable {
        let a: Int64, b: Int64
        init(_ a: Int64, _ b: Int64) { self.a = a; self.b = b }
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
    /// within an event, while names carry across projects through assignment and consolidation. Per project also
    /// keeps the n^2 pool small, and a backlog of old leftovers can't crowd out a new event's faces.
    func recluster() throws {
        let projects = try store.db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT COALESCE(s.projectId, 0) FROM face JOIN media ON media.id = face.mediaId LEFT JOIN source s ON s.id = media.sourceId
                WHERE face.assignment = 'none' AND face.embedding IS NOT NULL
                GROUP BY 1 ORDER BY MAX(face.id) DESC
                """)
        }.filter { !passiveProjects.contains($0) }
        guard processesAnything else { return }
        var more = false
        for p in projects { more = try recluster(project: p) || more }
        // New groups may be people already known (formed earlier, or at another event); leftovers may match a
        // group just formed, or a person that just grew another look.
        try consolidate()
        if !projects.isEmpty { try assignAllPending() }
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
                if members.allSatisfy({ pool[$0].quality < settings.exemplarMinQuality }) {
                    // Nothing sharp in it: only when its faces agree well beyond the usual bar.
                    var sum: Float = 0, n = 0
                    for i in members { for j in members where j > i { sum += sim[i * pool.count + j]; n += 1 } }
                    guard n > 0, sum / Float(n) >= settings.lowQualityGroupThreshold else { continue }
                }
                var person = PersonRecord()
                try store.db.write { db in try person.insert(db) }
                for m in members.sorted(by: { pool[$0].quality > pool[$1].quality }) { add(pool[m].vector, to: person.id!, quality: pool[m].quality) }
                updates.append((person.id!, faceIds))
            }
            try write(updates)
        }
        // Low-quality faces can join people created above.
        try write(lowQualityMatches(rows.filter { !qualifies($0) }))
        return pool.count == settings.maxReclusterUnits && !updates.isEmpty
    }
}
