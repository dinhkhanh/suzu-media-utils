import FaceCore
import Foundation
import GRDB

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
    }

    public struct Plan: Sendable {
        public var items: [Item] = []
        /// Already in the person's folder.
        public var alreadyThere = 0
        public var photos: Int { items.filter { !MediaKindHint.isVideo($0.from) }.count }
        public var videos: Int { items.count - photos }
        public var sharedCount: Int { items.filter(\.alsoHasOtherNamedPeople).count }
        public var copies: Int { items.filter { $0.operation == .copy }.count }
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
    public func plan(personId: Int64, name: String, base: URL?, mode: ExportMode = .copy) throws -> Plan {
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
                                   alsoHasOtherNamedPeople: r["shared"], operation: mode, personName: name))
        }
        return plan
    }

    /// Every given person's files into "<base>/<Name>/" in one go. With `.move`, a file showing several of these
    /// people is moved to the folder of the one whose face is largest in it and copied into the others' folders,
    /// so no one's folder loses it.
    public func planAll(people: [(id: Int64, name: String)], base: URL?, mode: ExportMode) throws -> Plan {
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
                let op: ExportMode = (mode == .move && !moveUsed && k == 0) ? .move : .copy
                if op == .move { moveUsed = true }
                plan.items.append(Item(mediaId: r["id"], from: from, to: dir.appendingPathComponent(from.lastPathComponent),
                                       alsoHasOtherNamedPeople: ordered.count > 1, operation: op, personName: name))
            }
        }
        // Copies read the original, so they run before the move of the same file.
        plan.items.sort { ($0.operation == .copy ? 0 : 1, $0.mediaId) < ($1.operation == .copy ? 0 : 1, $1.mediaId) }
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
                switch item.operation {
                case .move:
                    try fm.moveItem(at: item.from, to: dest)
                    try store.db.write { db in
                        try db.execute(sql: "UPDATE media SET path = ?, sourceId = ? WHERE id = ?",
                                       arguments: [dest.path, try Self.sourceId(for: dest, db: db), item.mediaId])
                    }
                case .copy:
                    try fm.copyItem(at: item.from, to: dest)
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

    /// Registers the copy as a duplicate right away, so the folder scan neither re-processes it nor shows it twice.
    func recordCopy(of mediaId: Int64, at dest: URL) throws {
        try store.db.write { db in
            guard var original = try MediaRecord.fetchOne(db, key: mediaId) else { return }
            if original.contentKey == nil {
                original.contentKey = ContentKey.compute(original.url, size: original.size)
                try original.update(db)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            var copy = MediaRecord(sourceId: try Self.sourceId(for: dest, db: db), path: dest.path, kind: original.kind,
                                   size: original.size,
                                   mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                                   contentKey: original.contentKey)
            copy.duplicateOf = mediaId
            copy.status = .done
            try copy.insert(db, onConflict: .replace)
        }
    }
}

enum MediaKindHint {
    static func isVideo(_ url: URL) -> Bool { VideoSampler.extensions.contains(url.pathExtension.lowercased()) }
}
