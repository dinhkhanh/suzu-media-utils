import FaceLibrary
import GRDB
import MediaKit
import SwiftUI

/// Pattern renaming with a live preview. People come from Face Grouping; renamed library files keep their faces and
/// names (the library is updated, nothing is re-scanned).
struct BatchRenameTool: View {
    @EnvironmentObject var faces: FaceGroupingModel
    @State private var input: [ToolItem] = []
    @State private var pattern = RenamePattern(pattern: "{event}_{date}_{person}_{seq:3}", event: "")
    @State private var order = 0  // 0 capture time, 1 name
    @State private var items: [RenamePattern.Item] = []
    @State private var names: [String] = []
    @State private var loading = false
    @State private var result: String?
    @State private var renaming = false

    var body: some View {
        Form {
            Section("Files") { ToolInputView(items: $input, kinds: MediaTypes.photos.union(MediaTypes.videos), mediaKind: nil) }
            Section("Pattern") {
                TextField("Pattern", text: $pattern.pattern).font(.body.monospaced())
                Text("{event} {date} {time} {person} {people} {folder} {name} {seq} {seq:3}").font(.caption.monospaced()).foregroundStyle(.secondary)
                TextField("Event", text: $pattern.event, prompt: Text("e.g. SOLINA-CUP"))
                Stepper("Start numbering at \(pattern.start)", value: $pattern.start, in: 0...99999)
                Picker("Order", selection: $order) { Text("Capture time").tag(0); Text("File name").tag(1) }.fixedSize()
            }
            Section("Preview") {
                if loading { HStack { ProgressView().controlSize(.small); Text("Reading dates and people…").foregroundStyle(.secondary) } }
                else if items.isEmpty { Text("Add files or people to see the new names.").foregroundStyle(.secondary) }
                ForEach(Array(zip(items.prefix(150), names.prefix(150))), id: \.0.url) { item, name in
                    HStack {
                        Text(item.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(name).lineLimit(1)
                    }
                    .font(.callout)
                }
                if items.count > 150 { Text("…and \(items.count - 150) more").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                HStack {
                    if let result { Text(result).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Rename \(items.count) Files") { apply() }.keyboardShortcut(.defaultAction).disabled(items.isEmpty || loading || renaming || names.count != items.count)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Batch Rename")
        .task(id: "\(input.count)|\(input.first?.url.path ?? "")|\(order)") { await load() }
        .task(id: "\(pattern.pattern)|\(pattern.event)|\(pattern.start)|\(items.count)|\(items.first?.url.path ?? "")") { await computeNames() }
    }

    /// Dates and people, once per input change, off the main thread. Library files use the database (no file reads).
    func load() async {
        let input = input, order = order, store = faces.store
        loading = true
        let list = await Task.detached(priority: .userInitiated) { () -> [RenamePattern.Item] in
            var seen: Set<URL> = []
            let unique = input.filter { seen.insert($0.url).inserted }  // a group photo appears once per person
            let fromFiles = unique.filter { $0.personName == nil }.map(\.url)
            let people = Self.people(for: fromFiles, store: store)
            var out = unique.map { item -> RenamePattern.Item in
                if item.personName != nil {
                    return RenamePattern.Item(url: item.url, date: item.takenAt, people: [item.personName!] + item.people.filter { $0 != item.personName })
                }
                let date = RenamePattern.captureDate(item.url)
                    ?? (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                return RenamePattern.Item(url: item.url, date: date, people: people[item.url.path] ?? [])
            }
            if order == 0 { out.sort { ($0.date ?? .distantFuture, $0.url.path) < ($1.date ?? .distantFuture, $1.url.path) } }
            return out
        }.value
        items = list
        loading = false
    }

    /// New names, recomputed after typing pauses.
    func computeNames() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let pattern = pattern, items = items
        names = await Task.detached(priority: .userInitiated) { pattern.names(for: items) }.value
    }

    /// Named people per file, for files that are in the Face Grouping library.
    nonisolated static func people(for files: [URL], store: LibraryStore?) -> [String: [String]] {
        guard let store, !files.isEmpty else { return [:] }
        let paths = files.map { canonicalPath($0) }
        var byPath: [String: [String]] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 500).map({ Array(paths[$0..<min($0 + 500, paths.count)]) }) {
            let rows = (try? store.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.path, p.name, MAX(f.w * f.h) AS a FROM media m JOIN face f ON f.mediaId = m.id JOIN person p ON p.id = f.personId
                    WHERE p.name IS NOT NULL AND m.path IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    GROUP BY m.path, p.id ORDER BY a DESC
                    """, arguments: StatementArguments(chunk))
            }) ?? []
            for r in rows { byPath[r["path"], default: []].append(r["name"]) }
        }
        var out: [String: [String]] = [:]
        for (orig, canon) in zip(files, paths) { out[orig.path] = byPath[canon] ?? [] }
        return out
    }

    func apply() {
        let items = items, names = names, service = faces.service
        renaming = true
        result = nil
        // Off the main thread, and off Swift's task threads: it waits for the folder watchers to finish what they're
        // doing before files change names.
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try service?.renameFiles(items, names: names) ?? RenamePattern.apply(items, names: names) }
            DispatchQueue.main.async {
                renaming = false
                switch outcome {
                case .success(let o):
                    result = "Renamed \(o.renamed.count) of \(items.count) files."
                        + (o.failed.isEmpty ? "" : " \(o.failed.count) kept their names: \(o.failed[0].0.lastPathComponent): \(o.failed[0].1)")
                    let renamed = Dictionary(o.renamed.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
                    input = input.map { var i = $0; i.url = renamed[i.url] ?? i.url; return i }
                case .failure(let error):
                    result = "Stopped: \(error.localizedDescription)"
                }
            }
        }
    }
}
