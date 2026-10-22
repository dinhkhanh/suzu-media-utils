import FaceLibrary
import GRDB
import MediaKit
import SwiftUI

/// Pattern renaming with a live preview. People come from the Face Grouping library; renamed library files keep
/// their faces and names (the library is updated, nothing is re-scanned).
struct BatchRenameTool: View {
    @EnvironmentObject var faces: FaceGroupingModel
    @State private var files: [URL] = []
    @State private var pattern = RenamePattern(pattern: "{event}_{date}_{person}_{seq:3}", event: "")
    @State private var order = 0  // 0 capture time, 1 name
    @State private var items: [RenamePattern.Item] = []
    @State private var result: String?

    var names: [String] { pattern.names(for: items) }

    var body: some View {
        Form {
            Section("Files") { FileInputList(files: $files, kinds: MediaTypes.photos.union(MediaTypes.videos)) }
            Section("Pattern") {
                TextField("Pattern", text: $pattern.pattern).font(.body.monospaced())
                Text("{event} {date} {time} {person} {people} {folder} {name} {seq} {seq:3}").font(.caption.monospaced()).foregroundStyle(.secondary)
                TextField("Event", text: $pattern.event, prompt: Text("e.g. SOLINA-CUP"))
                Stepper("Start numbering at \(pattern.start)", value: $pattern.start, in: 0...99999)
                Picker("Order", selection: $order) { Text("Capture time").tag(0); Text("File name").tag(1) }.fixedSize()
            }
            Section("Preview") {
                if items.isEmpty { Text("Add files to see the new names.").foregroundStyle(.secondary) }
                ForEach(Array(zip(items.prefix(200), names.prefix(200))), id: \.0.url) { item, name in
                    HStack {
                        Text(item.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(name).lineLimit(1)
                    }
                    .font(.callout)
                }
            }
            Section {
                HStack {
                    if let result { Text(result).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Rename \(items.count) Files") { apply() }.keyboardShortcut(.defaultAction).disabled(items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Batch Rename")
        .task(id: "\(files.count)|\(order)|\(files.first?.path ?? "")") { await load() }
    }

    func load() async {
        let files = files, order = order, store = faces.store
        items = await Task.detached(priority: .utility) {
            let people = Self.people(for: files, store: store)
            var list = files.map { RenamePattern.Item(url: $0, date: RenamePattern.captureDate($0), people: people[$0.path] ?? []) }
            if order == 0 { list.sort { ($0.date ?? .distantFuture, $0.url.path) < ($1.date ?? .distantFuture, $1.url.path) } }
            return list
        }.value
    }

    /// Named people per file, for files that are in the Face Grouping library.
    nonisolated static func people(for files: [URL], store: LibraryStore?) -> [String: [String]] {
        guard let store, !files.isEmpty else { return [:] }
        let paths = files.map { canonicalPath($0) }
        let rows = (try? store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.path, p.name, MAX(f.w * f.h) AS a FROM media m JOIN face f ON f.mediaId = m.id JOIN person p ON p.id = f.personId
                WHERE p.name IS NOT NULL AND m.path IN (\(paths.map { _ in "?" }.joined(separator: ",")))
                GROUP BY m.path, p.id ORDER BY a DESC
                """, arguments: StatementArguments(paths))
        }) ?? []
        var out: [String: [String]] = [:]
        for (orig, canon) in zip(files, paths) {
            out[orig.path] = rows.filter { ($0["path"] as String) == canon }.map { $0["name"] as String }
        }
        return out
    }

    func apply() {
        do {
            let done = try RenamePattern.apply(items, names: names)
            // Keep library files linked to their faces under the new names.
            if let store = faces.store {
                try store.db.write { db in
                    for (old, new) in done {
                        try db.execute(sql: "UPDATE media SET path = ? WHERE path = ?", arguments: [canonicalPath(new), canonicalPath(old)])
                    }
                }
            }
            result = "Renamed \(done.count) of \(items.count) files."
            files = files.map { f in done.first { $0.0 == f }?.1 ?? f }
        } catch {
            result = "Stopped: \(error.localizedDescription)"
        }
    }
}
