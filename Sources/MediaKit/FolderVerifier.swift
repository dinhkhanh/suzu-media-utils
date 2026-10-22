import CryptoKit
import Foundation

/// Checks that a copy of a folder (e.g. the photographer's card -> NAS) is complete and intact.
public enum FolderVerifier {
    public struct Report: Sendable {
        public var matched = 0
        /// Relative paths in the source that are not in the destination.
        public var missing: [String] = []
        /// Present in both but a different size (usually an interrupted copy).
        public var sizeMismatch: [String] = []
        /// Same size but different content (only checked with checksums on).
        public var contentMismatch: [String] = []
        /// In the destination only.
        public var extra: [String] = []
        public var bytesChecked: Int64 = 0
        public var isComplete: Bool { missing.isEmpty && sizeMismatch.isEmpty && contentMismatch.isEmpty }
    }

    static func listing(_ root: URL) -> [String: Int64] {
        var out: [String: Int64] = [:]
        let base = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return out }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            out[String(u.standardizedFileURL.path.dropFirst(base.count + 1))] = Int64(v.fileSize ?? 0)
        }
        return out
    }

    public static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(source: URL, destination: URL, checksums: Bool,
                              progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) -> Report {
        let a = listing(source), b = listing(destination)
        var r = Report()
        let common = a.keys.filter { b[$0] != nil }.sorted()
        r.missing = a.keys.filter { b[$0] == nil }.sorted()
        r.extra = b.keys.filter { a[$0] == nil }.sorted()
        for (i, rel) in common.enumerated() {
            if isCancelled() { break }
            progress(i + 1, common.count)
            guard a[rel] == b[rel] else { r.sizeMismatch.append(rel); continue }
            if checksums {
                r.bytesChecked += a[rel]! * 2
                if sha256(source.appendingPathComponent(rel)) != sha256(destination.appendingPathComponent(rel)) {
                    r.contentMismatch.append(rel)
                    continue
                }
            }
            r.matched += 1
        }
        return r
    }

    /// Copies missing files and replaces broken copies (size or content mismatch). Never touches extra files.
    public static func repair(_ report: Report, source: URL, destination: URL, progress: (Int, Int) -> Void = { _, _ in }) -> [String: String] {
        let fm = FileManager.default
        var failures: [String: String] = [:]
        let todo = report.missing + report.sizeMismatch + report.contentMismatch
        for (i, rel) in todo.enumerated() {
            progress(i + 1, todo.count)
            let s = source.appendingPathComponent(rel), d = destination.appendingPathComponent(rel)
            do {
                try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: d.path) { try fm.removeItem(at: d) }
                try fm.copyItem(at: s, to: d)
            } catch {
                failures[rel] = error.localizedDescription
            }
        }
        return failures
    }
}
