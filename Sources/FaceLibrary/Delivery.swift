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

    /// (rule, file, person) copies that failed, and when to try them again. In memory: a relaunch retries at once.
    final class RetryBook: @unchecked Sendable {
        private let lock = NSLock()
        private var until: [String: Date] = [:]
        static func key(_ rule: Int64, _ media: Int64, _ person: Int64) -> String { "\(rule)|\(media)|\(person)" }
        func waiting(_ rule: Int64) -> Int {
            let now = Date()
            return lock.withLock { until.filter { $0.key.hasPrefix("\(rule)|") && $0.value > now }.count }
        }
        func isWaiting(_ key: String) -> Bool { lock.withLock { (until[key] ?? .distantPast) > Date() } }
        func later(_ key: String) { lock.withLock { until[key] = Date().addingTimeInterval(300) } }
        func clear(_ key: String) { lock.withLock { until[key] = nil } }
    }
    static let retries = RetryBook()

    /// Handles up to `batch` new files per rule. Only files actually copied count as delivered: a target folder
    /// that is unmounted or full is tried again later, never silently skipped.
    public func run(batch: Int = 25) throws -> Report {
        var report = Report()
        let rules = try store.db.read { db in try DeliveryRule.filter(sql: "enabled = 1").fetchAll(db) }
        let exporter = Exporter(store: store)
        for rule in rules {
            guard let ruleId = rule.id else { continue }
            // Pairs that failed recently wait their turn; they don't block newer files.
            let retry = Self.retries
            let skip = retry.waiting(ruleId)
            let candidates = try pending(rule, limit: batch + skip + 1)
                .filter { !retry.isWaiting(RetryBook.key(ruleId, $0.mediaId, $0.personId)) }
            let pairs = Array(candidates.prefix(batch))
            guard !pairs.isEmpty else { continue }
            var delivered = pairs
            if let folder = rule.folder {
                let base = URL(fileURLWithPath: folder, isDirectory: true)
                var isDir: ObjCBool = false
                // Unmounted drive or share: try the whole batch again later (and don't create the path on the Mac's disk).
                guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else { continue }
                var opts = Exporter.Options()
                opts.recipe = rule.editRecipe
                opts.writeNames = rule.writeNames
                let plan = try exporter.planPairs(pairs, base: base, options: opts)
                // Two cameras' IMG_0001.JPG for the same person: keep both. The same file already there counts as done.
                let r = exporter.run(plan, policy: .keepBoth)
                report.copied += r.done
                report.failed += r.failed
                let ok = Set(r.handled.map { "\(plan.items[$0].mediaId)|\(plan.items[$0].personId ?? -1)" })
                let planned = Set(plan.items.map { "\($0.mediaId)|\($0.personId ?? -1)" })
                // Delivered: copied, already there, or no longer a file to copy (gone from the library).
                delivered = pairs.filter { ok.contains("\($0.mediaId)|\($0.personId)") || !planned.contains("\($0.mediaId)|\($0.personId)") }
                for p in pairs where !delivered.contains(where: { $0.mediaId == p.mediaId && $0.personId == p.personId }) {
                    retry.later(RetryBook.key(ruleId, p.mediaId, p.personId))
                }
            }
            try store.db.write { db in
                for p in delivered {
                    try db.execute(sql: "INSERT OR IGNORE INTO delivery (ruleId, mediaId, personId, deliveredAt) VALUES (?, ?, ?, ?)",
                                   arguments: [ruleId, p.mediaId, p.personId, Date()])
                }
            }
            for p in delivered {
                retry.clear(RetryBook.key(ruleId, p.mediaId, p.personId))
                report.newFiles[p.name, default: 0] += 1
            }
            if candidates.count > pairs.count { report.remaining += 1 }
        }
        return report
    }
}
