import Foundation

/// Best-shot scoring: which photos of a person are worth posting first.
public enum BestShot {
    /// Bump when analysis gains new measurements; older media are upgraded in the background.
    public static let analysisVersion = 2

    /// Sharpness (variance of the Laplacian on the aligned face) on a log scale: ~40 blurry -> 0, ~1000 crisp -> 1.
    public static func sharpnessScore(_ v: Double?) -> Double? {
        v.map { min(1, max(0, (log10(max($0, 1)) - 1.6) / 1.4)) }
    }

    /// 1 facing the camera, 0 turned ~40° to the side or tilted ~35° up/down (Vision angles are radians).
    public static func frontalScore(yaw: Double?, pitch: Double?) -> Double {
        let y = yaw.map { 1 - min(1, abs($0) / 0.7) } ?? 0.7
        let p = pitch.map { 1 - min(1, abs($0) / 0.6) } ?? 0.8
        return y * p
    }

    /// 0-1. Vision's capture quality already judges a portrait well (exposure, focus, pose, expression), so it
    /// carries most weight; sharpness, open eyes and facing the camera refine it; smile and size are tie-breakers.
    /// Closed eyes cut the score hard. Missing measurements count as average.
    public static func score(quality: Double?, sharpness: Double?, eyesOpen: Double?, smile: Double?, yaw: Double?,
                             pitch: Double? = nil, widthPixels: Double) -> Double {
        let q = quality ?? 0.4
        let s = sharpnessScore(sharpness) ?? 0.5
        let e = eyesOpen ?? 0.6
        let m = smile ?? 0.4
        let f = frontalScore(yaw: yaw, pitch: pitch)
        let size = min(1, widthPixels / 250)
        let base = 0.45 * q + 0.20 * s + 0.12 * e + 0.05 * m + 0.13 * f + 0.05 * size
        return e < 0.35 ? base * 0.6 : base
    }

    /// SQL expression ranking a person's faces for their picture: best score, strongly preferring faces that look
    /// at the camera and are sharp, and photos over video frames.
    public static let coverOrderSQL = """
        COALESCE(f.score, f.quality * 0.6, 0)
          * (CASE WHEN ABS(COALESCE(f.yaw, 0)) < 0.35 THEN 1.0 ELSE 0.55 END)
          * (CASE WHEN ABS(COALESCE(f.pitch, 0)) < 0.3 THEN 1.0 ELSE 0.6 END)
          * (CASE WHEN COALESCE(f.eyesOpen, 1) >= 0.5 THEN 1.0 ELSE 0.5 END)
          * (CASE WHEN f.sharpness IS NULL OR f.sharpness >= 120 THEN 1.0 ELSE 0.6 END)
          * (CASE WHEN f.time IS NULL THEN 1.0 ELSE 0.85 END)
        """

    /// Subquery for the automatic picture of person `p.id`: their best face, from this project's files when a
    /// project is given (a person recognised in a later event shows a face from that event).
    public static func coverSubquery(project: Int64?) -> String {
        guard project != nil else {
            return "(SELECT f.id FROM face f WHERE f.personId = p.id ORDER BY \(coverOrderSQL) DESC LIMIT 1)"
        }
        return """
            (SELECT f.id FROM face f JOIN media cm ON cm.id = f.mediaId LEFT JOIN source cs ON cs.id = cm.sourceId
             WHERE f.personId = p.id AND \(ProjectScope.sql(project, source: "cs")) ORDER BY \(coverOrderSQL) DESC LIMIT 1)
            """
    }
}

/// Splits a timeline into shooting sessions wherever there is a long gap (opening, matches, awards…).
public enum Sessions {
    public struct Session: Identifiable, Hashable, Sendable {
        public var id: Int { index }
        public var index: Int
        public var start: Date
        public var end: Date
        public var count: Int
        public var label: String {
            let d = DateFormatter(); d.dateFormat = "d MMM"
            let t = DateFormatter(); t.dateFormat = "HH:mm"
            return "\(d.string(from: start)) \(t.string(from: start))–\(t.string(from: end)) (\(count))"
        }
    }

    /// Sessions in time order; `gap` seconds without a shot starts a new one.
    public static func split(_ dates: [Date], gap: TimeInterval = 30 * 60) -> [Session] {
        var out: [Session] = []
        for d in dates.sorted() {
            if var last = out.last, d.timeIntervalSince(last.end) <= gap {
                last.end = d
                last.count += 1
                out[out.count - 1] = last
            } else {
                out.append(Session(index: out.count, start: d, end: d, count: 1))
            }
        }
        return out
    }
}
