import Foundation
import GRDB

/// Tags on people: singer, actor, model, KOL… Reusable labels to find people by, wherever they appear (a list is
/// what someone is at one event; a tag is what they are). A tag is its name, compared like names (any case or
/// Unicode form); it exists while someone has it.
///
/// Tags travel to teammates (TeamSync: `tag`, uuid = the person, name = the tag, deleted = taken off). The newest
/// change of each person's tag wins; a tag taken off is kept as `removed`, so an older copy elsewhere doesn't bring
/// it back.
public enum PersonTags {
    /// Every tag in use, the most used first.
    public static func all(db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT name FROM personTag WHERE NOT removed GROUP BY key ORDER BY COUNT(*) DESC, name COLLATE NOCASE
            """)
    }

    /// The person's tags, in the order they were given.
    public static func of(_ person: Int64, db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM personTag WHERE personId = ? AND NOT removed ORDER BY at", arguments: [person])
    }

    /// Tags people, or takes the tag off them. A tag already in use keeps its spelling ("kol" adds "KOL").
    public static func set(_ rawName: String, people: [Int64], on: Bool, db: Database) throws {
        let typed = PersonNames.clean(rawName)
        let key = PersonNames.key(typed)
        guard !key.isEmpty else { return }
        let name = try String.fetchAll(db, sql: "SELECT name FROM personTag WHERE key = ? AND NOT removed GROUP BY name ORDER BY COUNT(*) DESC",
                                       arguments: [key]).first ?? typed
        for p in people {
            let row = try Row.fetchOne(db, sql: "SELECT at, removed FROM personTag WHERE personId = ? AND key = ?", arguments: [p, key])
            if let row, (row["removed"] as Bool) == !on { continue }
            if row == nil && !on { continue }
            // Later than the tag's last change on this person, so this change wins on every Mac whatever its clock.
            let at = SyncIds.stamp(after: row?["at"])
            try db.execute(sql: "INSERT OR REPLACE INTO personTag (personId, key, name, at, removed) VALUES (?, ?, ?, ?, ?)",
                           arguments: [p, key, name, at, !on])
        }
    }

    /// When people are merged, the survivor keeps every tag any of them had.
    static func merge(_ others: [Int64], into target: Int64, db: Database) throws {
        let list = others.map(String.init).joined(separator: ",")
        guard !list.isEmpty else { return }
        for r in try Row.fetchAll(db, sql: "SELECT key, name, MAX(at) AS at FROM personTag WHERE personId IN (\(list)) AND NOT removed GROUP BY key") {
            let key: String = r["key"]
            let mine = try Row.fetchOne(db, sql: "SELECT at, removed FROM personTag WHERE personId = ? AND key = ?", arguments: [target, key])
            if let mine, !(mine["removed"] as Bool) { continue }
            let at: Double = mine == nil ? r["at"] : SyncIds.stamp(after: max(r["at"], mine?["at"] ?? 0))
            try db.execute(sql: "INSERT OR REPLACE INTO personTag (personId, key, name, at, removed) VALUES (?, ?, ?, ?, 0)",
                           arguments: [target, key, r["name"] as String, at])
        }
        try db.execute(sql: "DELETE FROM personTag WHERE personId IN (\(list))")
    }
}

extension TeamSync {
    /// People's tags and the tags taken off them, since last published.
    func tagOps(state: [String: String]) throws -> (ops: [Op], updates: [String: String]) {
        var ops: [Op] = []
        var updates: [String: String] = [:]
        for r in try store.db.read({ db in
            try Row.fetchAll(db, sql: "SELECT p.uuid, t.key, t.name, t.at, t.removed FROM personTag t JOIN person p ON p.id = t.personId")
        }) {
            let uuid: String = r["uuid"], key: String = r["key"], at: Double = r["at"], removed: Bool = r["removed"]
            let value = removed ? "x\(at)" : "\(at)"
            guard state["pub:tag:\(uuid):\(key)"] != value else { continue }
            ops.append(Op(t: "tag", at: at, uuid: uuid, name: r["name"], deleted: removed))
            updates["pub:tag:\(uuid):\(key)"] = value
        }
        return (ops, updates)
    }

    func applyTagOp(_ op: Op, team: TeamRecord, db: Database) throws -> Outcome {
        guard let uuid = op.uuid, let name = op.name.map(PersonNames.clean), !name.isEmpty else { return .ignored }
        guard let pid = try Self.resolve(uuid, db: db) else { return .deferred }
        let key = PersonNames.key(name)
        let current = try Double?.fetchOne(db, sql: "SELECT at FROM personTag WHERE personId = ? AND key = ?", arguments: [pid, key]) ?? nil
        guard op.at > (current ?? 0) else { return .ignored }
        let removed = op.deleted == true
        try db.execute(sql: "INSERT OR REPLACE INTO personTag (personId, key, name, at, removed) VALUES (?, ?, ?, ?, ?)",
                       arguments: [pid, key, name, op.at, removed])
        // Known here now: not sent back as this Mac's own change.
        let local: String = try String.fetchOne(db, sql: "SELECT uuid FROM person WHERE id = ?", arguments: [pid]) ?? uuid
        try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)",
                       arguments: [team.id, "pub:tag:\(local):\(key)", removed ? "x\(op.at)" : "\(op.at)"])
        return .applied(people: [], remote: [])
    }
}
