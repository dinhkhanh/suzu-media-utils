import CryptoKit
import Foundation
import GRDB
import MediaKit

/// A saved watermark (a logo, a banner, a text credit) to pick from in any editing screen.
public struct SavedWatermark: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var spec: WatermarkSpec
    public init(id: String = UUID().uuidString, name: String, spec: WatermarkSpec) {
        self.id = id
        self.name = name
        self.spec = spec
    }
}

/// Saved watermarks live in the library, so they travel to every Mac of the user's teams like names do (TeamSync,
/// `watermark` changes, the newest wins, a deleted one goes everywhere). The logo and banner files go with them:
/// copied into the team folder (`assets/`, named by their bytes) and from there into this Mac's own
/// `Watermarks/` folder, the preset pointing at that copy.
public enum SavedWatermarks {
    public static func all(_ db: Database) throws -> [SavedWatermark] {
        try Row.fetchAll(db, sql: "SELECT id, name, spec FROM watermarkPreset WHERE NOT deleted ORDER BY createdAt, rowid").compactMap { r in
            guard let spec = try? JSONDecoder().decode(WatermarkSpec.self, from: Data((r["spec"] as String).utf8)) else { return nil }
            return SavedWatermark(id: r["id"], name: r["name"], spec: spec)
        }
    }

    /// Adds the watermark, or replaces the one with the same id.
    public static func save(_ w: SavedWatermark, db: Database, at: Double? = nil) throws {
        let spec = String(decoding: try JSONEncoder().encode(w.spec), as: UTF8.self)
        // Later than the version it replaces, so it wins on every Mac whatever this one's clock says.
        let at = try at ?? SyncIds.stamp(after: try Double.fetchOne(db, sql: "SELECT updatedAt FROM watermarkPreset WHERE id = ?", arguments: [w.id]))
        try db.execute(sql: """
            INSERT INTO watermarkPreset (id, name, spec, updatedAt, createdAt, deleted) VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, spec = excluded.spec, updatedAt = excluded.updatedAt, deleted = 0
            """, arguments: [w.id, w.name, spec, at, at])
    }

    /// Gone here and, through the team, on the other Macs (kept as a tombstone so an older copy doesn't come back).
    public static func delete(_ id: String, db: Database) throws {
        try db.execute(sql: "UPDATE watermarkPreset SET deleted = 1, updatedAt = \(SyncIds.stampSQL("updatedAt")) WHERE id = ?",
                       arguments: [Date().timeIntervalSince1970, id])
    }

    /// This Mac's copies of teammates' logo and banner files.
    static func filesDirectory(_ store: LibraryStore) -> URL {
        store.directory.deletingLastPathComponent().appendingPathComponent("Watermarks", isDirectory: true)
    }

    /// The file's name in the team folder's `assets/`: its bytes' hash, so the same logo is stored once and a
    /// changed one under a new name.
    static func assetName(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }
}

extension TeamSync {
    struct WatermarkPayload: Codable {
        var spec: WatermarkSpec
        /// Asset names in the team folder's `assets/` of the spec's files: "logo", "portrait".
        var files: [String: String]?
    }

    static func assetsURL(_ folder: URL) -> URL { folder.appendingPathComponent("assets", isDirectory: true) }

    /// Saved watermarks added, changed or deleted here since last published, their files copied to the team folder
    /// first.
    func watermarkOps(_ team: TeamRecord, state: [String: String]) throws -> (ops: [Op], updates: [String: String]) {
        let rows = try store.db.read { db in try Row.fetchAll(db, sql: "SELECT id, name, spec, updatedAt, deleted FROM watermarkPreset") }
        var ops: [Op] = []
        var updates: [String: String] = [:]
        let fm = FileManager.default
        for r in rows {
            let id: String = r["id"], at: Double = r["updatedAt"]
            guard state["pub:wm:\(id)"] != "\(at)" else { continue }
            guard let spec = try? JSONDecoder().decode(WatermarkSpec.self, from: Data((r["spec"] as String).utf8)) else { continue }
            var files: [String: String] = [:]
            for (field, path) in [("logo", spec.logoPath), ("portrait", spec.portraitLogoPath ?? "")] where !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: false)
                guard let name = SavedWatermarks.assetName(url) else { continue }  // gone here: the path travels as it is
                let dst = Self.assetsURL(team.url).appendingPathComponent(name)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.createDirectory(at: Self.assetsURL(team.url), withIntermediateDirectories: true)
                    let data = try Data(contentsOf: url)
                    try data.write(to: dst, options: .atomic)
                }
                files[field] = name
            }
            var op = Op(t: "watermark", at: at, uuid: id, name: r["name"], deleted: (r["deleted"] as Bool) ? true : nil)
            op.watermark = WatermarkPayload(spec: spec, files: files.isEmpty ? nil : files)
            ops.append(op)
            updates["pub:wm:\(id)"] = "\(at)"
        }
        return (ops, updates)
    }

    /// A teammate saved, changed or deleted a watermark: the newest wins. Its files are copied from the team folder
    /// to this Mac first (deferred until they can be read there).
    func applyWatermarkOp(_ op: Op, team: TeamRecord, db: Database) throws -> Outcome {
        guard let id = op.uuid, let payload = op.watermark else { return .ignored }
        let current = try Double?.fetchOne(db, sql: "SELECT updatedAt FROM watermarkPreset WHERE id = ?", arguments: [id]) ?? nil
        guard op.at > (current ?? 0) else { return .ignored }
        var spec = payload.spec
        let fm = FileManager.default
        let local = SavedWatermarks.filesDirectory(store)
        for (field, name) in payload.files ?? [:] {
            let src = Self.assetsURL(team.url).appendingPathComponent(name), dst = local.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) {
                guard fm.fileExists(atPath: src.path) else { return .deferred }
                try fm.createDirectory(at: local, withIntermediateDirectories: true)
                try Data(contentsOf: src).write(to: dst, options: .atomic)
            }
            if field == "logo" { spec.logoPath = dst.path } else if field == "portrait" { spec.portraitLogoPath = dst.path }
        }
        spec.presetId = id
        try SavedWatermarks.save(SavedWatermark(id: id, name: op.name ?? "Watermark", spec: spec), db: db, at: op.at)
        if op.deleted == true { try db.execute(sql: "UPDATE watermarkPreset SET deleted = 1 WHERE id = ?", arguments: [id]) }
        // Known here now: not sent back as this Mac's own change.
        try db.execute(sql: "INSERT OR REPLACE INTO syncState (teamId, key, value) VALUES (?, ?, ?)", arguments: [team.id, "pub:wm:\(id)", "\(op.at)"])
        return .applied(people: [], remote: [])
    }
}
