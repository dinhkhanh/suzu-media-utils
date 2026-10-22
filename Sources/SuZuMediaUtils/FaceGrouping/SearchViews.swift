import FaceLibrary
import GRDB
import MediaKit
import SwiftUI
import UserNotifications

/// Search with filters; a saved search is a smart album that updates itself as files arrive.
struct SearchView: View {
    @EnvironmentObject var model: FaceGroupingModel
    let albumId: Int64?
    @State private var query = MediaQuery()
    @State private var hits: [MediaHit] = []
    @State private var useDates = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var to = Date()
    @State private var saving = false
    @State private var albumName = ""
    @State private var exporting = false
    @State private var shown = 600
    @State private var generation = 0

    var album: SmartAlbum? { albumId.flatMap { id in model.albums.first { $0.id == id } } }
    var named: [PersonSummary] { model.people.filter { $0.name != nil } }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            ScrollView {
                if hits.isEmpty {
                    ContentUnavailableView("No matching files", systemImage: "magnifyingglass").padding(.top, 60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                    ForEach(hits.prefix(shown)) { h in
                        MediaThumbnail(item: PersonMedia(id: h.id, path: h.path, kind: h.kind, faceId: h.faceId ?? 0, time: h.time,
                                                         score: h.score, takenAt: h.takenAt, burstId: h.burstId), side: 170)
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: h.path, isDirectory: false)) }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: h.path, isDirectory: false)) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.path, isDirectory: false)]) }
                            }
                    }
                }
                .padding(16)
                if hits.count > shown {
                    Button("Show \(min(600, hits.count - shown)) More") { shown += 600 }.padding(.bottom, 20)
                }
            }
        }
        .navigationTitle(album?.name ?? "Search")
        .navigationSubtitle("\(hits.count) files")
        .toolbar {
            ToolbarItem {
                Button(album == nil ? "Save as Smart Album…" : "Update Album") {
                    if let album { model.saveAlbum(id: album.id, name: album.name, query: currentQuery) } else { saving = true }
                }
            }
            ToolbarItem {
                Button { exporting = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }.disabled(hits.isEmpty)
            }
        }
        .alert("Save smart album", isPresented: $saving) {
            TextField("Name", text: $albumName)
            Button("Save") { model.saveAlbum(id: nil, name: albumName, query: currentQuery); albumName = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The album keeps updating as new files match.")
        }
        .sheet(isPresented: $exporting) {
            ExportSheet(scope: .media(hits.map(\.id), title: album?.name ?? "Search"), mode: .copy, initialName: album?.name ?? "Search results")
        }
        // Albums arrive with the first library read; load the album's filters whenever it (re)appears or changes.
        .onChange(of: album?.query, initial: true) { load() }
        // Re-run when the filters change (after typing pauses), and every 15 s for newly processed files.
        .task(id: currentQuery.hashValue) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            shown = 600
            search()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                search()
            }
        }
        .task { await benchFilters() }
    }

    /// SUZU_BENCH_SEARCH=1 (testing): flips through filter combinations like a user would; any value logs results.
    func benchFilters() async {
        guard ProcessInfo.processInfo.environment["SUZU_BENCH_SEARCH"] == "1" else { return }
        try? await Task.sleep(for: .seconds(4))
        let named = named.map(\.id)
        for step in 0..<24 where !Task.isCancelled {
            switch step % 6 {
            case 0: query.kind = .photo
            case 1: query.crowd = .group
            case 2: query.people = Array(named.prefix(1))
            case 3: query.kind = nil; query.crowd = .any
            case 4: query.people = []; query.kind = .video
            default: query = MediaQuery()
            }
            FileHandle.standardError.write(Data("BENCH step \(step) at \(Date().timeIntervalSince1970)\n".utf8))
            try? await Task.sleep(for: .seconds(1.5))
        }
        FileHandle.standardError.write(Data("BENCH done\n".utf8))
    }

    var currentQuery: MediaQuery {
        var q = query
        q.from = useDates ? Calendar.current.startOfDay(for: from) : nil
        q.to = useDates ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: to) : nil
        return q
    }

    func load() {
        guard let album else { return }
        query = album.mediaQuery
        useDates = query.from != nil
        if let f = query.from { from = f }
        if let t = query.to { to = t }
    }

    func search() {
        // An album's filters load with the album list; don't flash "everything" before that.
        guard let store = model.store, albumId == nil || album != nil else { return }
        let q = currentQuery
        generation += 1
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let r = (try? q.run(store)) ?? []
            await MainActor.run {
                // A slower earlier search must not overwrite the results of the latest filters.
                guard gen == generation else { return }
                if r != hits { hits = r }
                if ProcessInfo.processInfo.environment["SUZU_BENCH_SEARCH"] != nil {
                    FileHandle.standardError.write(Data("BENCH hits \(r.count) at \(Date().timeIntervalSince1970)\n".utf8))
                }
            }
        }
    }

    var filters: some View {
        FlowLayout(spacing: 10, lineSpacing: 8) {
            Menu("Add Person") {
                ForEach(named.filter { !query.people.contains($0.id) }) { p in Button(p.displayName) { query.people.append(p.id) } }
            }
            .fixedSize()
            ForEach(query.people, id: \.self) { id in
                Button { query.people.removeAll { $0 == id } } label: {
                    Label(model.people.first { $0.id == id }?.displayName ?? "?", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
            }
            if query.people.count > 1 {
                Picker("", selection: $query.match) {
                    Text("All of them together").tag(MediaQuery.PeopleMatch.all)
                    Text("Any of them").tag(MediaQuery.PeopleMatch.any)
                }
                .fixedSize()
            }
            Picker("", selection: $query.kind) {
                Text("Photos & videos").tag(MediaKind?.none)
                Text("Photos").tag(MediaKind?.some(.photo))
                Text("Videos").tag(MediaKind?.some(.video))
            }
            .fixedSize()
            Picker("", selection: $query.crowd) {
                Text("Any number of people").tag(MediaQuery.Crowd.any)
                Text("Solo shots").tag(MediaQuery.Crowd.solo)
                Text("Group shots").tag(MediaQuery.Crowd.group)
            }
            .fixedSize()
            Picker("", selection: $query.sourceId) {
                Text("All folders").tag(Int64?.none)
                ForEach(model.sources.filter { $0.kind == .media }) { Text($0.name).tag(Int64?.some($0.id)) }
            }
            .fixedSize()
            HStack(spacing: 6) {
                Toggle("Dates", isOn: $useDates).toggleStyle(.checkbox)
                if useDates {
                    DatePicker("", selection: $from, displayedComponents: .date).labelsHidden().fixedSize()
                    Text("–")
                    DatePicker("", selection: $to, displayedComponents: .date).labelsHidden().fixedSize()
                }
            }
            Toggle("Best shots only", isOn: $query.bestOnly).toggleStyle(.checkbox).fixedSize()
            Toggle("Hide similar shots", isOn: $query.collapseBursts).toggleStyle(.checkbox).fixedSize()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Delivery rules: copy new photos of people to folders (Drive, Dropbox, NAS…) and/or notify.
struct DeliveryRulesView: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var adding = false

    var body: some View {
        List {
            if model.rules.isEmpty {
                ContentUnavailableView("No delivery rules", systemImage: "paperplane",
                                       description: Text("Send new photos of a person to a folder — a Google Drive or Dropbox folder, a NAS share — and get notified, automatically as they arrive."))
            }
            ForEach(model.rules) { rule in
                HStack {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.setRule(rule, enabled: $0) })).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.personId.flatMap { id in model.people.first { $0.id == id }?.displayName } ?? "Everyone with a name")
                            .font(.headline)
                        Text(describe(rule)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { model.deleteRule(rule) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("Delivery Rules")
        .navigationSubtitle("Runs when new files are processed; never slows recognition")
        .toolbar { ToolbarItem { Button { adding = true } label: { Label("New Rule…", systemImage: "plus") } } }
        .sheet(isPresented: $adding) { NewRuleSheet() }
    }

    func describe(_ r: DeliveryRule) -> String {
        var parts: [String] = []
        if let f = r.folder { parts.append("Copy to \(f)/<Name>/") } else { parts.append("Notify only") }
        if let e = r.editRecipe {
            var edits: [String] = []
            if e.autoTone { edits.append("auto tone") }
            if let a = e.aspect { edits.append(a.rawValue + " crop") }
            if e.watermark != nil { edits.append("logo") }
            if let l = e.maxLongSide { edits.append("\(l) px") }
            if !edits.isEmpty { parts.append(edits.joined(separator: ", ")) }
        }
        if r.folder != nil && r.writeNames { parts.append("names in metadata") }
        parts.append("notification")
        return parts.joined(separator: " · ")
    }
}

struct NewRuleSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    var presetPerson: Int64?
    var notifyOnly = false
    @State private var personId: Int64?
    @State private var copy = true
    @State private var folder: URL?
    @State private var edit = false
    @State private var recipe = EditRecipe()
    @State private var writeNames = true
    @State private var includeExisting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Delivery Rule").font(.title2.bold())
            Picker("When new photos of", selection: $personId) {
                Text("anyone with a name").tag(Int64?.none)
                ForEach(model.people.filter { $0.name != nil }) { Text($0.displayName).tag(Int64?.some($0.id)) }
            }
            Toggle("Copy them into a folder per person", isOn: $copy)
            if copy {
                HStack {
                    Text(folder?.path ?? "No folder chosen").foregroundStyle(folder == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                .padding(.leading, 20)
                Text("Tip: choose a folder inside Google Drive or Dropbox to share automatically.").font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                Toggle("Write names into the files", isOn: $writeNames).padding(.leading, 20)
                Toggle("Edit photos (auto tone, crop, watermark, resize)", isOn: $edit).padding(.leading, 20)
                if edit { EditOptionsView(recipe: $recipe, previewSource: nil, previewFocus: nil).padding(.leading, 40) }
            }
            Toggle("Also handle files already in the library", isOn: $includeExisting)
            Text("You'll get a notification on this Mac each time new files arrive.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Rule") {
                    model.addRule(DeliveryRule(personId: personId, folder: copy ? folder?.path : nil, recipe: copy && edit ? recipe : nil,
                                               writeNames: writeNames), includeExisting: includeExisting)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(copy && folder == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { personId = presetPerson; copy = !notifyOnly }
    }

    func chooseFolder() {
        Panels.chooseFolder { folder = $0 }
    }
}

enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// "New photos: Mỹ Tâm 12 · Trấn Thành 5", plus how many were copied.
    static func post(_ report: DeliveryService.Report) {
        guard available, !report.newFiles.isEmpty else { return }
        let content = UNMutableNotificationContent()
        let total = report.newFiles.values.reduce(0, +)
        content.title = total == 1 ? "1 new photo" : "\(total) new photos"
        content.body = report.newFiles.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            + (report.copied > 0 ? "\n\(report.copied) delivered to folders" : "")
            + (report.failed.isEmpty ? "" : "\n\(report.failed.count) could not be copied")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
