import FaceCore
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
    /// Leave out photos whose main face is soft (out of focus or moved).
    public var skipBlurry = false
    /// Solo = exactly one clear face; group = two or more.
    public var crowd = Crowd.any
    /// Only this project's files (nil = every project).
    public var project: Int64?

    public init() {}

    /// Queries saved by older versions (smart albums, rules, team logs) lack the newer keys: those keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decodeIfPresent([Int64].self, forKey: .people) ?? []
        match = try c.decodeIfPresent(PeopleMatch.self, forKey: .match) ?? .all
        kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind)
        from = try c.decodeIfPresent(Date.self, forKey: .from)
        to = try c.decodeIfPresent(Date.self, forKey: .to)
        sourceId = try c.decodeIfPresent(Int64.self, forKey: .sourceId)
        bestOnly = try c.decodeIfPresent(Bool.self, forKey: .bestOnly) ?? false
        bestThreshold = try c.decodeIfPresent(Double.self, forKey: .bestThreshold) ?? 0.6
        collapseBursts = try c.decodeIfPresent(Bool.self, forKey: .collapseBursts) ?? false
        skipBlurry = try c.decodeIfPresent(Bool.self, forKey: .skipBlurry) ?? false
        crowd = try c.decodeIfPresent(Crowd.self, forKey: .crowd) ?? .any
        project = try c.decodeIfPresent(Int64.self, forKey: .project)
    }
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

    public init(id: Int64, path: String, kind: MediaKind, faceId: Int64? = nil, time: Double? = nil, score: Double,
                takenAt: Date? = nil, burstId: Int64? = nil) {
        self.id = id; self.path = path; self.kind = kind; self.faceId = faceId; self.time = time; self.score = score
        self.takenAt = takenAt; self.burstId = burstId
    }
}

extension MediaQuery {
    public func run(_ store: LibraryStore, limit: Int? = nil) throws -> [MediaHit] {
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
        if skipBlurry {
            conds.append("NOT (\(Selection.blurrySQL("m.id")))")
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
        // Every filter runs here, before any limit: "best shots" and "hide similar" over the whole event, not over
        // its first files. One burst keeps its best-scoring file.
        var sql = """
            SELECT m.id, m.path, m.kind, m.takenAt, m.burstId, bf.id AS faceId, bf.time, COALESCE(bf.score, bf.quality * 0.6, 0) AS score
            FROM media m LEFT JOIN source s ON s.id = m.sourceId
            LEFT JOIN face bf ON bf.id = (SELECT id FROM face bf WHERE bf.mediaId = m.id \(faceFilter)
                                          ORDER BY COALESCE(bf.score, bf.quality * 0.6, 0) DESC LIMIT 1)
            WHERE \(conds.joined(separator: " AND "))
            """
        var outer: [String] = []
        if collapseBursts {
            // The shot kept of a burst: a RAW file first (it holds the most), then the best by score.
            sql = "SELECT *, ROW_NUMBER() OVER (PARTITION BY burstId ORDER BY \(ImageLoader.rawSQL("path")) DESC, score DESC, id) AS burstRank FROM (\(sql))"
            outer.append("(burstId IS NULL OR burstRank = 1)")
        }
        if bestOnly { outer.append("score >= \(bestThreshold)") }
        let final = """
            SELECT * FROM (\(sql)) \(outer.isEmpty ? "" : "WHERE " + outer.joined(separator: " AND "))
            ORDER BY takenAt, path \(limit.map { "LIMIT \($0)" } ?? "")
            """
        return try store.db.read { db in
            try Row.fetchAll(db, sql: final, arguments: StatementArguments(args)!).map { r in
                MediaHit(id: r["id"], path: r["path"], kind: MediaKind(rawValue: r["kind"]) ?? .photo, faceId: r["faceId"],
                         time: r["time"], score: r["score"], takenAt: (r["takenAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                         burstId: r["burstId"])
            }
        }
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
