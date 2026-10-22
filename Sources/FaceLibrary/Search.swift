import Foundation
import GRDB

/// A search over the library; saved searches are smart albums.
public struct MediaQuery: Codable, Hashable, Sendable {
    public enum PeopleMatch: String, Codable, Sendable, CaseIterable { case all, any }
    public enum Crowd: String, Codable, Sendable, CaseIterable { case any, solo, group }

    public var people: [Int64] = []
    public var match = PeopleMatch.all
    public var kind: MediaKind?
    public var from: Date?
    public var to: Date?
    public var sourceId: Int64?
    /// Only files where the matched face scores as a good shot.
    public var bestOnly = false
    public var bestThreshold = 0.6
    /// Only the best photo of each burst.
    public var collapseBursts = false
    /// Solo = exactly one clear face; group = two or more.
    public var crowd = Crowd.any
    /// Only this project's files (nil = every project).
    public var project: Int64?

    public init() {}
}

public struct MediaHit: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var path: String
    public var kind: MediaKind
    /// Best matching face (thumbnail and video timestamp).
    public var faceId: Int64?
    public var time: Double?
    public var score: Double
    public var takenAt: Date?
    public var burstId: Int64?
}

extension MediaQuery {
    public func run(_ store: LibraryStore, limit: Int = 5000) throws -> [MediaHit] {
        var conds = ["m.duplicateOf IS NULL", "m.status = 'done'", ProjectScope.sql(project)]
        var args: [DatabaseValueConvertible?] = []
        if let kind { conds.append("m.kind = ?"); args.append(kind.rawValue) }
        if let from { conds.append("m.takenAt >= ?"); args.append(from.timeIntervalSince1970) }
        if let to { conds.append("m.takenAt <= ?"); args.append(to.timeIntervalSince1970) }
        if let sourceId { conds.append("m.sourceId = ?"); args.append(sourceId) }
        let ids = people.map(String.init).joined(separator: ",")
        if !people.isEmpty {
            conds.append(match == .all
                ? "m.id IN (SELECT mediaId FROM face WHERE personId IN (\(ids)) GROUP BY mediaId HAVING COUNT(DISTINCT personId) = \(people.count))"
                : "m.id IN (SELECT mediaId FROM face WHERE personId IN (\(ids)))")
        }
        switch crowd {
        case .any: break
        case .solo: conds.append("(SELECT COUNT(*) FROM face c WHERE c.mediaId = m.id AND c.quality >= 0.3 AND c.time IS NULL) = 1")
        case .group: conds.append("(SELECT COUNT(DISTINCT COALESCE(c.personId, -c.id)) FROM face c WHERE c.mediaId = m.id AND c.quality >= 0.3) >= 2")
        }
        // The face that represents the file: best of the searched people, else best of anyone.
        // "+" keeps SQLite on the per-file index: by person it would scan all of a star's faces for every file
        // (24 s instead of 0.08 s for someone with 12,000 faces).
        let faceFilter = people.isEmpty ? "" : "AND +bf.personId IN (\(ids))"
        let sql = """
            SELECT m.id, m.path, m.kind, m.takenAt, m.burstId, bf.id AS faceId, bf.time, COALESCE(bf.score, bf.quality * 0.6, 0) AS score
            FROM media m LEFT JOIN source s ON s.id = m.sourceId
            LEFT JOIN face bf ON bf.id = (SELECT id FROM face bf WHERE bf.mediaId = m.id \(faceFilter)
                                          ORDER BY COALESCE(bf.score, bf.quality * 0.6, 0) DESC LIMIT 1)
            WHERE \(conds.joined(separator: " AND "))
            ORDER BY m.takenAt, m.path
            LIMIT \(limit)
            """
        var hits = try store.db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)!).map { r in
                MediaHit(id: r["id"], path: r["path"], kind: MediaKind(rawValue: r["kind"]) ?? .photo, faceId: r["faceId"],
                         time: r["time"], score: r["score"], takenAt: (r["takenAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                         burstId: r["burstId"])
            }
        }
        if bestOnly { hits = hits.filter { $0.score >= bestThreshold } }
        if collapseBursts {
            var best: [Int64: MediaHit] = [:]
            for h in hits { if let b = h.burstId, (best[b]?.score ?? -1) < h.score { best[b] = h } }
            hits = hits.filter { h in h.burstId.map { best[$0]?.id == h.id } ?? true }
        }
        return hits
    }
}

public struct SmartAlbum: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "smartAlbum"
    public var id: Int64?
    public var name: String
    public var query: String  // JSON MediaQuery
    public var createdAt: Date
    public var projectId: Int64?

    public init(name: String, query: MediaQuery) {
        self.name = name
        projectId = query.project
        self.query = String(decoding: (try? JSONEncoder().encode(query)) ?? Data(), as: UTF8.self)
        createdAt = Date()
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var mediaQuery: MediaQuery { (try? JSONDecoder().decode(MediaQuery.self, from: Data(query.utf8))) ?? MediaQuery() }
}
