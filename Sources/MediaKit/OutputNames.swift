import Foundation

/// Hands out output file names for one batch: never the name of a file already on disk (an original included) nor
/// one already handed out in this batch. A taken name gets " (2)", " (3)"… like Finder's "Keep Both".
public final class OutputNames: @unchecked Sendable {
    private let lock = NSLock()
    private var taken: Set<String> = []

    public init() {}

    public func reserve(in dir: URL, base: String, ext: String) -> URL {
        lock.lock(); defer { lock.unlock() }
        var n = 1
        while true {
            let stem = n == 1 ? base : "\(base) (\(n))"
            let url = dir.appendingPathComponent(stem, isDirectory: false).appendingPathExtension(ext)
            // Folder names compare case- and form-insensitively on macOS volumes.
            let key = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            if !taken.contains(key), !FileManager.default.fileExists(atPath: url.path) {
                taken.insert(key)
                return url
            }
            n += 1
        }
    }
}
