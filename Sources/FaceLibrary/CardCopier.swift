import CryptoKit
import FaceCore
import Foundation
import GRDB
import MediaKit
import ImageIO

/// A photographer's memory card the library has seen. Cards can't be renamed (cameras depend on the volume name),
/// so one is known by its volume UUID: for FAT and exFAT cards that is the serial number the camera wrote when it
/// formatted the card, which survives every unmount and only changes when the card is formatted again, so a
/// formatted card is, rightly, a new card. A label ("Nam R5 card 1") and the camera's make, model and body serial
/// (from the first photo's EXIF) make it recognisable.
public struct CardRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "card"
    public var id: Int64?
    public var uuid: String
    public var label: String?
    public var volumeName: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var cameraSerial: String?
    public var firstSeenAt: Date
    public var lastCopiedAt: Date?
    public var lastCopiedTo: String?
    /// When the label was given (the newest wins between teammates' Macs).
    public var labelAt: Double?
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// What to call the card: its label, else the volume name, else the camera.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if let volumeName, !volumeName.isEmpty { return volumeName }
        return camera ?? "Card \(uuid.prefix(8))"
    }
    public var camera: String? {
        let parts = [cameraMake, cameraModel].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        // "Canon Canon EOS R5" → "Canon EOS R5".
        if parts.count == 2, parts[1].localizedCaseInsensitiveContains(parts[0]) { return parts[1] }
        return parts.joined(separator: " ")
    }
}

/// Copies the new files off memory cards that photographers hand over again and again during an event without
/// erasing them. A ledger (`cardFile`) remembers every file copied from every card, so the next hand-over copies only
/// what was shot since, wherever the earlier copies were moved, filtered or edited to in the meantime.
public enum CardCopier {
    /// What is copied: photos, videos and their XMP sidecars.
    public static let extensions: Set<String> = ImageLoader.extensions.union(VideoSampler.extensions).union(["xmp"])
    static let marker = ".suzu-card"
    /// FAT keeps modification times to 2 seconds.
    static let mtimeTolerance: TimeInterval = 2

    // MARK: Identity

    public struct Identity: Hashable, Sendable {
        public var uuid: String
        public var volume: URL
        public var volumeName: String
        public var capacity: Int64?
        public var available: Int64?
        public var cameraMake: String?
        public var cameraModel: String?
        public var cameraSerial: String?
        /// A mounted volume (a card), as against a folder standing in for one.
        public var isVolume = false
        public init(uuid: String, volume: URL, volumeName: String) { self.uuid = uuid; self.volume = volume; self.volumeName = volumeName }

        /// Still there? A pulled card's mount point can linger as an empty folder for a moment, so a volume counts
        /// as reachable only while something is mounted at it.
        public var isReachable: Bool { CardCopier.reachable(volume, volume: isVolume) }
    }

    /// Mounted removable or ejectable volumes that look like camera cards (a DCIM or PRIVATE folder, or media files
    /// at the root). A Mac's built-in card slot can report its card as internal, so that is not held against it.
    public static func mountedCards() -> [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { u in
            guard let v = try? u.resourceValues(forKeys: keys), v.volumeIsBrowsable != false, v.volumeIsRootFileSystem != true,
                  v.volumeIsRemovable == true || v.volumeIsEjectable == true else { return false }
            return looksLikeCard(u)
        }
    }

    /// Room left where the copies go.
    public static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    public static func looksLikeCard(_ root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("DCIM").path) || fm.fileExists(atPath: root.appendingPathComponent("PRIVATE").path) { return true }
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return top.contains { extensions.contains($0.pathExtension.lowercased()) }
    }

    /// Who this card is. A mounted volume is known by its UUID; a plain folder (a card image, or a copy of one) by
    /// a hidden marker file written once at its root, since the volume UUID would be the disk's.
    public static func identify(_ root: URL) -> Identity? {
        let root = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let v = try? root.resourceValues(forKeys: keys)
        let isMountRoot = v?.volume.map { $0.standardizedFileURL.path == root.path } ?? false
        var uuid = isMountRoot ? v?.volumeUUIDString : nil
        if uuid == nil {
            let m = root.appendingPathComponent(marker)
            if let s = try? String(contentsOf: m, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                uuid = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let fresh = UUID().uuidString
                guard (try? fresh.write(to: m, atomically: true, encoding: .utf8)) != nil else { return nil }
                uuid = fresh
            }
        }
        guard let uuid else { return nil }
        var id = Identity(uuid: uuid, volume: root, volumeName: (isMountRoot ? v?.volumeName : nil) ?? root.lastPathComponent)
        id.isVolume = isMountRoot
        id.capacity = v?.volumeTotalCapacity.map(Int64.init)
        id.available = v?.volumeAvailableCapacity.map(Int64.init)
        if let photo = firstPhoto(on: root), let src = try? ImageLoader.source(photo).0,
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
            id.cameraMake = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            id.cameraModel = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            id.cameraSerial = (exif?[kCGImagePropertyExifBodySerialNumber] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        return id
    }

    static func firstPhoto(on root: URL) -> URL? {
        let dcim = root.appendingPathComponent("DCIM")
        let start = FileManager.default.fileExists(atPath: dcim.path) ? dcim : root
        guard let e = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        for case let u as URL in e where ImageLoader.extensions.contains(u.pathExtension.lowercased()) { return u }
        return nil
    }

    // MARK: Files on the card

    public enum Kind: String, Sendable { case photo, video }

    public struct File: Hashable, Sendable {
        public var relPath: String
        public var size: Int64
        public var mtime: Date
        /// Photo or video; a sidecar takes the kind of the file it goes with.
        public var kind: Kind = .photo
        /// An XMP or XML that belongs to a photo or clip (not counted as one).
        public var isSidecar = false
        public var name: String { (relPath as NSString).lastPathComponent }
    }

    /// Folders of thumbnails the camera keeps for its own screen (Sony THMBNL): not photos.
    static let skippedFolders: Set<String> = ["THMBNL", "THMBNL_"]

    /// Every photo, video and sidecar on the card, by path relative to its root. A sidecar (a photo's .xmp, a clip's
    /// .xml: Sony C0001M01.XML, Canon, Panasonic) goes with its file: one whose name starts with a media file's name
    /// in the same folder, and it takes that file's kind.
    public static func listFiles(on root: URL) -> [File] {
        let base = root.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var out: [File] = []
        var sidecars: [File] = []
        var media: [String: [(stem: String, kind: Kind)]] = [:]  // folder → media names without extension (upper-cased)
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true {
                if skippedFolders.contains(u.lastPathComponent.uppercased()) { e.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            var f = File(relPath: rel, size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate ?? .distantPast)
            let ext = u.pathExtension.lowercased()
            if ext == "xml" || ext == "xmp" {
                f.isSidecar = true
                sidecars.append(f)
            } else if ImageLoader.extensions.contains(ext) || VideoSampler.extensions.contains(ext) {
                f.kind = VideoSampler.extensions.contains(ext) ? .video : .photo
                out.append(f)
                media[(rel as NSString).deletingLastPathComponent, default: []].append((u.deletingPathExtension().lastPathComponent.uppercased(), f.kind))
            }
        }
        for var x in sidecars {
            let stem = (x.name as NSString).deletingPathExtension.uppercased()
            guard let owner = media[(x.relPath as NSString).deletingLastPathComponent]?.first(where: { stem.hasPrefix($0.stem) }) else { continue }
            x.kind = owner.kind
            out.append(x)
        }
        return out.sorted { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
    }

    // MARK: Planning

    /// What a hand-over means: the card's record, the files to copy, and the ones already taken care of.
    public struct Plan: Sendable {
        public var card: CardRecord
        public var identity: Identity
        public var files: [File] = []
        /// Not copied yet, from any card, and not in the library either.
        public var new: [File] = []
        /// Copied from this or another card before (same path, size and time; else same contents), here or on a
        /// teammate's Mac.
        public var copiedBefore: [File] = []
        /// How many of those were copied on a teammate's Mac (the ledger came through the team).
        public var copiedElsewhere = 0
        /// Not in the ledger, but the library has a file with the same contents: copied by hand some other way.
        public var inLibrary: [File] = []
        /// Matched by contents rather than by path and time: recorded on the next copy so the quick check finds them.
        var matched: [File: (key: String, to: String?)] = [:]
        /// Content keys read while planning, reused by the copy.
        var keys: [String: String] = [:]
        public var newBytes: Int64 { new.reduce(0) { $0 + $1.size } }
        /// New photos and videos (sidecars go with them, uncounted).
        public var newPhotos: Int { new.filter { $0.kind == .photo && !$0.isSidecar }.count }
        public var newVideos: Int { new.filter { $0.kind == .video && !$0.isSidecar }.count }
        public func newBytes(_ kind: Kind) -> Int64 { new.filter { $0.kind == kind }.reduce(0) { $0 + $1.size } }
    }

    /// Looks at the card and decides what is new. Files whose path, size and time match a ledger entry are done
    /// without reading them; the rest are read (1 MB each) and matched by contents against every card's ledger and
    /// the library, so a renamed file, or one copied by hand, is not copied twice.
    public static func plan(_ identity: Identity, store: LibraryStore, isCancelled: () -> Bool = { false }) throws -> Plan {
        let card = try store.db.write { db in try upsert(identity, db: db) }
        var plan = Plan(card: card, identity: identity)
        plan.files = listFiles(on: identity.volume)
        struct Known { var size: Int64; var mtime: Double; var key: String; var elsewhere: Bool }
        let known: [String: Known] = try store.db.read { db in
            var out: [String: Known] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT relPath, size, mtime, contentKey, device FROM cardFile WHERE cardId = ?", arguments: [card.id]) {
                out[r["relPath"]] = Known(size: r["size"], mtime: r["mtime"], key: r["contentKey"], elsewhere: (r["device"] as String?) != nil)
            }
            return out
        }
        for f in plan.files {
            if isCancelled() { break }
            if let k = known[f.relPath], k.size == f.size, abs(k.mtime - f.mtime.timeIntervalSince1970) <= mtimeTolerance {
                plan.copiedBefore.append(f)
                if k.elsewhere { plan.copiedElsewhere += 1 }
                continue
            }
            guard let key = ContentKey.compute(identity.volume.appendingPathComponent(f.relPath), size: f.size) else { plan.new.append(f); continue }
            plan.keys[f.relPath] = key
            let (ledger, elsewhere, library): (String?, Bool, String?) = try store.db.read { db in
                let l = try Row.fetchOne(db, sql: "SELECT copiedTo, device FROM cardFile WHERE contentKey = ? ORDER BY copiedAt DESC LIMIT 1", arguments: [key])
                let m = try String.fetchOne(db, sql: "SELECT path FROM media WHERE contentKey = ? LIMIT 1", arguments: [key])
                return (l.map { ($0["copiedTo"] as String?) ?? "" }, (l?["device"] as String?) != nil, m)
            }
            if let ledger {
                plan.copiedBefore.append(f)
                if elsewhere { plan.copiedElsewhere += 1 }
                plan.matched[f] = (key, ledger.isEmpty ? nil : ledger)
            } else if let library {
                plan.inLibrary.append(f)
                plan.matched[f] = (key, library)
            } else {
                plan.new.append(f)
            }
        }
        return plan
    }

    /// The card's row, made on first sight; the volume name and camera are filled in whenever they are known.
    static func upsert(_ id: Identity, db: Database) throws -> CardRecord {
        if var c = try CardRecord.filter(Column("uuid") == id.uuid).fetchOne(db) {
            c.volumeName = id.volumeName
            if let m = id.cameraMake { c.cameraMake = m }
            if let m = id.cameraModel { c.cameraModel = m }
            if let s = id.cameraSerial { c.cameraSerial = s }
            try c.update(db)
            return c
        }
        var c = CardRecord(uuid: id.uuid, volumeName: id.volumeName, cameraMake: id.cameraMake, cameraModel: id.cameraModel,
                           cameraSerial: id.cameraSerial, firstSeenAt: Date())
        try c.insert(db)
        return c
    }

    // MARK: Copying

    public struct Options: Sendable {
        /// Where photos go (and videos, unless they have their own place).
        public var destination: URL
        /// Where videos go, when not with the photos.
        public var videoDestination: URL?
        /// Read each copy back and compare its SHA-256 with the original's.
        public var verify = true
        /// A folder per hand-over ("2026-10-24 14.05") inside the card's folder.
        public var perHandover = true
        /// Keep the card's folders (DCIM/100CANON/…) instead of putting the files side by side.
        public var keepLayout = false
        /// Go on in this hand-over's folders (one whose copy was interrupted) instead of starting a new one.
        public var folder: URL?
        public var videoFolder: URL?
        /// Called (on the copying thread) as each file lands, so the library can take it up at once: its faces are
        /// read from the card while it is still in the slot (the card is pulled the moment the copy ends), not from
        /// the share minutes later when the folder scan gets to it.
        public var onCopied: (@Sendable (Landed) -> Void)?
        public init(destination: URL) { self.destination = destination }
        func root(for kind: Kind) -> URL { kind == .video ? (videoDestination ?? destination) : destination }
    }

    /// One file just copied: where it landed, where it is on the card, and what the copy already knows about it.
    public struct Landed: Sendable {
        public var landed: URL
        public var onCard: URL
        public var size: Int64
        public var contentKey: String
        /// A RAW file whose JPEG came off the same card: the folder scan pairs it with the JPEG, so it is not
        /// taken up on its own.
        public var rawWithJPEG: Bool
    }

    /// Why a copy stopped before the end. What landed is recorded; the rest stays new for the next time.
    public enum Interruption: Sendable, Equatable {
        case cancelled
        /// The card was pulled, or its reader unplugged, in the middle of the copy.
        case cardRemoved
        /// The destination (a NAS share, an external disk) went away.
        case destinationLost
    }

    public struct Progress: Sendable {
        public var done = 0
        public var total = 0
        public var bytesDone: Int64 = 0
        public var bytesTotal: Int64 = 0
        public var current = ""
        public init(total: Int = 0, bytesTotal: Int64 = 0) { self.total = total; self.bytesTotal = bytesTotal }
    }

    public struct Outcome: Sendable {
        /// Where this hand-over's files went (the photos', when videos have their own place).
        public var folder: URL
        /// The card's folder: the one to watch in a project.
        public var cardFolder: URL
        /// Where the videos went, when not with the photos.
        public var videoFolder: URL?
        public var videoCardFolder: URL?
        public var copied: [String] = []
        public var skipped: [String] = []
        public var failed: [(file: String, reason: String)] = []
        public var bytes: Int64 = 0
        public var interruption: Interruption?
        public var cancelled: Bool { interruption == .cancelled }
        public var started = Date()
        public var finished = Date()
    }

    /// The card's own folder under the destination, named after the card.
    public static func cardFolderName(_ card: CardRecord) -> String {
        card.displayName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
    }

    public static func handoverName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: date)
    }

    /// Copies the plan's new files, each streamed through SHA-256 to a temporary name, checked (size, and with
    /// `verify` read back and compared), given the original's modification time and then its final name, and
    /// recorded in the ledger as it lands. A file that already sits at the destination with the same contents is
    /// recorded, not copied again; one with the same name and other contents gets a numbered name. Files matched
    /// by contents while planning are recorded too, so the next look at the card is quick. A card pulled in the
    /// middle, or a destination that goes away, stops the copy at once (`interruption`): the files that landed are
    /// recorded, the rest stays new, and the next copy can go on in the same folder (`Options.folder`).
    public static func copy(_ plan: Plan, options: Options, store: LibraryStore,
                            progress: (Progress) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> Outcome {
        let fm = FileManager.default
        let stamp = handoverName(Date())
        let cardFolder = options.destination.appendingPathComponent(cardFolderName(plan.card), isDirectory: true)
        let folder = options.folder ?? (options.perHandover ? cardFolder.appendingPathComponent(stamp, isDirectory: true) : cardFolder)
        var out = Outcome(folder: folder, cardFolder: cardFolder)
        var videoFolder = folder
        if let v = options.videoDestination {
            let videoCard = v.appendingPathComponent(cardFolderName(plan.card), isDirectory: true)
            videoFolder = options.videoFolder ?? (options.perHandover ? videoCard.appendingPathComponent(stamp, isDirectory: true) : videoCard)
            out.videoFolder = videoFolder
            out.videoCardFolder = videoCard
        }
        var p = Progress(total: plan.new.count, bytesTotal: plan.newBytes)
        let cardId = plan.card.id!
        for (f, m) in plan.matched {
            try? record(f, key: m.key, sha: nil, to: m.to, cardId: cardId, store: store)
        }
        // JPEGs on the card by name without extension: a RAW with one is that JPEG's companion.
        let jpegs = Set(plan.files.filter { !$0.isSidecar && $0.kind == .photo && !ImageLoader.isRaw(URL(fileURLWithPath: $0.relPath)) }.map { ImageLoader.pairKey($0.relPath) })
        for f in plan.new {
            if isCancelled() { out.interruption = .cancelled; break }
            if !plan.identity.isReachable { out.interruption = .cardRemoved; break }
            p.current = f.name
            progress(p)
            let src = plan.identity.volume.appendingPathComponent(f.relPath)
            let srcKey = plan.keys[f.relPath] ?? ContentKey.compute(src, size: f.size) ?? "\(f.size)-"
            do {
                let base = f.kind == .video ? videoFolder : folder
                let dir = options.keepLayout ? base.appendingPathComponent((f.relPath as NSString).deletingLastPathComponent, isDirectory: true) : base
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dst = freeName(for: f.name, in: dir, sameAs: srcKey, size: f.size)
                if fm.fileExists(atPath: dst.path) {
                    // The same file is already there (an earlier copy by hand): remember it and move on.
                    try record(f, key: srcKey, sha: nil, to: dst.path, cardId: cardId, store: store)
                    out.skipped.append(f.relPath)
                } else {
                    let tmp = dir.appendingPathComponent(".copying-\(UUID().uuidString)")
                    defer { try? fm.removeItem(at: tmp) }
                    let before = p.bytesDone
                    let (size, sha) = try stream(src, to: tmp, isCancelled: isCancelled) { n in
                        p.bytesDone = before + n
                        progress(p)
                    }
                    guard size == f.size else { throw CopyError.sizeChanged }
                    if options.verify, FolderVerifier.sha256(tmp) != sha { throw CopyError.mismatch }
                    try? fm.setAttributes([.modificationDate: f.mtime], ofItemAtPath: tmp.path)
                    try fm.moveItem(at: tmp, to: dst)
                    try record(f, key: srcKey, sha: sha, to: dst.path, cardId: cardId, store: store)
                    if !f.isSidecar {
                        options.onCopied?(Landed(landed: dst, onCard: src, size: size, contentKey: srcKey,
                                                 rawWithJPEG: ImageLoader.isRaw(src) && jpegs.contains(ImageLoader.pairKey(f.relPath))))
                    }
                    out.copied.append(f.relPath)
                    out.bytes += size
                }
            } catch CopyError.cancelled {
                out.interruption = .cancelled
                break
            } catch {
                // A file that failed because the card or the destination is gone is not a failed file: it is
                // still new, and the copy goes on when they are back. The system takes a moment to finish
                // unmounting a pulled card, so look twice.
                let root = options.root(for: f.kind)
                var gone = !plan.identity.isReachable, lost = !reachable(root, volume: false)
                if !gone, !lost {
                    Thread.sleep(forTimeInterval: 0.5)
                    gone = !plan.identity.isReachable
                    lost = !reachable(root, volume: false)
                }
                if gone { out.interruption = .cardRemoved; break }
                if lost { out.interruption = .destinationLost; break }
                out.failed.append((f.relPath, error.localizedDescription))
            }
            p.done += 1
            p.bytesDone = max(p.bytesDone, plan.new.prefix(p.done).reduce(0) { $0 + $1.size })
            progress(p)
        }
        if !out.copied.isEmpty || !out.skipped.isEmpty {
            try? store.db.write { db in
                try db.execute(sql: "UPDATE card SET lastCopiedAt = ?, lastCopiedTo = ? WHERE id = ?", arguments: [Date(), folder.path, cardId])
            }
        }
        out.finished = Date()
        return out
    }

    /// Whether the card (or the destination) is still there. A volume is there while something is mounted at its
    /// path; a folder (a destination, or a folder standing in for a card) while it exists and its volume answers.
    static func reachable(_ url: URL, volume: Bool) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              let v = try? url.resourceValues(forKeys: [.volumeURLKey]), let mount = v.volume else { return false }
        return !volume || mount.standardizedFileURL.path == url.standardizedFileURL.path
    }

    enum CopyError: LocalizedError {
        case sizeChanged, mismatch, cancelled
        var errorDescription: String? {
            switch self {
            case .sizeChanged: "The file changed while it was being copied."
            case .mismatch: "The copy did not match the original."
            case .cancelled: "Cancelled."
            }
        }
    }

    /// `name`, or `name_1`, `name_2`… when a different file has it. The existing file with the same contents keeps
    /// its name and is returned as is (the caller sees it exists).
    static func freeName(for name: String, in dir: URL, sameAs key: String, size: Int64) -> URL {
        let fm = FileManager.default
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 0
        while true {
            let candidate = n == 0 ? name : (ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)")
            let u = dir.appendingPathComponent(candidate)
            guard fm.fileExists(atPath: u.path) else { return u }
            let existingSize = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? -1
            if existingSize == size, ContentKey.compute(u, size: size) == key { return u }
            n += 1
        }
    }

    /// Copies in 8 MB pieces, hashing on the way (the card is read once).
    static func stream(_ src: URL, to dst: URL, isCancelled: () -> Bool, bytes: (Int64) -> Void) throws -> (Int64, String) {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        var hasher = SHA256()
        var n: Int64 = 0
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
            if isCancelled() { throw CopyError.cancelled }
            try output.write(contentsOf: chunk)
            hasher.update(data: chunk)
            n += Int64(chunk.count)
            bytes(n)
        }
        try output.synchronize()
        return (n, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func record(_ f: File, key: String, sha: String?, to: String?, cardId: Int64, store: LibraryStore) throws {
        try store.db.write { db in
            try db.execute(sql: """
                INSERT INTO cardFile (cardId, relPath, size, mtime, contentKey, sha256, copiedAt, copiedTo) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cardId, relPath, contentKey) DO UPDATE SET size = excluded.size, mtime = excluded.mtime,
                    sha256 = COALESCE(excluded.sha256, sha256), copiedAt = excluded.copiedAt, copiedTo = COALESCE(excluded.copiedTo, copiedTo)
                """, arguments: [cardId, f.relPath, f.size, f.mtime.timeIntervalSince1970, key, sha, Date(), to])
        }
    }

    // MARK: Known cards

    public struct KnownCard: Identifiable, Hashable, Sendable {
        public var card: CardRecord
        public var files: Int
        public var bytes: Int64
        public var id: Int64 { card.id! }
    }

    /// How many ledger entries came from teammates' Macs: grows when the team sync brings a copy made elsewhere,
    /// which is when a mounted card's plan is worth redoing.
    public static func teammateCopies(store: LibraryStore) -> Int {
        (try? store.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cardFile WHERE device IS NOT NULL") }) ?? 0
    }

    public static func knownCards(store: LibraryStore) throws -> [KnownCard] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.*, (SELECT COUNT(*) FROM cardFile f WHERE f.cardId = c.id) AS files,
                       (SELECT COALESCE(SUM(size), 0) FROM cardFile f WHERE f.cardId = c.id) AS bytes
                FROM card c ORDER BY COALESCE(c.lastCopiedAt, c.firstSeenAt) DESC
                """).map { KnownCard(card: try CardRecord(row: $0), files: $0["files"], bytes: $0["bytes"]) }
        }
    }

    public static func setLabel(_ label: String, card id: Int64, store: LibraryStore) throws {
        let l = label.trimmingCharacters(in: .whitespaces)
        try store.db.write { db in
            try db.execute(sql: "UPDATE card SET label = ?, labelAt = ? WHERE id = ?", arguments: [l.isEmpty ? nil : l, Date().timeIntervalSince1970, id])
        }
    }

    /// Forgets the card and everything copied from it: the next hand-over copies all of it again.
    public static func forget(card id: Int64, store: LibraryStore) throws {
        try store.db.write { db in try db.execute(sql: "DELETE FROM card WHERE id = ?", arguments: [id]) }
    }
}
