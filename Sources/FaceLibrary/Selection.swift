import FaceCore
import Foundation
import GRDB
import MediaKit

/// Files chosen by person, for the batch tools: each with the person, everyone named in it, and where they are.
public struct PersonFile: Sendable, Hashable {
    public var mediaId: Int64
    public var url: URL
    public var isVideo: Bool
    public var personName: String
    public var people: [String]
    public var takenAt: Date?
    public var focus: FocusHint?
    public static func == (a: PersonFile, b: PersonFile) -> Bool { a.mediaId == b.mediaId && a.personName == b.personName }
    public func hash(into h: inout Hasher) { h.combine(mediaId); h.combine(personName) }
}

public enum Selection {
    /// Every face in each photo (not video frames), so a crop keeps everyone in the shot, not only the chosen person.
    public static func faceBoxes(_ db: Database, mediaIds: some Collection<Int64>) throws -> [Int64: [(id: Int64, box: CGRect)]] {
        guard !mediaIds.isEmpty else { return [:] }
        var out: [Int64: [(id: Int64, box: CGRect)]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT id, mediaId, x, y, w, h FROM face WHERE time IS NULL AND mediaId IN (\(mediaIds.map(String.init).joined(separator: ",")))
            """) {
            out[r["mediaId"], default: []].append((r["id"], CGRect(x: r["x"] as Double, y: r["y"] as Double, width: r["w"] as Double, height: r["h"] as Double)))
        }
        return out
    }

    /// Crop focus on one face, with the photo's other faces.
    public static func focus(face: Int64, box: CGRect, in faces: [(id: Int64, box: CGRect)]?) -> FocusHint {
        FocusHint(primary: box, others: (faces ?? []).filter { $0.id != face }.map(\.box))
    }

    /// The files of the given people (best first per person), optionally only photos or videos, the best N, and the
    /// best of each burst. Reads only the database, so it's fast even for NAS libraries.
    public static func files(_ store: LibraryStore, personIds: [Int64], kind: MediaKind?, topN: Int?, bestOfBurst: Bool,
                             project: Int64? = nil, taken: ClosedRange<Double>? = nil) throws -> [PersonFile] {
        guard !personIds.isEmpty else { return [] }
        let ids = personIds.map(String.init).joined(separator: ",")
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.kind, m.takenAt, m.burstId, p.id AS pid, p.name, f.id AS faceId, f.x, f.y, f.w, f.h,
                       COALESCE(f.score, f.quality * 0.6, 0) AS s
                FROM face f JOIN media m ON m.id = f.mediaId JOIN person p ON p.id = f.personId LEFT JOIN source src ON src.id = m.sourceId
                WHERE f.personId IN (\(ids)) AND p.name IS NOT NULL AND m.duplicateOf IS NULL AND m.status = 'done'
                  AND \(ProjectScope.sql(project, source: "src")) AND \(EventSessions.sql(taken)) \(kind.map { "AND m.kind = '\($0.rawValue)'" } ?? "")
                ORDER BY p.name COLLATE NOCASE, \(ImageLoader.rawSQL("m.path")) DESC, s DESC
                """)
        }
        let mediaIds = Set(rows.map { $0["id"] as Int64 })
        let boxes = try store.db.read { db in try faceBoxes(db, mediaIds: mediaIds) }
        let namesByMedia = try store.db.read { db -> [Int64: [String]] in
            guard !mediaIds.isEmpty else { return [:] }
            var out: [Int64: [String]] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT DISTINCT f.mediaId, p.name FROM face f JOIN person p ON p.id = f.personId
                WHERE p.name IS NOT NULL AND f.mediaId IN (\(mediaIds.map(String.init).joined(separator: ",")))
                """) { out[r["mediaId"], default: []].append(r["name"]) }
            return out
        }
        var out: [PersonFile] = []
        for (_, group) in Dictionary(grouping: rows, by: { $0["pid"] as Int64 }).sorted(by: { ($0.value[0]["name"] as String) < ($1.value[0]["name"] as String) }) {
            var seen: Set<Int64> = [], bursts: Set<Int64> = []
            var list: [PersonFile] = []
            for r in group {
                let mid: Int64 = r["id"]
                guard seen.insert(mid).inserted else { continue }
                if bestOfBurst, let b = r["burstId"] as Int64?, !bursts.insert(b).inserted { continue }
                list.append(PersonFile(mediaId: mid, url: URL(fileURLWithPath: r["path"], isDirectory: false), isVideo: (r["kind"] as String) == "video",
                                       personName: r["name"], people: (namesByMedia[mid] ?? []).sorted(),
                                       takenAt: (r["takenAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                                       focus: focus(face: r["faceId"], box: CGRect(x: r["x"] as Double, y: r["y"] as Double, width: r["w"] as Double, height: r["h"] as Double),
                                                    in: boxes[mid])))
            }
            if let topN { list = Array(list.prefix(topN)) }
            out += list
        }
        return out
    }
}

extension Selection {
    /// What the library already knows about these files, for culling before an export: capture time, feature print
    /// (once the idle pass has made it) and the main face's sharpness and score. Files it never processed are
    /// left out, so the caller measures those itself (`ShotCuller.measure`).
    public static func measures(_ store: LibraryStore, urls: [URL]) throws -> [URL: ShotCuller.Measure] {
        guard !urls.isEmpty else { return [:] }
        // The library stores paths as scanned; /var and /private/var, or a symlinked volume, are the same file.
        var byPath: [String: URL] = [:]
        for u in urls { for p in Set([u.path, u.standardizedFileURL.path, u.resolvingSymlinksInPath().path]) { byPath[p] = byPath[p] ?? u } }
        var out: [URL: ShotCuller.Measure] = [:]
        try store.db.read { db in
            // Chunked: a selection can be thousands of files, past SQLite's parameter limit.
            for chunk in Array(byPath.keys).chunks(of: 500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for r in try Row.fetchAll(db, sql: """
                    SELECT m.path, m.takenAt, m.featurePrint,
                        (SELECT f.sharpness FROM face f WHERE f.mediaId = COALESCE(m.duplicateOf, m.id) AND f.time IS NULL AND f.w >= ?
                         ORDER BY f.w * f.h DESC LIMIT 1) AS faceSharpness,
                        (SELECT COALESCE(f.score, f.quality, 0) FROM face f WHERE f.mediaId = COALESCE(m.duplicateOf, m.id) AND f.time IS NULL AND f.w >= ?
                         ORDER BY f.w * f.h DESC LIMIT 1) AS faceScore
                    FROM media m WHERE m.status = 'done' AND m.path IN (\(marks))
                    """, arguments: StatementArguments([ShotCuller.minFaceWidth, ShotCuller.minFaceWidth] + chunk.map { $0 as DatabaseValueConvertible })) {
                    guard let url = byPath[r["path"]] else { continue }
                    let fp = (r["featurePrint"] as Data?).map(Vector.decode)
                    out[url] = ShotCuller.Measure(url: url, takenAt: (r["takenAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                                                  featurePrint: fp?.isEmpty == false ? fp : nil, blur: nil,
                                                  faceSharpness: r["faceSharpness"], faceScore: r["faceScore"])
                }
            }
        }
        return out
    }
}

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
