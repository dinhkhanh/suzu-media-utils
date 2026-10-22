import Foundation

public struct ScannedPhoto: Codable, Sendable {
    public var path: String
    public var bytes: Int
    public var longSide: Int
    public var detectWidth: Int
    public var detectHeight: Int
    public var error: String?
    /// Set for videos.
    public var duration: Double?
    public var framesSampled: Int?

    public var isVideo: Bool { duration != nil }

    public init(path: String, bytes: Int, longSide: Int, detectWidth: Int, detectHeight: Int, error: String? = nil) {
        self.path = path; self.bytes = bytes; self.longSide = longSide
        self.detectWidth = detectWidth; self.detectHeight = detectHeight; self.error = error
    }
}

public struct ScannedFace: Codable, Sendable {
    public var photo: Int
    public var face: DetectedFace
    /// Long side of the image the aligned crop was cut from.
    public var alignedFrom: Int?
    /// Video timestamp in seconds; nil for photos.
    public var time: Double?

    public init(photo: Int, face: DetectedFace, alignedFrom: Int? = nil, time: Double? = nil) {
        self.photo = photo; self.face = face; self.alignedFrom = alignedFrom; self.time = time
    }
}

public struct ScanResult: Codable, Sendable {
    public var root: String
    public var photos: [ScannedPhoto]
    public var faces: [ScannedFace]
    /// Model name -> embedding dimension. Embeddings live in emb_<model>.f32, one row per aligned face, in
    /// `faces` order, skipping faces whose `alignedFrom` is nil.
    public var models: [String: Int]
    public var timings: [String: Double]

    public init(root: String, photos: [ScannedPhoto], faces: [ScannedFace], models: [String: Int], timings: [String: Double]) {
        self.root = root; self.photos = photos; self.faces = faces; self.models = models; self.timings = timings
    }

    public static func load(_ dir: URL) throws -> ScanResult {
        try JSONDecoder().decode(ScanResult.self, from: Data(contentsOf: dir.appendingPathComponent("scan.json")))
    }

    public func save(_ dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: dir.appendingPathComponent("scan.json"))
    }

    public static func saveEmbeddings(_ emb: [[Float]], model: String, dir: URL) throws {
        let flat = emb.flatMap { $0 }
        try flat.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("emb_\(model).f32"))
    }

    public func loadEmbeddings(model: String, dir: URL) throws -> [[Float]] {
        guard let d = models[model] else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: dir.appendingPathComponent("emb_\(model).f32"))
        let flat = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return stride(from: 0, to: flat.count, by: d).map { Array(flat[$0..<$0 + d]) }
    }
}
