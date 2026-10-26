import FaceCore
import Foundation
import GRDB

/// A camera shooting RAW+JPEG: the JPEG holds the photo's faces and the RAW is its companion (`duplicateOf` the
/// JPEG, or the JPEG's original when the JPEG is itself a copy), never processed on its own.
///
/// Libraries up to 0.8.15 have pairs that ended up as two photos: RAWs processed before pairing existed (every
/// face counted twice), and RAWs whose JPEG was a copy of a file elsewhere. When that file's folder was removed,
/// the JPEG was left done and faceless, and the RAW stood for the photo. `repair` puts them right once.
enum RawPairs {
    /// Pairs two-photo RAW+JPEG pairs again, the JPEG side keeping (or taking over) the faces with their people
    /// and pictures; then sends copies that lost their original without any face back to processing.
    static func repair(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, path, sourceId, duplicateOf, status FROM media
            WHERE kind = 'photo' AND status IN ('done', 'failed') AND NOT skippedAsEdited
            """)
        var raws: [String: (id: Int64, dup: Int64?)] = [:]
        var jpegs: [String: (id: Int64, dup: Int64?)] = [:]
        for r in rows {
            let path: String = r["path"], sid: Int64? = r["sourceId"]
            let key = "\(sid ?? 0)|\(ImageLoader.pairKey(path))"
            let entry = (id: r["id"] as Int64, dup: r["duplicateOf"] as Int64?)
            // A RAW that couldn't be read is a companion all the same; a JPEG must be done to hold the faces.
            if ImageLoader.isRaw(URL(fileURLWithPath: path, isDirectory: false)) {
                raws[key] = entry
            } else if (r["status"] as String) == MediaStatus.done.rawValue {
                // A JPEG over another kind of companion (a TIFF beside it) when there are both.
                let ext = (path as NSString).pathExtension.lowercased()
                if jpegs[key] == nil || ext == "jpg" || ext == "jpeg" { jpegs[key] = entry }
            }
        }
        for (key, raw) in raws where raw.dup == nil {
            guard let jpeg = jpegs[key] else { continue }
            let target = jpeg.dup ?? jpeg.id
            // The face holder must be a photo of its own that is done (a chain of copies is left alone).
            guard try Int64?.fetchOne(db, sql: "SELECT duplicateOf FROM media WHERE id = ? AND status = 'done'", arguments: [target]) == .some(nil) else { continue }
            try merge(raw: raw.id, into: target, db: db)
        }
        // A copy whose original left the library without handing it the faces: read again.
        try db.execute(sql: """
            UPDATE media SET status = 'pending' WHERE status = 'done' AND duplicateOf IS NULL AND takenAt IS NULL
              AND NOT skippedAsEdited AND importedFrom IS NULL AND NOT EXISTS (SELECT 1 FROM face f WHERE f.mediaId = media.id)
            """)
    }

    /// The RAW becomes the companion of `target`. Its faces go to `target` when that has none; otherwise the
    /// target's own faces stay, taking the RAW's people where they have none (or only a guess against a name given
    /// by hand), and pictures picked on the RAW move to the same face.
    static func merge(raw: Int64, into target: Int64, db: Database) throws {
        let mine = try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ? ORDER BY id", arguments: [target])
        let theirs = try FaceRecord.fetchAll(db, sql: "SELECT * FROM face WHERE mediaId = ? ORDER BY id", arguments: [raw])
        if mine.isEmpty {
            try db.execute(sql: "UPDATE face SET mediaId = ? WHERE mediaId = ?", arguments: [target, raw])
            try db.execute(sql: """
                UPDATE media SET takenAt = COALESCE(media.takenAt, r.takenAt), width = COALESCE(media.width, r.width),
                    height = COALESCE(media.height, r.height), analysisVersion = MAX(media.analysisVersion, r.analysisVersion)
                FROM (SELECT * FROM media WHERE id = ?) AS r WHERE media.id = ?
                """, arguments: [raw, target])
        } else {
            func box(_ f: FaceRecord) -> CGRect { CGRect(x: f.x, y: f.y, width: f.w, height: f.h) }
            for r in theirs {
                guard let match = mine.max(by: { Processor.iou(box($0), box(r)) < Processor.iou(box($1), box(r)) }),
                      Processor.iou(box(match), box(r)) > 0.4 else { continue }
                try db.execute(sql: "UPDATE person SET coverFaceId = ? WHERE coverFaceId = ?", arguments: [match.id, r.id])
                guard let pid = r.personId else { continue }
                let current = try FaceRecord.fetchOne(db, key: match.id)
                guard current?.personId == nil || (r.assignment == .user && current?.assignment != .user) else { continue }
                try db.execute(sql: "UPDATE face SET personId = ?, assignment = ?, rejectedPersonId = ? WHERE id = ?",
                               arguments: [pid, r.assignment.rawValue, r.rejectedPersonId, match.id])
            }
            try db.execute(sql: "DELETE FROM face WHERE mediaId = ?", arguments: [raw])
        }
        try db.execute(sql: "UPDATE media SET duplicateOf = ? WHERE duplicateOf = ?", arguments: [target, raw])
        try db.execute(sql: "UPDATE media SET duplicateOf = ?, status = 'done', error = NULL WHERE id = ?", arguments: [target, raw])
    }
}
