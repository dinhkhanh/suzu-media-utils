import Foundation

/// Watches the staging folder for the team NAS: anything new under it goes up by itself, however it got there, a
/// card copy, a Finder drag, an export. The staging folder mirrors the folder on the NAS: each folder at its top
/// (a card's folder, an event's, a delivery, anything) travels as a unit to the same name there, and files dropped
/// at its top travel too, as its loose files.
///
/// FSEvents say something changed; the watcher then waits for the folder to go quiet (`settle`: a drag or a copy
/// in progress keeps changing it) before reporting the units that changed, each once. A slow poll stands in for
/// missed events.
public final class StagingWatcher: @unchecked Sendable {
    /// One thing to send: a top-level folder of the staging folder, or the staging folder's own files (`filesOnly`).
    public struct Unit: Hashable, Sendable {
        /// nil: the loose files at the top of the staging folder.
        public var folder: String?
        public var filesOnly: Bool { folder == nil }
        public var local: URL { folder.map { rootURL.appendingPathComponent($0, isDirectory: true) } ?? rootURL }
        /// Under the folder on the NAS; "" is that folder itself.
        public var remotePath: String { folder ?? "" }
        public var title: String { folder ?? "Loose files" }
        let rootURL: URL
        public init(root: URL, folder: String?) { rootURL = root; self.folder = folder }
    }

    public let root: URL
    /// Called on the watcher's queue with the units that changed and have been quiet for `settle`.
    let onChange: @Sendable ([Unit]) -> Void
    let queue = DispatchQueue(label: "staging-watcher", qos: .utility)
    /// How long a unit must go untouched before it is reported (a card copy writes a file every second or so).
    let settle: TimeInterval
    private var stream: FSEventStreamRef?
    private var poll: DispatchSourceTimer?
    /// Units seen changing, and when last.
    private var dirty: [Unit: Date] = [:]
    /// What each unit looked like when last reported (newest mtime and file count), so a look finds the new ones.
    private var seen: [Unit: Signature] = [:]
    private var checkScheduled = false
    private var started = false

    struct Signature: Equatable { var files: Int; var newest: TimeInterval; var bytes: Int64 }

    public init(root: URL, settle: TimeInterval = 20, onChange: @escaping @Sendable ([Unit]) -> Void) {
        self.root = root
        self.settle = settle
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // What is there now is taken as already known, except what is queued on top: a look at launch would
            // otherwise send every old folder again. The queue's own records say what went.
            seen = signatures()
            startFSEvents()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 60, repeating: 60)
            t.setEventHandler { [weak self] in self?.look() }
            t.resume()
            poll = t
        }
    }

    public func stop() {
        queue.sync {
            if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
            poll?.cancel()
            poll = nil
            started = false
        }
    }

    /// Everything under the root goes up (Send All Now): every unit, settled or not.
    public func reportAll() {
        queue.async { [self] in
            let all = signatures()
            seen = all
            if !all.isEmpty { onChange(Array(all.keys).sorted { $0.remotePath < $1.remotePath }) }
        }
    }

    /// When the unit's newest file was written (0: no files).
    public func lastChange(_ unit: Unit) -> Date { Date(timeIntervalSince1970: signature(unit).newest) }

    /// A unit went up: what it looks like now is the known state.
    public func markSent(_ unit: Unit) {
        queue.async { [self] in seen[unit] = signature(unit) }
    }

    // MARK: - Watching

    private func startFSEvents() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let me = Unmanaged<StagingWatcher>.fromOpaque(info!).takeUnretainedValue()
            me.look()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Compares every unit with what was last reported; changed ones are marked dirty now. Runs on `queue`.
    func look() {
        let now = Date()
        let current = signatures()
        for (unit, sig) in current where seen[unit] != sig {
            dirty[unit] = now
        }
        // Units that went away are forgotten.
        for unit in seen.keys where current[unit] == nil { seen[unit] = nil; dirty[unit] = nil }
        scheduleCheck()
    }

    private func scheduleCheck() {
        guard !checkScheduled, !dirty.isEmpty else { return }
        checkScheduled = true
        queue.asyncAfter(deadline: .now() + settle + 0.5) { [weak self] in
            self?.checkScheduled = false
            self?.check()
        }
    }

    /// Reports the dirty units that have been quiet for `settle`; the others wait for the next check.
    private func check() {
        let now = Date()
        var ready: [Unit] = []
        for (unit, at) in dirty {
            let sig = signature(unit)
            // Quiet: no event for `settle`, and no file written in the last `settle` either.
            if now.timeIntervalSince(at) >= settle, now.timeIntervalSince1970 - sig.newest >= settle {
                ready.append(unit)
                seen[unit] = sig
                dirty[unit] = nil
            } else if seen[unit] == sig {
                dirty[unit] = nil
            }
        }
        if !ready.isEmpty { onChange(ready.sorted { $0.remotePath < $1.remotePath }) }
        scheduleCheck()
    }

    // MARK: - Listing

    static func counts(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.hasPrefix("._") && !name.hasPrefix("~$") && name != "Icon\r"
    }

    /// Every unit under the root with its signature.
    func signatures() -> [Unit: Signature] {
        var out: [Unit: Signature] = [:]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return out }
        var loose = Signature(files: 0, newest: 0, bytes: 0)
        for i in items where Self.counts(i.lastPathComponent) {
            if (try? i.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                let u = Unit(root: root, folder: i.lastPathComponent)
                out[u] = signature(u)
            } else if let v = try? i.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                loose.files += 1
                loose.bytes += Int64(v.fileSize ?? 0)
                loose.newest = max(loose.newest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        if loose.files > 0 { out[Unit(root: root, folder: nil)] = loose }
        return out
    }

    func signature(_ unit: Unit) -> Signature {
        var sig = Signature(files: 0, newest: 0, bytes: 0)
        let fm = FileManager.default
        if unit.filesOnly {
            guard let items = try? fm.contentsOfDirectory(at: unit.local, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return sig }
            for i in items where Self.counts(i.lastPathComponent) {
                guard let v = try? i.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]), v.isDirectory != true else { continue }
                sig.files += 1
                sig.bytes += Int64(v.fileSize ?? 0)
                sig.newest = max(sig.newest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
            return sig
        }
        guard let e = fm.enumerator(at: unit.local, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return sig }
        for case let u as URL in e {
            guard Self.counts(u.lastPathComponent), let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true else { continue }
            sig.files += 1
            sig.bytes += Int64(v.fileSize ?? 0)
            sig.newest = max(sig.newest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return sig
    }
}
