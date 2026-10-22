import AppKit
import Combine
import FaceLibrary
import Foundation
import GRDB

struct PersonSummary: Identifiable, Hashable {
    var id: Int64
    var name: String?
    var faces: Int
    var photos: Int
    var videos: Int
    var coverFaceId: Int64?
    var displayName: String { name ?? "Unnamed" }
}

struct SourceSummary: Identifiable, Hashable {
    var id: Int64
    var path: String
    var kind: SourceKind
    var files: Int
    var pending: Int
    var failed: Int
    var online = true
    var network = false
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
    var url: URL { URL(fileURLWithPath: path) }
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
    let service: LibraryService?
    @Published var startupError: String?
    @Published var people: [PersonSummary] = []
    @Published var sources: [SourceSummary] = []
    @Published var stats = LibraryStats()
    @Published var rate: Double = 0
    private var cancellables: Set<AnyCancellable> = []
    private var lastProcessed = 0
    private var lastTick = Date()

    init() {
        guard let model = locateModel() else {
            service = nil
            startupError = "The face model (ArcFaceR50.mlmodelc) was not found. Rebuild the app with scripts/build-app.sh (see README)."
            return
        }
        do {
            // SUZU_FACE_LIBRARY points the app at another library (testing); default is Application Support.
            let dir = ProcessInfo.processInfo.environment["SUZU_FACE_LIBRARY"].map { URL(fileURLWithPath: $0) }
            service = try LibraryService(modelURL: model, directory: dir ?? LibraryStore.defaultDirectory)
        } catch {
            service = nil
            startupError = "Could not open the library: \(error.localizedDescription)"
            return
        }
        service!.start()
        observe()
    }

    var store: LibraryStore? { service?.store }

    private func observe() {
        guard let db = store?.db else { return }
        // Ingest writes after every file; throttling keeps the grid from re-rendering dozens of times a second.
        ValueObservation.tracking(Self.fetchPeople).publisher(in: db, scheduling: .immediate)
            .throttle(for: .milliseconds(700), scheduler: DispatchQueue.main, latest: true)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.people = $0 })
            .store(in: &cancellables)
        ValueObservation.tracking(Self.fetchSources).publisher(in: db, scheduling: .immediate)
            .throttle(for: .milliseconds(700), scheduler: DispatchQueue.main, latest: true)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.applySources($0) })
            .store(in: &cancellables)
        ValueObservation.tracking(Self.fetchStats).publisher(in: db, scheduling: .immediate)
            .throttle(for: .milliseconds(700), scheduler: DispatchQueue.main, latest: true)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.stats = $0 })
            .store(in: &cancellables)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
    }

    private func tick() {
        guard let service else { return }
        let n = service.processor.processedCount
        let now = Date()
        rate = Double(n - lastProcessed) / now.timeIntervalSince(lastTick)
        lastProcessed = n
        lastTick = now
        applySources(sources)
    }

    private func applySources(_ list: [SourceSummary]) {
        sources = list.map { s in
            var s = s
            if let m = service?.monitor(s.id) { s.online = m.isOnline; s.network = m.isNetwork }
            return s
        }
    }

    nonisolated static func fetchPeople(_ db: Database) throws -> [PersonSummary] {
        try Row.fetchAll(db, sql: """
            SELECT p.id, p.name,
                SUM(COALESCE(s.kind, 'media') = 'media') AS faces,
                COUNT(DISTINCT CASE WHEN COALESCE(s.kind, 'media') = 'media' AND m.kind = 'photo' THEN m.id END) AS photos,
                COUNT(DISTINCT CASE WHEN COALESCE(s.kind, 'media') = 'media' AND m.kind = 'video' THEN m.id END) AS videos,
                (SELECT f2.id FROM face f2 WHERE f2.personId = p.id ORDER BY f2.quality DESC LIMIT 1) AS cover
            FROM person p
            JOIN face f ON f.personId = p.id
            JOIN media m ON m.id = f.mediaId
            LEFT JOIN source s ON s.id = m.sourceId
            GROUP BY p.id
            ORDER BY (p.name IS NULL), faces DESC
            """).map {
            PersonSummary(id: $0["id"], name: $0["name"], faces: $0["faces"], photos: $0["photos"], videos: $0["videos"],
                          coverFaceId: $0["cover"])
        }
    }

    nonisolated static func fetchSources(_ db: Database) throws -> [SourceSummary] {
        try Row.fetchAll(db, sql: """
            SELECT s.id, s.path, s.kind,
                COUNT(m.id) FILTER (WHERE m.duplicateOf IS NULL) AS files,
                COUNT(m.id) FILTER (WHERE m.status = 'pending') AS pending,
                COUNT(m.id) FILTER (WHERE m.status = 'failed') AS failed
            FROM source s LEFT JOIN media m ON m.sourceId = s.id
            GROUP BY s.id ORDER BY s.kind, s.path
            """).map {
            SourceSummary(id: $0["id"], path: $0["path"], kind: SourceKind(rawValue: $0["kind"]) ?? .media,
                          files: $0["files"], pending: $0["pending"], failed: $0["failed"])
        }
    }

    nonisolated static func fetchStats(_ db: Database) throws -> LibraryStats {
        LibraryStats(
            files: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE duplicateOf IS NULL") ?? 0,
            pending: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE status = 'pending'") ?? 0,
            unassignedFaces: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM face JOIN media m ON m.id = face.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE face.personId IS NULL AND face.quality >= 0.3 AND COALESCE(s.kind, 'media') = 'media'
                """) ?? 0)
    }

    // MARK: - Queries for detail views

    func media(of personId: Int64, alsoWith others: Set<Int64>) -> [PersonMedia] {
        guard let db = store?.db else { return [] }
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.kind, f.id AS faceId, f.time FROM face f
                JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE f.personId = ? AND COALESCE(s.kind, 'media') = 'media'
                ORDER BY m.path, f.quality DESC
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
                               faceId: r["faceId"], time: r["time"])
        }
    }

    func faces(of personId: Int64?) -> [FaceItem] {
        guard let db = store?.db else { return [] }
        let filter = personId == nil
            ? "f.personId IS NULL AND f.quality >= 0.3 AND COALESCE(s.kind, 'media') = 'media'"
            : "f.personId = \(personId!)"
        return (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, f.mediaId, m.path, COALESCE(f.quality, 0) AS q, f.time FROM face f
                JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE \(filter) ORDER BY q DESC LIMIT 3000
                """).map { FaceItem(id: $0["id"], mediaId: $0["mediaId"], path: $0["path"], quality: $0["q"], time: $0["time"]) }
        }) ?? []
    }

    // MARK: - Actions

    func addFolder(kind: SourceKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = kind == .media
            ? "Choose folders with photos and videos (local, external drive or NAS)."
            : "Choose a folder with one subfolder per person, named after them, each holding a few clear photos of that person."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { perform { try $0.addSource(url, kind: kind) } }
    }

    func removeSource(_ id: Int64) { perform { try $0.removeSource(id) } }
    func rescan(_ id: Int64) { service?.rescan(id) }

    @discardableResult
    func rename(_ personId: Int64, to name: String) -> Int64 {
        var result = personId
        perform { result = try $0.rename(personId, to: name) }
        return result
    }

    func merge(_ ids: Set<Int64>) {
        // Keep a named person if there is one, else the largest group.
        let chosen = people.filter { ids.contains($0.id) }
        guard let target = chosen.first(where: { $0.name != nil }) ?? chosen.max(by: { $0.faces < $1.faces }) else { return }
        perform { try $0.merge(Array(ids), into: target.id) }
    }

    func reject(_ faceIds: Set<Int64>, from personId: Int64) { perform { try $0.reject(faceIds: Array(faceIds), from: personId) } }
    func assign(_ faceIds: Set<Int64>, to personId: Int64) { perform { try $0.assign(faceIds: Array(faceIds), to: personId) } }
    func newPerson(named name: String, faces: Set<Int64>) { perform { try $0.newPerson(name: name, faceIds: Array(faces)) } }

    @Published var actionError: String?

    private func perform(_ body: (LibraryService) throws -> Void) {
        guard let service else { return }
        do { try body(service) } catch { actionError = error.localizedDescription }
    }
}
