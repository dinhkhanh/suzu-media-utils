import FaceCore
import Foundation
import GRDB
import MediaKit

/// "When new photos of <person> arrive, copy them to <folder> (optionally edited) and/or tell me."
public struct DeliveryRule: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "deliveryRule"
    public var id: Int64?
    /// nil = every named person.
    public var personId: Int64?
    /// Base folder; each person gets "<folder>/<Name>/". nil = notify only.
    public var folder: String?
    public var recipe: String?
    public var writeNames = true
    public var enabled = true
    public var createdAt = Date()
    /// Only files of this project; nil = every project.
    public var projectId: Int64?

    public init(personId: Int64?, folder: String?, recipe: EditRecipe?, writeNames: Bool, projectId: Int64? = nil) {
        self.personId = personId
        self.projectId = projectId
        self.folder = folder
        self.recipe = recipe.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        self.writeNames = writeNames
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var editRecipe: EditRecipe? { recipe.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: Data($0.utf8)) } }
}

/// Runs delivery rules. Only called while no new file is waiting, one small batch at a time, so delivering never
/// slows face recognition or grouping.
public struct DeliveryService: Sendable {
    let store: LibraryStore

    public struct Report: Sendable {
        /// Person name -> new files (delivered or, for notify-only rules, just found).
        public var newFiles: [String: Int] = [:]
        public var copied = 0
        public var failed: [(String, String)] = []
        public var remaining = 0
    }

    public init(store: LibraryStore) { self.store = store }

    /// Adds a rule. Unless `includeExisting`, files already in the library count as delivered.
    @discardableResult
    public func add(_ rule: DeliveryRule, includeExisting: Bool) throws -> DeliveryRule {
        var r = rule
        try store.db.write { db in
            try r.insert(db)
            if !includeExisting {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO delivery (ruleId, mediaId, personId, deliveredAt)
                    SELECT ?, f.mediaId, f.personId, ? FROM face f JOIN person p ON p.id = f.personId
                    WHERE p.name IS NOT NULL AND (? IS NULL OR f.personId = ?)
                    GROUP BY f.mediaId, f.personId
                    """, arguments: [r.id, Date(), r.personId, r.personId])
            }
        }
        return r
    }

    /// (file, person) pairs a rule hasn't handled yet.
    func pending(_ rule: DeliveryRule, limit: Int) throws -> [(mediaId: Int64, personId: Int64, name: String)] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.mediaId, f.personId, p.name FROM face f
                JOIN person p ON p.id = f.personId JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE p.name IS NOT NULL AND (? IS NULL OR f.personId = ?) AND m.status = 'done' AND m.duplicateOf IS NULL
                  AND \(ProjectScope.sql(rule.projectId))
                  AND NOT EXISTS (SELECT 1 FROM delivery d WHERE d.ruleId = ? AND d.mediaId = f.mediaId AND d.personId = f.personId)
                GROUP BY f.mediaId, f.personId
                ORDER BY f.mediaId
                LIMIT ?
                """, arguments: [rule.personId, rule.personId, rule.id, limit])
                .map { (mediaId: $0["mediaId"], personId: $0["personId"], name: $0["name"]) }
        }
    }

    /// Handles up to `batch` new files per rule.
    public func run(batch: Int = 25) throws -> Report {
        var report = Report()
        let rules = try store.db.read { db in try DeliveryRule.filter(sql: "enabled = 1").fetchAll(db) }
        let exporter = Exporter(store: store)
        for rule in rules {
            let pairs = try pending(rule, limit: batch)
            guard !pairs.isEmpty else { continue }
            if let folder = rule.folder {
                var opts = Exporter.Options()
                opts.recipe = rule.editRecipe
                opts.writeNames = rule.writeNames
                let plan = try exporter.planPairs(pairs, base: URL(fileURLWithPath: folder, isDirectory: true), options: opts)
                let r = exporter.run(plan, policy: .skip)
                report.copied += r.done
                report.failed += r.failed
            }
            try store.db.write { db in
                for p in pairs {
                    try db.execute(sql: "INSERT OR IGNORE INTO delivery (ruleId, mediaId, personId, deliveredAt) VALUES (?, ?, ?, ?)",
                                   arguments: [rule.id, p.mediaId, p.personId, Date()])
                }
            }
            for p in pairs { report.newFiles[p.name, default: 0] += 1 }
            report.remaining += try pending(rule, limit: 1).count
        }
        return report
    }
}
