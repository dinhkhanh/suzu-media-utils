import Foundation
import ImageIO

/// Batch rename with a pattern such as "{event}_{date}_{person}_{seq:3}".
///
/// Tokens: {name} original name, {event} free text, {date} yyyy-MM-dd, {time} HHmmss, {seq} / {seq:N} counter
/// (zero-padded to N), {person} first person, {people} all people joined by "+", {folder} parent folder name.
public struct RenamePattern: Sendable, Equatable {
    public var pattern: String
    public var event: String
    public var start: Int

    public init(pattern: String = "{event}_{date}_{seq:3}", event: String = "", start: Int = 1) {
        self.pattern = pattern; self.event = event; self.start = start
    }

    public struct Item: Sendable {
        public var url: URL
        public var date: Date?
        public var people: [String]
        public init(url: URL, date: Date? = nil, people: [String] = []) { self.url = url; self.date = date; self.people = people }
    }

    /// New file names (with the original extension), unique within each folder.
    public func names(for items: [Item]) -> [String] {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HHmmss"
        var used: [String: Set<String>] = [:]
        return items.enumerated().map { i, item in
            var s = pattern
            let seq = start + i
            if let r = s.range(of: #"\{seq:(\d+)\}"#, options: .regularExpression) {
                let width = Int(s[r].dropFirst(5).dropLast()) ?? 1
                s.replaceSubrange(r, with: String(format: "%0\(width)d", seq))
            }
            let date = item.date ?? (try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let values: [String: String] = [
                "{seq}": String(seq), "{name}": item.url.deletingPathExtension().lastPathComponent, "{event}": event,
                "{date}": df.string(from: date), "{time}": tf.string(from: date), "{person}": item.people.first ?? "",
                "{people}": item.people.joined(separator: "+"), "{folder}": item.url.deletingLastPathComponent().lastPathComponent,
            ]
            for (k, v) in values { s = s.replacingOccurrences(of: k, with: v) }
            s = Self.clean(s)
            if s.isEmpty { s = item.url.deletingPathExtension().lastPathComponent }
            let ext = item.url.pathExtension
            let dir = item.url.deletingLastPathComponent().path
            var candidate = s, n = 2
            while used[dir, default: []].contains(candidate.lowercased()) { candidate = "\(s)-\(n)"; n += 1 }
            used[dir, default: []].insert(candidate.lowercased())
            return ext.isEmpty ? candidate : "\(candidate).\(ext)"
        }
    }

    /// No path separators, no doubled or dangling separators from empty tokens.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while t.contains("__") { t = t.replacingOccurrences(of: "__", with: "_") }
        while t.contains("--") { t = t.replacingOccurrences(of: "--", with: "-") }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "_- ."))
    }

    /// Renames in two steps (through temporary names) so swaps like a<->b work. Returns (old, new) per renamed file.
    public static func apply(_ items: [Item], names: [String]) throws -> [(URL, URL)] {
        let fm = FileManager.default
        var temps: [(URL, URL, URL)] = []
        for (item, name) in zip(items, names) where item.url.lastPathComponent != name {
            let tmp = item.url.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: item.url, to: tmp)
            temps.append((item.url, tmp, item.url.deletingLastPathComponent().appendingPathComponent(name)))
        }
        var done: [(URL, URL)] = []
        for (old, tmp, new) in temps {
            if fm.fileExists(atPath: new.path) {
                try fm.moveItem(at: tmp, to: old)  // a different file already has that name: leave this one as it was
                continue
            }
            try fm.moveItem(at: tmp, to: new)
            done.append((old, new))
        }
        return done
    }

    public static func captureDate(_ url: URL) -> Date? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(Metadata.captureDate)
    }
}
