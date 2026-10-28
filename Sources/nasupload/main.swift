import FaceLibrary
import Foundation

// The team NAS from the command line, with the same code the app uses (NASUpload, NASTeamConfig).
//
// Attach the NAS to a team, once, from the Mac that has the NAS's admin (writes nas/connection.json and the team's
// key into the team sync folder; every Mac of the team then uploads with it):
//
//   swift run nasupload attach "/Volumes/homes/SuZu Team" --user uploader
//       --host H --port N --base /volume1/photo    the NAS (defaults: the studio NAS)
//       --key FILE                                 attach this private key instead of making a new one
//   It prints the authorized_keys line to put on the NAS. `show <team folder>` prints what is attached;
//   `detach <team folder>` takes it out.
//
// Upload a folder:
//
//   swift run nasupload "~/SuZu Staging/Nam R5 card 1/2026-10-28 14.05" "Event/Nam R5 card 1/2026-10-28 14.05" \
//       --team "/Volumes/homes/SuZu Team"            with the team's NAS and key
//       --user dinhkhanh --key ~/.ssh/id_ed25519     or with a connection given by hand
//       --known-hosts FILE                           pin the NAS's host key (default: ~/.ssh/known_hosts)
//       --rsync FILE                                 the rsync to run (default: .build/rsync/bin/rsync)
//       --pass P                                     photosFirst | everything | verify; repeat (default: all three)
//       --dry                                        print the rsync command lines and stop
//   The remote path is under the base path (/volume1/photo) unless it starts with "/".

var args = Array(CommandLine.arguments.dropFirst())
var positional: [String] = []
var conn = NASConnection.suzu
var teamFolder: URL?
var keyFile: String?
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
    case "--key": keyFile = expand(value())
    case "--known-hosts": conn.knownHostsFile = expand(value())
    case "--team": teamFolder = URL(fileURLWithPath: expand(value()), isDirectory: true)
    case "--rsync": rsync = URL(fileURLWithPath: expand(value()))
    case "--pass":
        guard let p = RsyncUpload.Pass(rawValue: value()) else { fail("--pass is photosFirst, everything or verify") }
        passes.append(p)
    case "--dry": dry = true
    case "-h", "--help":
        print("""
        usage: nasupload <local folder> <remote path> [--team FOLDER | --user U --key FILE] [--host H] [--port N] [--base P] [--known-hosts FILE] [--rsync FILE] [--pass P]... [--dry]
               nasupload attach <team folder> [--host H] [--port N] [--user U] [--base P] [--key FILE]
               nasupload show <team folder>
               nasupload detach <team folder>
        """)
        exit(0)
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)") }
        positional.append(a)
    }
}

func teamFolderArg() -> URL {
    guard positional.count == 2 else { fail("\(positional.first ?? "") needs the team sync folder") }
    let f = URL(fileURLWithPath: expand(positional[1]), isDirectory: true)
    guard FileManager.default.fileExists(atPath: f.appendingPathComponent("team.json").path) else {
        fail("\(f.path) has no team.json in it: pick the team sync folder")
    }
    return f
}

switch positional.first {
case "attach":
    let folder = teamFolderArg()
    if let existing = try? NASTeamConfig.read(teamFolder: folder) {
        print("replacing the NAS attached by \(existing.attachedBy): \(existing.user)@\(existing.host):\(existing.port)")
    }
    print("asking \(conn.host) port \(conn.port) for its host key…")
    let hostKeys: [String]
    do { hostKeys = try NASTeamConfig.scanHostKeys(host: conn.host, port: conn.port) } catch { fail(error.localizedDescription) }
    let privateKey: Data, publicKey: String
    if let keyFile {
        do {
            privateKey = try Data(contentsOf: URL(fileURLWithPath: keyFile))
            publicKey = try String(contentsOf: URL(fileURLWithPath: keyFile + ".pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { fail("couldn't read \(keyFile) and \(keyFile).pub: \(error.localizedDescription)") }
    } else {
        do { (privateKey, publicKey) = try NASTeamConfig.makeKey(comment: "suzu-team-nas") } catch { fail(error.localizedDescription) }
        print("made a new key for the team")
    }
    do {
        try NASTeamConfig.attach(to: folder, connection: conn, privateKey: privateKey, publicKey: publicKey, hostKeys: hostKeys,
                                 by: Host.current().localizedName ?? NSUserName())
    } catch { fail("couldn't write to \(folder.path): \(error.localizedDescription)") }
    let file = try! NASTeamConfig.read(teamFolder: folder)!
    print("""
    attached \(conn.user)@\(conn.host):\(conn.port) (\(conn.basePath)) to the team in \(folder.path)
    \(hostKeys.count) host key(s) pinned.

    Put this line in the NAS user's ~/.ssh/authorized_keys (ssh -p \(conn.port) \(conn.user)@\(conn.host)):

    \(file.authorizedKeysLine)

    Every Mac of the team now uploads with this key; nobody needs to type anything.
    """)

case "show":
    let folder = teamFolderArg()
    guard let f = try? NASTeamConfig.read(teamFolder: folder) else { print("no NAS attached to the team in \(folder.path)"); exit(0) }
    print("\(f.user)@\(f.host):\(f.port)  base \(f.basePath)")
    print("attached by \(f.attachedBy) on \(Date(timeIntervalSince1970: f.attachedAt).formatted())")
    print("host keys: \(f.hostKeys.count)")
    print("authorized_keys line:\n\(f.authorizedKeysLine)")

case "detach":
    let folder = teamFolderArg()
    do { try NASTeamConfig.detach(from: folder) } catch { fail(error.localizedDescription) }
    print("detached. Take the key's line out of the NAS user's authorized_keys too.")

default:
    guard positional.count == 2 else { fail("usage: nasupload <local folder> <remote path> [options]; --help for the options") }
    if let teamFolder {
        do {
            guard var c = try NASTeamConfig.connection(teamFolder: teamFolder, teamUuid: teamFolder.lastPathComponent) else {
                fail("no NAS attached to the team in \(teamFolder.path); `nasupload attach` first")
            }
            // Options given by hand go over the team's.
            if conn.host != NASConnection.suzu.host { c.host = conn.host }
            if conn.port != NASConnection.suzu.port { c.port = conn.port }
            if conn.user != NASConnection.suzu.user { c.user = conn.user }
            if conn.basePath != NASConnection.suzu.basePath { c.basePath = conn.basePath }
            conn = c
        } catch { fail(error.localizedDescription) }
    } else if let keyFile {
        conn.identityFile = keyFile
    }
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

    print("\(local.path) → \(conn.target):\(remote) (port \(conn.port)\(conn.knownHostsFile != nil ? ", host key pinned" : ""))")
    let started = Date()
    final class Last: @unchecked Sendable { var line = "" }
    let lock = NSLock()
    let last = Last()
    do {
        try RsyncUpload.upload(local, to: remote, connection: conn, rsync: rsyncURL, passes: passes, progress: { p in
            let mb = Double(p.bytesDone) / 1e6
            let rate = p.bytesPerSecond / 1e6
            let left = p.remaining.map { String(format: "%d:%02d left", Int($0) / 60, Int($0) % 60) } ?? ""
            let files = p.filesLeft.map { "\($0) files to go" } ?? ""
            let line = String(format: "[%@] %3d%%  %.1f MB  %.2f MB/s  %@  %@  %@", p.pass.rawValue, p.percent, mb, rate, left, files, p.current)
            lock.lock()
            if line != last.line {
                last.line = line
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
}
