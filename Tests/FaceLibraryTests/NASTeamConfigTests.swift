import Foundation
import XCTest
@testable import FaceLibrary

/// The NAS attached to a team through its sync folder: what one Mac attaches, every Mac finds, with a private copy
/// of the key that ssh accepts.
final class NASTeamConfigTests: XCTestCase {
    var tmp: URL!
    var team: URL!
    var support: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nasteam-\(UUID().uuidString)")
        team = tmp.appendingPathComponent("SuZu Team", isDirectory: true)
        support = tmp.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: team, withIntermediateDirectories: true)
        try "{}".write(to: team.appendingPathComponent("team.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    let key = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
    let pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake suzu-team-nas"
    let hosts = ["[vnpt.ddns.suzu.one]:2904 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostHostHostHostHostHostHostHostHostHostHost"]

    func testNothingAttachedIsNil() throws {
        XCTAssertNil(try NASTeamConfig.read(teamFolder: team))
        XCTAssertNil(try NASTeamConfig.connection(teamFolder: team, teamUuid: "t1", support: support))
    }

    func testAttachedNASReachesEveryMacWithAPrivateKeyCopy() throws {
        try NASTeamConfig.attach(to: team, connection: .suzu, privateKey: key, publicKey: pub, hostKeys: hosts, by: "Khanh's Mac")
        let f = try XCTUnwrap(try NASTeamConfig.read(teamFolder: team))
        XCTAssertEqual(f.host, "vnpt.ddns.suzu.one")
        XCTAssertEqual(f.port, 2904)
        XCTAssertEqual(f.attachedBy, "Khanh's Mac")
        XCTAssertEqual(f.authorizedKeysLine, "restrict \(pub)", "the key opens rsync and nothing else on the NAS")
        // The team folder's copy may have any permissions (a share, Dropbox): pretend it is world-readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: team.appendingPathComponent("nas/key").path)

        let c = try XCTUnwrap(try NASTeamConfig.connection(teamFolder: team, teamUuid: "t1", support: support))
        XCTAssertEqual(c.host, "vnpt.ddns.suzu.one")
        XCTAssertEqual(c.user, "dinhkhanh")
        XCTAssertEqual(c.basePath, "/volume1/homes/00 SUZU MEDIA")
        let myKey = try XCTUnwrap(c.identityFile)
        XCTAssertTrue(myKey.hasPrefix(support.appendingPathComponent("t1").path), "this Mac's own copy, not the team folder's")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: myKey)), key)
        let perms = try FileManager.default.attributesOfItem(atPath: myKey)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "ssh refuses a key others can read")
        let dirPerms = try FileManager.default.attributesOfItem(atPath: support.appendingPathComponent("t1").path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(c.knownHostsFile)), encoding: .utf8), hosts[0] + "\n")
        XCTAssertTrue(c.sshCommand.contains("StrictHostKeyChecking=yes"))
    }

    func testTheTeamsKeyIsKeptForAttachingAgain() throws {
        XCTAssertNil(try NASTeamConfig.existingKey(teamFolder: team))
        try NASTeamConfig.attach(to: team, connection: .suzu, privateKey: key, publicKey: pub, hostKeys: hosts, by: "A")
        let k = try XCTUnwrap(try NASTeamConfig.existingKey(teamFolder: team))
        XCTAssertEqual(k.privateKey, key)
        XCTAssertEqual(k.publicKey, pub)
        try NASTeamConfig.detach(from: team)
        XCTAssertNil(try NASTeamConfig.existingKey(teamFolder: team))
    }

    func testANewKeyInTheTeamFolderReplacesTheCopy() throws {
        try NASTeamConfig.attach(to: team, connection: .suzu, privateKey: key, publicKey: pub, hostKeys: hosts, by: "A")
        let c1 = try XCTUnwrap(try NASTeamConfig.connection(teamFolder: team, teamUuid: "t1", support: support))
        let key2 = Data("second key".utf8)
        try NASTeamConfig.attach(to: team, connection: .suzu, privateKey: key2, publicKey: pub, hostKeys: [], by: "A")
        let c2 = try XCTUnwrap(try NASTeamConfig.connection(teamFolder: team, teamUuid: "t1", support: support))
        XCTAssertEqual(c1.identityFile, c2.identityFile)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: c2.identityFile!)), key2)
        XCTAssertNil(c2.knownHostsFile, "no host keys attached: ssh's own known_hosts")
    }

    func testDetachForgetsAndTeamsPickTheOneWithANAS() throws {
        let other = tmp.appendingPathComponent("Other Team", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try NASTeamConfig.attach(to: team, connection: .suzu, privateKey: key, publicKey: pub, hostKeys: hosts, by: "A")
        var a = TeamRecord(uuid: "a", name: "Other", folder: other.path)
        var b = TeamRecord(uuid: "b", name: "SuZu", folder: team.path)
        a.id = 1; b.id = 2
        let c = try XCTUnwrap(NASTeamConfig.connection(teams: [a, b], support: support))
        XCTAssertTrue(c.identityFile!.contains("/b/"))
        try NASTeamConfig.detach(from: team)
        XCTAssertNil(try NASTeamConfig.read(teamFolder: team))
        XCTAssertNil(NASTeamConfig.connection(teams: [a, b], support: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: team.appendingPathComponent("nas").path))
    }
}
