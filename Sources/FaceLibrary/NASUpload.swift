import Foundation

/// How this Mac reaches the team NAS over ssh, for `RsyncUpload`. The app's defaults are the studio's NAS; the
/// Advanced disclosure under Settings → Team NAS can change them.
public struct NASConnection: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    /// Where card folders go on the NAS (the share's path as the NAS sees it, e.g. /volume1/photo).
    public var basePath: String
    /// This Mac's private key. nil: ssh's own keys and agent (the command line).
    public var identityFile: String?
    /// A known_hosts file with the NAS's host key, so no "are you sure" and no stranger in the middle on a public
    /// DDNS name. nil: ssh's own ~/.ssh/known_hosts, which must already hold the key.
    public var knownHostsFile: String?

    public init(host: String, port: Int = 22, user: String, basePath: String, identityFile: String? = nil, knownHostsFile: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.basePath = basePath
        self.identityFile = identityFile
        self.knownHostsFile = knownHostsFile
    }

    /// The studio's NAS.
    public static let suzu = NASConnection(host: "vnpt.ddns.suzu.one", port: 2904, user: "dinhkhanh", basePath: "/volume1/homes/00 SUZU MEDIA")

    /// `user@host`.
    public var target: String { "\(user)@\(host)" }

    /// `path` under `basePath` (an absolute `path` is used as is), in the form the NAS stores names in.
    public func remotePath(_ path: String) -> String {
        if path.hasPrefix("/") { return Self.nasForm(path) }
        return Self.nasForm((basePath as NSString).appendingPathComponent(path))
    }

    /// A name the way a Linux NAS keeps it: precomposed Unicode (NFC). A Mac writes "Ị" as I plus a combining
    /// dot (NFD), and that is what a path typed or pasted here carries; sent as is, it names a different folder
    /// on the NAS, which mkdir then creates next to the real one, looking the same.
    public static func nasForm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// The remote shell for rsync's -e: never asks (BatchMode), gives up on a dead link within a minute instead of
    /// hanging for hours, pins the host key when there is one.
    public var sshCommand: String {
        var parts = ["ssh", "-p", String(port), "-o", "BatchMode=yes", "-o", "ConnectTimeout=20",
                     "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
        if let identityFile {
            parts += ["-i", identityFile, "-o", "IdentitiesOnly=yes"]
        }
        if let knownHostsFile {
            // ssh splits UserKnownHostsFile on whitespace (it takes several files); ours is under "Application
            // Support", so the path goes in ssh's own double quotes.
            parts += ["-o", "UserKnownHostsFile=\"\(knownHostsFile)\"", "-o", "StrictHostKeyChecking=yes"]
        }
        return parts.map(Self.quoteForRsh).joined(separator: " ")
    }

    /// rsync splits -e on spaces and honours double quotes, a doubled quote standing for one (man rsync, --rsh);
    /// backslashes are not special. Our paths live under "SuZu Media Utils", so this matters.
    static func quoteForRsh(_ s: String) -> String {
        guard s.contains(" ") || s.contains("\"") || s.contains("'") || s.isEmpty else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// One folder to the NAS with rsync over ssh: resumable, shows progress, says in plain words what went wrong.
/// Synchronous and blocking, like `CardCopier.copy`; `NASUploadQueue` runs it off the main thread.
public enum RsyncUpload {
    /// What one run does.
    public enum Pass: String, Codable, Sendable, CaseIterable {
        /// JPEGs and HEICs only, so the team can start culling while the RAW files are still coming.
        case photosFirst
        /// Everything.
        case everything
        /// Everything again, comparing checksums instead of size and time: a damaged or half-written file on the
        /// NAS is sent again. Reads every file on both sides, so it costs about as long as a local copy.
        case verify

        /// The usual order for a card folder.
        public static let cardFolder: [Pass] = [.photosFirst, .everything, .verify]
    }

    public struct Progress: Sendable, Equatable {
        public var pass: Pass
        /// Of this pass. rsync reports the bytes it has walked through, including files it skipped because they
        /// were already there, so a resumed upload starts well above zero.
        public var bytesDone: Int64 = 0
        public var percent: Int = 0
        public var bytesPerSecond: Double = 0
        public var remaining: TimeInterval?
        /// Files still to look at, when rsync has said (`to-chk=N/M`).
        public var filesLeft: Int?
        public var filesTotal: Int?
        /// The file being sent.
        public var current: String = ""
        public init(pass: Pass) { self.pass = pass }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The NAS didn't answer: no network, the DDNS name pointing nowhere, the port not forwarded, the NAS off.
        case unreachable
        /// ssh got through but the NAS didn't accept this Mac's key (or asked for a password).
        case refusedKey
        /// The host key isn't the one pinned: a different machine answers to the NAS's name.
        case hostKeyMismatch
        /// The NAS is full.
        case diskFull
        /// The NAS user can't write there.
        case notWritable(String)
        /// A Synology's rsync checks the destination against DSM's shared-folder permissions, not the file system's,
        /// and when they say no it closes the connection without a word (the reason is in the NAS's own log).
        case refusedFolder(String)
        /// Some files didn't make it (the rest did); rsync's words for the first.
        case someFilesFailed(String)
        /// The link dropped in the middle, or the NAS's rsync stopped; rsync's words for it, when it had any.
        case interrupted(String)
        case cancelled
        /// The bundled rsync isn't there.
        case rsyncMissing(String)
        /// A Synology's rsync refuses to serve (exit 43, "rsync service is no running") until its rsync service is on
        /// and the user holds the rsync application privilege; it says the same for both.
        case rsyncServiceOff
        case other(code: Int32, message: String)

        /// In the user's words, for the status pill and the Team NAS pane.
        public var message: String {
            switch self {
            case .unreachable: return "The NAS is not reachable. Check the internet connection; the upload will try again."
            case .refusedKey: return "The NAS refused this Mac's key. Connect this Mac again under Settings → Team NAS."
            case .hostKeyMismatch: return "Another machine answers to the NAS's address. Nothing was sent; ask Khanh to check the NAS."
            case .diskFull: return "The NAS is full."
            case .notWritable(let s): return "The NAS user can't write there: \(s)"
            case .refusedFolder(let p): return "The NAS's rsync refuses to write to \(p) for this user. On a Synology the folder must be inside a shared folder the user has Read/Write on (Control Panel → Shared Folder → Permissions); the user's own home always works."
            case .someFilesFailed(let s): return "Some files couldn't be sent: \(s). The upload will try again."
            case .interrupted(let s): return s.isEmpty ? "The connection dropped. The upload will carry on from where it stopped." : "The connection dropped (\(s)). The upload will carry on from where it stopped."
            case .cancelled: return "Stopped."
            case .rsyncMissing(let p): return "The app's copy of rsync is missing (\(p))."
            case .rsyncServiceOff: return "The NAS refuses rsync for this user. On a Synology, two settings: Control Panel → File Services → rsync → Enable rsync service, and Control Panel → User & Group → the user → Edit → Applications → rsync → Allow."
            case .other(let code, let m): return m.isEmpty ? "rsync stopped with code \(code)." : m
            }
        }

        /// Worth another go later without anyone changing anything.
        public var isRetryable: Bool {
            switch self {
            case .unreachable, .diskFull, .someFilesFailed, .interrupted: return true
            case .refusedKey, .hostKeyMismatch, .notWritable, .refusedFolder, .cancelled, .rsyncMissing, .rsyncServiceOff, .other: return false
            }
        }
    }

    /// The app's rsync: Contents/Helpers/rsync in the bundle, or .build/rsync/bin/rsync when run from the
    /// package (scripts/build-rsync.sh makes it).
    public static var bundledRsync: URL {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rsync")
        if FileManager.default.isExecutableFile(atPath: helpers.path) { return helpers }
        if let env = ProcessInfo.processInfo.environment["SUZU_RSYNC"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: ".build/rsync/bin/rsync", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
    }

    /// Prefix on the stdout line that names each transferred file (`--out-format`), so names and progress tell apart.
    static let namePrefix = ">>"
    static let partialDir = ".rsync-partial"

    /// The rsync command line for one pass of `local` (a folder; its contents go into `remotePath` on the NAS).
    public static func arguments(local: URL, remotePath: String, connection: NASConnection, pass: Pass, filesOnly: Bool = false) -> [String] {
        // -rlt rather than -a: no -p/-o/-g, which on a Synology share with ACLs fail with "Operation not permitted"
        // (exit 23) and would mark every upload as partly failed; the share's own permissions apply instead.
        // The folder is made on the NAS by the remote shell rather than by --mkpath, which a Synology's older rsync
        // doesn't know. The path is single-quoted for that shell.
        let remotePath = NASConnection.nasForm(remotePath)
        let mkdir = "mkdir -p '" + remotePath.replacingOccurrences(of: "'", with: "'\\''") + "' && rsync"
        var args = ["-rlt", "--partial", "--partial-dir=\(partialDir)", "--secluded-args", "--rsync-path=\(mkdir)",
                    "--info=progress2", "--no-inc-recursive", "--out-format=\(namePrefix)%n",
                    "--exclude=.DS_Store", "--exclude=.copying-*", "--exclude=\(partialDir)",
                    "-e", connection.sshCommand]
        // The folder's own files, none of its folders (they travel as units of their own): first rule wins.
        if filesOnly { args.append("--exclude=*/") }
        switch pass {
        case .photosFirst:
            args += ["--include=*/"]
            for ext in ["jpg", "jpeg", "heic", "JPG", "JPEG", "HEIC"] { args.append("--include=*.\(ext)") }
            args.append("--exclude=*")
        case .everything:
            break
        case .verify:
            args.append("--checksum")
        }
        var src = local.standardizedFileURL.path
        if !src.hasSuffix("/") { src += "/" }
        args += [src, "\(connection.target):\(remotePath)"]
        return args
    }

    /// Sends `local`'s contents to `remotePath` on the NAS, pass after pass. Throws the first failure; what landed
    /// before it stays on the NAS and the next run carries on from there.
    public static func upload(_ local: URL, to remotePath: String, connection: NASConnection, rsync: URL = bundledRsync,
                              passes: [Pass] = Pass.cardFolder, filesOnly: Bool = false,
                              progress: @escaping @Sendable (Progress) -> Void = { _ in },
                              isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        guard FileManager.default.isExecutableFile(atPath: rsync.path) else { throw Failure.rsyncMissing(rsync.path) }
        for pass in passes {
            if isCancelled() { throw Failure.cancelled }
            try run(rsync, arguments: arguments(local: local, remotePath: remotePath, connection: connection, pass: pass, filesOnly: filesOnly),
                    pass: pass, progress: progress, isCancelled: isCancelled)
        }
    }

    /// One rsync; its stdout feeds `progress`, its stderr the failure. Started with RawProcess, not Foundation's
    /// Process, so the NAS gets folder names byte for byte (Process would decompose the Vietnamese ones).
    static func run(_ rsync: URL, arguments: [String], pass: Pass,
                    progress: @escaping @Sendable (Progress) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        let reader = OutputReader(pass: pass, progress: progress)
        let stderr = Collector()
        let child: RawProcess.Child
        do { child = try RawProcess.spawn(rsync.path, arguments: arguments, environment: env) } catch { throw Failure.rsyncMissing(rsync.path) }
        child.stdout.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { reader.feed(d) }
        }
        child.stderr.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { stderr.append(d) }
        }
        var cancelled = false
        var exit: RawProcess.Exit
        while true {
            if let e = RawProcess.poll(child) { exit = e; break }
            if !cancelled, isCancelled() {
                cancelled = true
                RawProcess.terminate(child)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Whatever is still in the pipes after exit.
        child.stdout.readabilityHandler = nil
        child.stderr.readabilityHandler = nil
        reader.feed(child.stdout.readDataToEndOfFile())
        stderr.append(child.stderr.readDataToEndOfFile())
        if cancelled { throw Failure.cancelled }
        if exit.signaled { throw Failure.interrupted("") }
        if exit.status != 0 { throw classify(code: exit.status, stderr: stderr.string, remotePath: arguments.last.map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0 }) }
    }

    /// rsync's exit code and words, in ours.
    public static func classify(code: Int32, stderr: String, remotePath: String? = nil) -> Failure {
        let s = stderr
        // Synology: the server ends the session before the first byte when DSM's permissions say no.
        if code == 12, let remotePath, s.contains("closed (0 bytes received so far)"), !s.contains("ssh:"), !s.contains("Permission denied (") {
            return .refusedFolder(remotePath)
        }
        if s.contains("Host key verification failed") || s.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || s.contains("No ED25519 host key is known") || s.contains("host key for") && s.contains("has changed") {
            return .hostKeyMismatch
        }
        // ssh's refusal names the methods it tried ("Permission denied (publickey,password)"); rsync's own
        // "Permission denied (13)" is a file the NAS user can't write, further down.
        if s.contains("Permission denied (publickey") || s.contains("Permission denied (password") || s.contains("Permission denied (keyboard")
            || s.contains("Permission denied, please try again") {
            return .refusedKey
        }
        if s.contains("No space left on device") { return .diskFull }
        if s.contains("rsync service is no") { return .rsyncServiceOff }
        if code == 255 || s.contains("Could not resolve hostname") || s.contains("Connection refused") || s.contains("Connection timed out")
            || s.contains("Network is unreachable") || s.contains("No route to host") || s.contains("Operation timed out") || s.contains("Connection closed by") {
            return .unreachable
        }
        if s.contains("Permission denied") || s.contains("Read-only file system") {
            return .notWritable(firstRsyncLine(s))
        }
        switch code {
        case 20: return .cancelled
        case 10, 12, 30, 35: return .interrupted(firstRsyncLine(s))
        case 23, 24: return .someFilesFailed(firstRsyncLine(s))
        default: return .other(code: code, message: firstRsyncLine(s))
        }
    }

    /// rsync's first complaint, without the "rsync: " and "(code N) at main.c" noise.
    static func firstRsyncLine(_ stderr: String) -> String {
        for raw in stderr.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("rsync error:") { continue }
            if line.hasPrefix("rsync: ") { line.removeFirst("rsync: ".count) }
            if let r = line.range(of: " (code ") { line = String(line[..<r.lowerBound]) }
            if let r = line.range(of: " at main.c") { line = String(line[..<r.lowerBound]) }
            return line
        }
        return ""
    }

    /// A `--info=progress2` line: `  1,234,567  45%   11.23MB/s    0:01:23 (xfr#12, to-chk=100/312)`. nil for
    /// anything else.
    public static func parseProgress(_ line: String, into p: inout Progress) -> Bool {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 4, fields[1].hasSuffix("%"), fields[2].hasSuffix("/s"),
              let bytes = Int64(fields[0].replacingOccurrences(of: ",", with: "")),
              let percent = Int(fields[1].dropLast()) else { return false }
        p.bytesDone = bytes
        p.percent = percent
        p.bytesPerSecond = parseRate(fields[2])
        p.remaining = parseDuration(fields[3])
        if let r = line.range(of: "to-chk=") {
            let rest = line[r.upperBound...].prefix { $0 != ")" }
            let parts = rest.split(separator: "/")
            if parts.count == 2, let left = Int(parts[0]), let total = Int(parts[1]) {
                p.filesLeft = left
                p.filesTotal = total
            }
        }
        return true
    }

    static func parseRate(_ s: String) -> Double {
        var t = s
        t.removeLast(2)
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            t.removeLast(u.count)
            return (Double(t) ?? 0) * m
        }
        return Double(t) ?? 0
    }

    /// `h:mm:ss` or `d:hh:mm:ss`; rsync prints `??:??:??` when it doesn't know yet.
    static func parseDuration(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        var total = 0
        for p in parts { total = total * 60 + p! }
        if parts.count == 4 { total = parts[0]! * 86400 + parts[1]! * 3600 + parts[2]! * 60 + parts[3]! }
        return TimeInterval(total)
    }

    /// Splits rsync's stdout into progress updates (ended by `\r`) and file names (ended by `\n`).
    final class OutputReader: @unchecked Sendable {
        private var buffer = Data()
        private var progress: Progress
        private let report: @Sendable (Progress) -> Void
        private let lock = NSLock()

        init(pass: Pass, progress: @escaping @Sendable (Progress) -> Void) {
            self.progress = Progress(pass: pass)
            report = progress
        }

        func feed(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(d)
            while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...i)
                take(line)
            }
        }

        private func take(_ raw: String) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            if line.hasPrefix(namePrefix) {
                let name = String(line.dropFirst(namePrefix.count))
                if !name.hasSuffix("/") { progress.current = name }
                return
            }
            if RsyncUpload.parseProgress(line, into: &progress) { report(progress) }
        }
    }

    final class Collector: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

extension RsyncUpload {
    /// Tries the connection without sending anything: ssh in with the key and look at the base path. Returns a
    /// sentence for the Team NAS pane, or throws a `Failure` with one.
    public static func testConnection(_ c: NASConnection, rsync: URL = bundledRsync) throws -> String {
        var args = ["-p", String(c.port), "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
        if let k = c.identityFile { args += ["-i", k, "-o", "IdentitiesOnly=yes"] }
        if let h = c.knownHostsFile { args += ["-o", "UserKnownHostsFile=\"\(h)\"", "-o", "StrictHostKeyChecking=yes"] }
        let base = NASConnection.nasForm(c.basePath)
        let quoted = "'" + base.replacingOccurrences(of: "'", with: "'\\''") + "'"
        args += [c.target, "if [ -d \(quoted) ]; then if [ -w \(quoted) ]; then echo writable; else echo readonly; fi; else echo missing; fi; rsync --version 2>/dev/null | head -1"]
        let child = try RawProcess.spawn("/usr/bin/ssh", arguments: args)
        let o = String(decoding: child.stdout.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: child.stderr.readDataToEndOfFile(), as: UTF8.self)
        let exit = RawProcess.wait(child)
        guard exit.status == 0, !exit.signaled else { throw classify(code: exit.signaled ? 255 : exit.status, stderr: e) }
        let lines = o.split(whereSeparator: \.isNewline).map(String.init)
        let rsyncLine = lines.first { $0.hasPrefix("rsync") }.map { $0.split(separator: " ").prefix(3).joined(separator: " ") }
        guard let rsyncLine else { throw Failure.other(code: 0, message: "The NAS answered, but has no rsync. Enable the rsync service on it (Synology: File Services → rsync).") }
        switch lines.first {
        case "writable":
            // What the NAS's own rsync says about the folder: a Synology checks DSM's shared-folder permissions,
            // which the shell's -w knows nothing about, and refuses silently. A dry run of nothing tells.
            if FileManager.default.isExecutableFile(atPath: rsync.path) {
                let empty = FileManager.default.temporaryDirectory.appendingPathComponent("suzu-empty-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: empty) }
                var a = arguments(local: empty, remotePath: c.basePath, connection: c, pass: .everything)
                a.insert("--dry-run", at: 0)
                try run(rsync, arguments: a, pass: .everything, progress: { _ in }, isCancelled: { false })
            }
            return "Connected as \(c.user). \(c.basePath) is there and writable; the NAS has \(rsyncLine)."
        case "readonly": throw Failure.notWritable("\(c.basePath) is there but \(c.user) can't write to it")
        default:
            // The path as the NAS sees it: on a Synology every share is under /volume1 (or /volume2…), so
            // "/homes/Events" is really "/volume1/homes/Events".
            let hint = c.basePath.hasPrefix("/volume") ? "" : " On a Synology the shares are under /volume1: try /volume1\(c.basePath)."
            throw Failure.notWritable("\(c.basePath) is not on the NAS.\(hint)")
        }
    }
}
