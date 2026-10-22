import Foundation
import GRDB

public enum SourceKind: String, Codable, Sendable {
    /// Photos and videos to group.
    case media
    /// Known people: one subfolder per person, named after them, holding a few photos of that person.
    /// Their faces name matching groups automatically; the files themselves are not shown or exported.
    case reference
}

public struct SourceRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "source"
    public var id: Int64?
    public var path: String
    public var kind: SourceKind
    public var addedAt: Date

    public init(path: String, kind: SourceKind = .media) { self.path = path; self.kind = kind; addedAt = Date() }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
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

    public init(sourceId: Int64?, path: String, kind: MediaKind, size: Int64, mtime: Double, contentKey: String?) {
        self.sourceId = sourceId; self.path = path; self.kind = kind; self.size = size; self.mtime = mtime
        self.contentKey = contentKey; status = .pending
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var url: URL { URL(fileURLWithPath: path) }
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

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var vector: [Float]? { embedding.map(Vector.decode) }
}

public struct PersonRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "person"
    public var id: Int64?
    public var name: String?
    public var createdAt: Date

    public init(name: String? = nil) { self.name = name; createdAt = Date() }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum Vector {
    public static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    public static func decode(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let n = dot(v, v).squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}
