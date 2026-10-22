import FaceCore
import Foundation
import GRDB
import MediaKit

public enum ExportMode: String, Sendable { case copy, move }

/// What to do when the target folder already has a file with the same name.
public enum CollisionPolicy: String, Sendable, CaseIterable {
    /// Leave the existing file alone and don't write this one (never overwrites).
    case skip
    /// Keep both: write this one as "name (2).jpg" unless the existing file is identical.
    case keepBoth
}

/// Copies or moves a person's photos and videos into a folder named after them.
public struct Exporter: Sendable {
    public struct Item: Sendable {
        public var mediaId: Int64
        public var from: URL
        public var to: URL
        public var alsoHasOtherNamedPeople: Bool
        public var operation: ExportMode = .copy
        public var personName = ""
        /// Named people in the file (for metadata) and where they are (for face-aware crops).
        public var people: [String] = []
        public var focus: FocusHint?
    }

    /// Optional extras applied to every export.
    public struct Options: Sendable {
        /// Photos are rendered through this recipe (auto tone, crop, watermark, resize) as new JPEGs. Videos are
        /// copied unchanged. Implies copying: originals are never replaced by edited versions.
        public var recipe: EditRecipe?
        /// Write the names of the people in each photo into the copy's metadata (Lightroom, Photos…).
        public var writeNames = false
        /// Keep only each person's N best photos (best-shot score); nil = all.
        public var topN: Int?
        /// From a burst of near-identical shots keep only the best one.
        public var bestOfBurst = false
        public init() {}
    }

    public struct Plan: Sendable {
        public var items: [Item] = []
        /// Already in the person's folder.
        public var alreadyThere = 0
        public var photos: Int { items.filter { !MediaKindHint.isVideo($0.from) }.count }
        public var videos: Int { items.count - photos }
        public var sharedCount: Int { items.filter(\.alsoHasOtherNamedPeople).count }
        public var copies: Int { items.filter { $0.operation == .copy }.count }
        public var options = Options()
        public var moves: Int { items.filter { $0.operation == .move }.count }
    }

    public struct Result: Sendable {
        public var done = 0
        /// Not written because the target already had a file with that name (or the identical file).
        public var skippedExisting = 0
        public var failed: [(String, String)] = []
    }

    let store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    /// Folder-safe version of a person's name.
    public static func folderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    /// `base` nil means "inside each file's own source folder".
    public func plan(personId: Int64, name: String, base: URL?, mode: ExportMode = .copy, options: Options = Options()) throws -> Plan {
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, s.path AS sourcePath,
                    EXISTS (SELECT 1 FROM face f2 JOIN person p2 ON p2.id = f2.personId
                            WHERE f2.mediaId = m.id AND f2.personId != ? AND p2.name IS NOT NULL) AS shared
                FROM media m LEFT JOIN source s ON s.id = m.sourceId
                WHERE m.duplicateOf IS NULL AND COALESCE(s.kind, 'media') = 'media' AND m.id IN (SELECT mediaId FROM face WHERE personId = ?)
                ORDER BY m.path
                """, arguments: [personId, personId])
        }
        var plan = Plan()
        let folder = Self.folderName(name)
        for r in rows {
            let from = URL(fileURLWithPath: r["path"])
            let root = base ?? (r["sourcePath"] as String?).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? from.deletingLastPathComponent()
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            if from.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path {
                plan.alreadyThere += 1
                continue
            }
            plan.items.append(Item(mediaId: r["id"], from: from, to: dir.appendingPathComponent(from.lastPathComponent),
                                   alsoHasOtherNamedPeople: r["shared"], operation: options.recipe == nil ? mode : .copy, personName: name))
        }
        return try decorate(plan, personIds: [personId], options: options)
    }

    /// Every given person's files into "<base>/<Name>/" in one go. With `.move`, a file showing several of these
    /// people is moved to the folder of the one whose face is largest in it and copied into the others' folders,
    /// so no one's folder loses it.
    public func planAll(people: [(id: Int64, name: String)], base: URL?, mode: ExportMode, options: Options = Options()) throws -> Plan {
        let names = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let ids = people.map { String($0.id) }.joined(separator: ",")
        guard !ids.isEmpty else { return Plan() }
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, s.path AS sourcePath, f.personId, MAX(f.w * f.h) AS area FROM face f
                JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE f.personId IN (\(ids)) AND m.duplicateOf IS NULL AND COALESCE(s.kind, 'media') = 'media'
                GROUP BY m.id, f.personId
                ORDER BY m.path, area DESC
                """)
        }
        var plan = Plan()
        for (_, group) in Dictionary(grouping: rows, by: { $0["id"] as Int64 }).sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted { ($0["area"] as Double) > ($1["area"] as Double) }  // main subject first
            let from = URL(fileURLWithPath: ordered[0]["path"])
            var moveUsed = false
            for (k, r) in ordered.enumerated() {
                let name = names[r["personId"]]!
                let root = base ?? (r["sourcePath"] as String?).map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? from.deletingLastPathComponent()
                let dir = root.appendingPathComponent(Self.folderName(name), isDirectory: true)
                if from.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path {
                    plan.alreadyThere += 1
                    moveUsed = true  // it already lives in one person's folder: the rest get copies
                    continue
                }
                let op: ExportMode = (mode == .move && options.recipe == nil && !moveUsed && k == 0) ? .move : .copy
                if op == .move { moveUsed = true }
                plan.items.append(Item(mediaId: r["id"], from: from, to: dir.appendingPathComponent(from.lastPathComponent),
                                       alsoHasOtherNamedPeople: ordered.count > 1, operation: op, personName: name))
            }
        }
        plan = try decorate(plan, personIds: people.map(\.id), options: options)
        // Copies read the original, so they run before the move of the same file.
        plan.items.sort { ($0.operation == .copy ? 0 : 1, $0.mediaId) < ($1.operation == .copy ? 0 : 1, $1.mediaId) }
        return plan
    }

    /// Any set of files (search results, smart albums) into "<base>/<folder>/".
    public func planMedia(_ mediaIds: [Int64], folder: String, base: URL, options: Options) throws -> Plan {
        guard !mediaIds.isEmpty else { return Plan() }
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path FROM media WHERE id IN (\(mediaIds.map(String.init).joined(separator: ",")))")
        }
        let people = try store.db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT f.personId FROM face f JOIN person p ON p.id = f.personId
                WHERE p.name IS NOT NULL AND f.mediaId IN (\(mediaIds.map(String.init).joined(separator: ",")))
                """)
        }
        let dir = base.appendingPathComponent(Self.folderName(folder), isDirectory: true)
        var plan = Plan()
        for r in rows {
            let from = URL(fileURLWithPath: r["path"])
            plan.items.append(Item(mediaId: r["id"], from: from, to: dir.appendingPathComponent(from.lastPathComponent),
                                   alsoHasOtherNamedPeople: false, operation: .copy, personName: folder))
        }
        return try decorate(plan, personIds: people, options: options)
    }

    /// Specific (file, person) pairs into "<base>/<Name>/" (delivery rules). Always copies.
    public func planPairs(_ pairs: [(mediaId: Int64, personId: Int64, name: String)], base: URL, options: Options) throws -> Plan {
        guard !pairs.isEmpty else { return Plan() }
        let paths = Dictionary(uniqueKeysWithValues: try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path FROM media WHERE id IN (\(Set(pairs.map(\.mediaId)).map(String.init).joined(separator: ",")))")
        }.map { ($0["id"] as Int64, $0["path"] as String) })
        var plan = Plan()
        for p in pairs {
            guard let path = paths[p.mediaId] else { continue }
            let from = URL(fileURLWithPath: path)
            let dir = base.appendingPathComponent(Self.folderName(p.name), isDirectory: true)
            plan.items.append(Item(mediaId: p.mediaId, from: from, to: dir.appendingPathComponent(from.lastPathComponent),
                                   alsoHasOtherNamedPeople: false, operation: .copy, personName: p.name))
        }
        return try decorate(plan, personIds: Array(Set(pairs.map(\.personId))), options: options)
    }

    /// Applies Top N / best-of-burst and fills in each file's people and face positions; edited photos become .jpg.
    func decorate(_ input: Plan, personIds: [Int64], options: Options) throws -> Plan {
        var plan = input
        let mediaIds = Array(Set(plan.items.map(\.mediaId)))
        guard !mediaIds.isEmpty else { return plan }
        let list = mediaIds.map(String.init).joined(separator: ",")
        let names = Dictionary(uniqueKeysWithValues: try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM person WHERE id IN (\(personIds.map(String.init).joined(separator: ",")))")
        }.map { ($0["name"] as String? ?? "", $0["id"] as Int64) })
        let faces = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.mediaId, f.personId, f.x, f.y, f.w, f.h, COALESCE(f.score, f.quality, 0) AS s, p.name, m.burstId
                FROM face f JOIN media m ON m.id = f.mediaId LEFT JOIN person p ON p.id = f.personId
                WHERE f.mediaId IN (\(list)) AND f.time IS NULL
                """)
        }
        let byMedia = Dictionary(grouping: faces) { $0["mediaId"] as Int64 }
        func score(_ mediaId: Int64, _ personId: Int64?) -> Double {
            byMedia[mediaId]?.filter { ($0["personId"] as Int64?) == personId }.map { $0["s"] as Double }.max() ?? 0
        }
        // Per person: optionally only the best of each burst, then only the top N.
        var keep: Set<String> = []
        for (name, group) in Dictionary(grouping: plan.items, by: \.personName) {
            let pid = names[name]
            var items = group.sorted { score($0.mediaId, pid) > score($1.mediaId, pid) }
            if options.bestOfBurst {
                var seen: Set<Int64> = []
                items = items.filter { item in
                    guard let b = byMedia[item.mediaId]?.first?["burstId"] as Int64? else { return true }
                    return seen.insert(b).inserted
                }
            }
            if let n = options.topN { items = Array(items.prefix(n)) }
            for i in items { keep.insert("\(i.mediaId)|\(name)") }
        }
        plan.items = plan.items.filter { keep.contains("\($0.mediaId)|\($0.personName)") }
        for i in plan.items.indices {
            let fs = byMedia[plan.items[i].mediaId] ?? []
            plan.items[i].people = Array(Set(fs.compactMap { $0["name"] as String? })).sorted()
            func rect(_ r: Row) -> CGRect { CGRect(x: r["x"] as Double, y: r["y"] as Double, width: r["w"] as Double, height: r["h"] as Double) }
            let mine = fs.filter { ($0["name"] as String?) == plan.items[i].personName }.max { ($0["s"] as Double) < ($1["s"] as Double) }
            plan.items[i].focus = FocusHint(primary: mine.map(rect), others: fs.filter { ($0["name"] as String?) != nil && $0 != mine }.map(rect))
            if options.recipe != nil, !MediaKindHint.isVideo(plan.items[i].from) {
                plan.items[i].to = plan.items[i].to.deletingPathExtension().appendingPathExtension("jpg")
            }
        }
        plan.options = options
        return plan
    }

    public func run(_ plan: Plan, policy: CollisionPolicy = .skip, progress: (Int) -> Void = { _ in }) -> Result {
        var result = Result()
        let fm = FileManager.default
        for (i, item) in plan.items.enumerated() {
            defer { progress(i + 1) }
            do {
                try fm.createDirectory(at: item.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let dest = try Self.destination(for: item, policy: policy) else {
                    result.skippedExisting += 1
                    continue
                }
                let edit = plan.options.recipe.flatMap { MediaKindHint.isVideo(item.from) ? nil : $0 }
                if let edit {
                    try EditPipeline.render(item.from, recipe: edit, focus: item.focus, people: item.people, to: dest)
                    try recordCopy(of: item.mediaId, at: dest)
                    result.done += 1
                    continue
                }
                switch item.operation {
                case .move:
                    try fm.moveItem(at: item.from, to: dest)
                    try store.db.write { db in
                        try db.execute(sql: "UPDATE media SET path = ?, sourceId = ? WHERE id = ?",
                                       arguments: [dest.path, try Self.sourceId(for: dest, db: db), item.mediaId])
                    }
                case .copy:
                    try fm.copyItem(at: item.from, to: dest)
                    if plan.options.writeNames { _ = try? Metadata.writePeople(item.people, to: dest) }
                    try recordCopy(of: item.mediaId, at: dest)
                }
                result.done += 1
            } catch {
                result.failed.append((item.from.lastPathComponent, error.localizedDescription))
            }
        }
        return result
    }

    /// Target path, or nil to skip: with `.skip` whenever the name is taken, with `.keepBoth` only when the same
    /// file (size and content key) is already there.
    static func destination(for item: Item, policy: CollisionPolicy) throws -> URL? {
        let fm = FileManager.default
        var dest = item.to
        if policy == .skip { return fm.fileExists(atPath: dest.path) ? nil : dest }
        let size = (try fm.attributesOfItem(atPath: item.from.path)[.size] as? Int64) ?? -1
        let key = ContentKey.compute(item.from, size: size)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            if (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) == size,
               key != nil, ContentKey.compute(dest, size: size) == key { return nil }
            let stem = item.to.deletingPathExtension().lastPathComponent
            dest = item.to.deletingLastPathComponent()
                .appendingPathComponent("\(stem) (\(n))").appendingPathExtension(item.to.pathExtension)
            n += 1
        }
        return dest
    }

    static func sourceId(for url: URL, db: Database) throws -> Int64? {
        let sources = try SourceRecord.fetchAll(db)
        return sources.filter { url.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }?.id
    }

    /// Registers an exported copy (plain, tagged or edited) as derived from the original right away, so the folder
    /// scan neither re-processes it nor shows the person twice.
    func recordCopy(of mediaId: Int64, at dest: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs[.size] as? Int64) ?? 0
        let key = ContentKey.compute(dest, size: size)
        try store.db.write { db in
            guard let original = try MediaRecord.fetchOne(db, key: mediaId) else { return }
            var copy = MediaRecord(sourceId: try Self.sourceId(for: dest, db: db), path: dest.path,
                                   kind: MediaKindHint.isVideo(dest) ? .video : original.kind, size: size,
                                   mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, contentKey: key)
            copy.duplicateOf = mediaId
            copy.status = .done
            try copy.insert(db, onConflict: .replace)
        }
    }
}

enum MediaKindHint {
    static func isVideo(_ url: URL) -> Bool { VideoSampler.extensions.contains(url.pathExtension.lowercased()) }
}
