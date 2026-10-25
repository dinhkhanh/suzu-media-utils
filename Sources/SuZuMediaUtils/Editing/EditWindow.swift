import FaceLibrary
import GRDB
import MediaKit
import SwiftUI

/// Photos opened from the library (right-click → Open in People, faces, search, albums): edited and exported in a
/// window of their own, the Edit & Export screen with just them.
struct EditRequest: Codable, Hashable {
    var paths: [String]
    /// The face to keep in frame first, per photo: the person or face it was opened from.
    var faces: [String: Int64] = [:]
}

struct EditWindow: View {
    @EnvironmentObject var model: FaceGroupingModel
    let request: EditRequest?
    @State private var items: [ToolItem]?

    var body: some View {
        Group {
            if let items {
                BatchExportTool(initial: items, title: items.count == 1 ? items[0].url.lastPathComponent : "\(items.count) Photos")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .task(id: request) { if let request { items = await model.toolItems(request) } }
    }
}

extension OpenWindowAction {
    /// Opens photos for editing and export; videos open in their own app.
    func edit(_ paths: [String], faces: [String: Int64] = [:]) {
        let photos = paths.filter { MediaTypes.photos.contains(($0 as NSString).pathExtension.lowercased()) }
        for v in paths where !photos.contains(v) { NSWorkspace.shared.open(URL(fileURLWithPath: v, isDirectory: false)) }
        if !photos.isEmpty { self(id: "edit", value: EditRequest(paths: photos, faces: faces)) }
    }
}

extension FaceGroupingModel {
    /// The photos of an edit request with what the library knows: everyone's face (so crops keep them all in frame,
    /// the opened face first, else the biggest), the names in it and when it was taken.
    func toolItems(_ request: EditRequest) async -> [ToolItem] {
        let plain = request.paths.map { ToolItem(url: URL(fileURLWithPath: $0, isDirectory: false)) }
        guard let store else { return plain }
        return await Task.detached(priority: .userInitiated) {
            (try? store.db.read { db -> [ToolItem] in
                let rows = try Row.fetchAll(db, sql: "SELECT id, path, takenAt FROM media WHERE path IN (\(databaseQuestionMarks(count: request.paths.count)))",
                                            arguments: StatementArguments(request.paths))
                let byPath = Dictionary(rows.map { ($0["path"] as String, $0) }, uniquingKeysWith: { a, _ in a })
                let ids = rows.map { $0["id"] as Int64 }
                let boxes = try Selection.faceBoxes(db, mediaIds: ids)
                // A camera's RAW+JPEG pair opens as its RAW, which holds the most (the library works on the JPEG).
                let raws = try Selection.rawPartners(db, mediaIds: ids)
                var names: [Int64: Set<String>] = [:]
                if !ids.isEmpty {
                    for r in try Row.fetchAll(db, sql: """
                        SELECT f.mediaId, p.name FROM face f JOIN person p ON p.id = f.personId
                        WHERE p.name IS NOT NULL AND f.mediaId IN (\(ids.map(String.init).joined(separator: ",")))
                        """) { names[r["mediaId"], default: []].insert(r["name"]) }
                }
                return zip(request.paths, plain).map { path, item in
                    guard let row = byPath[path] else { return item }
                    let id: Int64 = row["id"]
                    let faces = boxes[id] ?? []
                    let main = request.faces[path].flatMap { f in faces.first { $0.id == f } }
                        ?? faces.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
                    return ToolItem(url: raws[id] ?? item.url, people: (names[id] ?? []).sorted(), takenAt: (row["takenAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                                    focus: main.map { Selection.focus(face: $0.id, box: $0.box, in: faces) })
                }
            }) ?? plain
        }.value
    }
}
