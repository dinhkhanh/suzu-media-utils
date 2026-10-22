import AppKit
import Combine
import FaceLibrary
import Foundation
import GRDB
import MediaKit

struct PersonSummary: Identifiable, Hashable {
    var id: Int64
    var name: String?
    var faces: Int
    var photos: Int
    var videos: Int
    var coverFaceId: Int64?
    var displayName: String { name ?? "Unnamed" }
}

struct ProjectSummary: Identifiable, Hashable {
    var id: Int64
    var name: String
    var folders: Int
    var files: Int
    var createdAt: Date
}

struct SourceSummary: Identifiable, Hashable {
    var id: Int64
    var path: String
    var kind: SourceKind
    var projectId: Int64?
    var files: Int
    var pending: Int
    var failed: Int
    var online = true
    var network = false
    var scanning = false
    var found = 0
    var name: String { (path as NSString).lastPathComponent }
}

struct LibraryStats: Equatable {
    var files = 0
    var pending = 0
    var unassignedFaces = 0
}

/// A file in a person's view: the media plus the best face of that person in it.
struct PersonMedia: Identifiable, Hashable {
    var id: Int64
    var path: String
    var kind: MediaKind
    var faceId: Int64
    var time: Double?
    var score: Double
    var takenAt: Date?
    var burstId: Int64?
    /// Other shots of the same burst hidden behind this one when bursts are collapsed.
    var hiddenInBurst = 0
    var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
}

struct FaceItem: Identifiable, Hashable {
    var id: Int64
    var mediaId: Int64
    var path: String
    var quality: Double
    var time: Double?
}

@MainActor
final class FaceGroupingModel: ObservableObject {
    private(set) var service: LibraryService?
    @Published var startupError: String?
    @Published var projects: [ProjectSummary] = []
    /// The event being worked on; nil = all projects. People, folders, search, albums, rules and exports follow it.
    @Published var currentProject: Int64? {
        didSet {
            guard currentProject != oldValue else { return }
            UserDefaults.standard.set(currentProject ?? 0, forKey: "currentProject")
            people = []
            server?.show(project: currentProject, title: projectName)
            refresh()
        }
    }
    /// Asks the window to show the New Project sheet (e.g. "Add Folder" with no project open).
    @Published var askNewProject = false
    /// People in the open project.
    @Published var people: [PersonSummary] = []
    /// Everyone with a name, in any project: names are given once and shared by all projects.
    @Published var knownPeople: [PersonSummary] = []
    @Published var sources: [SourceSummary] = []
    @Published var stats = LibraryStats()
    @Published var rate: Double = 0
    @Published var albums: [SmartAlbum] = []
    @Published var sharingURL: String?
    private var server: GalleryServer?
    @Published var rules: [DeliveryRule] = []
    /// Folders being removed in the background; hidden from the sidebar right away.
    @Published var removing: Set<Int64> = []
    private var cancellables: Set<AnyCancellable> = []
    private var regionObserver: AnyDatabaseCancellable?
    private var dirty = true
    private var refreshing = false
    private var lastProcessed = 0
    private var lastTick = Date()
    /// False on first launch with projects: open the most recent project once they're loaded.
    private var restoredProject = false

    init() {
        guard let model = locateModel() else {
            startupError = "The face model (ArcFaceR50.mlmodelc) was not found. Rebuild the app with scripts/build-app.sh (see README)."
            return
        }
        let saved = UserDefaults.standard.object(forKey: "currentProject") as? Int
        _currentProject = Published(initialValue: saved.flatMap { $0 == 0 ? nil : Int64($0) })
        restoredProject = saved != nil
        // Opening the database (migrations) and loading the Core ML model take a few seconds: never on the main
        // thread, or the window would freeze at launch.
        let dir = ProcessInfo.processInfo.environment["SUZU_FACE_LIBRARY"].map { URL(fileURLWithPath: $0) }
        Task.detached(priority: .userInitiated) {
            do {
                let service = try LibraryService(modelURL: model, directory: dir ?? LibraryStore.defaultDirectory)
                await MainActor.run { self.attach(service) }
            } catch {
                await MainActor.run { self.startupError = "Could not open the library: \(error.localizedDescription)" }
            }
        }
    }

    private func attach(_ service: LibraryService) {
        self.service = service
        service.onDelivered = { report in Notifier.post(report) }
        ToolWork.faces = self
        service.start()
        observe()
        if UserDefaults.standard.bool(forKey: "sharingEnabled") { setSharing(true) }
    }

    var store: LibraryStore? { service?.store }

    /// Commits only mark the data dirty (cheap, can happen dozens of times a second during ingest); a 1 s timer
    /// re-reads people, folders and stats on a background reader when something changed.
    private func observe() {
        guard let db = store?.db else { return }
        regionObserver = DatabaseRegionObservation(tracking: Table("face"), Table("person"), Table("media"), Table("source"),
                                                   Table("smartAlbum"), Table("deliveryRule"), Table("project"))
            .start(in: db, onError: { _ in }, onChange: { [weak self] _ in
                DispatchQueue.main.async { self?.dirty = true }
            })
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
        refresh()
    }

    /// Re-reads everything now (after the user changed something).
    func refresh() {
        dirty = true
        tick()
    }

    private func tick() {
        guard let service else { return }
        let n = service.processor.processedCount
        let now = Date()
        if now.timeIntervalSince(lastTick) >= 1 {
            rate = Double(n - lastProcessed) / now.timeIntervalSince(lastTick)
            lastProcessed = n
            lastTick = now
        }
        applySources(sources)
        guard dirty, !refreshing, let db = store?.db else { return }
        dirty = false
        refreshing = true
        let project = currentProject
        Task.detached(priority: .userInitiated) {
            let result = try? await db.read { db in
                (try Self.fetchPeople(db, project: project), try Self.fetchSources(db), try Self.fetchStats(db, project: project),
                 try SmartAlbum.order(Column("name")).fetchAll(db), try DeliveryRule.order(Column("createdAt")).fetchAll(db),
                 try Self.fetchProjects(db), try Self.fetchKnownPeople(db))
            }
            await MainActor.run {
                defer { self.refreshing = false }
                // The project changed while reading: the next tick reads the new one.
                guard project == self.currentProject else { self.dirty = true; return }
                if let (people, sources, stats, albums, rules, projects, known) = result {
                    if projects != self.projects { self.projects = projects }
                    if !self.restoredProject, let latest = projects.max(by: { $0.createdAt < $1.createdAt }) {
                        self.restoredProject = true
                        self.currentProject = latest.id
                        return
                    }
                    if let p = self.currentProject, !projects.contains(where: { $0.id == p }) {
                        // The open project was deleted.
                        self.currentProject = projects.max(by: { $0.createdAt < $1.createdAt })?.id
                        return
                    }
                    if known != self.knownPeople { self.knownPeople = known }
                    if people != self.people { self.people = people }
                    self.applySources(sources)
                    if stats != self.stats { self.stats = stats }
                    if albums != self.albums { self.albums = albums }
                    if rules != self.rules {
                        if self.rules.isEmpty && !rules.isEmpty { Notifier.requestPermission() }
                        self.rules = rules
                    }
                }
            }
        }
    }

    private func applySources(_ list: [SourceSummary]) {
        let updated = list.filter { !removing.contains($0.id) }.map { s in
            var s = s
            if let m = service?.monitor(s.id) {
                s.online = m.isOnline; s.network = m.isNetwork; s.scanning = m.isScanning; s.found = m.foundCount
            }
            return s
        }
        if updated != sources { sources = updated }
    }

    /// People with faces in the project (nil = anywhere), with counts for that project.
    nonisolated static func fetchPeople(_ db: Database, project: Int64?) throws -> [PersonSummary] {
        let scope = ProjectScope.sql(project)
        return try Row.fetchAll(db, sql: """
            SELECT p.id, p.name, COUNT(*) AS faces,
                COUNT(DISTINCT CASE WHEN m.kind = 'photo' THEN m.id END) AS photos,
                COUNT(DISTINCT CASE WHEN m.kind = 'video' THEN m.id END) AS videos,
                COALESCE((SELECT c.id FROM face c WHERE c.id = p.coverFaceId AND c.personId = p.id),
                         \(BestShot.coverSubquery(project: project))) AS cover
            FROM person p
            JOIN face f ON f.personId = p.id
            JOIN media m ON m.id = f.mediaId
            LEFT JOIN source s ON s.id = m.sourceId
            WHERE \(scope)
            GROUP BY p.id
            ORDER BY (p.name IS NULL), faces DESC
            """).map {
            PersonSummary(id: $0["id"], name: $0["name"], faces: $0["faces"], photos: $0["photos"], videos: $0["videos"],
                          coverFaceId: $0["cover"])
        }
    }

    nonisolated static func fetchProjects(_ db: Database) throws -> [ProjectSummary] {
        try Row.fetchAll(db, sql: """
            SELECT p.id, p.name, p.createdAt, COUNT(DISTINCT s.id) AS folders, COUNT(m.id) AS files
            FROM project p LEFT JOIN source s ON s.projectId = p.id LEFT JOIN media m ON m.sourceId = s.id AND m.duplicateOf IS NULL
            GROUP BY p.id ORDER BY p.createdAt DESC
            """).map { ProjectSummary(id: $0["id"], name: $0["name"], folders: $0["folders"], files: $0["files"], createdAt: $0["createdAt"]) }
    }

    /// Every named person in the library (cheap: counts come from the people list where shown).
    nonisolated static func fetchKnownPeople(_ db: Database) throws -> [PersonSummary] {
        try Row.fetchAll(db, sql: """
            SELECT p.id, p.name, COALESCE(p.coverFaceId, (SELECT f.id FROM face f WHERE f.personId = p.id ORDER BY f.score DESC LIMIT 1)) AS cover
            FROM person p WHERE p.name IS NOT NULL ORDER BY p.name COLLATE NOCASE
            """).map { PersonSummary(id: $0["id"], name: $0["name"], faces: 0, photos: 0, videos: 0, coverFaceId: $0["cover"]) }
    }

    nonisolated static func fetchSources(_ db: Database) throws -> [SourceSummary] {
        try Row.fetchAll(db, sql: """
            SELECT s.id, s.path, s.kind, s.projectId,
                COUNT(m.id) FILTER (WHERE m.duplicateOf IS NULL) AS files,
                COUNT(m.id) FILTER (WHERE m.status = 'pending') AS pending,
                COUNT(m.id) FILTER (WHERE m.status = 'failed') AS failed
            FROM source s LEFT JOIN media m ON m.sourceId = s.id
            GROUP BY s.id ORDER BY s.kind, s.path
            """).map {
            SourceSummary(id: $0["id"], path: $0["path"], kind: SourceKind(rawValue: $0["kind"]) ?? .media, projectId: $0["projectId"],
                          files: $0["files"], pending: $0["pending"], failed: $0["failed"])
        }
    }

    /// Files and unassigned faces of the project; pending files of the whole library (processing is shared).
    nonisolated static func fetchStats(_ db: Database, project: Int64?) throws -> LibraryStats {
        LibraryStats(
            files: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM media m LEFT JOIN source s ON s.id = m.sourceId WHERE m.duplicateOf IS NULL AND \(ProjectScope.sql(project))
                """) ?? 0,
            pending: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") ?? 0,
            unassignedFaces: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM face JOIN media m ON m.id = face.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE face.personId IS NULL AND face.quality >= 0.3 AND \(ProjectScope.sql(project))
                """) ?? 0)
    }

    // MARK: - Queries for detail views

    func media(of personId: Int64, alsoWith others: Set<Int64>) async -> [PersonMedia] {
        guard let store else { return [] }
        let project = currentProject
        return await Task.detached(priority: .userInitiated) { Self.loadMedia(store, personId, others, project: project) }.value
    }

    func faces(of personId: Int64?) async -> [FaceItem] {
        guard let store else { return [] }
        let project = currentProject
        return await Task.detached(priority: .userInitiated) { Self.loadFaces(store, personId, project: project) }.value
    }

    /// Names of the other projects a person appears in (shown on their page: the name carries over).
    func otherProjects(of personId: Int64) async -> [String] {
        guard let store else { return [] }
        let project = currentProject
        return await Task.detached(priority: .utility) {
            (try? store.db.read { db in
                try String.fetchAll(db, sql: """
                    SELECT pr.name FROM project pr WHERE pr.id != ? AND EXISTS (
                        SELECT 1 FROM source s JOIN media m ON m.sourceId = s.id JOIN face f ON f.mediaId = m.id
                        WHERE s.projectId = pr.id AND f.personId = ?)
                    ORDER BY pr.createdAt DESC
                    """, arguments: [project ?? 0, personId])
            }) ?? []
        }.value
    }

    /// The open project's best photos (of one person, or anyone), for edit previews.
    func samples(personId: Int64? = nil, limit: Int = 24) async -> [ToolItem] {
        guard let store else { return [] }
        let project = currentProject
        return await Task.detached(priority: .userInitiated) {
            let rows = (try? store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.path, f.x, f.y, f.w, f.h, p.name FROM face f JOIN media m ON m.id = f.mediaId
                    LEFT JOIN source s ON s.id = m.sourceId LEFT JOIN person p ON p.id = f.personId
                    WHERE m.kind = 'photo' AND m.duplicateOf IS NULL AND \(ProjectScope.sql(project))
                      \(personId.map { "AND f.personId = \($0)" } ?? "AND f.personId IS NOT NULL")
                    ORDER BY COALESCE(f.score, f.quality * 0.6, 0) DESC LIMIT \(limit * 4)
                    """)
            }) ?? []
            var seen: Set<String> = []
            return rows.compactMap { r -> ToolItem? in
                let path: String = r["path"]
                guard seen.insert(path).inserted else { return nil }
                return ToolItem(url: URL(fileURLWithPath: path, isDirectory: false), personName: r["name"],
                                focus: FocusHint(primary: CGRect(x: r["x"] as Double, y: r["y"] as Double, width: r["w"] as Double, height: r["h"] as Double)))
            }.prefix(limit).map { $0 }
        }.value
    }

    nonisolated static func loadMedia(_ store: LibraryStore, _ personId: Int64, _ others: Set<Int64>, project: Int64?) -> [PersonMedia] {
        let db = store.db
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.kind, m.takenAt, m.burstId, f.id AS faceId, f.time,
                    COALESCE(f.score, f.quality * 0.6, 0) AS score FROM face f
                JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE f.personId = ? AND \(ProjectScope.sql(project))
                ORDER BY m.path, score DESC
                """, arguments: [personId])
        }) ?? []
        var allowed: Set<Int64>?
        for other in others {
            let ids = Set((try? db.read { db in
                try Int64.fetchAll(db, sql: "SELECT DISTINCT mediaId FROM face WHERE personId = ?", arguments: [other])
            }) ?? [])
            allowed = allowed.map { $0.intersection(ids) } ?? ids
        }
        var seen: Set<Int64> = []
        return rows.compactMap { r in
            let id: Int64 = r["id"]
            guard seen.insert(id).inserted, allowed?.contains(id) ?? true else { return nil }
            return PersonMedia(id: id, path: r["path"], kind: MediaKind(rawValue: r["kind"]) ?? .photo,
                               faceId: r["faceId"], time: r["time"], score: r["score"],
                               takenAt: (r["takenAt"] as Double?).map(Date.init(timeIntervalSince1970:)), burstId: r["burstId"])
        }
    }

    nonisolated static func loadFaces(_ store: LibraryStore, _ personId: Int64?, project: Int64?) -> [FaceItem] {
        let db = store.db
        let filter = personId == nil
            ? "f.personId IS NULL AND f.quality >= 0.3 AND \(ProjectScope.sql(project))"
            : "f.personId = \(personId!) AND (\(ProjectScope.sql(project)) OR s.kind = 'reference')"
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, f.mediaId, m.path, COALESCE(f.quality, 0) AS q, f.time FROM face f
                JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE \(filter) ORDER BY q DESC LIMIT 3000
                """).map { FaceItem(id: $0["id"], mediaId: $0["mediaId"], path: $0["path"], quality: $0["q"], time: $0["time"]) }
        }) ?? []
    }

    // MARK: - Actions

    /// Photo & video folders of the open project (every project's in "All Projects").
    var projectSources: [SourceSummary] {
        sources.filter { $0.kind == .media && (currentProject == nil || $0.projectId == currentProject) }
    }

    var projectName: String { projects.first { $0.id == currentProject }?.name ?? "All Projects" }

    /// Creates a project, adds its folders and opens it.
    func createProject(named name: String, folders: [URL]) {
        guard let service else { return }
        do {
            let p = try service.createProject(name)
            for url in folders { perform { try $0.addSource(url, project: p.id) } }
            currentProject = p.id
        } catch { actionError = error.localizedDescription }
        refresh()
    }

    func renameProject(_ id: Int64, to name: String) { perform { try $0.renameProject(id, to: name) } }

    /// Forgets the project's folders in the background; people keep their names for other projects.
    func deleteProject(_ id: Int64) {
        guard let service else { return }
        let ids = sources.filter { $0.projectId == id }.map(\.id)
        removing.formUnion(ids)
        if currentProject == id { currentProject = projects.first { $0.id != id }?.id }
        Task.detached {
            let error = Result { try service.deleteProject(id) }.failure
            await MainActor.run {
                self.removing.subtract(ids)
                if let error { self.actionError = error.localizedDescription }
                self.refresh()
            }
        }
    }

    func moveSource(_ id: Int64, to project: Int64) { perform { try $0.moveSource(id, to: project) } }

    func addFolder(kind: SourceKind) {
        if kind == .media && currentProject == nil { askNewProject = true; return }
        let project = currentProject
        let message = kind == .media
            ? "Choose folders with photos and videos (local, external drive or NAS)."
            : "Choose a folder with one subfolder per person, named after them, each holding a few clear photos of that person."
        Panels.choose(folders: true, files: false, multiple: true, prompt: "Add", message: message,
                      start: FileManager.default.homeDirectoryForCurrentUser) { [weak self] urls in
            for url in urls { self?.perform { try $0.addSource(url, kind: kind, project: project) } }
        }
    }

    /// Hides the folder at once and forgets its files in the background (can take a while for big folders).
    func removeSource(_ id: Int64) {
        guard let service else { return }
        removing.insert(id)
        applySources(sources)
        Task.detached {
            let error = Result { try service.removeSource(id) }.failure
            await MainActor.run {
                self.removing.remove(id)
                if let error { self.actionError = error.localizedDescription }
                self.refresh()
            }
        }
    }
    func rescan(_ id: Int64) { service?.rescan(id) }

    @discardableResult
    func rename(_ personId: Int64, to name: String) -> Int64 {
        var result = personId
        perform { result = try $0.rename(personId, to: name) }
        return result
    }

    /// Merges a group into a known person (named in this or another project).
    func mergeInto(_ id: Int64, _ target: Int64) { perform { try $0.merge([id], into: target) } }

    func merge(_ ids: Set<Int64>) {
        // Keep a named person if there is one, else the largest group.
        let chosen = people.filter { ids.contains($0.id) }
        guard let target = chosen.first(where: { $0.name != nil }) ?? chosen.max(by: { $0.faces < $1.faces }) else { return }
        perform { try $0.merge(Array(ids), into: target.id) }
    }

    /// Starts or stops the local-network gallery (remembered across launches).
    func setSharing(_ on: Bool) {
        server?.stop()
        server = nil
        sharingURL = nil
        UserDefaults.standard.set(on, forKey: "sharingEnabled")
        guard on, let service else { return }
        var token = UserDefaults.standard.string(forKey: "sharingToken") ?? ""
        if token.isEmpty {
            token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
            UserDefaults.standard.set(token, forKey: "sharingToken")
        }
        let s = GalleryServer(store: service.store, token: token) { [weak self] pid, name in
            _ = try service.rename(pid, to: name)
            Task { @MainActor in self?.refresh() }
        }
        s.show(project: currentProject, title: projectName)
        do {
            try s.start()
            server = s
            sharingURL = s.url
        } catch {
            actionError = "Couldn't start the gallery: \(error.localizedDescription)"
        }
    }

    func regenerateSharingToken() {
        UserDefaults.standard.removeObject(forKey: "sharingToken")
        setSharing(true)
    }

    func saveAlbum(id: Int64?, name: String, query: MediaQuery) {
        perform { service in
            var album = SmartAlbum(name: name.isEmpty ? "Untitled" : name, query: query)
            album.id = id
            album.projectId = query.project
            try service.store.db.write { db in try album.save(db) }
        }
    }

    func deleteAlbum(_ id: Int64) {
        perform { service in try service.store.db.write { db in _ = try SmartAlbum.deleteOne(db, key: id) } }
    }

    func addRule(_ rule: DeliveryRule, includeExisting: Bool) {
        Notifier.requestPermission()
        perform { try $0.delivery.add(rule, includeExisting: includeExisting) }
    }

    func setRule(_ rule: DeliveryRule, enabled: Bool) {
        perform { service in
            var r = rule
            r.enabled = enabled
            try service.store.db.write { db in try r.update(db) }
        }
    }

    func deleteRule(_ rule: DeliveryRule) {
        perform { service in try service.store.db.write { db in _ = try rule.delete(db) } }
    }

    func setCover(_ personId: Int64, faceId: Int64?) { perform { try $0.setCover(personId, faceId: faceId) } }

    func reject(_ faceIds: Set<Int64>, from personId: Int64) { perform { try $0.reject(faceIds: Array(faceIds), from: personId) } }
    func assign(_ faceIds: Set<Int64>, to personId: Int64) { perform { try $0.assign(faceIds: Array(faceIds), to: personId) } }
    func newPerson(named name: String, faces: Set<Int64>) { perform { try $0.newPerson(name: name, faceIds: Array(faces)) } }

    @Published var actionError: String?

    private func perform(_ body: (LibraryService) throws -> Void) {
        guard let service else { return }
        do { try body(service) } catch { actionError = error.localizedDescription }
        refresh()
    }
}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}
