import FaceCore
import Foundation
import GRDB

public struct CelebritySuggestion: Identifiable, Sendable, Hashable {
    public var id: Int64 { personId }
    public var personId: Int64
    public var name: String
    public var celebrityId: String
    /// Mean match confidence of the agreeing faces, 0-100.
    public var confidence: Double
    /// Faces that returned this name, out of `asked` faces looked up for the person.
    public var votes: Int
    public var asked: Int
    public var urls: [String]
    /// Several faces agree, or the single face asked is a near-certain match.
    public var isStrong: Bool { votes >= 2 || (asked == 1 && confidence >= 99) }
}

/// Suggests names for unnamed groups with Amazon Rekognition's celebrity recognition.
/// Sends up to `facesPerPerson` head-and-shoulders crops per group (best quality, different files), never whole photos.
public final class CelebrityNamer: @unchecked Sendable {
    let store: LibraryStore
    let client: RekognitionClient
    public var facesPerPerson = 3
    public var minConfidence = 90.0
    public var concurrency = 3

    public init(store: LibraryStore, client: RekognitionClient) {
        self.store = store
        self.client = client
    }

    struct Candidate { var faceId: Int64; var path: String; var box: CGRect; var time: Double? }

    /// Faces that would be looked up per unnamed person (already-looked-up faces count but cost nothing).
    func candidates(personIds: [Int64]) throws -> [Int64: [Candidate]] {
        try store.db.read { db in
            var out: [Int64: [Candidate]] = [:]
            for pid in personIds {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT f.id, f.mediaId, m.path, f.x, f.y, f.w, f.h, f.time FROM face f
                    JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                    WHERE f.personId = ? AND COALESCE(s.kind, 'media') = 'media'
                    ORDER BY f.quality * MIN(1.0, f.w * COALESCE(m.width, 1500) / 120.0) DESC
                    """, arguments: [pid])
                var seenMedia: Set<Int64> = []
                var list: [Candidate] = []
                for r in rows where list.count < facesPerPerson {
                    guard seenMedia.insert(r["mediaId"] as Int64).inserted else { continue }
                    list.append(Candidate(faceId: r["id"], path: r["path"],
                                          box: CGRect(x: r["x"] as Double, y: r["y"] as Double,
                                                      width: r["w"] as Double, height: r["h"] as Double),
                                          time: r["time"]))
                }
                out[pid] = list
            }
            return out
        }
    }

    /// Unnamed people, largest first, and how many paid lookups naming them would take.
    public func plan(minFaces: Int = 3) throws -> (personIds: [Int64], newLookups: Int) {
        let pids = try store.db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT p.id FROM person p JOIN face f ON f.personId = p.id
                WHERE p.name IS NULL GROUP BY p.id HAVING COUNT(*) >= ? ORDER BY COUNT(*) DESC
                """, arguments: [minFaces])
        }
        let cands = try candidates(personIds: pids)
        let cached = Set(try store.db.read { db in try Int64.fetchAll(db, sql: "SELECT faceId FROM celebrityLookup") })
        return (pids, cands.values.joined().filter { !cached.contains($0.faceId) }.count)
    }

    public func suggest(personIds: [Int64], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [CelebritySuggestion] {
        let cands = try candidates(personIds: personIds)
        let cached = Set(try await store.db.read { db in try Int64.fetchAll(db, sql: "SELECT faceId FROM celebrityLookup") })
        let todo = cands.values.joined().filter { !cached.contains($0.faceId) }
        var done = 0
        progress(0, todo.count)

        // Look up uncached faces, a few at a time.
        var firstError: Error?
        var index = 0
        while index < todo.count {
            let chunk = todo[index..<min(index + concurrency, todo.count)]
            index += chunk.count
            let results = await withTaskGroup(of: (Candidate, Result<Celebrity?, Error>).self) { group in
                for c in chunk {
                    group.addTask { [client] in
                        guard let jpeg = MediaAnalyzer.faceContextJPEG(URL(fileURLWithPath: c.path, isDirectory: false), box: c.box, time: c.time) else {
                            return (c, .success(nil))
                        }
                        do { return (c, .success(Self.centralFace(try await client.recognizeCelebrities(jpeg: jpeg)))) }
                        catch { return (c, .failure(error)) }
                    }
                }
                var out: [(Candidate, Result<Celebrity?, Error>)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (c, r) in results {
                switch r {
                case .success(let celeb):
                    try await store.db.write { db in
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO celebrityLookup (faceId, name, celebrityId, confidence, urls, lookedUpAt)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """, arguments: [c.faceId, celeb?.name, celeb?.id, celeb?.confidence,
                                             celeb?.urls.joined(separator: " "), Date()])
                    }
                case .failure(let e):
                    firstError = firstError ?? e
                }
            }
            done += chunk.count
            progress(done, todo.count)
            // Bad credentials fail every call the same way: stop instead of repeating it for every face.
            if let e = firstError as? AWSError, !e.isThrottle { throw e }
        }
        if let firstError, !(firstError is AWSError) { throw firstError }
        return try aggregate(cands)
    }

    /// The celebrity whose face is nearest the crop centre, which is where the face we asked about is.
    static func centralFace(_ celebs: [Celebrity]) -> Celebrity? {
        celebs.filter { $0.box.insetBy(dx: -0.1, dy: -0.1).contains(CGPoint(x: 0.5, y: 0.5)) }
            .min { hypot($0.box.midX - 0.5, $0.box.midY - 0.5) < hypot($1.box.midX - 0.5, $1.box.midY - 0.5) }
    }

    /// Majority vote per person over its looked-up faces.
    func aggregate(_ cands: [Int64: [Candidate]]) throws -> [CelebritySuggestion] {
        try store.db.read { db in
            var out: [CelebritySuggestion] = []
            for (pid, list) in cands where !list.isEmpty {
                let ids = list.map { String($0.faceId) }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM celebrityLookup WHERE faceId IN (\(ids))")
                let hits = rows.filter { ($0["name"] as String?) != nil && ($0["confidence"] as Double? ?? 0) >= minConfidence }
                let byName = Dictionary(grouping: hits) { $0["name"] as String }
                guard let best = byName.max(by: { a, b in
                    a.value.count != b.value.count ? a.value.count < b.value.count
                        : a.value.map { $0["confidence"] as Double }.reduce(0, +) < b.value.map { $0["confidence"] as Double }.reduce(0, +)
                }) else { continue }
                // A tie between two different names is not a suggestion.
                if byName.values.filter({ $0.count == best.value.count }).count > 1 { continue }
                let conf = best.value.map { $0["confidence"] as Double }.reduce(0, +) / Double(best.value.count)
                out.append(CelebritySuggestion(
                    personId: pid, name: best.key, celebrityId: best.value[0]["celebrityId"] ?? "", confidence: conf,
                    votes: best.value.count, asked: rows.count,
                    urls: ((best.value[0]["urls"] as String?) ?? "").split(separator: " ").map(String.init)))
            }
            return out.sorted { $0.confidence > $1.confidence }
        }
    }
}
