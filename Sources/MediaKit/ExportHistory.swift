import Foundation

/// Which photos were exported to which files, so a batch doesn't export a photo into the same folder twice by
/// accident and the preview can mark the photos already exported. An export counts only while its file is there.
public final class ExportHistory: @unchecked Sendable {
    public static let shared = ExportHistory()
    /// Posted on the main queue when exports are added.
    public static let changed = Notification.Name("ExportHistory.changed")

    public struct Record: Codable, Sendable, Hashable {
        public var path: String
        public var date: Date
    }

    private let lock = NSLock()
    /// By source file path.
    private var records: [String: [Record]] = [:]
    private var unsaved = 0
    private let file: URL?

    init(file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("SuZu Media Utils/export-history.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file) {
            records = (try? JSONDecoder().decode([String: [Record]].self, from: data)) ?? [:]
        }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Exports of this photo whose files are still there, newest first.
    public func exports(of source: URL) -> [Record] {
        let list = lock.withLock { records[Self.key(source)] ?? [] }
        return list.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.date > $1.date }
    }

    /// The latest export of this photo into `folder` (or a folder inside it), while its file is there.
    public func exported(_ source: URL, into folder: URL) -> Record? {
        let prefix = Self.key(folder) + "/"
        return exports(of: source).first { $0.path.hasPrefix(prefix) }
    }

    /// The photo each recorded export was made from, by export path.
    public func sources() -> [String: String] {
        lock.withLock {
            var out: [String: String] = [:]
            for (source, list) in records { for r in list { out[r.path] = source } }
            return out
        }
    }

    /// Records an export; `replacing` is the earlier export it took the place of.
    public func add(_ source: URL, to dest: URL, replacing: String? = nil) {
        let save = lock.withLock {
            let path = Self.key(dest)
            records[Self.key(source), default: []].removeAll { $0.path == path || $0.path == replacing }
            records[Self.key(source), default: []].append(Record(path: path, date: Date()))
            unsaved += 1
            return unsaved >= 25
        }
        if save { self.save() }
    }

    /// Writes the history to disk (batches call it when they finish) and tells the views.
    public func save() {
        let data = lock.withLock {
            unsaved = 0
            return try? JSONEncoder().encode(records)
        }
        if let file, let data {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}
