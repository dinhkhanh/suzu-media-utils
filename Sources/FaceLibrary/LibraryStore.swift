import Foundation
import GRDB

/// The on-disk library: SQLite database plus face preview crops.
public final class LibraryStore: @unchecked Sendable {
    public let db: DatabasePool
    public let directory: URL
    public let facesDirectory: URL

    /// `~/Library/Application Support/SuZu Media Utils/Face Grouping`. A library from the earlier stand-alone
    /// "Face Grouping" app is copied over on first use; the old folder is left in place as a backup.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("SuZu Media Utils", isDirectory: true)
            .appendingPathComponent("Face Grouping", isDirectory: true)
        let legacy = support.appendingPathComponent("FaceGrouping", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.appendingPathComponent("library.sqlite").path) {
            try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: legacy, to: dir)
        }
        return dir
    }

    public init(directory: URL = LibraryStore.defaultDirectory) throws {
        self.directory = directory
        facesDirectory = directory.appendingPathComponent("faces", isDirectory: true)
        try FileManager.default.createDirectory(at: facesDirectory, withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        db = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path, configuration: config)
        try Self.migrator.migrate(db)
    }

    public func faceCropURL(_ faceId: Int64) -> URL {
        facesDirectory.appendingPathComponent("\(faceId).jpg")
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("kind", .text).notNull().defaults(to: "media")
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "media") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("source", onDelete: .cascade)
                t.column("path", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("contentKey", .text).indexed()
                t.column("duplicateOf", .integer).indexed().references("media", onDelete: .setNull)
                t.column("status", .text).notNull().indexed()
                t.column("error", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("duration", .double)
            }
            try db.create(table: "person") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "face") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("media", onDelete: .cascade).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("w", .double).notNull()
                t.column("h", .double).notNull()
                t.column("quality", .double)
                t.column("time", .double)
                t.column("embedding", .blob)
                t.column("track", .integer)
                t.belongsTo("person", onDelete: .setNull)
                t.column("assignment", .text).notNull()
                t.column("rejectedPersonId", .integer)
            }
        }
        m.registerMigration("v2-celebrity") { db in
            // One Rekognition answer per face (name nil = no celebrity found), so no face is ever paid for twice.
            try db.create(table: "celebrityLookup") { t in
                t.primaryKey("faceId", .integer).references("face", onDelete: .cascade)
                t.column("name", .text)
                t.column("celebrityId", .text)
                t.column("confidence", .double)
                t.column("urls", .text)
                t.column("lookedUpAt", .datetime).notNull()
            }
        }
        return m
    }
}

/// Canonical absolute path (symlinks resolved, including /var -> /private/var), so a file has exactly one path.
public func canonicalPath(_ url: URL) -> String {
    guard let p = realpath(url.path, nil) else { return url.standardizedFileURL.path }
    defer { free(p) }
    return String(cString: p)
}
