import Foundation
import GRDB
import MediaKit

/// A saved look: the editor's light, colour, detail, tone curve and HSL sliders under a name, to pick from Looks in
/// any editing screen.
public struct SavedLook: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Turns auto tone on when picked (the sliders then go on top of it).
    public var autoTone: Bool
    public var adjustments: Adjustments
    public init(id: String = UUID().uuidString, name: String, autoTone: Bool = false, adjustments: Adjustments) {
        self.id = id
        self.name = name
        self.autoTone = autoTone
        self.adjustments = adjustments
    }
}

/// Saved looks live in the library, so they travel to every Mac of the user's teams like saved watermarks do
/// (TeamSync, `look` changes, the newest wins, a deleted one goes everywhere).
public enum SavedLooks {
    public static func all(_ db: Database) throws -> [SavedLook] {
        try Row.fetchAll(db, sql: "SELECT id, name, autoTone, adjustments FROM lookPreset WHERE NOT deleted ORDER BY createdAt, rowid").compactMap { r in
            guard let a = try? JSONDecoder().decode(Adjustments.self, from: Data((r["adjustments"] as String).utf8)) else { return nil }
            return SavedLook(id: r["id"], name: r["name"], autoTone: r["autoTone"], adjustments: a)
        }
    }

    /// Adds the look, or replaces the one with the same id.
    public static func save(_ l: SavedLook, db: Database, at: Double? = nil) throws {
        let adjustments = String(decoding: try JSONEncoder().encode(l.adjustments), as: UTF8.self)
        // Later than the version it replaces, so it wins on every Mac whatever this one's clock says.
        let at = try at ?? SyncIds.stamp(after: try Double.fetchOne(db, sql: "SELECT updatedAt FROM lookPreset WHERE id = ?", arguments: [l.id]))
        try db.execute(sql: """
            INSERT INTO lookPreset (id, name, autoTone, adjustments, updatedAt, createdAt, deleted) VALUES (?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, autoTone = excluded.autoTone, adjustments = excluded.adjustments,
              updatedAt = excluded.updatedAt, deleted = 0
            """, arguments: [l.id, l.name, l.autoTone, adjustments, at, at])
    }

    /// Gone here and, through the team, on the other Macs (kept as a tombstone so an older copy doesn't come back).
    public static func delete(_ id: String, db: Database) throws {
        try db.execute(sql: "UPDATE lookPreset SET deleted = 1, updatedAt = \(SyncIds.stampSQL("updatedAt")) WHERE id = ?",
                       arguments: [Date().timeIntervalSince1970, id])
    }
}

extension TeamSync {
    struct LookPayload: Codable {
        var autoTone: Bool?
        var adjustments: Adjustments
    }

    /// Saved looks added, changed or deleted here since last published.
    func lookOps(state: [String: String]) throws -> (ops: [Op], updates: [String: String]) {
        let rows = try store.db.read { db in try Row.fetchAll(db, sql: "SELECT id, name, autoTone, adjustments, updatedAt, deleted FROM lookPreset") }
        var ops: [Op] = []
        var updates: [String: String] = [:]
        for r in rows {
            let id: String = r["id"], at: Double = r["updatedAt"]
            guard state["pub:look:\(id)"] != "\(at)" else { continue }
            guard let a = try? JSONDecoder().decode(Adjustments.self, from: Data((r["adjustments"] as String).utf8)) else { continue }
            var op = Op(t: "look", at: at, uuid: id, name: r["name"], deleted: (r["deleted"] as Bool) ? true : nil)
            op.look = LookPayload(autoTone: (r["autoTone"] as Bool) ? true : nil, adjustments: a)
            ops.append(op)
            updates["pub:look:\(id)"] = "\(at)"
        }
        return (ops, updates)
    }

    /// A teammate saved, changed or deleted a look: the newest wins.
    func applyLookOp(_ op: Op, team: TeamRecord, db: Database) throws -> Outcome {
        guard let id = op.uuid, let payload = op.look else { return .ignored }
        let current = try Double?.fetchOne(db, sql: "SELECT updatedAt FROM lookPreset WHERE id = ?", arguments: [id]) ?? nil
        guard op.at > (current ?? 0) else { return .ignored }
        try SavedLooks.save(SavedLook(id: id, name: op.name ?? "Look", autoTone: payload.autoTone == true, adjustments: payload.adjustments), db: db, at: op.at)
        if op.deleted == true { try db.execute(sql: "UPDATE lookPreset SET deleted = 1 WHERE id = ?", arguments: [id]) }
        // Known here now: not sent back as this Mac's own change.
        try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [team.id, "pub:look:\(id)", "\(op.at)"])
        return .applied(people: [], remote: [])
    }
}
