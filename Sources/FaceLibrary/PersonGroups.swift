import Foundation
import GRDB

/// A list of people: the cast, the sponsors, the VIPs. An event has a thousand faces; the few dozen that matter are
/// found again by list, and pinned people float to the top of every people grid.
///
/// A list belongs to one project: what someone is at one event (the main cast at one, a guest at the next). Pins
/// apply to the person wherever they appear, like a name. Lists and pins travel to teammates (TeamSync: `list`,
/// `listMember`, `pin`; the newest change wins, and what was taken away stays away).
public struct PersonGroupRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "personGroup"
    public var id: Int64?
    public var name: String
    /// Position in the sidebar; new lists go last.
    public var sortOrder: Int
    public var createdAt: Date
    /// The same list on every Mac of a team.
    public var uuid: String
    /// When the list was made or last renamed, seconds since 1970.
    public var updatedAt: Double
    /// The project (event) the list is of.
    public var projectId: Int64?

    public init(name: String, sortOrder: Int, projectId: Int64?, uuid: String = SyncIds.new(), updatedAt: Double = Date().timeIntervalSince1970) {
        self.name = name
        self.projectId = projectId
        self.sortOrder = sortOrder
        createdAt = Date()
        self.uuid = uuid
        self.updatedAt = updatedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum PersonGroups {
    /// Lists photographers reach for; offered where a list is made so the first one takes a click, not typing.
    public static let suggestedNames = ["Cast", "Producers", "Sponsors", "Guests", "VIP", "VVIP"]

    /// Creates a list in the project, or returns the project's list already called `name` (any case).
    @discardableResult
    public static func create(_ rawName: String, project: Int64, db: Database) throws -> Int64 {
        let name = PersonNames.clean(rawName)
        if let existing = try find(name, project: project, db: db) { return existing }
        let last = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM personGroup WHERE projectId = ?", arguments: [project]) ?? -1
        var g = PersonGroupRecord(name: name, sortOrder: last + 1, projectId: project)
        try g.insert(db)
        return g.id!
    }

    public static func find(_ name: String, project: Int64, db: Database) throws -> Int64? {
        let k = PersonNames.key(name)
        guard !k.isEmpty else { return nil }
        return try Row.fetchAll(db, sql: "SELECT id, name FROM personGroup WHERE projectId = ?", arguments: [project])
            .first { PersonNames.key($0["name"]) == k }?["id"]
    }

    /// Lists from before lists were a project's, made the projects': each list is copied into every project where
    /// someone on it appears (with the people on it who appear there), else into the newest project. A copy's id is
    /// the list's and the project's, so every Mac of a team makes the same copies; the old list is retired, and what
    /// teammates' logs still say of it is ignored.
    static func splitByProject(db: Database) throws {
        let newest = try Int64.fetchOne(db, sql: "SELECT id FROM project ORDER BY createdAt DESC LIMIT 1")
        for g in try Row.fetchAll(db, sql: "SELECT id, uuid, name, sortOrder, createdAt, updatedAt FROM personGroup WHERE projectId IS NULL") {
            let id: Int64 = g["id"], uuid: String = g["uuid"]
            let members = try Row.fetchAll(db, sql: """
                SELECT DISTINCT gm.personId, gm.at, s.projectId FROM personGroupMember gm
                JOIN face f ON f.personId = gm.personId JOIN media m ON m.id = f.mediaId JOIN source s ON s.id = m.sourceId
                WHERE gm.groupId = ? AND s.kind = 'media' AND s.projectId IS NOT NULL
                """, arguments: [id])
            var projects = Set(members.map { $0["projectId"] as Int64 })
            if projects.isEmpty, let newest { projects = [newest] }
            for p in projects {
                let puuid: String = try String.fetchOne(db, sql: "SELECT uuid FROM project WHERE id = ?", arguments: [p]) ?? "\(p)"
                try db.execute(sql: """
                    INSERT OR IGNORE INTO personGroup (name, sortOrder, createdAt, uuid, updatedAt, projectId) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [g["name"] as String, g["sortOrder"] as Int, g["createdAt"] as Date, "\(uuid):\(puuid)", g["updatedAt"] as Double, p])
                let copy = db.lastInsertedRowID
                for m in members where (m["projectId"] as Int64) == p {
                    try db.execute(sql: "INSERT OR IGNORE INTO personGroupMember (groupId, personId, at) VALUES (?, ?, ?)",
                                   arguments: [copy, m["personId"] as Int64, m["at"] as Double])
                }
            }
            try db.execute(sql: "DELETE FROM personGroup WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM personGroupMemberGone WHERE groupUuid = ?", arguments: [uuid])
            try db.execute(sql: "DELETE FROM personGroupAlias WHERE fromUuid = ? OR intoUuid = ?", arguments: [uuid, uuid])
            // Retired for good (no project: not published).
            try db.execute(sql: "INSERT OR REPLACE INTO personGroupGone (uuid, at, project) VALUES (?, ?, NULL)", arguments: [uuid, Double.greatestFiniteMagnitude])
        }
    }

    public static func rename(_ id: Int64, to rawName: String, db: Database) throws {
        let name = PersonNames.clean(rawName)
        guard !name.isEmpty else { return }
        try db.execute(sql: "UPDATE personGroup SET name = ?, updatedAt = \(SyncIds.stampSQL("updatedAt")) WHERE id = ?",
                       arguments: [name, Date().timeIntervalSince1970, id])
    }

    public static func delete(_ id: Int64, db: Database) throws {
        // Later than the list's last change (and than an earlier deletion of a list with this id), so the
        // deletion wins on every Mac whatever its clock.
        try db.execute(sql: """
            INSERT OR REPLACE INTO personGroupGone (uuid, at, project)
            SELECT uuid, MAX(?, updatedAt + 0.001, COALESCE((SELECT at FROM personGroupGone g WHERE g.uuid = personGroup.uuid), 0) + 0.001),
                (SELECT uuid FROM project WHERE id = personGroup.projectId)
            FROM personGroup WHERE id = ?
            """, arguments: [Date().timeIntervalSince1970, id])
        try db.execute(sql: "DELETE FROM personGroup WHERE id = ?", arguments: [id])
    }

    /// Puts people on a list, or takes them off it.
    public static func set(_ group: Int64, people: [Int64], member: Bool, db: Database) throws {
        for p in people {
            // Later than the pair's last change either way (on the list, or taken off it), so this change wins
            // on every Mac whatever its clock.
            let now = SyncIds.stamp(after: try Double.fetchOne(db, sql: """
                SELECT MAX(COALESCE((SELECT at FROM personGroupMember WHERE groupId = ? AND personId = ?), 0),
                           COALESCE((SELECT at FROM personGroupMemberGone WHERE groupUuid = (SELECT uuid FROM personGroup WHERE id = ?)
                                     AND personUuid = (SELECT uuid FROM person WHERE id = ?)), 0))
                """, arguments: [group, p, group, p]))
            if member {
                try db.execute(sql: "INSERT OR IGNORE INTO personGroupMember (groupId, personId, at) VALUES (?, ?, ?)", arguments: [group, p, now])
                guard db.changesCount > 0 else { continue }
                try db.execute(sql: """
                    DELETE FROM personGroupMemberGone WHERE groupUuid = (SELECT uuid FROM personGroup WHERE id = ?)
                      AND personUuid = (SELECT uuid FROM person WHERE id = ?)
                    """, arguments: [group, p])
            } else {
                try db.execute(sql: "DELETE FROM personGroupMember WHERE groupId = ? AND personId = ?", arguments: [group, p])
                guard db.changesCount > 0 else { continue }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO personGroupMemberGone (groupUuid, personUuid, at)
                    SELECT g.uuid, p.uuid, ? FROM personGroup g, person p WHERE g.id = ? AND p.id = ?
                    """, arguments: [now, group, p])
            }
        }
    }

    /// Pins people (they sort first everywhere) or unpins them; teammates follow (see TeamSync).
    public static func pin(_ people: [Int64], _ on: Bool, db: Database) throws {
        let list = people.map(String.init).joined(separator: ",")
        guard !list.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        if on {
            try db.execute(sql: "UPDATE person SET pinnedAt = ?, pinAt = \(SyncIds.stampSQL("pinAt")) WHERE id IN (\(list)) AND pinnedAt IS NULL", arguments: [now, now])
        } else {
            try db.execute(sql: "UPDATE person SET pinnedAt = NULL, pinAt = \(SyncIds.stampSQL("pinAt")) WHERE id IN (\(list)) AND pinnedAt IS NOT NULL", arguments: [now])
        }
    }

    /// Sets the short note on who the person is (empty: none); teammates follow (see TeamSync).
    public static func setBio(_ person: Int64, _ raw: String, db: Database) throws {
        let bio = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.execute(sql: "UPDATE person SET bio = ?, bioAt = \(SyncIds.stampSQL("bioAt")) WHERE id = ? AND COALESCE(bio, '') != ?",
                       arguments: [bio.isEmpty ? nil : bio, Date().timeIntervalSince1970, person, bio])
    }

    /// When people are merged, the survivor keeps every list and the pin any of them had, and its own note (else
    /// the newest of theirs).
    static func merge(_ others: [Int64], into target: Int64, db: Database) throws {
        let list = others.map(String.init).joined(separator: ",")
        guard !list.isEmpty else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO personGroupMember (groupId, personId, at) SELECT DISTINCT groupId, ?, ? FROM personGroupMember WHERE personId IN (\(list))",
                       arguments: [target, Date().timeIntervalSince1970])
        try db.execute(sql: "DELETE FROM personGroupMember WHERE personId IN (\(list))")
        try db.execute(sql: """
            UPDATE person SET pinnedAt = COALESCE(pinnedAt, (SELECT MIN(pinnedAt) FROM person WHERE id IN (\(list)))),
                pinAt = NULLIF(MAX(COALESCE(pinAt, 0), COALESCE((SELECT MAX(pinAt) FROM person WHERE id IN (\(list)) AND pinnedAt IS NOT NULL), 0)), 0)
            WHERE id = ?
            """, arguments: [target])
        try db.execute(sql: """
            UPDATE person SET (bio, bioAt) = (SELECT bio, bioAt FROM person WHERE id IN (\(list)) AND bio IS NOT NULL ORDER BY bioAt DESC LIMIT 1)
            WHERE id = ? AND bio IS NULL
              AND (SELECT MAX(bioAt) FROM person WHERE id IN (\(list)) AND bio IS NOT NULL) > COALESCE(bioAt, 0)
            """, arguments: [target])
    }
}
