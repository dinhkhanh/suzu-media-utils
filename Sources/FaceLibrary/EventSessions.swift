import Foundation
import GRDB

/// A stretch of an event without a long pause in shooting: the opening, a match, the awards ceremony.
public struct EventSession: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    /// Capture time of the first and last file, seconds since 1970.
    public var start: Double
    public var end: Double
    public var photos: Int
    public var videos: Int
    /// Given by the user ("Awards"); nil = shown as its time.
    public var name: String?

    public var range: ClosedRange<Double> { start...end }
    public func contains(_ t: Double) -> Bool { range.contains(t) }
}

/// Splits a project's files into sessions wherever there is a gap in capture times, and keeps the names users give
/// them. Names are stored as a moment inside the session, so they survive the session growing as files arrive.
public enum EventSessions {
    public static let defaultGap: TimeInterval = 30 * 60

    /// Sessions of the project's photos and videos (every project's when nil), in time order.
    public static func list(_ db: Database, project: Int64?, gap: TimeInterval = defaultGap) throws -> [EventSession] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.takenAt, m.kind FROM media m LEFT JOIN source s ON s.id = m.sourceId
            WHERE m.duplicateOf IS NULL AND m.takenAt IS NOT NULL AND \(ProjectScope.sql(project))
            ORDER BY m.takenAt
            """)
        var out: [EventSession] = []
        for r in rows {
            let t: Double = r["takenAt"]
            let video = (r["kind"] as String) == "video"
            if var last = out.last, t - last.end <= gap {
                last.end = t
                if video { last.videos += 1 } else { last.photos += 1 }
                out[out.count - 1] = last
            } else {
                out.append(EventSession(index: out.count, start: t, end: t, photos: video ? 0 : 1, videos: video ? 1 : 0))
            }
        }
        guard let project, !out.isEmpty else { return out }
        let labels = try Row.fetchAll(db, sql: "SELECT at, name FROM sessionLabel WHERE projectId = ? ORDER BY at", arguments: [project])
        for l in labels {
            let at: Double = l["at"]
            if let i = out.firstIndex(where: { $0.contains(at) }), out[i].name == nil { out[i].name = l["name"] }
        }
        return out
    }

    /// Names a session (nil or empty clears it).
    public static func setName(_ store: LibraryStore, project: Int64, session: EventSession, name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM sessionLabel WHERE projectId = ? AND at BETWEEN ? AND ?",
                           arguments: [project, session.start, session.end])
            if !trimmed.isEmpty {
                try db.execute(sql: "INSERT INTO sessionLabel (projectId, at, name) VALUES (?, ?, ?)",
                               arguments: [project, session.start, trimmed])
            }
        }
    }

    /// SQL condition on media alias `m`: captured within the range (true when nil).
    public static func sql(_ range: ClosedRange<Double>?, media m: String = "m") -> String {
        guard let r = range else { return "1" }
        return "(\(m).takenAt BETWEEN \(r.lowerBound) AND \(r.upperBound))"
    }
}
