import FaceCore
import Foundation
import GRDB
import MediaKit

/// Exports a person's moments from videos: separate clips, one highlight reel, or still frames.
public struct VideoExport: Sendable {
    let store: LibraryStore

    public enum Kind: Sendable, Hashable {
        case clips
        /// Best moments joined into one movie, at most this many seconds (nil = everything).
        case reel(maxSeconds: Double?)
        /// The best frame of each appearance, through an edit recipe.
        case stills(EditRecipe)
    }

    public struct Appearance: Sendable {
        public var mediaId: Int64
        public var url: URL
        public var segment: VideoTools.Segment
        /// Best face score in the segment, and when/where that face is.
        public var score: Double
        public var bestTime: Double
        public var bestBox: CGRect
    }

    public init(store: LibraryStore) { self.store = store }

    /// Every on-screen appearance of a person across their videos, in time order per file.
    public func appearances(personId: Int64) throws -> [Appearance] {
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, COALESCE(m.duration, 0) AS duration, f.time, COALESCE(f.score, f.quality, 0) AS s,
                       f.x, f.y, f.w, f.h
                FROM face f JOIN media m ON m.id = f.mediaId
                WHERE f.personId = ? AND m.kind = 'video' AND f.time IS NOT NULL AND m.duplicateOf IS NULL
                ORDER BY m.path, f.time
                """, arguments: [personId])
        }
        var out: [Appearance] = []
        for (_, faces) in Dictionary(grouping: rows, by: { $0["id"] as Int64 }).sorted(by: { ($0.value[0]["path"] as String) < ($1.value[0]["path"] as String) }) {
            let duration: Double = faces[0]["duration"]
            for seg in VideoTools.segments(times: faces.map { $0["time"] as Double }, duration: duration) {
                let inside = faces.filter { let t: Double = $0["time"]; return t >= seg.start && t <= seg.end }
                guard let best = inside.max(by: { ($0["s"] as Double) < ($1["s"] as Double) }) else { continue }
                out.append(Appearance(mediaId: faces[0]["id"], url: URL(fileURLWithPath: faces[0]["path"]), segment: seg,
                                      score: best["s"], bestTime: best["time"],
                                      bestBox: CGRect(x: best["x"] as Double, y: best["y"] as Double, width: best["w"] as Double, height: best["h"] as Double)))
            }
        }
        return out
    }

    /// Picks the highest-scoring appearances that fit in `maxSeconds`, back in time order.
    public static func reelSelection(_ apps: [Appearance], maxSeconds: Double?) -> [Appearance] {
        guard let maxSeconds else { return apps }
        var total = 0.0
        var chosen: Set<Int> = []
        for (i, a) in apps.enumerated().sorted(by: { $0.element.score > $1.element.score }) where total + a.segment.duration <= maxSeconds {
            chosen.insert(i)
            total += a.segment.duration
        }
        return apps.enumerated().filter { chosen.contains($0.offset) }.map(\.element)
    }

    /// Writes into `folder`; returns the files created.
    public func export(personId: Int64, name: String, kind: Kind, to folder: URL,
                       progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [URL] {
        let apps = try appearances(personId: personId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = Exporter.folderName(name)
        var out: [URL] = []
        switch kind {
        case .clips:
            for (i, a) in apps.enumerated() {
                progress(i, apps.count)
                let ext = ["mov", "mp4", "m4v"].contains(a.url.pathExtension.lowercased()) ? a.url.pathExtension : a.url.pathExtension
                let dest = folder.appendingPathComponent("\(safe) – \(a.url.deletingPathExtension().lastPathComponent) \(VideoTools.timecode(a.segment.start).replacingOccurrences(of: ":", with: "."))")
                    .appendingPathExtension(ext)
                try await VideoTools.exportClip(a.url, segment: a.segment, to: dest)
                out.append(dest)
            }
        case .reel(let maxSeconds):
            progress(0, 1)
            let parts = Self.reelSelection(apps, maxSeconds: maxSeconds).map { (url: $0.url, segment: $0.segment) }
            let dest = folder.appendingPathComponent("\(safe) – highlights.mov")
            try await VideoTools.exportReel(parts, to: dest)
            out.append(dest)
        case .stills(let recipe):
            for (i, a) in apps.enumerated() {
                progress(i, apps.count)
                let dest = folder.appendingPathComponent("\(safe) – \(a.url.deletingPathExtension().lastPathComponent) \(VideoTools.timecode(a.bestTime).replacingOccurrences(of: ":", with: ".")).jpg")
                try VideoTools.still(a.url, at: a.bestTime, recipe: recipe, focus: FocusHint(primary: a.bestBox), people: [name], to: dest)
                out.append(dest)
            }
        }
        progress(apps.count, apps.count)
        return out
    }
}
