import Foundation
import GRDB

/// Marks bursts: photos from the same folder taken within a couple of seconds that look nearly the same.
/// Each burst's members share `media.burstId` (the id of its first photo); the UI can then show only the best one.
public struct BurstGrouper: Sendable {
    let store: LibraryStore
    /// Max seconds between consecutive shots of one burst.
    public var maxGap: Double = 2.0
    /// Max feature-print distance between consecutive shots (calibrated on event photos, see PLAN.md).
    public var maxDistance: Float = BurstGrouper.defaultMaxDistance
    public static let defaultMaxDistance: Float = 0.48

    public init(store: LibraryStore) { self.store = store }

    struct Shot { var id: Int64; var folder: String; var t: Double; var fp: [Float]; var burst: Int64? }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { let d = a[i] - b[i]; s += d * d }
        return s.squareRoot()
    }

    /// Recomputes bursts for all photos with a capture time and feature print. Returns how many photos are in bursts.
    @discardableResult
    public func regroup() throws -> Int {
        let shots = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path, takenAt, featurePrint, burstId FROM media
                WHERE kind = 'photo' AND duplicateOf IS NULL AND takenAt IS NOT NULL AND LENGTH(featurePrint) > 0
                """).map { r in
                Shot(id: r["id"], folder: ((r["path"] as String) as NSString).deletingLastPathComponent, t: r["takenAt"],
                     fp: Vector.decode(r["featurePrint"]), burst: r["burstId"])
            }
        }
        var newBurst: [Int64: Int64?] = [:]
        for (_, list) in Dictionary(grouping: shots, by: \.folder) {
            let sorted = list.sorted { ($0.t, $0.id) < ($1.t, $1.id) }
            var groups: [[Shot]] = []
            for s in sorted {
                if let prev = groups.last?.last, s.t - prev.t <= maxGap, Self.distance(s.fp, prev.fp) <= maxDistance {
                    groups[groups.count - 1].append(s)
                } else {
                    groups.append([s])
                }
            }
            for g in groups {
                let id: Int64? = g.count > 1 ? g[0].id : nil
                for s in g where s.burst != id { newBurst[s.id] = id }
            }
        }
        if !newBurst.isEmpty {
            try store.db.write { db in
                for (id, b) in newBurst { try db.execute(sql: "UPDATE media SET burstId = ? WHERE id = ?", arguments: [b, id]) }
            }
        }
        return try store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE burstId IS NOT NULL") ?? 0 }
    }
}
