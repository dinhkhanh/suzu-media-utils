import FaceCore
import Foundation
import GRDB
import MediaKit

/// "When new files match <query>, copy them (optionally edited) into <folder> and/or tell me."
///
/// The trigger is a smart-album query (people, solo or group shots, photos or videos, best shots only…), so a
/// rule can be "best solo shots of anyone" as well as "photos of Minh". The actions are the edit recipe (auto
/// tone, level, crop, watermark, resize), names written into the files, and a notification. In a project shared
/// with a team the rule runs on every Mac, each handling the files it processed.
public struct DeliveryRule: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "deliveryRule"

    /// Where copies go inside the folder.
    public enum Layout: String, Codable, Sendable, CaseIterable {
        /// "<folder>/<Person>/": a file showing two named people lands in both folders.
        case person
        /// "<folder>/": every matching file, once.
        case flat
    }

    public var id: Int64?
    /// Stable across Macs (team sync).
    public var uuid: String = SyncIds.new()
    /// Shown in the list; nil = described from the query.
    public var name: String?
    /// Rules made before queries existed: nil = every named person. Newer rules use `query`.
    public var personId: Int64?
    /// JSON MediaQuery (people, crowd, kind, best shots…); its project is `projectId`.
    public var query: String?
    /// Base folder. nil = notify only.
    public var folder: String?
    public var layout = Layout.person
    public var recipe: String?
    public var writeNames = true
    public var enabled = true
    public var createdAt = Date()
    /// Only files of this project; nil = every project.
    public var projectId: Int64?
    /// Last change, seconds since 1970 (a teammate's newer version of the rule wins).
    public var updatedAt: Double = Date().timeIntervalSince1970
    /// Set instead of deleting the row, so teammates' Macs delete it too.
    public var deletedAt: Double?

    public init(personId: Int64?, folder: String?, recipe: EditRecipe?, writeNames: Bool, projectId: Int64? = nil) {
        var q = MediaQuery()
        if let personId { q.people = [personId]; q.match = .any }
        self.init(name: nil, query: q, folder: folder, layout: .person, recipe: recipe, writeNames: writeNames, projectId: projectId)
    }

    public init(name: String?, query: MediaQuery, folder: String?, layout: Layout, recipe: EditRecipe?, writeNames: Bool, projectId: Int64?) {
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.projectId = projectId
        var q = query
        q.project = projectId
        self.query = String(decoding: (try? JSONEncoder().encode(q)) ?? Data(), as: UTF8.self)
        self.folder = folder
        self.layout = layout
        self.recipe = recipe.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        self.writeNames = writeNames
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var editRecipe: EditRecipe? { recipe.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: Data($0.utf8)) } }

    /// The trigger, always scoped to the rule's project; older per-person rules become a query for that person.
    public var mediaQuery: MediaQuery {
        var q = query.flatMap { try? JSONDecoder().decode(MediaQuery.self, from: Data($0.utf8))
        } ?? {
            var q = MediaQuery()
            if let personId { q.people = [personId]; q.match = .any }
            return q
        }()
        q.project = projectId
        return q
    }

    public mutating func setQuery(_ q: MediaQuery) {
        var q = q
        q.project = projectId
        query = String(decoding: (try? JSONEncoder().encode(q)) ?? Data(), as: UTF8.self)
    }

    public mutating func setRecipe(_ r: EditRecipe?) {
        recipe = r.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Name for the list and for notifications when the rule has none.
    public func displayName(people: (Int64) -> String?) -> String {
        if let name { return name }
        let q = mediaQuery
        var parts: [String] = []
        if q.people.isEmpty { parts.append(layout == .person ? "Everyone with a name" : "All files") }
        else { parts.append(q.people.compactMap(people).joined(separator: q.match == .all ? " + " : ", ")) }
        if q.crowd == .solo { parts.append("solo") } else if q.crowd == .group { parts.append("group shots") }
        if let k = q.kind { parts.append(k == .photo ? "photos" : "videos") }
        if q.bestOnly { parts.append("best shots") }
        return parts.joined(separator: " · ")
    }
}

/// Runs rules. Only called while no new file is waiting, one small batch at a time, so delivering never slows face
/// recognition or grouping.
public struct DeliveryService: Sendable {
    let store: LibraryStore

    public struct Report: Sendable {
        /// Person (or rule) name -> new files (delivered or, for notify-only rules, just found).
        public var newFiles: [String: Int] = [:]
        public var copied = 0
        public var failed: [(String, String)] = []
        public var remaining = 0
    }

    /// A file a rule still has to handle; `personId` 0 for a flat rule (the file itself, not a person's copy).
    public struct Pending: Hashable, Sendable {
        public var mediaId: Int64
        public var personId: Int64
        public var name: String
    }

    public init(store: LibraryStore) { self.store = store }

    /// Adds a rule. Unless `includeExisting`, files already in the library count as delivered.
    @discardableResult
    public func add(_ rule: DeliveryRule, includeExisting: Bool) throws -> DeliveryRule {
        var r = rule
        r.updatedAt = SyncIds.stamp(after: nil)
        try store.db.write { db in try r.insert(db) }
        if !includeExisting { try markDelivered(try pending(r, limit: nil), rule: r.id!) }
        return r
    }

    /// Changes a rule in place (its files already delivered stay delivered).
    public func update(_ rule: DeliveryRule) throws {
        var r = rule
        r.updatedAt = SyncIds.stamp(after: rule.updatedAt)
        try store.db.write { db in try r.update(db) }
    }

    /// Hides the rule and stops it; the row stays so teammates' Macs delete it too.
    public func delete(_ rule: DeliveryRule) throws {
        let now = SyncIds.stamp(after: rule.updatedAt)
        try store.db.write { db in
            try db.execute(sql: "UPDATE deliveryRule SET deletedAt = ?, updatedAt = ?, enabled = 0 WHERE id = ?", arguments: [now, now, rule.id])
            try db.execute(sql: "DELETE FROM delivery WHERE ruleId = ?", arguments: [rule.id])
        }
    }

    /// Rules in use (not deleted), oldest first.
    public static func rules(_ db: Database) throws -> [DeliveryRule] {
        try DeliveryRule.filter(sql: "deletedAt IS NULL").order(Column("createdAt")).fetchAll(db)
    }

    func markDelivered(_ items: [Pending], rule: Int64) throws {
        guard !items.isEmpty else { return }
        try store.db.write { db in
            for p in items {
                try db.execute(sql: "INSERT OR IGNORE INTO delivery (ruleId, mediaId, personId, deliveredAt) VALUES (?, ?, ?, ?)",
                               arguments: [rule, p.mediaId, p.personId, Date()])
            }
        }
    }

    /// Files (and, per person, copies) the rule hasn't handled yet, oldest file first.
    func pending(_ rule: DeliveryRule, limit: Int?) throws -> [Pending] {
        let q = rule.mediaQuery
        let hits = try q.run(store)
        guard !hits.isEmpty else { return [] }
        let done = Set(try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT mediaId, personId FROM delivery WHERE ruleId = ?", arguments: [rule.id])
                .map { "\($0["mediaId"] as Int64)|\($0["personId"] as Int64)" }
        })
        var out: [Pending] = []
        switch rule.layout {
        case .flat:
            let name = rule.displayName { _ in nil }
            for h in hits where !done.contains("\(h.id)|0") {
                out.append(Pending(mediaId: h.id, personId: 0, name: name))
                if let limit, out.count >= limit { break }
            }
        case .person:
            // A copy per named person in the file (only the searched people when the rule names some).
            let only = q.people.isEmpty ? "" : "AND f.personId IN (\(q.people.map(String.init).joined(separator: ",")))"
            let order = Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($0.element.id, $0.offset) })
            let rows = try store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT f.mediaId, f.personId, p.name FROM face f JOIN person p ON p.id = f.personId
                    WHERE f.mediaId IN (\(hits.map { String($0.id) }.joined(separator: ","))) AND p.name IS NOT NULL \(only)
                    GROUP BY f.mediaId, f.personId
                    """)
            }
            .map { Pending(mediaId: $0["mediaId"], personId: $0["personId"], name: $0["name"]) }
            .sorted { (order[$0.mediaId] ?? 0, $0.personId) < (order[$1.mediaId] ?? 0, $1.personId) }
            for p in rows where !done.contains("\(p.mediaId)|\(p.personId)") {
                out.append(p)
                if let limit, out.count >= limit { break }
            }
        }
        return out
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
        let rules = try store.db.read { db in try Self.rules(db).filter(\.enabled) }
        let exporter = Exporter(store: store)
        for rule in rules {
            guard let ruleId = rule.id else { continue }
            // Pairs that failed recently wait their turn; they don't block newer files.
            let retry = Self.retries
            let skip = retry.waiting(ruleId)
            let candidates = try pending(rule, limit: batch + skip + 1)
                .filter { !retry.isWaiting(RetryBook.key(ruleId, $0.mediaId, $0.personId)) }
            let items = Array(candidates.prefix(batch))
            guard !items.isEmpty else { continue }
            var delivered = items
            if let folder = rule.folder {
                let base = URL(fileURLWithPath: folder, isDirectory: true)
                var isDir: ObjCBool = false
                // Unmounted drive or share: try the whole batch again later (and don't create the path on the Mac's disk).
                guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else { continue }
                var opts = Exporter.Options()
                opts.recipe = rule.editRecipe
                opts.writeNames = rule.writeNames
                let plan = rule.layout == .flat
                    ? try exporter.planFlat(items.map(\.mediaId), base: base, options: opts)
                    : try exporter.planPairs(items.map { ($0.mediaId, $0.personId, $0.name) }, base: base, options: opts)
                // Two cameras' IMG_0001.JPG for the same person: keep both. The same file already there counts as done.
                let r = exporter.run(plan, policy: .keepBoth)
                report.copied += r.done
                report.failed += r.failed
                let ok = Set(r.handled.map { "\(plan.items[$0].mediaId)|\(plan.items[$0].personId ?? 0)" })
                let planned = Set(plan.items.map { "\($0.mediaId)|\($0.personId ?? 0)" })
                // Delivered: copied, already there, or no longer a file to copy (gone from the library).
                delivered = items.filter { ok.contains("\($0.mediaId)|\($0.personId)") || !planned.contains("\($0.mediaId)|\($0.personId)") }
                for p in items where !delivered.contains(p) {
                    retry.later(RetryBook.key(ruleId, p.mediaId, p.personId))
                }
            }
            try markDelivered(delivered, rule: ruleId)
            for p in delivered {
                retry.clear(RetryBook.key(ruleId, p.mediaId, p.personId))
                report.newFiles[p.name, default: 0] += 1
            }
            if candidates.count > items.count { report.remaining += 1 }
        }
        return report
    }
}
