import AppKit
import FaceLibrary
import Foundation
import GRDB
import MediaKit

/// Finds the ArcFace model: inside the app bundle, else models/compiled above the executable (development).
func locateModel() -> URL? {
    if let u = Bundle.main.url(forResource: "ArcFaceR50", withExtension: "mlmodelc") { return u }
    if let env = ProcessInfo.processInfo.environment["SUZU_FACE_MODEL"] { return URL(fileURLWithPath: env) }
    return locateModel(named: "ArcFaceR50")
}

/// A compiled model by name: inside the app bundle, else models/compiled above the executable (development).
func locateModel(named name: String) -> URL? {
    if let u = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return u }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<6 {
        let u = dir.appendingPathComponent("models/compiled/\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: u.path) { return u }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

/// `SuZuMediaUtils --headless <folder> [--library <dir>] [--project <name>] [--reference <folder>]`: runs the full pipeline without UI
/// and prints the people found. Used for testing and timing.
func runHeadless(_ args: [String]) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)  // progress lines show up immediately when piped
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let folder = URL(fileURLWithPath: value("--headless")!)
    let lib = URL(fileURLWithPath: value("--library") ?? NSTemporaryDirectory() + "facegrouping-headless")
    guard let model = locateModel() else { print("model not found"); exit(1) }
    let service = try! LibraryService(modelURL: model, directory: lib)
    if args.contains("--bench-ui") {  // runs at once, without processing the folder
        // Timings of what the batch tools and export dialogs run on each interaction.
        func time(_ label: String, _ body: () throws -> Int) {
            let t = Date(); let n = (try? body()) ?? -1
            print(String(format: "  %@: %d items in %.0f ms", label, n, Date().timeIntervalSince(t) * 1000))
        }
        let people = try! service.store.db.read { db in try Row.fetchAll(db, sql: "SELECT id, name FROM person WHERE name IS NOT NULL") }
            .map { (id: $0["id"] as Int64, name: $0["name"] as String) }
        print("bench-ui with \(people.count) named people")
        time("people as source (all photos)") { try Selection.files(service.store, personIds: people.map(\.id), kind: .photo, topN: nil, bestOfBurst: true).count }
        time("people as source (best 20)") { try Selection.files(service.store, personIds: people.map(\.id), kind: .photo, topN: 20, bestOfBurst: true).count }
        var opts = Exporter.Options(); opts.bestOfBurst = true
        time("Export All plan") { try service.exporter.planAll(people: people, base: nil, mode: .move, options: opts).items.count }
        if let first = people.first { time("single person plan") { try service.exporter.plan(personId: first.id, name: first.name, base: nil, options: opts).items.count } }
        var q = MediaQuery(); q.people = Array(people.prefix(3).map(\.id)); q.match = .any
        time("search 3 people") { try q.run(service.store).count }
        time("search everything") { try MediaQuery().run(service.store).count }
        // What the sidebar and People view re-read after changes, per project and for all projects.
        let firstProject = try! service.store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM project ORDER BY id LIMIT 1") }
        for p in [firstProject, nil] {
            time("people (project \(p.map(String.init) ?? "all"))") { try service.store.db.read { db in try FaceGroupingModel.fetchPeople(db, project: p).count } }
            time("stats (project \(p.map(String.init) ?? "all"))") { try service.store.db.read { db in _ = try FaceGroupingModel.fetchStats(db, project: p); return 1 } }
        }
        // Export cost per photo: JPEG vs PNG, full size and Instagram 4:5.
        if let path = try! service.store.db.read({ db in try String.fetchOne(db, sql: "SELECT path FROM media WHERE kind = 'photo' AND status = 'done' ORDER BY id LIMIT 1") }) {
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-export")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (label, crop) in [("full size", false), ("4:5 1350 px", true)] {
                for format in OutputFormat.allCases {
                    var r = EditRecipe(); r.format = format == .jpeg ? nil : format; r.autoTone = true
                    if crop { r.aspect = .portrait; r.maxLongSide = 1350 }
                    let dest = out.appendingPathComponent("b.\(r.fileExtension)")
                    time("export \(label) \(format.label)") {
                        try EditPipeline.render(URL(fileURLWithPath: path), recipe: r, focus: nil, to: dest)
                        return ((try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0) / 1024
                    }
                }
            }
        }
        time("sessions (project \(firstProject ?? 0))") {
            let list = try service.store.db.read { db in try EventSessions.list(db, project: firstProject) }
            for x in list { print(String(format: "    %@ – %@  %d photos %d videos", Date(timeIntervalSince1970: x.start).formatted(), Date(timeIntervalSince1970: x.end).formatted(.dateTime.hour().minute()), x.photos, x.videos)) }
            return list.count
        }
        if let s = try? service.store.db.read({ db in try EventSessions.list(db, project: firstProject) }).last {
            time("people in last session") { try service.store.db.read { db in try FaceGroupingModel.fetchPeople(db, project: firstProject, taken: s.range).count } }
        }
        time("projects") { try service.store.db.read { db in try FaceGroupingModel.fetchProjects(db).count } }
        time("known people") { try service.store.db.read { db in try FaceGroupingModel.fetchKnownPeople(db).count } }
        // The person with the most faces is the slow case for per-person queries.
        if let top = try! service.store.db.read({ db in
            try Int64.fetchOne(db, sql: "SELECT personId FROM face WHERE personId IS NOT NULL GROUP BY personId ORDER BY COUNT(*) DESC LIMIT 1")
        }) {
            var one = MediaQuery(); one.people = [top]
            time("search person with most faces") { try one.run(service.store).count }
            one.kind = .photo; one.crowd = .group
            time("  + photos, group shots") { try one.run(service.store).count }
            one.crowd = .any; one.bestOnly = true; one.collapseBursts = true
            time("  + best shots, one per burst") { try one.run(service.store).count }
            for album in try! service.store.db.read({ db in try SmartAlbum.fetchAll(db) }) {
                time("album \(album.name)") { try album.mediaQuery.run(service.store).count }
            }
        }
        exit(0)
    }
    let t0 = Date()
    let existing = try! service.store.db.read { db in try String.fetchAll(db, sql: "SELECT path FROM source") }
    if let ref = value("--reference"), !existing.contains(canonicalPath(URL(fileURLWithPath: ref))) {
        try! service.addSource(URL(fileURLWithPath: ref), kind: .reference)
    }
    if !existing.contains(canonicalPath(folder)) {
        // --project <name>: put the folder in that project (created if needed); default "Headless".
        let name = value("--project") ?? "Headless"
        let pid = try! service.store.db.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM project WHERE name = ?", arguments: [name]) }
            ?? service.createProject(name).id!
        try! service.addSource(folder, project: pid)
    }
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
    if let dir = value("--reel") {
        // Highlight reel (max 30 s) and clips of the person seen in the most videos: a real-footage check.
        let pid = try! service.store.db.read { db in
            try Int64.fetchOne(db, sql: "SELECT personId FROM face WHERE personId IS NOT NULL AND time IS NOT NULL GROUP BY personId ORDER BY COUNT(DISTINCT mediaId) DESC LIMIT 1")
        }
        if let pid {
            let sem = DispatchSemaphore(value: 0)
            Task {
                let vx = VideoExport(store: service.store)
                let apps = (try? vx.appearances(personId: pid)) ?? []
                let t = Date()
                let reel = try? await vx.export(personId: pid, name: "Person \(pid)", kind: .reel(maxSeconds: 30), to: URL(fileURLWithPath: dir))
                let tReel = Date().timeIntervalSince(t)
                let clips = try? await vx.export(personId: pid, name: "Person \(pid)", kind: .clips, to: URL(fileURLWithPath: dir).appendingPathComponent("clips"))
                print(String(format: "person %lld: %d appearances; reel %@ in %.1f s; %d clips in %.1f s total", pid, apps.count,
                             reel?.first?.lastPathComponent ?? "failed", tReel, clips?.count ?? 0, Date().timeIntervalSince(t)))
                sem.signal()
            }
            sem.wait()
        }
    }
    if let dir = value("--gallery") {
        let t = Date()
        let index = try! GalleryExporter(store: service.store).export(title: "Test", personIds: nil, options: GalleryExporter.Options(), to: URL(fileURLWithPath: dir))
        print(String(format: "gallery %@ in %.1f s", index.path, Date().timeIntervalSince(t)))
    }
    if let seconds = value("--serve").flatMap(Double.init) {
        let server = GalleryServer(store: service.store, token: "test") { pid, name in _ = try service.rename(pid, to: name) }
        try! server.start(port: 8643)
        print("serving \(server.url) for \(Int(seconds)) s")
        Thread.sleep(forTimeInterval: seconds)
        server.stop()
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

/// Steps passed, counted once each from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func advance(to v: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard v > value else { return false }
        value = v
        return true
    }
}

/// SUZU_HANG_LOG=1 (testing): logs to stderr whenever the main thread is blocked for more than 250 ms.
func startHangWatchdog() {
    guard ProcessInfo.processInfo.environment["SUZU_HANG_LOG"] != nil else { return }
    let launch = Date()
    Thread.detachNewThread {
        while true {
            let sem = DispatchSemaphore(value: 0)
            let t = Date()
            DispatchQueue.main.async { sem.signal() }
            if sem.wait(timeout: .now() + 0.25) == .timedOut {
                sem.wait()
                FileHandle.standardError.write(Data(String(format: "HANG main thread blocked %.0f ms at %.1f s\n",
                                                           Date().timeIntervalSince(t) * 1000, t.timeIntervalSince(launch)).utf8))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

if CommandLine.arguments.contains("--headless") {
    runHeadless(CommandLine.arguments)
} else if CommandLine.arguments.contains("--download-body-parts") {
    // Edit & Export's body-parts model, as its Download button gets it (for setting up several Macs from a script).
    setvbuf(stdout, nil, _IOLBF, 0)
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let shown = Counter()
        do {
            let url = try await BodyPartsModel.fetch { p in
                if shown.advance(to: Int(p * 10)) { print("\(Int(p * 100))%") }
            }
            print("installed \(url.path)")
            exit(0)
        } catch {
            print("failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    sem.wait()
} else {
    NSApplication.shared.setActivationPolicy(.regular)
    startHangWatchdog()
    SuZuMediaUtilsApp.main()
}
