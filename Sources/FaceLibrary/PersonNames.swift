import Foundation
import GRDB

/// One name, one person. Names typed in the app are precomposed (NFC) while folder names read from disk are often
/// decomposed, and SQLite's NOCASE only folds ASCII ("Đức" vs "đức"), so names are compared here, not in SQL.
public enum PersonNames {
    /// Trimmed and precomposed: how a name is stored.
    public static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// Equal for the same name in any case or Unicode form.
    public static func key(_ name: String) -> String { clean(name).lowercased() }

    /// The person already called `name`, other than `excluding`.
    static func find(_ name: String, excluding: Int64? = nil, db: Database) throws -> Int64? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        return try Row.fetchAll(db, sql: "SELECT id, name FROM person WHERE name IS NOT NULL ORDER BY id")
            .first { ($0["id"] as Int64) != excluding && key($0["name"]) == k }?["id"]
    }

    /// Moves everything of `others` onto `target` (faces, "not this person" marks, delivery rules and their
    /// history, smart albums), then deletes `others`.
    static func merge(_ others: [Int64], into target: Int64, db: Database) throws {
        let others = others.filter { $0 != target }
        guard !others.isEmpty else { return }
        let list = others.map(String.init).joined(separator: ",")
        try db.execute(sql: "UPDATE face SET personId = ? WHERE personId IN (\(list))", arguments: [target])
        try db.execute(sql: "UPDATE face SET rejectedPersonId = ? WHERE rejectedPersonId IN (\(list))", arguments: [target])
        try db.execute(sql: "UPDATE person SET coverFaceId = (SELECT coverFaceId FROM person WHERE id IN (\(list)) AND coverFaceId IS NOT NULL LIMIT 1) WHERE id = ? AND coverFaceId IS NULL", arguments: [target])
        // Rules follow the person instead of being deleted with them (the foreign key cascades).
        try db.execute(sql: "UPDATE deliveryRule SET personId = ? WHERE personId IN (\(list))", arguments: [target])
        try db.execute(sql: "UPDATE OR IGNORE delivery SET personId = ? WHERE personId IN (\(list))", arguments: [target])
        try db.execute(sql: "DELETE FROM delivery WHERE personId IN (\(list))")
        let set = Set(others)
        for var album in try SmartAlbum.fetchAll(db) {
            var q = album.mediaQuery
            guard q.people.contains(where: set.contains) else { continue }
            var seen: Set<Int64> = []
            q.people = q.people.map { set.contains($0) ? target : $0 }.filter { seen.insert($0).inserted }
            album.query = String(decoding: (try? JSONEncoder().encode(q)) ?? Data(), as: UTF8.self)
            try album.update(db)
        }
        try db.execute(sql: "DELETE FROM person WHERE id IN (\(list))")
    }

    /// Cleans every stored name and merges people whose names are the same. Returns the people merged into.
    @discardableResult
    static func mergeDuplicates(db: Database) throws -> Set<Int64> {
        let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM person WHERE name IS NOT NULL ORDER BY id")
        var groups: [String: [Int64]] = [:]
        for r in rows {
            let name: String = r["name"], id: Int64 = r["id"]
            let cleaned = clean(name)
            if cleaned.isEmpty {
                try db.execute(sql: "UPDATE person SET name = NULL WHERE id = ?", arguments: [id])
                continue
            }
            if cleaned != name { try db.execute(sql: "UPDATE person SET name = ? WHERE id = ?", arguments: [cleaned, id]) }
            groups[key(cleaned), default: []].append(id)
        }
        var merged: Set<Int64> = []
        for ids in groups.values where ids.count > 1 {
            try merge(Array(ids.dropFirst()), into: ids[0], db: db)
            merged.insert(ids[0])
        }
        return merged
    }
}
