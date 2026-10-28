import Foundation
import GRDB

/// The on-disk library: SQLite database plus face preview crops.
public final class LibraryStore: @unchecked Sendable {
    public let db: DatabasePool
    public let directory: URL
    public let facesDirectory: URL
    /// Small JPEGs of every file (long side `LibraryStore.thumbnailSide`), made when a file is processed and read
    /// instead of the file when a grid shows it, so folders open as fast as the Finder's.
    public let thumbsDirectory: URL
    public static let thumbnailSide = 400

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
        thumbsDirectory = directory.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbsDirectory, withIntermediateDirectories: true)
        var config = Configuration()
        // At an event, cards copy, faces are processed, folders are exported and the team syncs at the same time:
        // every one of them reads, so readers must not queue behind each other (the default allows 5).
        config.maximumReaderCount = 12
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // WAL with synchronous=NORMAL: a commit no longer waits for the disk. The database stays consistent
            // through an app crash; only a power cut can lose the last moments' commits, which are re-derived from
            // the files anyway. With a commit per processed file and per copied file, this is what keeps three
            // jobs from stalling each other on fsync.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        db = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path, configuration: config)
        try Self.migrator.migrate(db)
    }

    public func faceCropURL(_ faceId: Int64) -> URL {
        facesDirectory.appendingPathComponent("\(faceId).jpg")
    }

    /// The thumbnail of a file (`thumbs/m<id>.jpg`); may not exist yet.
    public func thumbnailURL(_ mediaId: Int64) -> URL {
        thumbsDirectory.appendingPathComponent("m\(mediaId).jpg")
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
        m.registerMigration("v3-bestshot") { db in
            try db.alter(table: "face") { t in
                t.add(column: "eyesOpen", .double)
                t.add(column: "smile", .double)
                t.add(column: "sharpness", .double)
                t.add(column: "yaw", .double)
                t.add(column: "pitch", .double)
                /// Best-shot score 0-1 (see BestShot); higher is better.
                t.add(column: "score", .double)
            }
            try db.create(index: "face_person_score", on: "face", columns: ["personId", "score"])
            try db.alter(table: "media") { t in
                t.add(column: "takenAt", .double)  // seconds since 1970
                t.add(column: "featurePrint", .blob)
                /// Id of the first photo of a burst of near-identical shots; nil when not part of a burst.
                t.add(column: "burstId", .integer)
                /// 1 = Phase 1 analysis; 2 = adds best-shot scores, capture time and feature print.
                t.add(column: "analysisVersion", .integer).notNull().defaults(to: 1)
            }
            try db.create(index: "media_takenAt", on: "media", columns: ["takenAt"])
            try db.alter(table: "person") { t in
                /// The face the user picked as this person's picture; nil = best shot automatically.
                t.add(column: "coverFaceId", .integer).references("face", onDelete: .setNull)
            }
        }
        m.registerMigration("v4-albums-delivery") { db in
            try db.create(table: "smartAlbum") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("query", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "deliveryRule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("personId", .integer).references("person", onDelete: .cascade)  // nil = every named person
                t.column("folder", .text)  // nil = notify only
                t.column("recipe", .text)  // JSON EditRecipe, nil = plain copy
                t.column("writeNames", .boolean).notNull().defaults(to: true)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }
            /// What each rule already delivered, so nothing is sent twice.
            try db.create(table: "delivery") { t in
                t.column("ruleId", .integer).notNull().references("deliveryRule", onDelete: .cascade)
                t.column("mediaId", .integer).notNull().references("media", onDelete: .cascade)
                t.column("personId", .integer).notNull()
                t.column("deliveredAt", .datetime).notNull()
                t.primaryKey(["ruleId", "mediaId", "personId"])
            }
        }
        m.registerMigration("v5-projects") { db in
            // A project is one event: a set of folders. People (and their names) are shared by every project.
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "source") { t in
                t.add(column: "projectId", .integer).references("project", onDelete: .setNull)  // nil for known-people folders
            }
            try db.create(index: "source_projectId", on: "source", columns: ["projectId"])
            try db.alter(table: "smartAlbum") { t in t.add(column: "projectId", .integer).references("project", onDelete: .cascade) }
            /// nil = the rule covers every project.
            try db.alter(table: "deliveryRule") { t in t.add(column: "projectId", .integer).references("project", onDelete: .cascade) }
            // Folders added before projects existed become the first project; existing delivery rules keep covering
            // everything.
            let folders = try String.fetchAll(db, sql: "SELECT path FROM source WHERE kind = 'media' ORDER BY id")
            if !folders.isEmpty {
                let name = folders.count == 1 ? (folders[0] as NSString).lastPathComponent : "First Project"
                try db.execute(sql: "INSERT INTO project (name, createdAt) VALUES (?, ?)", arguments: [name, Date()])
                let pid = db.lastInsertedRowID
                try db.execute(sql: "UPDATE source SET projectId = ? WHERE kind = 'media'", arguments: [pid])
                try db.execute(sql: "UPDATE smartAlbum SET projectId = ?", arguments: [pid])
            }
        }
        m.registerMigration("v6-sessions") { db in
            /// A session's name, stored as a moment inside it (see EventSessions).
            try db.create(table: "sessionLabel") { t in
                t.column("projectId", .integer).notNull().references("project", onDelete: .cascade)
                t.column("at", .double).notNull()
                t.column("name", .text).notNull()
            }
            try db.create(index: "sessionLabel_project", on: "sessionLabel", columns: ["projectId", "at"])
        }
        m.registerMigration("v7-one-person-per-name") { db in
            // Older versions could end up with two people of the same name (different case or Unicode form, or
            // "New Person…" with a name in use). Merge them.
            try PersonNames.mergeDuplicates(db: db)
            // A copy belongs to its own project's folder: one in another project used to be hidden as "the same
            // file as" the original elsewhere. Process those on their own.
            try db.execute(sql: """
                UPDATE media SET duplicateOf = NULL, status = 'pending' WHERE id IN (
                    SELECT c.id FROM media c JOIN source cs ON cs.id = c.sourceId
                    JOIN media o ON o.id = c.duplicateOf JOIN source os ON os.id = o.sourceId
                    WHERE cs.kind = 'media' AND os.kind = 'media' AND cs.projectId IS NOT os.projectId)
                """)
        }
        m.registerMigration("v8-marks") { db in
            // Culling marks (see Marks). Not in MediaRecord, so writing a record back never resets them.
            try db.alter(table: "media") { t in
                t.add(column: "rating", .integer).notNull().defaults(to: 0)  // 0-5 stars
                t.add(column: "label", .text)  // ColorLabel
                t.add(column: "flag", .integer).notNull().defaults(to: 0)  // PickFlag
            }
        }
        m.registerMigration("v9-team-sync") { db in
            // Team sync (see TeamSync): people, session names and rules travel between Macs by a stable id, and the
            // newest change wins.
            try db.alter(table: "person") { t in
                t.add(column: "uuid", .text)
                /// When the name was last set, seconds since 1970 (a newer name from a teammate replaces an older one).
                t.add(column: "nameAt", .double)
            }
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM person") {
                try db.execute(sql: "UPDATE person SET uuid = ? WHERE id = ?", arguments: [SyncIds.new(), id])
            }
            try db.create(index: "person_uuid", on: "person", columns: ["uuid"], unique: true)
            try db.alter(table: "deliveryRule") { t in
                t.add(column: "uuid", .text)
                t.add(column: "name", .text)
                /// JSON MediaQuery; nil = the person in personId (rules made before queries).
                t.add(column: "query", .text)
                /// "person" = a folder per person; "flat" = everything into the folder.
                t.add(column: "layout", .text).notNull().defaults(to: "person")
                t.add(column: "updatedAt", .double).notNull().defaults(to: 0)
                /// Kept (not deleted) so teammates' Macs learn of the deletion.
                t.add(column: "deletedAt", .double)
            }
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM deliveryRule") {
                try db.execute(sql: "UPDATE deliveryRule SET uuid = ? WHERE id = ?", arguments: [SyncIds.new(), id])
            }
            try db.alter(table: "sessionLabel") { t in t.add(column: "updatedAt", .double).notNull().defaults(to: 0) }
            try db.create(table: "team") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("name", .text).notNull()
                /// The shared folder every Mac of the team reads and writes (NAS, Dropbox, iCloud Drive…).
                t.column("folder", .text).notNull()
                t.column("projectId", .integer).notNull().unique().references("project", onDelete: .cascade)
                t.column("joinedAt", .datetime).notNull()
            }
            /// A teammate's Mac's summary of a person's faces: the mean of their embeddings and how many.
            try db.create(table: "personRemote") { t in
                t.column("personId", .integer).notNull().references("person", onDelete: .cascade)
                t.column("teamId", .integer).notNull().references("team", onDelete: .cascade)
                t.column("deviceId", .text).notNull()
                t.column("centroid", .blob).notNull()
                t.column("count", .integer).notNull()
                t.primaryKey(["personId", "teamId", "deviceId"])
            }
            /// A person merged into another (by id), so teammates' Macs merge them too.
            try db.create(table: "personMerge") { t in
                t.primaryKey("fromUuid", .text)
                t.column("intoUuid", .text).notNull()
                t.column("at", .double).notNull()
            }
            /// Per team: what this Mac has published and how far it has read each teammate's log.
            try db.create(table: "syncState") { t in
                t.column("teamId", .integer).notNull().references("team", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.primaryKey(["teamId", "key"])
            }
            /// Changes read from a teammate that can't be applied yet (a rule naming a person not yet known).
            try db.create(table: "syncDeferred") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("teamId", .integer).notNull().references("team", onDelete: .cascade)
                t.column("op", .text).notNull()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('deviceId', ?)", arguments: [SyncIds.new()])
        }
        m.registerMigration("v10-team-projects") { db in
            // A team holds many projects: the project carries the team, not the other way round, and has a stable
            // id so it is the same project on every Mac of the team.
            try db.alter(table: "project") { t in
                t.add(column: "uuid", .text)
                t.add(column: "teamId", .integer).references("team", onDelete: .setNull)
                t.add(column: "updatedAt", .double).notNull().defaults(to: 0)
            }
            // The one project a team held so far gets the same id on every Mac of that team (derived from the
            // team's), so the logs already in the team folder keep applying to it.
            for r in try Row.fetchAll(db, sql: "SELECT id, uuid, projectId FROM team") {
                try db.execute(sql: "UPDATE project SET uuid = ?, teamId = ? WHERE id = ?",
                               arguments: [TeamSync.legacyProjectUuid(r["uuid"]), r["id"] as Int64, r["projectId"] as Int64])
            }
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM project WHERE uuid IS NULL") {
                try db.execute(sql: "UPDATE project SET uuid = ? WHERE id = ?", arguments: [SyncIds.new(), id])
            }
            try db.create(index: "project_uuid", on: "project", columns: ["uuid"], unique: true)
            try db.create(table: "team_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("folder", .text).notNull()
                t.column("joinedAt", .datetime).notNull()
            }
            try db.execute(sql: "INSERT INTO team_new (id, uuid, name, folder, joinedAt) SELECT id, uuid, name, folder, joinedAt FROM team")
            try db.execute(sql: "DROP TABLE team")
            try db.execute(sql: "ALTER TABLE team_new RENAME TO team")
        }
        m.registerMigration("v11-person-memory") { db in
            /// The mean of a named person's faces that left the library (see PersonMemory).
            try db.create(table: "personMemory") { t in
                t.column("personId", .integer).primaryKey().references("person", onDelete: .cascade)
                t.column("centroid", .blob).notNull()
                t.column("count", .integer).notNull()
            }
        }
        m.registerMigration("v12-cards") { db in
            /// A photographer's memory card, known by its volume UUID (see CardCopier), and what was copied from it.
            try db.create(table: "card") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("label", .text)
                t.column("volumeName", .text)
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("cameraSerial", .text)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastCopiedAt", .datetime)
                t.column("lastCopiedTo", .text)
            }
            try db.create(table: "cardFile") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("cardId", .integer).notNull().indexed().references("card", onDelete: .cascade)
                t.column("relPath", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("contentKey", .text).notNull().indexed()
                t.column("sha256", .text)
                t.column("copiedAt", .datetime).notNull()
                t.column("copiedTo", .text)
                t.uniqueKey(["cardId", "relPath", "contentKey"])
            }
        }
        m.registerMigration("v13-cards-sync") { db in
            /// The ledger travels with the team: `device` is the teammate's Mac an entry came from (nil = copied
            /// here, and so published); `labelAt` lets the newest name win.
            try db.execute(sql: "ALTER TABLE cardFile ADD COLUMN device TEXT")
            try db.execute(sql: "ALTER TABLE card ADD COLUMN labelAt DOUBLE")
        }
        m.registerMigration("v13-lists-pins") { db in
            /// Lists of people (cast, sponsors, VIPs…) and pinned people (see PersonGroups). This Mac's own.
            try db.alter(table: "person") { t in t.add(column: "pinnedAt", .double) }
            try db.create(table: "personGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "personGroupMember") { t in
                t.column("groupId", .integer).notNull().references("personGroup", onDelete: .cascade)
                t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
                t.primaryKey(["groupId", "personId"])
            }
        }
        m.registerMigration("v14-shared-faces") { db in
            /// One Mac can do a team's face work (`team.processorId`); the others take its results from the
            /// team folder. `media.importedFrom` is the Mac a file's faces came from.
            try db.execute(sql: "ALTER TABLE team ADD COLUMN processorId TEXT")
            try db.execute(sql: "ALTER TABLE team ADD COLUMN processorName TEXT")
            try db.execute(sql: "ALTER TABLE media ADD COLUMN importedFrom TEXT")
            /// When the file's thumbnail was written (0 = tried and couldn't), see `thumbnailURL`.
            try db.execute(sql: "ALTER TABLE media ADD COLUMN thumbAt DOUBLE")
            /// A teammate's exemplar faces of a person (Float16 rows), beside the mean.
            try db.execute(sql: "ALTER TABLE personRemote ADD COLUMN exemplars BLOB")
            /// Media whose faces this Mac has yet to publish (processed, or changed since).
            try db.create(table: "facePublish") { t in t.column("mediaId", .integer).primaryKey() }
            /// Faces whose person changed, by whoever changed it (a trigger, so no code path is missed).
            try db.create(table: "faceChange") { t in t.column("faceId", .integer).primaryKey() }
            try db.execute(sql: """
                CREATE TRIGGER faceChangeLog AFTER UPDATE OF personId, assignment, rejectedPersonId ON face
                BEGIN INSERT OR IGNORE INTO faceChange (faceId) VALUES (NEW.id); END
                """)
            /// Faces the user moved or rejected here, to tell the Mac that does the processing.
            try db.create(table: "faceEditPublish") { t in t.column("faceId", .integer).primaryKey() }
            /// Where a teammate's record for a file sits, by the file's content key, for files this Mac sees later.
            try db.create(table: "faceIndex") { t in
                t.column("teamId", .integer).notNull().references("team", onDelete: .cascade)
                t.column("contentKey", .text).notNull()
                t.column("deviceId", .text).notNull()
                t.column("file", .text).notNull()
                t.column("offset", .integer).notNull()
                t.column("length", .integer).notNull()
                t.primaryKey(["teamId", "contentKey"])
            }
        }
        m.registerMigration("v15-cover-sync") { db in
            /// When the person's picture was picked (or put back to automatic), so the choice travels to teammates
            /// and the newest wins.
            try db.execute(sql: "ALTER TABLE person ADD COLUMN coverAt DOUBLE")
        }
        m.registerMigration("v16-shared-folders") { db in
            /// A folder can be the team's (every Mac of the team gets it) or the editing Mac's (same), see
            /// `SourceShare`; a stable id makes it the same folder on every Mac.
            try db.execute(sql: "ALTER TABLE source ADD COLUMN uuid TEXT")
            try db.execute(sql: "ALTER TABLE source ADD COLUMN share TEXT NOT NULL DEFAULT 'mac'")
            try db.execute(sql: "ALTER TABLE source ADD COLUMN shareAt DOUBLE")
            try db.execute(sql: "ALTER TABLE source ADD COLUMN fromDevice TEXT")
            try db.execute(sql: "ALTER TABLE source ADD COLUMN removedAt DOUBLE")
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM source") {
                try db.execute(sql: "UPDATE source SET uuid = ? WHERE id = ?", arguments: [SyncIds.new(), id])
            }
            try db.create(index: "source_uuid", on: "source", columns: ["uuid"], unique: true)
            /// Shared folders removed here, to tell the team (the row is gone by then).
            try db.create(table: "sourceGone") { t in
                t.column("uuid", .text).primaryKey()
                t.column("projectId", .integer)
                t.column("at", .double).notNull()
            }
        }
        m.registerMigration("v17-hybrid-processing") { db in
            /// A file this Mac processes itself although another Mac does the team's face work (copied off a card
            /// here), and when the library first saw a file (the processing Mac gives a copier's record a moment
            /// to arrive before reading a fresh file from the share).
            try db.execute(sql: "ALTER TABLE media ADD COLUMN localWork BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE media ADD COLUMN seenAt DOUBLE")
        }
        m.registerMigration("v18-edited-folders") { db in
            /// A file of an edited folder: listed, never read for faces (see `LibraryService.settleEditedFolders`).
            try db.execute(sql: "ALTER TABLE media ADD COLUMN skippedAsEdited BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: "CREATE INDEX media_skippedAsEdited ON media(sourceId) WHERE skippedAsEdited")
        }
        m.registerMigration("v19-published-faces") { db in
            /// What the team folder holds for each file this Mac published (see `TeamSync.facePublished`): the
            /// processing Mac compares it with the file's faces now and publishes again whatever drifted, whatever
            /// path the change took.
            try db.create(table: "facePublished") { t in
                t.column("mediaId", .integer).primaryKey()
                t.column("sig", .text).notNull()
                t.column("boxes", .text).notNull()
                /// Learnt by reading the team folder back (libraries from before this table), not written here.
                t.column("fromShare", .boolean).notNull().defaults(to: false)
            }
            /// When a person was last pinned or unpinned, so the newest choice wins across the team.
            try db.execute(sql: "ALTER TABLE person ADD COLUMN pinAt DOUBLE")
            try db.execute(sql: "UPDATE person SET pinAt = pinnedAt WHERE pinnedAt IS NOT NULL")
        }
        m.registerMigration("v20-orphaned-copies") { db in
            /// A copy that loses its original with no face of its own (the original's folder removed, a file
            /// deleted) is read again, whichever way that happened: done with no faces, it would stay faceless.
            try db.execute(sql: """
                CREATE TRIGGER mediaOrphaned AFTER UPDATE OF duplicateOf ON media
                WHEN OLD.duplicateOf IS NOT NULL AND NEW.duplicateOf IS NULL AND NEW.status = 'done' AND NOT NEW.skippedAsEdited
                  AND NOT EXISTS (SELECT 1 FROM face WHERE mediaId = NEW.id)
                BEGIN UPDATE media SET status = 'pending' WHERE id = NEW.id; END
                """)
            try RawPairs.repair(db)
        }
        m.registerMigration("v21-saved-watermarks") { db in
            /// Saved watermarks (see SavedWatermarks), in the library so they travel to teammates; until now they
            /// were the app's own settings. A deleted one stays as a tombstone.
            try db.create(table: "watermarkPreset") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("spec", .text).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("createdAt", .double).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v22-shared-lists") { db in
            /// Lists of people travel to teammates (see PersonGroups): a stable id, when each list was named and each
            /// person put on it, and what was taken away (a deleted list, a person taken off), so an older copy
            /// elsewhere doesn't bring it back. Lists two Macs made apart under one name become one (`personGroupAlias`).
            try db.execute(sql: "ALTER TABLE personGroup ADD COLUMN uuid TEXT")
            try db.execute(sql: "ALTER TABLE personGroup ADD COLUMN updatedAt DOUBLE NOT NULL DEFAULT 1")
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM personGroup") {
                try db.execute(sql: "UPDATE personGroup SET uuid = ? WHERE id = ?", arguments: [SyncIds.new(), id])
            }
            try db.execute(sql: "CREATE UNIQUE INDEX personGroup_uuid ON personGroup(uuid)")
            try db.execute(sql: "ALTER TABLE personGroupMember ADD COLUMN at DOUBLE NOT NULL DEFAULT 1")
            try db.create(table: "personGroupGone") { t in
                t.column("uuid", .text).primaryKey()
                t.column("at", .double).notNull()
            }
            try db.create(table: "personGroupMemberGone") { t in
                t.column("groupUuid", .text).notNull()
                t.column("personUuid", .text).notNull()
                t.column("at", .double).notNull()
                t.primaryKey(["groupUuid", "personUuid"])
            }
            try db.create(table: "personGroupAlias") { t in
                t.column("fromUuid", .text).primaryKey()
                t.column("intoUuid", .text).notNull()
            }
        }
        m.registerMigration("v23-crop-retry") { db in
            /// Files taken from a teammate's face records whose crops or thumbnail couldn't all be copied yet
            /// (see `TeamSync.fetchMissingCrops`): tried again each pass until they are.
            try db.create(table: "cropRetry") { t in
                t.column("mediaId", .integer).primaryKey()
                t.column("teamId", .integer).notNull().references("team", onDelete: .cascade)
                t.column("deviceId", .text).notNull()
                t.column("contentKey", .text).notNull()
                t.column("boxes", .text).notNull()
            }
        }
        m.registerMigration("v24-saved-looks") { db in
            /// Saved looks (see SavedLooks), in the library so they travel to teammates; until now they were the
            /// app's own settings. A deleted one stays as a tombstone.
            try db.create(table: "lookPreset") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("autoTone", .boolean).notNull().defaults(to: false)
                t.column("adjustments", .text).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("createdAt", .double).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v25-nas-upload") { db in
            /// Folders on their way to the team NAS over rsync (see NASUploadQueue); the queue survives a quit.
            try db.create(table: "nasUpload") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("localFolder", .text).notNull()
                t.column("remotePath", .text).notNull()
                t.column("title", .text).notNull()
                t.column("state", .text).notNull().indexed()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("nextAttemptAt", .double).notNull().defaults(to: 0)
                t.column("marker", .text)
                t.column("deleteLocalWhenDone", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .double).notNull()
                t.column("finishedAt", .double)
            }
        }
        m.registerMigration("v26-nas-upload-files-only") { db in
            /// An event folder's loose files as a unit of their own (StagingWatcher).
            try db.alter(table: "nasUpload") { t in t.add(column: "filesOnly", .boolean).notNull().defaults(to: false) }
        }
        return m
    }
}

/// Which files a view covers: one project's photo & video folders, or every project's (nil). Known-people folders
/// never count as event files.
public enum ProjectScope {
    /// SQL condition on a joined `source` row (alias `s` by default). Media without a source count only for "all".
    public static func sql(_ project: Int64?, source s: String = "s") -> String {
        let media = "COALESCE(\(s).kind, 'media') = 'media'"
        guard let project else { return media }
        return "\(media) AND \(s).projectId = \(project)"
    }
}

/// Canonical absolute path (symlinks resolved, including /var -> /private/var), so a file has exactly one path.
public func canonicalPath(_ url: URL) -> String {
    guard let p = realpath(url.path, nil) else { return url.standardizedFileURL.path }
    defer { free(p) }
    return String(cString: p)
}
