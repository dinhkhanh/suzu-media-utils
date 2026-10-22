import AppKit
import FaceLibrary
import Foundation
import GRDB

/// Finds the ArcFace model: inside the app bundle, else models/compiled above the executable (development).
func locateModel() -> URL? {
    if let u = Bundle.main.url(forResource: "ArcFaceR50", withExtension: "mlmodelc") { return u }
    if let env = ProcessInfo.processInfo.environment["SUZU_FACE_MODEL"] { return URL(fileURLWithPath: env) }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<6 {
        let u = dir.appendingPathComponent("models/compiled/ArcFaceR50.mlmodelc")
        if FileManager.default.fileExists(atPath: u.path) { return u }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

/// `SuZuMediaUtils --headless <folder> [--library <dir>] [--reference <folder>]`: runs the full pipeline without UI
/// and prints the people found. Used for testing and timing.
func runHeadless(_ args: [String]) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)  // progress lines show up immediately when piped
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let folder = URL(fileURLWithPath: value("--headless")!)
    let lib = URL(fileURLWithPath: value("--library") ?? NSTemporaryDirectory() + "facegrouping-headless")
    guard let model = locateModel() else { print("model not found"); exit(1) }
    let service = try! LibraryService(modelURL: model, directory: lib)
    let t0 = Date()
    let existing = try! service.store.db.read { db in try String.fetchAll(db, sql: "SELECT path FROM source") }
    if let ref = value("--reference"), !existing.contains(canonicalPath(URL(fileURLWithPath: ref))) {
        try! service.addSource(URL(fileURLWithPath: ref), kind: .reference)
    }
    if !existing.contains(canonicalPath(folder)) { try! service.addSource(folder) }
    service.start()

    func count(_ sql: String) -> Int { (try? service.store.db.read { db in try Int.fetchOne(db, sql: sql) }) ?? 0 }
    var idleTicks = 0
    while idleTicks < 3 {
        Thread.sleep(forTimeInterval: 1)
        let total = count("SELECT COUNT(*) FROM media WHERE duplicateOf IS NULL")
        let pending = count("SELECT COUNT(*) FROM media WHERE status = 'pending'")
        print(String(format: "%5.0f s  files %d  pending %d  faces %d", Date().timeIntervalSince(t0), total, pending,
                     count("SELECT COUNT(*) FROM face")))
        idleTicks = (total > 0 && pending == 0 && service.processor.queuedCount == 0) ? idleTicks + 1 : 0
    }
    let tProcess = Date().timeIntervalSince(t0)
    service.engine.reclusterNow()
    service.engine.waitUntilIdle()
    if args.contains("--extras") {
        // Run the idle-time extras (score upgrades, burst fingerprints, bursts) to completion.
        let t1 = Date()
        while !service.maintain() { Thread.sleep(forTimeInterval: 0.5) }
        print(String(format: "extras done in %.1f s; %d photos in bursts", Date().timeIntervalSince(t1),
                     count("SELECT COUNT(*) FROM media WHERE burstId IS NOT NULL")))
    }
    let rows = try! service.store.db.read { db in
        try Row.fetchAll(db, sql: """
            SELECT p.name, COUNT(f.id) AS faces, COUNT(DISTINCT f.mediaId) AS media FROM person p
            JOIN face f ON f.personId = p.id GROUP BY p.id ORDER BY (p.name IS NULL), faces DESC
            """)
    }
    print(String(format: "processed in %.1f s; %d people; %d faces assigned of %d (%d unassigned with quality >= 0.3)",
                 tProcess, rows.count, count("SELECT COUNT(*) FROM face WHERE personId IS NOT NULL"),
                 count("SELECT COUNT(*) FROM face"),
                 count("SELECT COUNT(*) FROM face WHERE personId IS NULL AND quality >= 0.3")))
    for r in rows.prefix(15) {
        print("  \((r["name"] as String?) ?? "(unnamed)"): \(r["faces"] as Int) faces in \(r["media"] as Int) files")
    }
    if args.contains("--suggest-names") { suggestNamesHeadless(service, apply: args.contains("--apply")) }
    let failed = try! service.store.db.read { db in try Row.fetchAll(db, sql: "SELECT path, error FROM media WHERE status = 'failed' LIMIT 5") }
    for f in failed { print("  failed: \(f["path"] as String): \(f["error"] as String? ?? "")") }
    exit(0)
}

/// Celebrity suggestions from the command line. Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
/// (and AWS_SESSION_TOKEN, AWS_REGION) or, failing that, the app's Keychain entry.
func suggestNamesHeadless(_ service: LibraryService, apply: Bool) {
    let env = ProcessInfo.processInfo.environment
    let creds = env["AWS_ACCESS_KEY_ID"].map {
        AWSCredentials(accessKeyId: $0, secretAccessKey: env["AWS_SECRET_ACCESS_KEY"] ?? "", sessionToken: env["AWS_SESSION_TOKEN"])
    } ?? AWSSettings.credentials
    guard let creds else { print("no AWS credentials"); return }
    let namer = CelebrityNamer(store: service.store, client: RekognitionClient(credentials: creds, region: env["AWS_REGION"] ?? AWSSettings.region))
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let plan = try namer.plan()
            print("celebrity lookup: \(plan.personIds.count) unnamed groups, \(plan.newLookups) new lookups (~$\(String(format: "%.3f", Double(plan.newLookups) * 0.001)))")
            let suggestions = try await namer.suggest(personIds: plan.personIds) { done, total in
                if done % 10 == 0 || done == total { print("  looked up \(done)/\(total)") }
            }
            for s in suggestions {
                print(String(format: "  %@ %.1f%% (%d of %d faces)%@", s.name, s.confidence, s.votes, s.asked, s.isStrong ? "" : "  [weak]"))
                if apply && s.isStrong { _ = try service.rename(s.personId, to: s.name) }
            }
            if suggestions.isEmpty { print("  no celebrities recognised") }
        } catch {
            print("celebrity lookup failed: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    service.engine.waitUntilIdle()
}

if CommandLine.arguments.contains("--headless") {
    runHeadless(CommandLine.arguments)
} else {
    NSApplication.shared.setActivationPolicy(.regular)
    SuZuMediaUtilsApp.main()
}
