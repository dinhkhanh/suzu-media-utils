import Foundation
import GRDB

/// A list of people: the cast, the sponsors, the VIPs. An event has a thousand faces; the few dozen that matter are
/// found again by list, and pinned people float to the top of every people grid.
///
/// Lists and pins are the Mac's own (not shared with the team) and apply to the person wherever they appear, like
/// a name: a sponsor at one event is still listed as one at the next.
public struct PersonGroupRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "personGroup"
    public var id: Int64?
    public var name: String
    /// Position in the sidebar; new lists go last.
    public var sortOrder: Int
    public var createdAt: Date

    public init(name: String, sortOrder: Int) {
        self.name = name
        self.sortOrder = sortOrder
        createdAt = Date()
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum PersonGroups {
    /// Lists photographers reach for; offered where a list is made so the first one takes a click, not typing.
    public static let suggestedNames = ["Cast", "Producers", "Sponsors", "Guests", "VIP", "VVIP"]

    /// Creates a list, or returns the one already called `name` (any case).
    @discardableResult
    public static func create(_ rawName: String, db: Database) throws -> Int64 {
        let name = PersonNames.clean(rawName)
        if let existing = try find(name, db: db) { return existing }
        let last = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM personGroup") ?? -1
        var g = PersonGroupRecord(name: name, sortOrder: last + 1)
        try g.insert(db)
        return g.id!
    }

    public static func find(_ name: String, db: Database) throws -> Int64? {
        let k = PersonNames.key(name)
        guard !k.isEmpty else { return nil }
        return try Row.fetchAll(db, sql: "SELECT id, name FROM personGroup").first { PersonNames.key($0["name"]) == k }?["id"]
    }

    public static func rename(_ id: Int64, to rawName: String, db: Database) throws {
        let name = PersonNames.clean(rawName)
        guard !name.isEmpty else { return }
        try db.execute(sql: "UPDATE personGroup SET name = ? WHERE id = ?", arguments: [name, id])
    }

    public static func delete(_ id: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM personGroup WHERE id = ?", arguments: [id])
    }

    /// Puts people on a list, or takes them off it.
    public static func set(_ group: Int64, people: [Int64], member: Bool, db: Database) throws {
        for p in people {
            if member {
                try db.execute(sql: "INSERT OR IGNORE INTO personGroupMember (groupId, personId) VALUES (?, ?)", arguments: [group, p])
            } else {
                try db.execute(sql: "DELETE FROM personGroupMember WHERE groupId = ? AND personId = ?", arguments: [group, p])
            }
        }
    }

    /// Pins people (they sort first everywhere) or unpins them.
    public static func pin(_ people: [Int64], _ on: Bool, db: Database) throws {
        let list = people.map(String.init).joined(separator: ",")
        guard !list.isEmpty else { return }
        if on {
            try db.execute(sql: "UPDATE person SET pinnedAt = ? WHERE id IN (\(list)) AND pinnedAt IS NULL", arguments: [Date().timeIntervalSince1970])
        } else {
            try db.execute(sql: "UPDATE person SET pinnedAt = NULL WHERE id IN (\(list))")
        }
    }

    /// When people are merged, the survivor keeps every list and the pin any of them had.
    static func merge(_ others: [Int64], into target: Int64, db: Database) throws {
        let list = others.map(String.init).joined(separator: ",")
        guard !list.isEmpty else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO personGroupMember (groupId, personId) SELECT DISTINCT groupId, ? FROM personGroupMember WHERE personId IN (\(list))", arguments: [target])
        try db.execute(sql: "DELETE FROM personGroupMember WHERE personId IN (\(list))")
        try db.execute(sql: "UPDATE person SET pinnedAt = COALESCE(pinnedAt, (SELECT MIN(pinnedAt) FROM person WHERE id IN (\(list)))) WHERE id = ?", arguments: [target])
    }
}
