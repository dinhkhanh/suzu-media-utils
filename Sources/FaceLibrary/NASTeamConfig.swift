import Foundation

/// The team NAS's address and key, kept in the team sync folder (`nas/`) so every Mac of the team uploads without
/// anyone typing anything: one Mac attaches them (`attach`, from the command line today), and every teammate's app
/// finds them where it already finds the team (`connection(teamFolder:)`).
///
/// The key is one key for the whole team, and the team folder is where it lives, so whoever can read the team
/// folder can upload to the NAS: the same people who can already write to the share. On the NAS the key's
/// authorized_keys line carries `restrict` (`authorizedKeysLine`), so it opens no shell and forwards no port, only
/// rsync. To take it back, `detach` and take the line out of the NAS user's authorized_keys.
///
/// ssh refuses a private key other people can read, and files on a share or in Dropbox have whatever permissions
/// the share gives them, so each Mac keeps its own copy under Application Support with 0600, refreshed whenever
/// the team's copy changes.
public enum NASTeamConfig {
    public struct File: Codable, Equatable, Sendable {
        public var format = 1
        public var host: String
        public var port: Int
        public var user: String
        public var basePath: String
        /// The team key's public half, as ssh prints it (`ssh-ed25519 AAAA… comment`).
        public var publicKey: String
        /// known_hosts lines for the NAS (`ssh-keyscan -p port host`), so a stranger answering to the NAS's name is
        /// refused rather than asked about.
        public var hostKeys: [String]
        public var attachedAt: Double
        public var attachedBy: String

        public var connection: NASConnection { NASConnection(host: host, port: port, user: user, basePath: basePath) }

        /// The line for the NAS user's `~/.ssh/authorized_keys`: this key, allowed to run rsync and nothing else.
        public var authorizedKeysLine: String {
            "restrict \(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    public static let folderName = "nas"
    static let fileName = "connection.json"
    static let keyName = "key"

    static func dir(_ teamFolder: URL) -> URL { teamFolder.appendingPathComponent(folderName, isDirectory: true) }
    static func fileURL(_ teamFolder: URL) -> URL { dir(teamFolder).appendingPathComponent(fileName) }
    static func keyURL(_ teamFolder: URL) -> URL { dir(teamFolder).appendingPathComponent(keyName) }

    /// What the team folder says, or nil when no NAS is attached.
    public static func read(teamFolder: URL) throws -> File? {
        let url = fileURL(teamFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    /// Puts the NAS in the team folder: the address, the host keys, and the private key, for every Mac of the team.
    public static func attach(to teamFolder: URL, connection c: NASConnection, privateKey: Data, publicKey: String,
                              hostKeys: [String], by: String) throws {
        let d = dir(teamFolder)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let file = File(host: c.host, port: c.port, user: c.user, basePath: c.basePath, publicKey: publicKey, hostKeys: hostKeys,
                        attachedAt: Date().timeIntervalSince1970, attachedBy: by)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try privateKey.write(to: keyURL(teamFolder), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL(teamFolder).path)
        try enc.encode(file).write(to: fileURL(teamFolder), options: .atomic)
    }

    /// The team's key as it is, to attach the NAS again with other details and keep the line on the NAS valid.
    public static func existingKey(teamFolder: URL) throws -> (privateKey: Data, publicKey: String)? {
        guard let file = try read(teamFolder: teamFolder), FileManager.default.fileExists(atPath: keyURL(teamFolder).path),
              !file.publicKey.isEmpty else { return nil }
        return (try Data(contentsOf: keyURL(teamFolder)), file.publicKey)
    }

    /// Takes the NAS out of the team folder. The Macs forget it on their next look; the NAS keeps accepting the
    /// key until its line goes from authorized_keys.
    public static func detach(from teamFolder: URL) throws {
        let d = dir(teamFolder)
        if FileManager.default.fileExists(atPath: d.path) { try FileManager.default.removeItem(at: d) }
    }

    /// `~/Library/Application Support/SuZu Media Utils/NAS`: this Mac's copies of the teams' keys.
    public static var defaultSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuZu Media Utils", isDirectory: true).appendingPathComponent("NAS", isDirectory: true)
    }

    /// The connection this Mac uses for the team in `teamFolder`: the address from the team folder, the key and
    /// known_hosts copied to `support/<teamUuid>/` with permissions ssh accepts (refreshed when the team's copy
    /// changed). nil when the team has no NAS, or its folder can't be reached right now.
    public static func connection(teamFolder: URL, teamUuid: String, support: URL = defaultSupport) throws -> NASConnection? {
        guard let file = try read(teamFolder: teamFolder) else { return nil }
        let key = try Data(contentsOf: keyURL(teamFolder))
        let mine = support.appendingPathComponent(teamUuid, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: mine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let myKey = mine.appendingPathComponent(keyName)
        if (try? Data(contentsOf: myKey)) != key {
            try key.write(to: myKey, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: myKey.path)
        let hosts = mine.appendingPathComponent("known_hosts")
        let lines = file.hostKeys.joined(separator: "\n") + "\n"
        if (try? String(contentsOf: hosts, encoding: .utf8)) != lines {
            try lines.write(to: hosts, atomically: true, encoding: .utf8)
        }
        var c = file.connection
        c.identityFile = myKey.path
        c.knownHostsFile = file.hostKeys.isEmpty ? nil : hosts.path
        return c
    }

    /// Among this Mac's teams, the first with a NAS attached whose folder can be reached: what the upload queue
    /// uses. A studio has one NAS; a Mac in two teams with two NASes would need the project's team instead.
    public static func connection(teams: [TeamRecord], support: URL = defaultSupport) -> NASConnection? {
        for t in teams {
            if let c = try? connection(teamFolder: URL(fileURLWithPath: t.folder, isDirectory: true), teamUuid: t.uuid, support: support) {
                return c
            }
        }
        return nil
    }

    /// The NAS's host keys as known_hosts lines, from `ssh-keyscan`; the port is written into them the way ssh
    /// looks them up (`[host]:port`). Needs the network.
    public static func scanHostKeys(host: String, port: Int) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        p.arguments = ["-p", String(port), "-T", "15", "-t", "ed25519,ecdsa,rsa", host]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !lines.isEmpty else { throw ScanError.noAnswer(host: host, port: port) }
        return lines
    }

    /// A fresh ed25519 key for the team, made by `ssh-keygen`: (private, public line).
    public static func makeKey(comment: String) throws -> (privateKey: Data, publicKey: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("suzu-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("key")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", key.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ScanError.keygenFailed }
        return (try Data(contentsOf: key), try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public enum ScanError: LocalizedError {
        case noAnswer(host: String, port: Int), keygenFailed
        public var errorDescription: String? {
            switch self {
            case .noAnswer(let h, let p): "No ssh answered at \(h) port \(p). Check the address, the port forward and that the NAS is on."
            case .keygenFailed: "ssh-keygen couldn't make a key."
            }
        }
    }
}
