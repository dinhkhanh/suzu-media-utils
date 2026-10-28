import Foundation
import GRDB
import XCTest
@testable import FaceLibrary

/// The NAS uploader: rsync's words read right, the command line is the one we mean, and the queue drives rsync
/// through a job, a dropped link and a stop. rsync itself is stood in for by a script (`fakeRsync`) so the tests
/// need no NAS and no network; `testRealRsyncCopiesLocally` runs the built rsync when scripts/build-rsync.sh has
/// made it.
final class NASUploadTests: XCTestCase {
    var tmp: URL!
    var store: LibraryStore!
    var local: URL!
    var remoteRoot: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nas-\(UUID().uuidString)")
        local = tmp.appendingPathComponent("staging/Nam R5 card 1/2026-10-28 14.05", isDirectory: true)
        remoteRoot = tmp.appendingPathComponent("nas", isDirectory: true)
        try FileManager.default.createDirectory(at: local.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: local.appendingPathComponent("IMG_0001.JPG"))
        try Data(repeating: 2, count: 9000).write(to: local.appendingPathComponent("IMG_0001.CR3"))
        try Data(repeating: 3, count: 100).write(to: local.appendingPathComponent("sub/IMG_0002.JPG"))
        store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    var connection: NASConnection {
        NASConnection(host: "nas.test", port: 2904, user: "uploader", basePath: remoteRoot.path,
                      identityFile: tmp.appendingPathComponent("My Keys/id_ed25519").path)
    }

    /// Stands in for rsync: copies the source folder into the "remote" path (its `user@host:` stripped), printing
    /// progress like `--info=progress2` and file names like `--out-format`. `FAKE_FAIL_TIMES` in a file beside it
    /// makes the first N runs die as if the NAS were unreachable.
    func fakeRsync(failTimes: Int = 0) throws -> URL {
        let dir = tmp.appendingPathComponent("fake", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let counter = dir.appendingPathComponent("runs")
        try "0".write(to: counter, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("rsync")
        let body = """
        #!/bin/zsh
        set -e
        runs=$(cat "\(counter.path)"); runs=$((runs + 1)); echo $runs > "\(counter.path)"
        if (( runs <= \(failTimes) )); then
          echo "ssh: connect to host nas.test port 2904: Connection refused" >&2
          echo "rsync: connection unexpectedly closed (0 bytes received so far) [sender]" >&2
          echo "rsync error: unexplained error (code 255) at io.c(231) [sender=3.5.1]" >&2
          exit 255
        fi
        args=("$@")
        src="${args[-2]}"
        dst="${args[-1]#*:}"
        mkdir -p "$dst"
        printf '%s\\n' "${args[@]}" > "\(dir.path)/last-args"
        for f in "$src"**/*(.ND); do
          rel="${f#$src}"
          mkdir -p "$dst/$(dirname "$rel")"
          cp "$f" "$dst/$rel"
          echo ">>$rel"
          printf '      1,234  50%%    1.20MB/s    0:00:01 (xfr#1, to-chk=1/3)\\r'
          sleep 0.3
        done
        printf '     14,100 100%%    2.50MB/s    0:00:00 (xfr#3, to-chk=0/3)\\n'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testProgressLineReads() {
        var p = RsyncUpload.Progress(pass: .everything)
        XCTAssertTrue(RsyncUpload.parseProgress("  1,234,567,890  45%   11.23MB/s    0:01:23 (xfr#12, to-chk=100/312)", into: &p))
        XCTAssertEqual(p.bytesDone, 1_234_567_890)
        XCTAssertEqual(p.percent, 45)
        XCTAssertEqual(p.bytesPerSecond, 11_230_000, accuracy: 1)
        XCTAssertEqual(p.remaining, 83)
        XCTAssertEqual(p.filesLeft, 100)
        XCTAssertEqual(p.filesTotal, 312)
        XCTAssertTrue(RsyncUpload.parseProgress("32,768   0%   31.25kB/s    ??:??:??", into: &p))
        XCTAssertEqual(p.bytesPerSecond, 31_250, accuracy: 1)
        XCTAssertNil(p.remaining)
        XCTAssertTrue(RsyncUpload.parseProgress("5,000,000,000 100%    1.05GB/s    1:02:03:04 (xfr#9, to-chk=0/9)", into: &p))
        let dayPlus: TimeInterval = 93784
        XCTAssertEqual(p.remaining, dayPlus)
        XCTAssertFalse(RsyncUpload.parseProgress(">>IMG_0001.JPG", into: &p))
        XCTAssertFalse(RsyncUpload.parseProgress("sending incremental file list", into: &p))
    }

    func testRsyncWordsBecomeOurs() {
        XCTAssertEqual(RsyncUpload.classify(code: 255, stderr: "ssh: connect to host nas port 2904: Connection refused\nrsync error: unexplained error (code 255)"), .unreachable)
        XCTAssertEqual(RsyncUpload.classify(code: 255, stderr: "uploader@nas: Permission denied (publickey,password).\nrsync: connection unexpectedly closed"), .refusedKey)
        XCTAssertEqual(RsyncUpload.classify(code: 255, stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed."), .hostKeyMismatch)
        XCTAssertEqual(RsyncUpload.classify(code: 11, stderr: "rsync: [receiver] write failed on \"/volume1/photo/x.CR3\": No space left on device (28)"), .diskFull)
        XCTAssertEqual(RsyncUpload.classify(code: 23, stderr: "rsync: [receiver] mkstemp \"/volume1/photo/.x.CR3.abc\" failed: Permission denied (13)\nrsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338) [sender=3.5.1]"),
                       .notWritable("[receiver] mkstemp \"/volume1/photo/.x.CR3.abc\" failed: Permission denied (13)"))
        XCTAssertEqual(RsyncUpload.classify(code: 23, stderr: "rsync: [sender] read errors mapping \"/x/IMG.CR3\": Input/output error (5)\nrsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338)"),
                       .someFilesFailed("[sender] read errors mapping \"/x/IMG.CR3\": Input/output error (5)"))
        XCTAssertEqual(RsyncUpload.classify(code: 12, stderr: "rsync: connection unexpectedly closed (1234 bytes received so far) [sender]"), .interrupted("connection unexpectedly closed (1234 bytes received so far) [sender]"))
        XCTAssertEqual(RsyncUpload.classify(code: 12, stderr: "sh: rsync: command not found\nrsync: connection unexpectedly closed (0 bytes received so far) [sender]\nrsync error: error in rsync protocol data stream (code 12) at io.c(231)"), .interrupted("sh: rsync: command not found"))
        XCTAssertEqual(RsyncUpload.classify(code: 20, stderr: ""), .cancelled)
        XCTAssertEqual(RsyncUpload.classify(code: 12, stderr: "rsync: connection unexpectedly closed (0 bytes received so far) [sender]\nrsync error: error in rsync protocol data stream (code 12) at io.c(303) [sender=3.5.1]", remotePath: "/volume1/homes/Events"),
                       .refusedFolder("/volume1/homes/Events"), "a Synology saying no to the folder, silently")
        XCTAssertEqual(RsyncUpload.classify(code: 12, stderr: "ssh: connect to host nas port 2904: Connection refused\nrsync: connection unexpectedly closed (0 bytes received so far) [sender]", remotePath: "/x"), .unreachable)
        XCTAssertFalse(RsyncUpload.Failure.refusedFolder("/x").isRetryable)
        XCTAssertEqual(RsyncUpload.classify(code: 12, stderr: "rsync error: rsync service is no running (code 43) at io.c(254) [Receiver=3.1.2]\nrsync: connection unexpectedly closed (0 bytes received so far) [sender]"), .rsyncServiceOff)
        XCTAssertFalse(RsyncUpload.Failure.rsyncServiceOff.isRetryable)
        XCTAssertEqual(RsyncUpload.classify(code: 1, stderr: "rsync: --no-such-option: unknown option"), .other(code: 1, message: "--no-such-option: unknown option"))
        XCTAssertTrue(RsyncUpload.Failure.unreachable.isRetryable)
        XCTAssertTrue(RsyncUpload.Failure.interrupted("").isRetryable)
        XCTAssertFalse(RsyncUpload.Failure.refusedKey.isRetryable)
        XCTAssertFalse(RsyncUpload.Failure.hostKeyMismatch.isRetryable)
    }

    func testCommandLine() {
        let c = NASConnection(host: "vnpt.ddns.suzu.one", port: 2904, user: "uploader", basePath: "/volume1/photo",
                              identityFile: "/Users/me/Library/Application Support/SuZu Media Utils/nas_key",
                              knownHostsFile: "/Applications/SuZu Media Utils.app/Contents/Resources/nas_known_hosts")
        XCTAssertEqual(c.remotePath("Event/Nam R5 card 1"), "/volume1/photo/Event/Nam R5 card 1")
        XCTAssertEqual(c.remotePath("/volume2/other"), "/volume2/other")
        // A Vietnamese name as a Mac types it (I + combining dot below) goes to the NAS precomposed, as it keeps names.
        let nfd = "16 - CHI\u{0323} EM 3"
        XCTAssertEqual(Array(c.remotePath(nfd).unicodeScalars.suffix(10).map { $0.value }).contains(0x1ECA), true)
        XCTAssertEqual(c.remotePath(nfd), "/volume1/photo/16 - CHỊ EM 3")
        XCTAssertTrue(RsyncUpload.arguments(local: URL(fileURLWithPath: "/tmp/x"), remotePath: "/v/" + nfd, connection: c, pass: .everything).last!.hasSuffix("/v/16 - CHỊ EM 3"))
        // Paths with spaces are double-quoted for rsync's own -e parsing; everything else bare.
        XCTAssertEqual(c.sshCommand, "ssh -p 2904 -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "
                       + "-i \"/Users/me/Library/Application Support/SuZu Media Utils/nas_key\" -o IdentitiesOnly=yes "
                       + "-o \"UserKnownHostsFile=\"\"/Applications/SuZu Media Utils.app/Contents/Resources/nas_known_hosts\"\"\" -o StrictHostKeyChecking=yes",
                       "ssh's own quotes around the file (it splits the option on spaces), doubled for rsync's -e parsing")
        XCTAssertEqual(NASConnection.quoteForRsh("a\"b c"), "\"a\"\"b c\"")
        let a = RsyncUpload.arguments(local: URL(fileURLWithPath: "/tmp/stage/card"), remotePath: "/volume1/photo/E/card", connection: c, pass: .photosFirst)
        XCTAssertEqual(a.suffix(2), ["/tmp/stage/card/", "uploader@vnpt.ddns.suzu.one:/volume1/photo/E/card"])
        XCTAssertTrue(a.contains("--partial-dir=.rsync-partial"), "half-sent files never sit under their final name")
        XCTAssertTrue(a.contains("--secluded-args"), "spaces in the card's name reach the NAS intact")
        XCTAssertTrue(a.contains("--rsync-path=mkdir -p '/volume1/photo/E/card' && rsync"), "the folder is made by the remote shell, not --mkpath")
        let quoted = RsyncUpload.arguments(local: URL(fileURLWithPath: "/tmp/x"), remotePath: "/volume1/photo/Nam's card", connection: c, pass: .everything)
        XCTAssertTrue(quoted.contains("--rsync-path=mkdir -p '/volume1/photo/Nam'\\''s card' && rsync"))
        XCTAssertTrue(a.contains("--include=*.JPG") && a.contains("--exclude=*") && a.last != "--exclude=*")
        XCTAssertFalse(a.contains("-a"), "no -p/-o/-g on a Synology share with ACLs")
        XCTAssertEqual(a[a.firstIndex(of: "-e")! + 1], c.sshCommand)
        let v = RsyncUpload.arguments(local: URL(fileURLWithPath: "/tmp/stage/card/"), remotePath: "/x", connection: c, pass: .verify)
        XCTAssertTrue(v.contains("--checksum"))
        XCTAssertFalse(v.contains("--include=*/"))
        XCTAssertEqual(RsyncUpload.arguments(local: URL(fileURLWithPath: "/tmp/stage/card/"), remotePath: "/x", connection: c, pass: .everything).filter { $0.hasPrefix("--include") }, [])
    }

    /// Swift compares strings by canonical equivalence, so only the bytes prove it: "Ị" typed on a Mac (I + U+0323)
    /// reaches the NAS as U+1ECA, the one form it keeps.
    func testVietnameseNamesGoPrecomposed() {
        let nfd = "16 - CHI\u{0323} EM 3"
        let hex = Array(NASConnection.nasForm(nfd).utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(hex.contains("e1bb8a"))
        XCTAssertFalse(hex.contains("49cca3"))
        let c = NASConnection(host: "h", user: "u", basePath: "/volume1/" + nfd)
        let sent = RsyncUpload.arguments(local: URL(fileURLWithPath: "/tmp/x"), remotePath: c.remotePath("card"), connection: c, pass: .everything)
        let remote = Array(sent.last!.utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(remote.contains("e1bb8a") && !remote.contains("49cca3"), "the destination")
        let mkdir = Array(sent.first { $0.hasPrefix("--rsync-path=") }!.utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(mkdir.contains("e1bb8a") && !mkdir.contains("49cca3"), "and the mkdir before it")
    }

    func testBackoffGrowsThenHolds() {
        XCTAssertEqual(NASUploadQueue.backoff(attempt: 1), 30)
        XCTAssertEqual(NASUploadQueue.backoff(attempt: 2), 60)
        XCTAssertEqual(NASUploadQueue.backoff(attempt: 4), 240)
        XCTAssertEqual(NASUploadQueue.backoff(attempt: 9), 600)
    }

    /// A job goes through every pass, leaves the marker, reports progress, and is done; the files are on the "NAS".
    func testQueueUploadsAndLeavesMarker() async throws {
        let rsync = try fakeRsync()
        let conn = connection
        let q = NASUploadQueue(store: store, rsync: rsync, backoff: { _ in 0.1 }, connection: { conn })
        let seen = Seen()
        await q.setOnChange { seen.add($0) }
        let marker = #"{"card":"Nam R5 card 1","handover":"2026-10-28 14.05"}"#
        let job = try await q.enqueue(local: local, remotePath: "Event/Nam R5 card 1/2026-10-28 14.05", title: "Nam R5 card 1 · 14.05",
                                      marker: Data(marker.utf8), deleteLocalWhenDone: true)
        await q.start()
        try await waitUntil { (try? await q.jobs().first?.state) == .done }
        let remote = remoteRoot.appendingPathComponent("Event/Nam R5 card 1/2026-10-28 14.05")
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("IMG_0001.CR3")).count, 9000)
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("sub/IMG_0002.JPG")).count, 100)
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent(NASUploadQueue.markerName), encoding: .utf8), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path), "the staging copy goes once it is on the NAS")
        let runs = try String(contentsOf: tmp.appendingPathComponent("fake/runs"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(runs, "4", "photos first, everything, verify, then the marker")
        let lastArgs = try String(contentsOf: tmp.appendingPathComponent("fake/last-args"), encoding: .utf8)
        XCTAssertTrue(lastArgs.contains("--include=\(NASUploadQueue.markerName)\n--exclude=*\n"), "the marker run touches nothing else")
        XCTAssertTrue(lastArgs.contains("uploader@nas.test:\(remote.path)"))
        let statuses = seen.all
        XCTAssertTrue(statuses.contains { if case .uploading(let j, let p) = $0.phase { return j.id == job.id && p.percent > 0 && p.current.hasSuffix(".JPG") || p.current.hasSuffix(".CR3") }; return false },
                      "progress with the file's name reached the app")
        XCTAssertEqual(statuses.last?.phase, .idle)
        XCTAssertEqual(statuses.last?.queued, 0)
        let done = try await q.jobs().first!
        XCTAssertEqual(done.attempts, 1)
        XCTAssertNotNil(done.finishedAt)
    }

    /// The NAS is unreachable twice; the job waits (with the reason) and goes through on the third try.
    func testQueueTriesAgainWhenUnreachable() async throws {
        let rsync = try fakeRsync(failTimes: 2)
        let conn = connection
        let q = NASUploadQueue(store: store, rsync: rsync, backoff: { _ in 0.2 }, connection: { conn })
        let seen = Seen()
        await q.setOnChange { seen.add($0) }
        try await q.enqueue(local: local, remotePath: "Event/card", title: "card")
        await q.start()
        try await waitUntil { (try? await q.jobs().first?.state) == .done }
        let job = try await q.jobs().first!
        XCTAssertEqual(job.attempts, 3)
        XCTAssertTrue(seen.all.contains { if case .waiting(_, _, let reason) = $0.phase { return reason == RsyncUpload.Failure.unreachable.message }; return false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent("Event/card/IMG_0001.CR3").path))
    }

    /// A refused key is not tried again: the job is failed with the words for the pane, and the next job still runs.
    func testRefusedKeyStopsTheJobNotTheQueue() async throws {
        let rsync = try fakeRsync()
        let bad = tmp.appendingPathComponent("fake/bad-rsync")
        try """
        #!/bin/zsh
        if [[ "${@[-1]}" == *refused* ]]; then echo 'uploader@nas.test: Permission denied (publickey).' >&2; exit 255; fi
        exec "\(rsync.path)" "$@"
        """.write(to: bad, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bad.path)
        let conn = connection
        let q = NASUploadQueue(store: store, rsync: bad, backoff: { _ in 0.1 }, connection: { conn })
        try await q.enqueue(local: local, remotePath: "refused/card", title: "first")
        try await q.enqueue(local: local, remotePath: "ok/card", title: "second")
        await q.start()
        try await waitUntil {
            let states = (try? await q.jobs().map(\.state)) ?? []
            return states == [.done, .failed]
        }
        let jobs = try await q.jobs()
        XCTAssertEqual(jobs[1].lastError, RsyncUpload.Failure.refusedKey.message)
        XCTAssertEqual(jobs[1].attempts, 1)
        let status = await q.status
        XCTAssertEqual(status.failed.map(\.title), ["first"])
        try await q.retry(jobs[1].id!)
        let after = try await q.jobs()
        XCTAssertEqual(after[1].state, .queued)
    }

    /// The built rsync, local to local, through the same reader: files land and progress comes back.
    func testRealRsyncCopiesLocally() throws {
        let rsync = RsyncUpload.bundledRsync
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: rsync.path), "no built rsync at \(rsync.path); run scripts/build-rsync.sh")
        let dest = remoteRoot.appendingPathComponent("local copy", isDirectory: true)
        var args = RsyncUpload.arguments(local: local, remotePath: dest.path, connection: connection, pass: .everything)
        args.removeLast()
        args.append(dest.path)
        if let e = args.firstIndex(of: "-e") { args.removeSubrange(e...e + 1) }
        let seen = Seen()
        try RsyncUpload.run(rsync, arguments: args, pass: .everything, progress: { seen.addProgress($0) }, isCancelled: { false })
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("IMG_0001.CR3")).count, 9000)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("sub/IMG_0002.JPG")).count, 100)
        XCTAssertEqual(seen.progress.last?.percent, 100)
        XCTAssertEqual(seen.progress.last?.filesLeft, 0)
    }

    func waitUntil(_ timeout: TimeInterval = 20, _ cond: () async -> Bool) async throws {
        let start = Date()
        while !(await cond()) {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [NASUploadQueue.Status] = []
        private var progresses: [RsyncUpload.Progress] = []
        func add(_ s: NASUploadQueue.Status) { lock.lock(); statuses.append(s); lock.unlock() }
        func addProgress(_ p: RsyncUpload.Progress) { lock.lock(); progresses.append(p); lock.unlock() }
        var all: [NASUploadQueue.Status] { lock.lock(); defer { lock.unlock() }; return statuses }
        var progress: [RsyncUpload.Progress] { lock.lock(); defer { lock.unlock() }; return progresses }
    }
}
