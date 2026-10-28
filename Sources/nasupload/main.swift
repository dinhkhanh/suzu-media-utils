import FaceLibrary
import Foundation

// Sends a folder to the NAS the way the app will (RsyncUpload), from the command line, to try the connection and
// watch the progress without the app:
//
//   swift run nasupload "~/SuZu Staging/Nam R5 card 1/2026-10-28 14.05" "Event/Nam R5 card 1/2026-10-28 14.05" \
//       --user dinhkhanh --key ~/.ssh/nas_uploader
//
// The remote path is under the connection's base path (/volume1/photo) unless it starts with "/". Options:
//   --host H --port N --user U --base /volume1/photo   the connection (defaults: the studio NAS)
//   --key FILE          this Mac's private key (default: ssh's own keys and agent)
//   --known-hosts FILE  pin the NAS's host key (default: ~/.ssh/known_hosts)
//   --rsync FILE        the rsync to run (default: .build/rsync/bin/rsync, from scripts/build-rsync.sh)
//   --pass P            photosFirst | everything | verify; repeat for several (default: all three, in that order)
//   --dry               print the rsync command line and stop

var args = Array(CommandLine.arguments.dropFirst())
var positional: [String] = []
var conn = NASConnection.suzu
var rsync: URL?
var passes: [RsyncUpload.Pass] = []
var dry = false

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(2)
}

while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(a) needs a value") }
        return args.removeFirst()
    }
    switch a {
    case "--host": conn.host = value()
    case "--port":
        guard let n = Int(value()) else { fail("--port needs a number") }
        conn.port = n
    case "--user": conn.user = value()
    case "--base": conn.basePath = value()
    case "--key": conn.identityFile = expand(value())
    case "--known-hosts": conn.knownHostsFile = expand(value())
    case "--rsync": rsync = URL(fileURLWithPath: expand(value()))
    case "--pass":
        guard let p = RsyncUpload.Pass(rawValue: value()) else { fail("--pass is photosFirst, everything or verify") }
        passes.append(p)
    case "--dry": dry = true
    case "-h", "--help":
        print("usage: nasupload <local folder> <remote path> [--host H] [--port N] [--user U] [--base P] [--key FILE] [--known-hosts FILE] [--rsync FILE] [--pass P]... [--dry]")
        exit(0)
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)") }
        positional.append(a)
    }
}
guard positional.count == 2 else { fail("usage: nasupload <local folder> <remote path> [options]; --help for the options") }
let local = URL(fileURLWithPath: expand(positional[0]), isDirectory: true)
let remote = conn.remotePath(positional[1])
if passes.isEmpty { passes = RsyncUpload.Pass.cardFolder }
let rsyncURL = rsync ?? RsyncUpload.bundledRsync

if dry {
    for p in passes {
        print(([rsyncURL.path] + RsyncUpload.arguments(local: local, remotePath: remote, connection: conn, pass: p))
            .map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
    }
    exit(0)
}
guard FileManager.default.isExecutableFile(atPath: rsyncURL.path) else {
    fail("no rsync at \(rsyncURL.path): run scripts/build-rsync.sh, or pass --rsync")
}
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir), isDir.boolValue else { fail("\(local.path) is not a folder") }

print("\(local.path) → \(conn.target):\(remote) (port \(conn.port))")
let started = Date()
let lock = NSLock()
var lastLine = ""
do {
    try RsyncUpload.upload(local, to: remote, connection: conn, rsync: rsyncURL, passes: passes, progress: { p in
        let mb = Double(p.bytesDone) / 1e6
        let rate = p.bytesPerSecond / 1e6
        let left = p.remaining.map { String(format: "%d:%02d left", Int($0) / 60, Int($0) % 60) } ?? ""
        let files = p.filesLeft.map { "\($0) files to go" } ?? ""
        let line = String(format: "[%@] %3d%%  %.1f MB  %.2f MB/s  %@  %@  %@", p.pass.rawValue, p.percent, mb, rate, left, files, p.current)
        lock.lock()
        if line != lastLine {
            lastLine = line
            print("\r" + line.padding(toLength: 110, withPad: " ", startingAt: 0), terminator: "")
            fflush(stdout)
        }
        lock.unlock()
    })
    print("\ndone in \(Int(Date().timeIntervalSince(started))) s")
} catch let f as RsyncUpload.Failure {
    print("")
    fail("\(f.message)\(f.isRetryable ? " (worth trying again)" : "")")
} catch {
    print("")
    fail(error.localizedDescription)
}
