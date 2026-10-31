import Accelerate
import Foundation
import GRDB

public enum SourceKind: String, Codable, Sendable {
    /// Photos and videos to group.
    case media
    /// Known people: one subfolder per person, named after them, holding a few photos of that person.
    /// Their faces name matching groups automatically; the files themselves are not shown or exported.
    case reference
}

/// Who a photo & video folder belongs to in a team (see TeamSync): the team's shared folders and the editing
/// Mac's folders travel to every Mac of the team; a Mac's own folders stay on it.
public enum SourceShare: String, Codable, Sendable, CaseIterable {
    /// Only on this Mac (the default, and every folder of a project that is not shared).
    case mac
    /// A folder the whole team works on (the sources on the NAS): on every Mac of the team.
    case team
    /// The folder the Mac in charge of editing / filtering / selecting fills: on every Mac of the team. Its files
    /// are finished work (edits of photos already in the library), so they are never read for faces.
    case edited

    /// SQL: the ids of the edited folders.
    public static let editedIds = "SELECT id FROM source WHERE share = 'edited'"

    public var title: String {
        switch self {
        case .mac: "Only on this Mac"
        case .team: "Team folder"
        case .edited: "Edited folder"
        }
    }
}

public struct SourceRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "source"
    public var id: Int64?
    public var path: String
    public var kind: SourceKind
    public var addedAt: Date
    /// The event this folder belongs to; nil for known-people folders, which every project shares.
    public var projectId: Int64?
    /// Stable across Macs (team sync): a shared folder is the same folder on every Mac of its team.
    public var uuid: String
    public var share: SourceShare
    /// When `share` was last set, seconds since 1970 (a teammate's newer choice wins); nil = never shared.
    public var shareAt: Double?
    /// The teammate's Mac that shared this folder here; nil = added on this Mac.
    public var fromDevice: String?
    /// Set when a teammate took the folder out of the team: this Mac forgets it in the background.
    public var removedAt: Double?
    /// Subfolders left out of the library, relative to `path` (so they survive Locate Folder and a share mounted
    /// elsewhere): never listed, and what was found in them leaves (SourceMonitor.dropExcluded).
    public var excluded: [String]

    public init(path: String, kind: SourceKind = .media, projectId: Int64? = nil, share: SourceShare = .mac, uuid: String = SyncIds.new()) {
        self.path = path; self.kind = kind; addedAt = Date(); self.projectId = projectId
        self.uuid = uuid
        self.share = share
        excluded = []
        shareAt = share == .mac ? nil : Date().timeIntervalSince1970
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// Whether a file at `path` is in one of the excluded subfolders.
    public func excludes(_ file: String) -> Bool { excluded.contains { file.hasPrefix(path + "/" + $0 + "/") } }
}

/// One event (a wedding, a show, a match): a set of folders. People are shared across projects, so a name given in
/// one project is recognised in every later one.
public struct ProjectRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "project"
    public var id: Int64?
    public var name: String
    public var createdAt: Date
    /// Stable across Macs (team sync): a shared project is the same project on every Mac of its team.
    public var uuid: String
    /// The team this project is shared with; nil = only on this Mac.
    public var teamId: Int64?
    /// Last rename, seconds since 1970 (a teammate's newer name wins).
    public var updatedAt: Double

    public init(name: String, uuid: String = SyncIds.new(), teamId: Int64? = nil) {
        self.name = name
        createdAt = Date()
        self.uuid = uuid
        self.teamId = teamId
        updatedAt = Date().timeIntervalSince1970
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum MediaKind: String, Codable, Sendable { case photo, video }
public enum MediaStatus: String, Codable, Sendable { case pending, done, failed }

public struct MediaRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "media"
    public var id: Int64?
    public var sourceId: Int64?
    /// Absolute path; unique.
    public var path: String
    public var kind: MediaKind
    public var size: Int64
    public var mtime: Double
    /// Size + SHA-256 of the first 1 MB. Identifies copies and files moved outside the app.
    public var contentKey: String?
    /// Set when this file is a byte-identical copy of another media; copies have no faces of their own.
    public var duplicateOf: Int64?
    public var status: MediaStatus
    public var error: String?
    /// Pixel size of the image the face boxes were detected on.
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var takenAt: Double?
    public var featurePrint: Data?
    public var burstId: Int64?
    public var analysisVersion: Int = BestShot.analysisVersion
    /// The teammate's Mac whose face results this file carries (shared processing); nil = processed here.
    public var importedFrom: String?
    /// When the thumbnail was written (0: tried, couldn't); nil = not yet.
    public var thumbAt: Double?
    /// Processed on this Mac even when another Mac does the team's face work: a file this Mac copied off a card
    /// (read from the card while it is in; the result goes to the team, see SharedFaces).
    public var localWork = false
    /// When the library first saw the file, seconds since 1970.
    public var seenAt: Double?
    /// In an edited folder (finished work, mostly edits of photos already here): listed, never read for faces.
    public var skippedAsEdited = false

    public init(sourceId: Int64?, path: String, kind: MediaKind, size: Int64, mtime: Double, contentKey: String?) {
        self.sourceId = sourceId; self.path = path; self.kind = kind; self.size = size; self.mtime = mtime
        self.contentKey = contentKey; status = .pending
        seenAt = Date().timeIntervalSince1970
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
}

public enum Assignment: String, Codable, Sendable {
    /// Not grouped yet (or too low quality to group).
    case none
    /// Grouped by the engine; may be changed by later reclustering.
    case auto
    /// Set or confirmed by the user; the engine never changes it.
    case user
}

public struct FaceRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "face"
    public var id: Int64?
    public var mediaId: Int64
    /// Box normalized to 0-1, top-left origin.
    public var x, y, w, h: Double
    public var quality: Double?
    public var time: Double?
    /// L2-normalized Float32 ArcFace embedding.
    public var embedding: Data?
    /// Faces of one person within one video share a track number.
    public var track: Int?
    public var personId: Int64?
    public var assignment: Assignment
    /// The person the user said this is not; never auto-assigned back.
    public var rejectedPersonId: Int64?
    public var eyesOpen: Double?
    public var smile: Double?
    public var sharpness: Double?
    public var yaw: Double?
    public var pitch: Double?
    public var score: Double?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var vector: [Float]? { embedding.map(Vector.decode) }
}

public struct PersonRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "person"
    public var id: Int64?
    public var name: String?
    public var createdAt: Date
    public var coverFaceId: Int64?
    /// When the picture was picked by hand (nil: never, or automatic), seconds since 1970; travels to teammates.
    public var coverAt: Double?
    /// Stable across Macs (team sync): the same person has the same id everywhere.
    public var uuid: String
    /// When the name was last set, seconds since 1970; a teammate's newer name wins over an older one.
    public var nameAt: Double?

    public init(name: String? = nil, uuid: String = SyncIds.new()) {
        self.name = name
        createdAt = Date()
        self.uuid = uuid
        nameAt = name == nil ? nil : Date().timeIntervalSince1970
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Ids that are the same on every Mac.
public enum SyncIds {
    public static func new() -> String { UUID().uuidString.lowercased() }

    /// The moment of a change made here that travels to teammates, where the newest change wins: now, but always
    /// later than `after`, the moment of the value it replaces. A Mac whose clock runs behind a teammate's would
    /// otherwise stamp its edit older than what it replaces; the teammates ignore it while this Mac shows it, and
    /// the two never agree again. With this, what the user did last on any Mac wins everywhere.
    public static func stamp(after: Double?) -> Double { max(Date().timeIntervalSince1970, (after ?? 0) + 0.001) }

    /// The same in SQL, for an UPDATE of `column` in place; binds one argument, the current time.
    public static func stampSQL(_ column: String) -> String { "MAX(?, COALESCE(\(column), 0) + 0.001)" }
}

/// Macs sharing projects through a folder they can all reach (see TeamSync). A team holds any number of projects
/// (`ProjectRecord.teamId`).
public struct TeamRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "team"
    public var id: Int64?
    public var uuid: String
    public var name: String
    public var folder: String
    public var joinedAt: Date
    /// The one Mac that does this team's face work, when the team has chosen one (see SharedFaces); nil = every
    /// Mac processes its own files.
    public var processorId: String?
    public var processorName: String?

    public init(uuid: String, name: String, folder: String) {
        self.uuid = uuid; self.name = name; self.folder = folder; joinedAt = Date()
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var url: URL { URL(fileURLWithPath: folder, isDirectory: true) }
}

public enum Vector {
    public static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    public static func decode(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!, 1, &s, vDSP_Length(n)) } }
        return s
    }

    public static func dot(_ a: [Float], _ b: ArraySlice<Float>) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!, 1, &s, vDSP_Length(n)) } }
        return s
    }

    /// Rows of 512 floats as Float16 (half the bytes; plenty for a cosine), and back.
    public static func encodeHalfRows(_ rows: [[Float]]) -> Data {
        var out = [Float16]()
        out.reserveCapacity(rows.count * 512)
        for r in rows where r.count == 512 { out += r.map { Float16($0) } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    public static func decodeHalfRows(_ d: Data) -> [[Float]] {
        let flat = d.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map { Float($0) }
        return stride(from: 0, to: flat.count - flat.count % 512, by: 512).map { Array(flat[$0..<$0 + 512]) }
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let n = dot(v, v).squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}
