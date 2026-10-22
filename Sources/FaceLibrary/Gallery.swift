import FaceCore
import Foundation
import GRDB
import ImageIO
import MediaKit
import Network

/// People and their files for the gallery (best shots first).
struct GalleryData {
    let store: LibraryStore

    struct Person { var id: Int64; var name: String; var photos: Int; var videos: Int; var cover: Int64? }
    struct File { var mediaId: Int64; var path: String; var isVideo: Bool; var faceId: Int64; var time: Double?; var score: Double; var burstId: Int64?; var box: CGRect }

    func people(_ ids: [Int64]? = nil) throws -> [Person] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name,
                  COUNT(DISTINCT CASE WHEN m.kind = 'photo' THEN m.id END) AS photos,
                  COUNT(DISTINCT CASE WHEN m.kind = 'video' THEN m.id END) AS videos,
                  COALESCE((SELECT c.id FROM face c WHERE c.id = p.coverFaceId AND c.personId = p.id),
                           (SELECT f.id FROM face f WHERE f.personId = p.id ORDER BY \(BestShot.coverOrderSQL) DESC LIMIT 1)) AS cover
                FROM person p JOIN face f ON f.personId = p.id JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE p.name IS NOT NULL AND COALESCE(s.kind, 'media') = 'media' AND m.duplicateOf IS NULL
                  \(ids.map { "AND p.id IN (\($0.map(String.init).joined(separator: ",")))" } ?? "")
                GROUP BY p.id ORDER BY p.name COLLATE NOCASE
                """).map { Person(id: $0["id"], name: $0["name"], photos: $0["photos"], videos: $0["videos"], cover: $0["cover"]) }
        }
    }

    func files(personId: Int64, topN: Int?, bestOfBurst: Bool) throws -> [File] {
        var files = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.path, m.kind, m.burstId, f.id AS faceId, f.time, f.x, f.y, f.w, f.h, COALESCE(f.score, f.quality * 0.6, 0) AS s
                FROM face f JOIN media m ON m.id = f.mediaId LEFT JOIN source s ON s.id = m.sourceId
                WHERE f.personId = ? AND m.duplicateOf IS NULL AND COALESCE(s.kind, 'media') = 'media'
                ORDER BY s DESC
                """, arguments: [personId]).map {
                File(mediaId: $0["id"], path: $0["path"], isVideo: ($0["kind"] as String) == "video", faceId: $0["faceId"], time: $0["time"],
                     score: $0["s"], burstId: $0["burstId"], box: CGRect(x: $0["x"] as Double, y: $0["y"] as Double, width: $0["w"] as Double, height: $0["h"] as Double))
            }
        }
        var seen: Set<Int64> = [], bursts: Set<Int64> = []
        files = files.filter { seen.insert($0.mediaId).inserted }
        if bestOfBurst { files = files.filter { f in f.burstId.map { bursts.insert($0).inserted } ?? true } }
        if let topN { files = Array(files.prefix(topN)) }
        return files
    }
}

/// Writes a self-contained web gallery folder (open index.html, or put the folder on Drive/NAS and share it).
public struct GalleryExporter: Sendable {
    let store: LibraryStore
    public init(store: LibraryStore) { self.store = store }

    public struct Options: Sendable {
        public var topN: Int? = 60
        public var bestOfBurst = true
        /// Web-size photos; set a watermark here to brand them.
        public var recipe: EditRecipe = { var r = EditRecipe(); r.maxLongSide = 2048; r.jpegQuality = 0.85; return r }()
        public var includeVideos = false
        public init() {}
    }

    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi")).replacingOccurrences(of: "đ", with: "d")
        return folded.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().split(separator: "-").joined(separator: "-")
    }

    /// Returns the index.html it wrote.
    public func export(title: String, personIds: [Int64]?, options: Options, to folder: URL,
                       progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> URL {
        let data = GalleryData(store: store)
        let people = try data.people(personIds)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("faces"), withIntermediateDirectories: true)
        var cards: [GalleryHTML.PersonCard] = []
        let lists = try people.map { try data.files(personId: $0.id, topN: options.topN, bestOfBurst: options.bestOfBurst).filter { options.includeVideos || !$0.isVideo } }
        let total = lists.map(\.count).reduce(0, +)
        var done = 0
        for (p, files) in zip(people, lists) {
            let slug = Self.slug(p.name).isEmpty ? "person-\(p.id)" : Self.slug(p.name)
            let dir = folder.appendingPathComponent(slug)
            try fm.createDirectory(at: dir.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
            if let c = p.cover { try? fm.copyItem(at: store.faceCropURL(c), to: folder.appendingPathComponent("faces/\(slug).jpg")) }
            var tiles: [GalleryHTML.Tile] = []
            for f in files {
                defer { done += 1; progress(done, total) }
                let src = URL(fileURLWithPath: f.path)
                let base = "\(f.mediaId)"
                if f.isVideo {
                    let name = base + "." + src.pathExtension.lowercased()
                    try? fm.copyItem(at: src, to: dir.appendingPathComponent(name))
                    if let frame = VideoSampler.frameSync(src, at: f.time ?? 0, maxPixel: 480) {
                        ImageLoader.writeJPEG(frame, to: dir.appendingPathComponent("thumbs/\(base).jpg"), quality: 0.8)
                    }
                    tiles.append(.init(thumb: "thumbs/\(base).jpg", view: name, download: name, isVideo: true, caption: src.lastPathComponent))
                } else {
                    do {
                        try EditPipeline.render(src, recipe: options.recipe, focus: FocusHint(primary: f.box), people: [p.name], to: dir.appendingPathComponent("\(base).jpg"))
                        var thumb = EditRecipe(); thumb.maxLongSide = 480; thumb.jpegQuality = 0.8; thumb.writePeopleNames = false
                        try EditPipeline.render(dir.appendingPathComponent("\(base).jpg"), recipe: thumb, focus: nil, to: dir.appendingPathComponent("thumbs/\(base).jpg"))
                        tiles.append(.init(thumb: "thumbs/\(base).jpg", view: "\(base).jpg", download: "\(base).jpg", isVideo: false, caption: src.lastPathComponent))
                    } catch { continue }
                }
            }
            try GalleryHTML.person(p.name, back: "../index.html", tiles: tiles).write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            cards.append(.init(name: p.name, photos: p.photos, videos: p.videos, cover: "faces/\(slug).jpg", link: "\(slug)/index.html"))
        }
        let index = folder.appendingPathComponent("index.html")
        try GalleryHTML.people(title, cards).write(to: index, atomically: true, encoding: .utf8)
        return index
    }
}

/// Serves the library as a web gallery on the local network (browse, play, download, rename from any device).
/// Every URL starts with a secret token, so only people given the link can see it.
public final class GalleryServer: @unchecked Sendable {
    let store: LibraryStore
    let token: String
    let rename: (Int64, String) throws -> Void
    var listener: NWListener?
    let queue = DispatchQueue(label: "gallery-server", qos: .utility, attributes: .concurrent)
    let thumbCache = NSCache<NSString, NSData>()
    public private(set) var port: UInt16 = 0

    public init(store: LibraryStore, token: String, rename: @escaping (Int64, String) throws -> Void) {
        self.store = store
        self.token = token
        self.rename = rename
        thumbCache.totalCostLimit = 200 << 20
    }

    public func start(port: UInt16 = 8642) throws {
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        l.service = NWListener.Service(name: "SuZu Media Utils on \(Host.current().localizedName ?? "Mac")", type: "_http._tcp")
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: queue)
        listener = l
        self.port = port
    }

    public func stop() { listener?.cancel(); listener = nil }

    public var url: String { "http://\(ProcessInfo.processInfo.hostName):\(port)/\(token)/" }

    // MARK: HTTP

    struct Request { var method: String; var path: String; var query: [String: String]; var headers: [String: String]; var body: Data }

    func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self, error == nil else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.respond(c, req)
            } else if done || buf.count > 1 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            if let i = line.firstIndex(of: ":") { headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        let body = data[end.upperBound...]
        if let len = headers["content-length"].flatMap(Int.init), body.count < len { return nil }
        let comps = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value }
        return Request(method: String(parts[0]), path: comps?.percentEncodedPath.removingPercentEncoding ?? "/", query: query, headers: headers, body: Data(body))
    }

    func send(_ c: NWConnection, status: String = "200 OK", type: String, body: Data, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: private, max-age=300\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    func respond(_ c: NWConnection, _ r: Request) {
        let parts = r.path.split(separator: "/").map(String.init)
        guard parts.first == token else { send(c, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8)); return }
        let route = Array(parts.dropFirst())
        let data = GalleryData(store: store)
        do {
            switch (r.method, route.first, route.count) {
            case ("GET", nil, _):
                let cards = try data.people().map {
                    GalleryHTML.PersonCard(name: $0.name, photos: $0.photos, videos: $0.videos, cover: "face/\($0.cover ?? 0).jpg", link: "person/\($0.id)")
                }
                send(c, type: "text/html; charset=utf-8", body: Data(GalleryHTML.people("SuZu Media", cards).utf8))
            case ("GET", "person", 2):
                guard let pid = Int64(route[1]), let p = try data.people([pid]).first else { throw CocoaError(.fileNoSuchFile) }
                let files = try data.files(personId: pid, topN: r.query["all"] == nil ? 300 : nil, bestOfBurst: true)
                let tiles = files.map { f in
                    GalleryHTML.Tile(thumb: "../thumb/\(f.mediaId)?t=\(f.time ?? 0)", view: f.isVideo ? "../file/\(f.mediaId)" : "../view/\(f.mediaId)",
                                     download: "../file/\(f.mediaId)?dl=1", isVideo: f.isVideo, caption: (f.path as NSString).lastPathComponent)
                }
                send(c, type: "text/html; charset=utf-8", body: Data(GalleryHTML.person(p.name, back: "../", tiles: tiles, renameAction: "\(pid)/name").utf8))
            case ("POST", "person", 3) where route[2] == "name":
                let form = String(decoding: r.body, as: UTF8.self).replacingOccurrences(of: "+", with: " ")
                let name = form.split(separator: "&").first { $0.hasPrefix("name=") }.map { String($0.dropFirst(5)).removingPercentEncoding ?? "" } ?? ""
                if let pid = Int64(route[1]), !name.trimmingCharacters(in: .whitespaces).isEmpty { try rename(pid, name) }
                send(c, status: "303 See Other", type: "text/plain", body: Data(), extra: ["Location": "/\(token)/"])
            case ("GET", "face", 2):
                let id = Int64(route[1].replacingOccurrences(of: ".jpg", with: "")) ?? 0
                send(c, type: "image/jpeg", body: (try? Data(contentsOf: store.faceCropURL(id))) ?? Data())
            case ("GET", "thumb", 2):
                send(c, type: "image/jpeg", body: try image(Int64(route[1]) ?? 0, side: 480, time: r.query["t"].flatMap(Double.init)))
            case ("GET", "view", 2):
                send(c, type: "image/jpeg", body: try image(Int64(route[1]) ?? 0, side: 2048, time: nil))
            case ("GET", "file", 2):
                try sendFile(c, mediaId: Int64(route[1]) ?? 0, request: r)
            default:
                send(c, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            }
        } catch {
            send(c, status: "500 Internal Server Error", type: "text/plain", body: Data(error.localizedDescription.utf8))
        }
    }

    func mediaPath(_ id: Int64) throws -> (String, Bool) {
        guard let r = try store.db.read({ db in try Row.fetchOne(db, sql: "SELECT path, kind FROM media WHERE id = ?", arguments: [id]) })
        else { throw CocoaError(.fileNoSuchFile) }
        return (r["path"], (r["kind"] as String) == "video")
    }

    func image(_ id: Int64, side: Int, time: Double?) throws -> Data {
        let key = "\(id)-\(side)" as NSString
        if let d = thumbCache.object(forKey: key) { return d as Data }
        let (path, isVideo) = try mediaPath(id)
        let url = URL(fileURLWithPath: path)
        var cg: CGImage?
        if isVideo { cg = VideoSampler.frameSync(url, at: time ?? 0, maxPixel: side) }
        else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) { cg = ImageLoader.decode(src, maxPixel: side) }
        guard let cg else { throw CocoaError(.fileReadCorruptFile) }
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dst)
        thumbCache.setObject(out, forKey: key, cost: out.length)
        return out as Data
    }

    /// Originals, with byte ranges so videos stream and seek in the browser.
    func sendFile(_ c: NWConnection, mediaId: Int64, request r: Request) throws {
        let (path, isVideo) = try mediaPath(mediaId)
        let url = URL(fileURLWithPath: path)
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let type = isVideo ? (url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4") : "image/jpeg"
        var extra = ["Accept-Ranges": "bytes"]
        if r.query["dl"] != nil { extra["Content-Disposition"] = "attachment; filename=\"\(url.lastPathComponent)\"" }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        if let range = r.headers["range"], range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds.first ?? "") ?? 0
            let end = min(size - 1, Int(bounds.count > 1 ? bounds[1] : "") ?? (start + (8 << 20) - 1))
            try h.seek(toOffset: UInt64(start))
            let body = try h.read(upToCount: end - start + 1) ?? Data()
            extra["Content-Range"] = "bytes \(start)-\(start + body.count - 1)/\(size)"
            send(c, status: "206 Partial Content", type: type, body: body, extra: extra)
        } else {
            // Whole file: stream it in chunks instead of loading a multi-GB video into memory.
            var head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(size)\r\nConnection: close\r\n"
            for (k, v) in extra { head += "\(k): \(v)\r\n" }
            let reader = try FileHandle(forReadingFrom: url)
            func pump() {
                let chunk = (try? reader.read(upToCount: 4 << 20)) ?? Data()
                if chunk.isEmpty {
                    try? reader.close()
                    c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                    return
                }
                c.send(content: chunk, completion: .contentProcessed { error in
                    if error == nil { pump() } else { try? reader.close(); c.cancel() }
                })
            }
            c.send(content: Data((head + "\r\n").utf8), completion: .contentProcessed { _ in pump() })
        }
    }
}
