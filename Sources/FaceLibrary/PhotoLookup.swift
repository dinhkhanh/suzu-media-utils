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
    public func nearestPeople(to v: [Float], limit: Int) -> [(personId: Int64, similarity: Float, likely: Bool)] {
        queue.sync {
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
        var found: [(face: AnalyzedFace, ranked: [(personId: Int64, similarity: Float, likely: Bool)])] = []
        for af in faces {
            var ranked: [(personId: Int64, similarity: Float, likely: Bool)] = []
            if af.aligned != nil {
                if k < vectors.count { ranked = engine.nearestPeople(to: Vector.normalized(vectors[k]), limit: limit) }
                k += 1
            }
            found.append((af, ranked))
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
                preview: f.face.preview, quality: f.face.face.quality.map(Double.init),
                matches: f.ranked.compactMap { m in
                    // A person deleted meanwhile drops out.
                    guard let r = info[m.personId] else { return nil }
                    return PhotoLookup.Match(personId: m.personId, name: r["name"], coverFaceId: r["cover"], faces: r["faces"],
                                             similarity: m.similarity, likely: m.likely)
                })
        })
    }
}
