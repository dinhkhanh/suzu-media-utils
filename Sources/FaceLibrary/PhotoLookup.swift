import Accelerate
import CoreGraphics
import FaceCore
import Foundation
import GRDB

/// Who is in a photo the user brings (dropped, pasted, picked from the Finder): its faces, found and embedded the
/// way the library's own are, each with the people it looks most like. Nothing is added to the library.
public struct PhotoLookup: @unchecked Sendable {
    /// Size of the decode the boxes refer to.
    public var width: Int
    public var height: Int
    /// Biggest face first: in a photo brought to find someone, that is usually them.
    public var faces: [Face]

    public struct Face: Identifiable, @unchecked Sendable {
        public var id: Int
        /// Normalized, top-left origin, like `FaceRecord`.
        public var box: CGRect
        public var preview: CGImage?
        /// Vision capture quality; a blurred or turned-away face matches less reliably.
        public var quality: Double?
        /// Its embedding (normalized), to find the files it is in (`LibraryStore.files(like:)`); nil when unreadable.
        public var vector: [Float]?
        /// Best first; empty when the face couldn't be read (no landmarks).
        public var matches: [Match]
    }

    public struct Match: Identifiable, Hashable, Sendable {
        public var id: Int64 { personId }
        public var personId: Int64
        public var name: String?
        /// The person's picture (picked, else their best face); nil for someone known only from a teammate or an
        /// earlier event.
        public var coverFaceId: Int64?
        public var faces: Int
        /// The better of the face's mean similarity to the person's faces and to their two nearest exemplars.
        public var similarity: Float
        /// The face's best match, close enough that the library would have put the face with them.
        public var likely: Bool
    }
}

extension GroupingEngine {
    /// The people `v` (a normalized embedding) looks most like, best first, scored as `bestPerson` scores them.
    /// Only the first can be `likely`: like the library, a face goes with its best match, however many clear the bar.
    /// Waits for the engine's job under way only, not for the ones queued behind it (see `stateLock`).
    public func nearestPeople(to v: [Float], limit: Int) -> [(personId: Int64, similarity: Float, likely: Bool)] {
        stateLock.withLock {
            let c = means.similarities(v), e = exemplars.similarities(v)
            var top: [Int64: (Float, Float)] = [:]
            for (row, pid) in exemplars.owner.enumerated() where pid >= 0 {
                let s = e[row]
                var t = top[pid] ?? (-1, -1)
                if s > t.0 { t = (s, t.0) } else if s > t.1 { t.1 = s }
                top[pid] = t
            }
            var out: [(personId: Int64, similarity: Float, likely: Bool)] = []
            for (pid, p) in people where p.count > 0 {
                let centroid = c[p.meanRow]
                let nearest: Float
                if let t = top[pid] { nearest = p.exemplarRows.count == 1 ? t.0 : (t.0 + t.1) / 2 } else { nearest = centroid }
                let likely = centroid >= settings.assignThreshold || nearest >= settings.nearestThreshold
                out.append((pid, max(centroid, nearest), likely))
            }
            var ranked = Array(out.sorted { $0.similarity > $1.similarity }.prefix(limit))
            for i in ranked.indices.dropFirst() { ranked[i].likely = false }
            return ranked
        }
    }
}

extension LibraryService {
    /// Finds the faces in the photo at `url` and, for each, the `limit` people it looks most like.
    public func lookUpPeople(in url: URL, limit: Int = 6) throws -> PhotoLookup {
        let analyzed = try MediaAnalyzer.analyzePhoto(url, thumbnail: false)
        let W = Double(max(1, analyzed.width)), H = Double(max(1, analyzed.height))
        let faces = analyzed.faces.sorted { $0.face.w * $0.face.h > $1.face.w * $1.face.h }
        let crops = faces.compactMap(\.aligned)
        let vectors = crops.isEmpty ? [] : processor.embed(crops)
        var k = 0
        var found: [(face: AnalyzedFace, vector: [Float]?, ranked: [(personId: Int64, similarity: Float, likely: Bool)])] = []
        for af in faces {
            var ranked: [(personId: Int64, similarity: Float, likely: Bool)] = []
            var vector: [Float]?
            if af.aligned != nil {
                if k < vectors.count {
                    vector = Vector.normalized(vectors[k])
                    ranked = engine.nearestPeople(to: vector!, limit: limit)
                }
                k += 1
            }
            found.append((af, vector, ranked))
        }
        // Names, pictures and counts for everyone matched, in one read.
        let ids = Set(found.flatMap { $0.ranked.map(\.personId) })
        let info: [Int64: Row] = ids.isEmpty ? [:] : try store.db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, (SELECT COUNT(*) FROM face f WHERE f.personId = p.id) AS faces,
                       COALESCE((SELECT c.id FROM face c WHERE c.id = p.coverFaceId AND c.personId = p.id),
                                (SELECT c.id FROM face c WHERE c.personId = p.id ORDER BY c.score DESC LIMIT 1)) AS cover
                FROM person p WHERE p.id IN (\(ids.map(String.init).joined(separator: ",")))
                """).map { ($0["id"] as Int64, $0) })
        }
        return PhotoLookup(width: analyzed.width, height: analyzed.height, faces: found.enumerated().map { i, f in
            PhotoLookup.Face(
                id: i, box: CGRect(x: f.face.face.x / W, y: f.face.face.y / H, width: f.face.face.w / W, height: f.face.face.h / H),
                preview: f.face.preview, quality: f.face.face.quality.map(Double.init), vector: f.vector,
                matches: f.ranked.compactMap { m in
                    // A person deleted meanwhile drops out.
                    guard let r = info[m.personId] else { return nil }
                    return PhotoLookup.Match(personId: m.personId, name: r["name"], coverFaceId: r["cover"], faces: r["faces"],
                                             similarity: m.similarity, likely: m.likely)
                })
        })
    }
}

/// A file a face looked for is in (see `LibraryStore.files(like:)`): its face most like it.
public struct FaceMatch: Identifiable, Hashable, Sendable {
    /// The file's media id.
    public var id: Int64
    public var path: String
    public var kind: MediaKind
    public var faceId: Int64
    /// Where in a video that face is.
    public var time: Double?
    public var similarity: Float
    /// How many of its faces match (a video's: one per sampled frame).
    public var faces: Int
    public var takenAt: Date?
    public var burstId: Int64?
    /// In only because the library put a face in it with the person looked for: none of its faces is alike enough
    /// on its own (a profile, a face half hidden).
    public var throughPerson: Bool
}

/// How alike a face in the library has to be to the one looked for. On a real event library (173,000 faces), one
/// face finds about 85% of the files its person is in at strict, 90% at normal and 95% at loose (with the second
/// look below), each step letting in a few more of somebody else's.
public enum FaceMatchStrictness: String, CaseIterable, Identifiable, Sendable {
    case strict, normal, loose
    public var id: String { rawValue }
    public var threshold: Float {
        switch self {
        case .strict: 0.5
        case .normal: 0.42
        case .loose: 0.36
        }
    }
}

extension LibraryStore {
    /// The files `vector` (a normalized embedding) is in, from every face of them in the library, grouped with a
    /// person or not: one hit per file, best match first. A blurred or turned-away face in the library needs to be
    /// more alike (its embedding wanders). After a first look, the faces surely the same (0.55 and up) are averaged
    /// with the one looked for and the library looked at again, which finds the person turned or lit otherwise.
    /// `person` (the person the face is likely to be) brings in every file the library has put them in too.
    /// Only `project`'s event files (every project's with nil), never duplicates.
    public func files(like vector: [Float], strictness: FaceMatchStrictness = .normal, person: Int64? = nil,
                      project: Int64?) throws -> [FaceMatch] {
        let dim = vector.count
        guard dim > 0 else { return [] }
        let bar = strictness.threshold
        // Each face, and the embeddings of those that could still match after the second look (it can't raise a
        // face far from the first).
        var faceIds: [Int64] = [], mediaIds: [Int64] = [], times: [Double?] = [], extra: [Float] = [], first: [Float] = []
        var owned: [Bool] = [], kept: [Int] = [], pool: [Float] = []
        try db.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT f.id, f.mediaId, f.time, COALESCE(f.quality, 0) AS quality, f.personId, f.embedding FROM face f
                JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE f.embedding IS NOT NULL AND m.duplicateOf IS NULL AND m.status = 'done' AND \(ProjectScope.sql(project))
                """)
            while let r = try rows.next() {
                guard let e = r.dataNoCopy(atIndex: 5), e.count == dim * 4 else { continue }
                var sim: Float = 0
                e.withUnsafeBytes { b in
                    vector.withUnsafeBufferPointer { v in vDSP_dotpr(v.baseAddress!, 1, b.bindMemory(to: Float.self).baseAddress!, 1, &sim, vDSP_Length(dim)) }
                }
                faceIds.append(r[0]); mediaIds.append(r[1]); times.append(r[2])
                // Low quality: a stricter bar.
                extra.append((r[3] as Double) < 0.3 ? 0.06 : 0)
                first.append(sim)
                owned.append(person != nil && (r[4] as Int64?) == person)
                if sim >= 0.12 {
                    kept.append(faceIds.count - 1)
                    e.withUnsafeBytes { pool.append(contentsOf: $0.bindMemory(to: Float.self)) }
                }
            }
        }
        var score = first
        // The second look: the surest matches (up to 30) averaged in.
        let surest = kept.indices.filter { first[kept[$0]] >= 0.55 }.sorted { first[kept[$0]] > first[kept[$1]] }.prefix(30)
        if !surest.isEmpty {
            var probe = vector
            for k in surest { for j in 0..<dim { probe[j] += pool[k * dim + j] / Float(surest.count) } }
            probe = Vector.normalized(probe)
            for (k, i) in kept.enumerated() {
                var sim: Float = 0
                pool.withUnsafeBufferPointer { p in probe.withUnsafeBufferPointer { v in vDSP_dotpr(v.baseAddress!, 1, p.baseAddress! + k * dim, 1, &sim, vDSP_Length(dim)) } }
                score[i] = max(score[i], sim)
            }
        }
        // The best face of each file.
        var best: [Int64: (index: Int, faces: Int, alike: Bool)] = [:]
        for i in faceIds.indices {
            let alike = score[i] >= bar + extra[i]
            guard alike || owned[i] else { continue }
            var b = best[mediaIds[i]] ?? (i, 0, false)
            // An alike face beats one there only through the person; then the more alike.
            if (alike && !b.alike) || (alike == b.alike && score[i] > score[b.index]) || b.faces == 0 { b.index = i }
            b.faces += 1
            b.alike = b.alike || alike
            best[mediaIds[i]] = b
        }
        guard !best.isEmpty else { return [] }
        let info: [Int64: Row] = try db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT id, path, kind, takenAt, burstId FROM media WHERE id IN (\(best.keys.map(String.init).joined(separator: ",")))
                """).map { ($0["id"] as Int64, $0) })
        }
        return best.compactMap { mid, b -> FaceMatch? in
            guard let r = info[mid] else { return nil }
            return FaceMatch(id: mid, path: r["path"], kind: MediaKind(rawValue: r["kind"]) ?? .photo, faceId: faceIds[b.index],
                             time: times[b.index], similarity: score[b.index], faces: b.faces,
                             takenAt: (r["takenAt"] as Double?).map(Date.init(timeIntervalSince1970:)), burstId: r["burstId"],
                             throughPerson: !b.alike)
        }
        .sorted { ($0.throughPerson ? 0 : 1, $0.similarity) > ($1.throughPerson ? 0 : 1, $1.similarity) }
    }
}
