import CoreGraphics
import FaceCore
import Foundation
import GRDB

/// A photo or video in a project's folders, with what the library knows about it (for the Files browser).
public struct ProjectFile: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var path: String
    public var kind: MediaKind
    public var size: Int64
    public var mtime: Double
    public var takenAt: Double?
    public var duration: Double?
    public var status: MediaStatus
    /// A byte-identical copy of another file; its faces and names are the original's.
    public var duplicate: Bool
    public var faces: Int
    /// Named people in it, sorted.
    public var people: [String]
    /// Everyone grouped in it, named or not.
    public var personIds: [Int64]
    public var rating = 0
    public var label: ColorLabel?
    public var flag = PickFlag.none
    /// The main face (the biggest in a photo) has its eyes closed.
    public var eyesClosed = false
    /// The main face is out of focus or blurred by motion.
    public var soft = false

    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: false) }

    public mutating func apply(_ change: MarkChange) {
        switch change {
        case .rating(let r): rating = max(0, min(5, r))
        case .label(let l): label = l
        case .flag(let f): flag = f
        }
    }
}

/// A face in a photo, for the culling view.
public struct MediaFace: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// Normalized to 0-1, top-left origin.
    public var box: CGRect
    public var personId: Int64?
    public var name: String?
    public var eyesOpen: Double?
    public var sharpness: Double?
}

public enum ProjectFiles {
    /// Eye openness below which a face counts as blinking (BestShot treats it as closed too).
    public static let eyesClosedBelow = 0.35
    /// Face sharpness (variance of the Laplacian) below which it counts as soft; ~40 is blurry, ~1000 crisp.
    public static let softBelow = ShotCuller.softFaceBelow
    /// Faces narrower than this share of the frame (crowds, background) don't raise hints.
    public static let hintMinFaceWidth = ShotCuller.minFaceWidth

    /// Every file of the project's photo & video folders (every project's for nil), copies included, by path; or
    /// just the files `ids`, wherever they are.
    public static func list(_ db: Database, project: Int64?, ids: [Int64]? = nil) throws -> [ProjectFile] {
        var scope = ProjectScope.sql(project)
        if let ids {
            // With the originals of copies among them, whose faces and names the copies show.
            let all = Set(ids).union(try Int64.fetchAll(db, sql: """
                SELECT duplicateOf FROM media WHERE duplicateOf IS NOT NULL AND id IN (\(ids.map(String.init).joined(separator: ",")))
                """))
            scope = "m.id IN (\(all.isEmpty ? "NULL" : all.map(String.init).joined(separator: ",")))"
        }
        // Copies have no faces of their own: count and name the original's.
        struct Faces { var count: Int; var area: Double?; var eyesOpen: Double?; var sharpness: Double? }
        var faces: [Int64: Faces] = [:]
        // The eye and sharpness columns come from the photo's biggest face (SQLite's bare columns with MAX).
        for r in try Row.fetchAll(db, sql: """
            SELECT f.mediaId, COUNT(*) AS n, MAX(CASE WHEN f.time IS NULL THEN f.w * f.h END) AS area, f.eyesOpen, f.sharpness
            FROM face f JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
            WHERE \(scope) GROUP BY f.mediaId
            """) { faces[r["mediaId"]] = Faces(count: r["n"], area: r["area"], eyesOpen: r["eyesOpen"], sharpness: r["sharpness"]) }
        var people: [Int64: [(id: Int64, name: String?)]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT DISTINCT f.mediaId, p.id, p.name FROM face f JOIN person p ON p.id = f.personId
            JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
            WHERE \(scope)
            """) { people[r["mediaId"], default: []].append((r["id"], r["name"])) }
        let minArea = hintMinFaceWidth * hintMinFaceWidth
        let wanted = ids.map(Set.init)
        return try Row.fetchAll(db, sql: """
            SELECT m.id, m.path, m.kind, m.size, m.mtime, m.takenAt, m.duration, m.status, m.duplicateOf, m.rating, m.label, m.flag
            FROM media m LEFT JOIN source s ON s.id = m.sourceId
            WHERE \(scope) ORDER BY m.path
            """).compactMap { r in
            if let wanted, !wanted.contains(r["id"]) { return nil }
            let id: Int64 = r["id"], original: Int64? = r["duplicateOf"]
            let f = faces[original ?? id], who = people[original ?? id] ?? []
            let main = (f?.area ?? 0) >= minArea ? f : nil
            return ProjectFile(id: id, path: r["path"], kind: MediaKind(rawValue: r["kind"]) ?? .photo, size: r["size"], mtime: r["mtime"],
                               takenAt: r["takenAt"], duration: r["duration"], status: MediaStatus(rawValue: r["status"]) ?? .pending,
                               duplicate: original != nil, faces: f?.count ?? 0,
                               people: who.compactMap(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                               personIds: who.map(\.id),
                               rating: r["rating"], label: (r["label"] as String?).flatMap(ColorLabel.init), flag: PickFlag(rawValue: r["flag"]) ?? .none,
                               eyesClosed: main?.eyesOpen.map { $0 < eyesClosedBelow } ?? false,
                               soft: main?.sharpness.map { $0 < softBelow } ?? false)
        }
    }

    /// The faces of a photo (a copy's are its original's), biggest first.
    public static func faces(_ db: Database, mediaId: Int64) throws -> [MediaFace] {
        try Row.fetchAll(db, sql: """
            SELECT f.id, f.x, f.y, f.w, f.h, f.personId, p.name, f.eyesOpen, f.sharpness FROM face f LEFT JOIN person p ON p.id = f.personId
            WHERE f.time IS NULL AND f.mediaId = (SELECT COALESCE(duplicateOf, id) FROM media WHERE id = ?)
            ORDER BY f.w * f.h DESC
            """, arguments: [mediaId]).map {
            MediaFace(id: $0["id"], box: CGRect(x: $0["x"] as Double, y: $0["y"] as Double, width: $0["w"] as Double, height: $0["h"] as Double),
                      personId: $0["personId"], name: $0["name"], eyesOpen: $0["eyesOpen"], sharpness: $0["sharpness"])
        }
    }

    /// What a folder holds: its subfolders (with how many files are anywhere under each) and the files directly in
    /// it, or every file under it when `recursive`. `files` is any list of files; only those under `folder` count.
    public static func contents(of folder: String, in files: [ProjectFile], recursive: Bool = false) -> (folders: [String: Int], files: [ProjectFile]) {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var folders: [String: Int] = [:]
        var direct: [ProjectFile] = []
        for f in files where f.path.hasPrefix(prefix) {
            let rest = f.path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                if recursive { direct.append(f) } else { folders[prefix + rest[..<slash], default: 0] += 1 }
            } else {
                direct.append(f)
            }
        }
        return (folders, direct)
    }
}
