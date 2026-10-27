import AppKit
import Combine
import FaceCore
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
    /// Pinned people sort first in every grid.
    var pinned = false
    /// The lists this person is on (PersonGroupSummary ids).
    var groups: Set<Int64> = []
    var displayName: String { name ?? "Unnamed" }
}

/// A list of people (cast, sponsors, VIP…), see PersonGroups. Counts come from the people list where shown.
struct PersonGroupSummary: Identifiable, Hashable {
    var id: Int64
    var name: String
}

struct ProjectSummary: Identifiable, Hashable {
    var id: Int64
    var name: String
    var folders: Int
    var files: Int
    var createdAt: Date
    /// The team the project is shared with (nil = only on this Mac).
    var teamId: Int64?
}

struct SourceSummary: Identifiable, Hashable {
    var id: Int64
    var path: String
    var kind: SourceKind
    var projectId: Int64?
    /// This Mac's own, the team's, or the editing Mac's (see SourceShare).
    var share: SourceShare = .mac
    /// The teammate's Mac that shared it here, if it came through the team.
    var fromDevice: String?
    var files: Int
    var pending: Int
    var failed: Int
    var online = true
    var network = false
    var scanning = false
    var found = 0
    /// A Rescan asked for and not done yet; `retried`: the unreadable files the last one queued again.
    var rescanning = false
    var retried = 0
    var name: String { (path as NSString).lastPathComponent }
}

struct LibraryStats: Equatable {
    var files = 0
    var pending = 0
    var unassignedFaces = 0
}

/// What the Overview shows beyond `LibraryStats`: culling marks, deliveries, faces to review.
struct OverviewStats: Equatable {
    var picks = 0
    var rejects = 0
    /// Photos rated ★★★ or better.
    var rated = 0
    /// Files auto rules copied somewhere, and when the last one went.
    var delivered = 0
    var lastDelivered: Date?
    /// Photos with a face nobody is assigned to yet.
    var unassignedPhotos = 0
}

/// Someone a person is often photographed with.
struct Companion: Identifiable, Equatable {
    var id: Int64
    var name: String
    var count: Int
    var coverFaceId: Int64?
}

/// One line of tonight's activity (Overview, status popover).
struct ActivityItem: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let text: String
    let icon: String
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
            sessions = []
            sessionAnchor = nil
            server?.show(project: currentProject, title: projectName)
            refresh()
        }
    }
    /// The open project split into sessions at gaps in capture time (opening, matches, awards…).
    @Published var sessions: [EventSession] = []
    /// A moment inside the session being looked at (nil = the whole event). People, faces, person pages, search,
    /// exports and the batch tools' People source follow it. A moment, not an index: sessions grow as files arrive.
    @Published var sessionAnchor: Double? {
        didSet { if sessionAnchor != oldValue { refresh() } }
    }
    /// Minutes without a shot that start a new session.
    @Published var sessionGapMinutes: Int = UserDefaults.standard.object(forKey: "sessionGap") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(sessionGapMinutes, forKey: "sessionGap"); refresh() }
    }
    var currentSession: EventSession? { sessionAnchor.flatMap { a in sessions.first { $0.contains(a) } } }
    var sessionRange: ClosedRange<Double>? { currentSession?.range }
    /// Asks the window to show the New Project sheet (e.g. "Add Folder" with no project open).
    @Published var askNewProject = false
    /// People in the open project.
    @Published var people: [PersonSummary] = []
    /// Everyone with a name, in any project: names are given once and shared by all projects.
    @Published var knownPeople: [PersonSummary] = []
    /// Lists of people, in sidebar order.
    @Published var groups: [PersonGroupSummary] = []
    /// Set to ask for a new list's name; the people in it are put on the list once it is made.
    @Published var askNewGroup: Set<Int64>?
    /// Set to ask for a list's new name.
    @Published var askRenameGroup: PersonGroupSummary?
    @Published var sources: [SourceSummary] = []
    @Published var stats = LibraryStats()
    /// How fast files are being processed. Its own object: it changes every second during ingest, and a change on
    /// the model redraws every screen, where this redraws only the status pill.
    let processing = ProcessingStatus()
    /// Copies and moves to people's folders running in the background.
    let exports = PeopleCopies()
    var rate: Double { processing.rate }
    /// A refresh asked for by the user (a name, a merge) goes at once; the ones the database triggers during
    /// ingest wait a few seconds between them, so the screens aren't rebuilt under every click.
    private var urgent = false
    private var lastRefresh = Date.distantPast
    @Published var albums: [SmartAlbum] = []
    @Published var sharingURL: String?
    private var server: GalleryServer?
    @Published var rules: [DeliveryRule] = []
    /// Projects shared with other Macs through a folder (see TeamSync), and how the sharing is going.
    @Published var teams: [TeamRecord] = []
    @Published var teamStatus: [Int64: TeamSync.TeamStatus] = [:]
    @Published var askShareTeam = false
    @Published var askJoinTeam = false
    /// The open project's team, if it is shared.
    var currentTeam: TeamRecord? {
        guard let tid = projects.first(where: { $0.id == currentProject })?.teamId else { return nil }
        return teams.first { $0.id == tid }
    }
    func projects(in team: TeamRecord) -> [ProjectSummary] { projects.filter { $0.teamId == team.id } }
    /// Projects shared with no team.
    var localProjects: [ProjectSummary] { projects.filter { $0.teamId == nil } }
    /// Bumped after ratings, labels or flags change, so every view showing them re-reads.
    @Published var marksVersion = 0
    /// Counts the Overview shows beside `stats`: culling marks, deliveries, faces to review.
    @Published var overview = OverviewStats()
    /// What happened tonight (names, merges, deliveries, folders), newest first; see `log`.
    @Published var activity: [ActivityItem] = []
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
        // Edit & Export's retouch finds the people's parts with it (Apple Vision until it's downloaded).
        BodyParts.modelURL = BodyPartsModel.located
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
        Thumbnails.shared.store = service.store
        WatermarkPresets.shared.attach(service.store) { [teamSync = service.teamSync] in teamSync.pushSoon() }
        UserLooks.shared.attach(service.store) { [teamSync = service.teamSync] in teamSync.pushSoon() }
        service.onDelivered = { [weak self] report in
            Notifier.post(report)
            Task { @MainActor in self?.logDelivery(report) }
        }
        service.teamSync.onChange = { [weak self] in Task { @MainActor in self?.applyTeamStatus() } }
        ToolWork.faces = self
        exports.model = self
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
                                                   Table("smartAlbum"), Table("deliveryRule"), Table("project"),
                                                   Table("sessionLabel"), Table("team"), Table("delivery"),
                                                   Table("personGroup"), Table("personGroupMember"))
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
        urgent = true
        tick()
    }

    private func tick() {
        guard let service else { return }
        let n = service.processor.processedCount
        let now = Date()
        if now.timeIntervalSince(lastTick) >= 1 {
            // Published only when it changes: every published change redraws every screen, and a redraw while a
            // right-click menu is open rebuilds the menu (its submenus flash or close).
            let r = Double(n - lastProcessed) / now.timeIntervalSince(lastTick)
            if r != processing.rate { processing.rate = r }
            lastProcessed = n
            lastTick = now
        }
        applySources(sources)
        applyTeamStatus()
        guard dirty, !refreshing, let db = store?.db else { return }
        // While files pour in, every commit marks the data dirty: re-read at most every 3 s then.
        let busy = service.processor.queuedCount > 0 || service.processor.backgroundCount > 0
        if !urgent, busy, now.timeIntervalSince(lastRefresh) < 3 { return }
        urgent = false
        lastRefresh = now
        dirty = false
        refreshing = true
        let project = currentProject, range = sessionRange, gap = Double(sessionGapMinutes * 60)
        Task.detached(priority: .userInitiated) {
            let result = try? await db.read { db in
                (try Self.fetchPeople(db, project: project, taken: range), try Self.fetchSources(db),
                 try Self.fetchStats(db, project: project, taken: range),
                 try SmartAlbum.order(Column("name")).fetchAll(db), try DeliveryService.rules(db),
                 try Self.fetchProjects(db), try Self.fetchKnownPeople(db),
                 project == nil ? [] : try EventSessions.list(db, project: project, gap: gap),
                 try TeamRecord.order(Column("joinedAt")).fetchAll(db),
                 try Self.fetchOverview(db, project: project),
                 try Self.fetchGroups(db))
            }
            await MainActor.run {
                defer { self.refreshing = false }
                // The project changed while reading: the next tick reads the new one.
                guard project == self.currentProject, range == self.sessionRange else { self.dirty = true; return }
                if let (people, sources, stats, albums, rules, projects, known, sessions, teams, overview, groups) = result {
                    if teams != self.teams { self.teams = teams; self.applyTeamStatus() }
                    if sessions != self.sessions {
                        if sessions.count > self.sessions.count, !self.sessions.isEmpty, let s = sessions.last {
                            self.log("Session \(self.sessionTitle(s)) started", icon: "clock")
                        }
                        self.sessions = sessions
                        // The session may have grown, merged or split: re-read with its current range.
                        if self.sessionRange != range { self.dirty = true }
                    }
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
                    if groups != self.groups { self.groups = groups }
                    if people != self.people { self.people = people }
                    self.applySources(sources)
                    if stats != self.stats { self.stats = stats }
                    if overview != self.overview { self.overview = overview }
                    if albums != self.albums { self.albums = albums }
                    if rules != self.rules {
                        if self.rules.isEmpty && !rules.isEmpty { Notifier.requestPermission() }
                        self.rules = rules
                    }
                }
            }
        }
    }

    private func applyTeamStatus() {
        guard let sync = service?.teamSync else { return }
        var status: [Int64: TeamSync.TeamStatus] = [:]
        for t in teams { if let s = sync.status(t.id!) { status[t.id!] = s } }
        if status != teamStatus { teamStatus = status }
    }

    private func applySources(_ list: [SourceSummary]) {
        let updated = list.filter { !removing.contains($0.id) }.map { s in
            var s = s
            if let m = service?.monitor(s.id) {
                s.online = m.isOnline; s.network = m.isNetwork; s.scanning = m.isScanning; s.found = m.foundCount
                s.rescanning = m.isRescanning; s.retried = m.retriedCount
            }
            return s
        }
        if updated != sources {
            for s in updated {
                guard let old = sources.first(where: { $0.id == s.id }) else { continue }
                if old.rescanning && !s.rescanning {
                    log("Rescanned \(s.name) · \(s.found.formatted()) files"
                        + (s.retried > 0 ? " · \(s.retried.formatted()) that couldn't be read are read again" : ""), icon: "arrow.clockwise")
                } else if old.scanning && !s.scanning && !s.rescanning {
                    log("Finished scanning \(s.name) · \(s.found.formatted()) files found", icon: "folder")
                }
                if old.online && !s.online { log("\(s.name) went offline", icon: "externaldrive.badge.xmark") }
                if !old.online && s.online { log("\(s.name) is back online", icon: "externaldrive") }
            }
            sources = updated
        }
    }

    // MARK: - Activity

    /// Notes something that happened, for the Overview and the status popover.
    func log(_ text: String, icon: String = "circle.fill") {
        activity.insert(ActivityItem(at: Date(), text: text, icon: icon), at: 0)
        if activity.count > 60 { activity.removeLast(activity.count - 60) }
    }

    private func logDelivery(_ report: DeliveryService.Report) {
        let who = report.newFiles.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        if report.copied > 0 {
            log("Delivered \(report.copied) file\(report.copied == 1 ? "" : "s") · \(who)", icon: "paperplane")
        } else if !report.newFiles.isEmpty {
            log("New photos: \(who)", icon: "bell")
        }
    }

    /// Culling, delivery and review counts of the project (nil = every project).
    nonisolated static func fetchOverview(_ db: Database, project: Int64?) throws -> OverviewStats {
        var o = OverviewStats()
        if let r = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) FILTER (WHERE m.flag = 1) AS picks, COUNT(*) FILTER (WHERE m.flag = -1) AS rejects,
                COUNT(*) FILTER (WHERE m.rating >= 3) AS rated
            FROM media m LEFT JOIN source s ON s.id = m.sourceId WHERE m.duplicateOf IS NULL AND \(ProjectScope.sql(project))
            """) {
            o.picks = r["picks"]; o.rejects = r["rejects"]; o.rated = r["rated"]
        }
        if let r = try Row.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT d.mediaId) AS n, MAX(d.deliveredAt) AS last
            FROM delivery d JOIN media m ON m.id = d.mediaId LEFT JOIN source s ON s.id = m.sourceId WHERE \(ProjectScope.sql(project))
            """) {
            o.delivered = r["n"]; o.lastDelivered = r["last"]
        }
        o.unassignedPhotos = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT face.mediaId) FROM face JOIN media m ON m.id = face.mediaId LEFT JOIN source s ON s.id = m.sourceId
            WHERE face.personId IS NULL AND face.quality >= 0.3 AND \(ProjectScope.sql(project))
            """) ?? 0
        return o
    }

    /// People with faces in the project (nil = anywhere), with counts for that project.
    ///
    /// Order: pinned, then named (by how often they appear), then the unnamed. Among the unnamed, those whose
    /// picture looks straight at the camera and is sharp come first: if even a person's best face is turned away or
    /// blurred, they were in the background, and are rarely someone to name. Within a band of picture quality (five
    /// bands) the people seen more often come first.
    nonisolated static func fetchPeople(_ db: Database, project: Int64?, taken: ClosedRange<Double>? = nil) throws -> [PersonSummary] {
        let scope = "\(ProjectScope.sql(project)) AND \(EventSessions.sql(taken))"
        return try Row.fetchAll(db, sql: """
            SELECT y.* FROM (
                SELECT x.*, (SELECT \(BestShot.coverOrderSQL) FROM face f WHERE f.id = x.cover) AS look FROM (
                    SELECT p.id, p.name, p.pinnedAt IS NOT NULL AS pinned, COUNT(*) AS faces,
                        COUNT(DISTINCT CASE WHEN m.kind = 'photo' THEN m.id END) AS photos,
                        COUNT(DISTINCT CASE WHEN m.kind = 'video' THEN m.id END) AS videos,
                        COALESCE((SELECT c.id FROM face c WHERE c.id = p.coverFaceId AND c.personId = p.id),
                                 \(BestShot.coverSubquery(project: project))) AS cover,
                        (SELECT group_concat(groupId) FROM personGroupMember gm WHERE gm.personId = p.id) AS groups
                    FROM person p
                    JOIN face f ON f.personId = p.id
                    JOIN media m ON m.id = f.mediaId
                    LEFT JOIN source s ON s.id = m.sourceId
                    WHERE \(scope)
                    GROUP BY p.id
                ) x
            ) y
            ORDER BY (y.pinned = 0), (y.name IS NULL),
                CASE WHEN y.name IS NULL THEN CAST(COALESCE(y.look, 0) * 5 AS INTEGER) ELSE 0 END DESC, y.faces DESC
            """).map {
            PersonSummary(id: $0["id"], name: $0["name"], faces: $0["faces"], photos: $0["photos"], videos: $0["videos"],
                          coverFaceId: $0["cover"], pinned: $0["pinned"],
                          groups: Set((($0["groups"] as String?) ?? "").split(separator: ",").compactMap { Int64($0) }))
        }
    }

    nonisolated static func fetchGroups(_ db: Database) throws -> [PersonGroupSummary] {
        try Row.fetchAll(db, sql: "SELECT id, name FROM personGroup ORDER BY sortOrder, id")
            .map { PersonGroupSummary(id: $0["id"], name: $0["name"]) }
    }

    nonisolated static func fetchProjects(_ db: Database) throws -> [ProjectSummary] {
        try Row.fetchAll(db, sql: """
            SELECT p.id, p.name, p.createdAt, p.teamId, COUNT(DISTINCT s.id) AS folders, COUNT(m.id) AS files
            FROM project p LEFT JOIN source s ON s.projectId = p.id LEFT JOIN media m ON m.sourceId = s.id AND m.duplicateOf IS NULL
            GROUP BY p.id ORDER BY p.createdAt DESC
            """).map { ProjectSummary(id: $0["id"], name: $0["name"], folders: $0["folders"], files: $0["files"], createdAt: $0["createdAt"], teamId: $0["teamId"]) }
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
            SELECT s.id, s.path, s.kind, s.projectId, s.share, s.fromDevice,
                COUNT(m.id) FILTER (WHERE m.duplicateOf IS NULL) AS files,
                COUNT(m.id) FILTER (WHERE m.status = 'pending') AS pending,
                COUNT(m.id) FILTER (WHERE m.status = 'failed') AS failed
            FROM source s LEFT JOIN media m ON m.sourceId = s.id
            WHERE s.removedAt IS NULL
            GROUP BY s.id ORDER BY s.kind, s.path
            """).map {
            SourceSummary(id: $0["id"], path: $0["path"], kind: SourceKind(rawValue: $0["kind"]) ?? .media, projectId: $0["projectId"],
                          share: SourceShare(rawValue: $0["share"]) ?? .mac, fromDevice: $0["fromDevice"],
                          files: $0["files"], pending: $0["pending"], failed: $0["failed"])
        }
    }

    /// Files and unassigned faces of the project; pending files of the whole library (processing is shared).
    nonisolated static func fetchStats(_ db: Database, project: Int64?, taken: ClosedRange<Double>? = nil) throws -> LibraryStats {
        LibraryStats(
            files: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM media m LEFT JOIN source s ON s.id = m.sourceId WHERE m.duplicateOf IS NULL AND \(ProjectScope.sql(project))
                """) ?? 0,
            pending: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") ?? 0,
            unassignedFaces: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM face JOIN media m ON m.id = face.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE face.personId IS NULL AND face.quality >= 0.3 AND \(ProjectScope.sql(project)) AND \(EventSessions.sql(taken))
                """) ?? 0)
    }

    // MARK: - Queries for detail views

    func media(of personId: Int64, alsoWith others: Set<Int64>) async -> [PersonMedia] {
        guard let store else { return [] }
        let project = currentProject, range = sessionRange
        return await Task.detached(priority: .userInitiated) { Self.loadMedia(store, personId, others, project: project, taken: range) }.value
    }

    func faces(of personId: Int64?) async -> [FaceItem] {
        guard let store else { return [] }
        let project = currentProject, range = sessionRange
        return await Task.detached(priority: .userInitiated) { Self.loadFaces(store, personId, project: project, taken: range) }.value
    }

    /// Unassigned faces that look like one another but were seen only twice (groups need three): a guest shot
    /// twice, offered as a pair so one click names them. Clear faces of the open project and session only.
    func likelyPairs() async -> [[FaceItem]] {
        guard let store else { return [] }
        let project = currentProject, range = sessionRange
        let threshold = service?.engine.settings.clusterThreshold ?? 0.45
        let minQuality = service?.engine.settings.exemplarMinQuality ?? 0.3
        return await Task.detached(priority: .userInitiated) {
            let rows = (try? store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT f.id, f.mediaId, m.path, f.quality, f.time, f.embedding FROM face f JOIN media m ON m.id = f.mediaId
                    LEFT JOIN source s ON s.id = m.sourceId
                    WHERE f.personId IS NULL AND f.assignment = 'none' AND f.embedding IS NOT NULL AND f.quality >= ?
                      AND f.w * COALESCE(m.width, 0) >= 40 AND m.duplicateOf IS NULL AND \(ProjectScope.sql(project)) AND \(EventSessions.sql(range))
                    ORDER BY f.id DESC LIMIT 3000
                    """, arguments: [minQuality])
            }) ?? []
            guard rows.count >= 2 else { return [] }
            let items = rows.map { FaceItem(id: $0["id"], mediaId: $0["mediaId"], path: $0["path"], quality: $0["quality"], time: $0["time"]) }
            let vectors = rows.map { Vector.decode($0["embedding"]) }
            guard vectors.allSatisfy({ $0.count == 512 }) else { return [] }
            let labels = Clustering.averageLinkage(similarity: Clustering.similarityMatrix(vectors), count: vectors.count, threshold: threshold)
            var groups: [Int: [Int]] = [:]
            for (i, l) in labels.enumerated() { groups[l, default: []].append(i) }
            // Two different photos of one face (not two faces in one photo).
            return groups.values.filter { $0.count == 2 && items[$0[0]].mediaId != items[$0[1]].mediaId }
                .map { $0.map { items[$0] } }
                .sorted { max($0[0].quality, $0[1].quality) > max($1[0].quality, $1[1].quality) }
        }.value
    }

    /// The named people this person is most often photographed with, in the open project and session.
    func companions(of personId: Int64) async -> [Companion] {
        guard let store else { return [] }
        let project = currentProject, range = sessionRange
        return await Task.detached(priority: .utility) {
            (try? store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT p.id, p.name, COUNT(DISTINCT m.id) AS n,
                        COALESCE(p.coverFaceId, (SELECT c.id FROM face c WHERE c.personId = p.id ORDER BY c.score DESC LIMIT 1)) AS cover
                    FROM face f JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                    JOIN face o ON o.mediaId = m.id AND o.personId IS NOT NULL AND o.personId != f.personId
                    JOIN person p ON p.id = o.personId
                    WHERE f.personId = ? AND p.name IS NOT NULL AND \(ProjectScope.sql(project)) AND \(EventSessions.sql(range))
                    GROUP BY p.id ORDER BY n DESC LIMIT 8
                    """, arguments: [personId]).map { Companion(id: $0["id"], name: $0["name"], count: $0["n"], coverFaceId: $0["cover"]) }
            }) ?? []
        }.value
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
                    SELECT m.id, m.path, f.id AS faceId, f.x, f.y, f.w, f.h, p.name FROM face f JOIN media m ON m.id = f.mediaId
                    LEFT JOIN source s ON s.id = m.sourceId LEFT JOIN person p ON p.id = f.personId
                    WHERE m.kind = 'photo' AND m.duplicateOf IS NULL AND \(ProjectScope.sql(project))
                      \(personId.map { "AND f.personId = \($0)" } ?? "AND f.personId IS NOT NULL")
                    ORDER BY COALESCE(f.score, f.quality * 0.6, 0) DESC LIMIT \(limit * 4)
                    """)
            }) ?? []
            var seen: Set<String> = []
            let picked = rows.filter { seen.insert($0["path"]).inserted }.prefix(limit)
            let boxes = (try? store.db.read { db in try Selection.faceBoxes(db, mediaIds: picked.map { $0["id"] as Int64 }) }) ?? [:]
            return picked.map { r in
                ToolItem(url: URL(fileURLWithPath: r["path"], isDirectory: false), personName: r["name"],
                         focus: Selection.focus(face: r["faceId"], box: CGRect(x: r["x"] as Double, y: r["y"] as Double, width: r["w"] as Double, height: r["h"] as Double),
                                                in: boxes[r["id"]]))
            }
        }.value
    }

    nonisolated static func loadMedia(_ store: LibraryStore, _ personId: Int64, _ others: Set<Int64>, project: Int64?,
                                      taken: ClosedRange<Double>? = nil) -> [PersonMedia] {
        let db = store.db
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.kind, m.takenAt, m.burstId, f.id AS faceId, f.time,
                    COALESCE(f.score, f.quality * 0.6, 0) AS score FROM face f
                JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE f.personId = ? AND \(ProjectScope.sql(project)) AND \(EventSessions.sql(taken))
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

    nonisolated static func loadFaces(_ store: LibraryStore, _ personId: Int64?, project: Int64?, taken: ClosedRange<Double>? = nil) -> [FaceItem] {
        let db = store.db
        let filter = personId == nil
            ? "f.personId IS NULL AND f.quality >= 0.3 AND \(ProjectScope.sql(project)) AND \(EventSessions.sql(taken))"
            : "f.personId = \(personId!) AND ((\(ProjectScope.sql(project)) AND \(EventSessions.sql(taken))) OR s.kind = 'reference')"
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

    /// Names a session of the open project ("Awards"); empty clears it.
    func renameSession(_ session: EventSession, to name: String) {
        guard let project = currentProject else { return }
        perform { try EventSessions.setName($0.store, project: project, session: session, name: name) }
    }

    /// "Awards" or "14:00–14:05"; with the day when the event spans several days.
    func sessionTitle(_ s: EventSession) -> String { s.name ?? sessionTime(s) }

    func sessionTime(_ s: EventSession) -> String {
        let start = Date(timeIntervalSince1970: s.start), end = Date(timeIntervalSince1970: s.end)
        let cal = Calendar.current
        let multiDay = Set(sessions.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0.start)) }).count > 1
        let time = DateFormatter()
        time.dateFormat = "HH:mm"  // 24-hour, as event schedules are written
        let range = "\(time.string(from: start))–\(time.string(from: end))"
        return multiDay ? "\(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(range)" : range
    }

    func moveSource(_ id: Int64, to project: Int64) { perform { try $0.moveSource(id, to: project) } }

    /// Asks for folders and adds them: this Mac's own, the team's (every Mac of the team gets them), or the editing
    /// Mac's folder (the same).
    func addFolder(kind: SourceKind, share: SourceShare = .mac) {
        if kind == .media && currentProject == nil { askNewProject = true; return }
        if share != .mac && currentTeam == nil { actionError = LibraryService.ProjectError.notShared.localizedDescription; return }
        let project = currentProject
        let message: String
        switch (kind, share) {
        case (.reference, _): message = "Choose a folder with one subfolder per person, named after them, each holding a few clear photos of that person."
        case (_, .team): message = "Choose the folders the whole team works on (on the NAS share every Mac mounts). Every Mac in the team gets them."
        case (_, .edited): message = "Choose the folder the editing Mac fills with edited and selected photos. Every Mac in the team sees it."
        case (_, .mac): message = "Choose folders with photos and videos (local, external drive or NAS)."
        }
        // Team folders live where the team sync folder is: start the picker there.
        let start = share == .mac ? FileManager.default.homeDirectoryForCurrentUser
                                  : currentTeam.map { URL(fileURLWithPath: $0.folder).deletingLastPathComponent() } ?? FileManager.default.homeDirectoryForCurrentUser
        Panels.choose(folders: true, files: false, multiple: true, prompt: "Add", message: message, start: start) { [weak self] urls in
            for url in urls {
                self?.perform { try $0.addSource(url, kind: kind, project: project, share: share) }
                self?.log(share == .mac ? "Added folder \(url.lastPathComponent)" : "Added \(share.title.lowercased()) \(url.lastPathComponent) · on every Mac of the team",
                          icon: share == .mac ? "folder.badge.plus" : "person.3")
            }
        }
    }

    /// Makes a folder the team's, the editing Mac's, or this Mac's own again; the team's Macs follow.
    func setShare(_ id: Int64, _ share: SourceShare) {
        let name = sources.first { $0.id == id }?.name ?? "Folder"
        perform { try $0.setShare(id, share) }
        log(share == .mac ? "\(name) is now only on this Mac" : "\(name) is now a \(share.title.lowercased()) · on every Mac of the team", icon: "person.3")
    }

    /// The Mac a shared folder came from, by name when the team has seen it.
    func sharer(of s: SourceSummary) -> String? {
        guard let dev = s.fromDevice else { return nil }
        return teamStatus.values.lazy.compactMap { st in st.devices.first { $0.id == dev }?.name }.first ?? "a teammate's Mac"
    }

    /// Adds the folder Copy from Cards fills, unless a folder of the library already holds it.
    func addCopiedFolder(_ url: URL, project: Int64) {
        let path = canonicalPath(url)
        if sources.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { return }
        perform { try $0.addSource(url, kind: .media, project: project) }
        log("Added the card folder \(url.lastPathComponent)", icon: "sdcard")
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
    func rescan(_ id: Int64) {
        service?.rescan(id)
        refresh()  // shows Rescanning at once, not on the next tick
    }

    /// The folder was renamed or moved in Finder: point the library at it again, keeping every face and name.
    func locateSource(_ id: Int64) {
        let start = sources.first { $0.id == id }.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
        Panels.chooseFolder(prompt: "Use This Folder", start: start, key: "locateSource") { [weak self] url in
            self?.perform { try $0.relinkSource(id, to: url) }
        }
    }

    @discardableResult
    func rename(_ personId: Int64, to name: String) -> Int64 {
        var result = personId
        perform { result = try $0.rename(personId, to: name) }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { log(result == personId ? "Named \(n)" : "Named \(n) · merged with the person of that name", icon: "pencil") }
        return result
    }

    /// Merges a group into a known person (named in this or another project).
    func mergeInto(_ id: Int64, _ target: Int64) {
        perform { try $0.merge([id], into: target) }
        if let name = knownPeople.first(where: { $0.id == target })?.name { log("This is \(name) · group merged", icon: "person.2") }
    }

    // MARK: Lists and pins

    func pin(_ ids: Set<Int64>, _ on: Bool) {
        perform { try $0.pin(Array(ids), on) }
        let who = ids.count == 1 ? (people.first { $0.id == ids.first }?.displayName ?? "1 person") : "\(ids.count) people"
        log(on ? "Pinned \(who)" : "Unpinned \(who)", icon: on ? "star.fill" : "star")
    }

    /// Makes a list (or finds the one of that name) and puts `ids` on it.
    func createGroup(_ name: String, people ids: Set<Int64> = []) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        perform { try $0.createGroup(n, people: Array(ids)) }
        log(ids.isEmpty ? "List \(n) made" : "\(ids.count == 1 ? "1 person" : "\(ids.count) people") put on \(n)", icon: "list.bullet")
    }

    func renameGroup(_ id: Int64, to name: String) { perform { try $0.renameGroup(id, to: name) } }

    func deleteGroup(_ id: Int64) {
        let name = groups.first { $0.id == id }?.name ?? "list"
        perform { try $0.deleteGroup(id) }
        log("List \(name) deleted", icon: "list.bullet")
    }

    func setGroup(_ id: Int64, people ids: Set<Int64>, member: Bool) {
        perform { try $0.setGroup(id, people: Array(ids), member: member) }
        if let name = groups.first(where: { $0.id == id })?.name {
            let who = ids.count == 1 ? (people.first { $0.id == ids.first }?.displayName ?? "1 person") : "\(ids.count) people"
            log(member ? "\(who) put on \(name)" : "\(who) taken off \(name)", icon: "list.bullet")
        }
    }

    func merge(_ ids: Set<Int64>) {
        // Keep a named person if there is one, else the largest group.
        let chosen = people.filter { ids.contains($0.id) }
        guard let target = chosen.first(where: { $0.name != nil }) ?? chosen.max(by: { $0.faces < $1.faces }) else { return }
        perform { try $0.merge(Array(ids), into: target.id) }
        log("Merged \(ids.count) people into \(target.displayName)", icon: "person.2")
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
        perform { try $0.delivery.add(rule, includeExisting: includeExisting); $0.teamSync.pushSoon() }
    }

    func updateRule(_ rule: DeliveryRule) {
        perform { try $0.delivery.update(rule); $0.teamSync.pushSoon() }
    }

    func setRule(_ rule: DeliveryRule, enabled: Bool) {
        var r = rule
        r.enabled = enabled
        updateRule(r)
    }

    func deleteRule(_ rule: DeliveryRule) {
        perform { try $0.delivery.delete(rule); $0.teamSync.pushSoon() }
    }

    // MARK: - Teams

    /// Starts a team in `folder` and shares the open project with it; teammates join by picking the same folder.
    func createTeam(named name: String, folder: URL) -> Bool {
        guard let project = currentProject else { return false }
        var ok = false
        perform { try $0.teamSync.create(name: name, folder: folder, project: project); ok = true }
        return ok
    }

    /// Joins the team in `folder`: its projects appear as the teammates' logs are read (the first ones right away).
    func joinTeam(folder: URL) -> Bool {
        guard let service else { return false }
        // Already in this team through this very folder: nothing to read again, just open one of its projects.
        if let team = service.teamSync.member(of: folder), team.folder == canonicalPath(folder) {
            if projects.first(where: { $0.id == currentProject })?.teamId != team.id,
               let first = projects.last(where: { $0.teamId == team.id }) { currentProject = first.id }
            log("Already in \(team.name) · same team sync folder, nothing to sync again", icon: "person.3")
            return true
        }
        var joined: TeamRecord?
        perform { joined = try $0.teamSync.join(folder: folder) }
        guard let joined else { return false }
        Task.detached {
            service.teamSync.syncNow()
            let first = try? service.teamSync.projects(in: joined.id!).last
            await MainActor.run {
                self.refresh()
                // Open one of the team's projects unless the open one is already in it.
                if let first, self.projects.first(where: { $0.id == self.currentProject })?.teamId != joined.id { self.currentProject = first.id }
            }
        }
        return true
    }

    func shareProject(with team: TeamRecord) {
        guard let project = currentProject else { return }
        perform { try $0.teamSync.share(project: project, team: team.id!) }
    }

    func stopSharingProject() {
        guard let project = currentProject else { return }
        perform { try $0.teamSync.unshare(project: project) }
    }

    func leaveTeam(_ id: Int64) { perform { try $0.teamSync.leave(id) } }

    /// Shared processing (see SharedFaces): whether this Mac does the team's face work, and choosing that.
    func isProcessor(_ team: TeamRecord) -> Bool { team.processorId != nil && team.processorId == service?.teamSync.deviceId }
    /// The teammate's Mac that processes the open project's faces, when it isn't this one.
    var processingMac: String? {
        guard let team = currentTeam, team.processorId != nil, !isProcessor(team) else { return nil }
        return team.processorName ?? "a teammate's Mac"
    }
    func setProcessor(_ team: TeamRecord, thisMac: Bool) {
        perform { try $0.teamSync.setProcessor(team.id!, thisMac: thisMac) }
        log(thisMac ? "This Mac now processes faces for \(team.name)" : "Every Mac in \(team.name) processes its own files", icon: "cpu")
    }

    func renameTeam(_ id: Int64, to name: String) { perform { try $0.teamSync.rename(id, to: name) } }

    /// The team sync folder moved (new NAS address or mount name): same team, new path.
    func relocateTeam(_ id: Int64, to folder: URL) {
        var moved = true
        perform { moved = try $0.teamSync.relocate(id, to: folder) }
        if !moved, actionError == nil { log("Same team sync folder as before · nothing to sync again", icon: "person.3") }
    }

    func syncTeamNow() { service?.teamSync.syncSoon() }

    func setCover(_ personId: Int64, faceId: Int64?) { perform { try $0.setCover(personId, faceId: faceId) } }

    func reject(_ faceIds: Set<Int64>, from personId: Int64) { perform { try $0.reject(faceIds: Array(faceIds), from: personId) } }
    func assign(_ faceIds: Set<Int64>, to personId: Int64) { perform { try $0.assign(faceIds: Array(faceIds), to: personId) } }
    func regroup(_ faceIds: Set<Int64>) { perform { try $0.regroup(faceIds: Array(faceIds)) } }
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

/// See `FaceGroupingModel.processing`.
@MainActor
final class ProcessingStatus: ObservableObject {
    @Published var rate: Double = 0
}
