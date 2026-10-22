import Foundation
import GRDB
import MediaKit

/// Lightroom's colour labels (keys 6-9, purple from the menu).
public enum ColorLabel: String, CaseIterable, Codable, Sendable {
    case red, yellow, green, blue, purple
    /// The label text Lightroom and Bridge write in xmp:Label.
    public var xmpName: String { rawValue.capitalized }
}

/// Pick (P), reject (X) or neither (U).
public enum PickFlag: Int, Codable, Sendable {
    case none = 0, pick = 1, reject = -1
}

/// One culling change to a set of files.
public enum MarkChange: Hashable, Sendable {
    case rating(Int)
    case label(ColorLabel?)
    case flag(PickFlag)
}

/// Culling marks: star ratings, colour labels and pick/reject flags. They live in the library, so marking is instant,
/// works for videos and network shares, and never touches the files; `LibraryService.writeMarksToFiles` copies them
/// into the photos' XMP when the user asks.
public enum Marks {
    public static func apply(_ change: MarkChange, to mediaIds: [Int64], db: Database) throws {
        guard !mediaIds.isEmpty else { return }
        let ids = mediaIds.map(String.init).joined(separator: ",")
        switch change {
        case .rating(let r): try db.execute(sql: "UPDATE media SET rating = ? WHERE id IN (\(ids))", arguments: [max(0, min(5, r))])
        case .label(let l): try db.execute(sql: "UPDATE media SET label = ? WHERE id IN (\(ids))", arguments: [l?.rawValue])
        case .flag(let f): try db.execute(sql: "UPDATE media SET flag = ? WHERE id IN (\(ids))", arguments: [f.rawValue])
        }
    }

    /// Writes each photo's marks into its XMP (a reject as rating -1), then records the file's new size, date and
    /// fingerprint so the library sees the same file, not a changed one to process again (which would drop its faces).
    /// Videos and RAW files are skipped. Call while the folder watchers are held.
    static func writeToFiles(_ mediaIds: [Int64], store: LibraryStore) throws -> (written: Int, skipped: Int) {
        guard !mediaIds.isEmpty else { return (0, 0) }
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path, kind, rating, label, flag FROM media WHERE id IN (\(mediaIds.map(String.init).joined(separator: ",")))")
        }
        var written = 0
        for r in rows where (r["kind"] as String) == MediaKind.photo.rawValue {
            let url = URL(fileURLWithPath: r["path"], isDirectory: false)
            let rating: Int = (r["flag"] as Int) == PickFlag.reject.rawValue ? -1 : r["rating"]
            guard (try? Metadata.writeRating(rating, label: (r["label"] as String?).flatMap(ColorLabel.init)?.xmpName, to: url)) == true,
                  let v = try? URL(fileURLWithPath: url.path, isDirectory: false).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { continue }
            let size = Int64(v.fileSize ?? 0)
            try store.db.write { db in
                try db.execute(sql: "UPDATE media SET size = ?, mtime = ?, contentKey = ? WHERE id = ?",
                               arguments: [size, v.contentModificationDate?.timeIntervalSince1970 ?? 0, ContentKey.compute(url, size: size), r["id"] as Int64])
            }
            written += 1
        }
        return (written, mediaIds.count - written)
    }
}

extension LibraryService {
    /// Copies the files' ratings and labels into their XMP for Lightroom and Bridge (see `Marks.writeToFiles`).
    /// Call it off the main thread.
    public func writeMarksToFiles(_ mediaIds: [Int64]) throws -> (written: Int, skipped: Int) {
        try holdingMonitors { try Marks.writeToFiles(mediaIds, store: store) }
    }
}
