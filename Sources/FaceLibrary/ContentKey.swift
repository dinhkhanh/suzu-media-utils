import CryptoKit
import Foundation

public enum ContentKey {
    /// "<size>-<sha256 of first 1 MB>". Cheap on network shares, and stable across renames, moves and copies.
    public static func compute(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 1 << 20) else { return nil }
        let digest = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(digest)"
    }
}
