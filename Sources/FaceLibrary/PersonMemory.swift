import Foundation
import GRDB

/// What the library still knows of a named person whose faces left it (their folder removed, files deleted or
/// changed): the mean of those faces and how many. The name stays and keeps being recognised, so the same people
/// at a later event, or the same photos added again, get their names back without naming them twice.
enum PersonMemory {
    /// Call in the transaction that deletes the faces matching `condition` (on `face` joined with `media`), before
    /// deleting them. Faces of unnamed groups are not kept: nobody would recognise those again.
    static func remember(_ condition: String, _ args: StatementArguments = [], db: Database) throws {
        let settings = GroupingSettings()
        let rows = try Row.fetchAll(db, sql: """
            SELECT face.id, face.personId, face.mediaId, face.track, face.embedding FROM face
            JOIN media ON media.id = face.mediaId JOIN person ON person.id = face.personId
            WHERE person.name IS NOT NULL AND face.embedding IS NOT NULL
              AND COALESCE(face.quality, 0) >= ? AND face.w * COALESCE(media.width, 0) >= ? AND (\(condition))
            """, arguments: [settings.minQuality, settings.minFacePixels] + args)
        // One unit per photo face or per video track, as the grouping engine counts them.
        var units: [Int64: [String: [Float]]] = [:]
        for r in rows {
            let id: Int64 = r["id"], pid: Int64 = r["personId"], mediaId: Int64 = r["mediaId"], track: Int64? = r["track"]
            let v = Vector.decode(r["embedding"])
            guard v.count == 512 else { continue }
            let key = track.map { "\(mediaId)/t\($0)" } ?? "f\(id)"
            var sum = units[pid]?[key] ?? [Float](repeating: 0, count: 512)
            for i in 0..<512 { sum[i] += v[i] }
            units[pid, default: [:]][key] = sum
        }
        for (pid, byKey) in units {
            var sum = [Float](repeating: 0, count: 512)
            for u in byKey.values { for (i, x) in Vector.normalized(u).enumerated() { sum[i] += x } }
            try add(sum, count: byKey.count, to: pid, db: db)
        }
    }

    /// Adds `count` units summing to `sum` to what is remembered of the person.
    static func add(_ sum: [Float], count: Int, to pid: Int64, db: Database) throws {
        guard count > 0 else { return }
        var total = sum, n = count
        if let row = try Row.fetchOne(db, sql: "SELECT centroid, count FROM personMemory WHERE personId = ?", arguments: [pid]) {
            let c = Vector.decode(row["centroid"]), m: Int = row["count"]
            if c.count == 512 {
                for i in 0..<512 { total[i] += c[i] * Float(m) }
                n += m
            }
        }
        try db.execute(sql: "INSERT OR REPLACE INTO personMemory (personId, centroid, count) VALUES (?, ?, ?)",
                       arguments: [pid, Vector.encode(total.map { $0 / Float(n) }), n])
    }

    /// A merge: what was remembered of `others` now belongs to `target`.
    static func merge(_ others: [Int64], into target: Int64, db: Database) throws {
        let list = others.map(String.init).joined(separator: ",")
        for r in try Row.fetchAll(db, sql: "SELECT centroid, count FROM personMemory WHERE personId IN (\(list))") {
            let c = Vector.decode(r["centroid"]), n: Int = r["count"]
            guard c.count == 512 else { continue }
            try add(c.map { $0 * Float(n) }, count: n, to: target, db: db)
        }
        try db.execute(sql: "DELETE FROM personMemory WHERE personId IN (\(list))")
    }
}
