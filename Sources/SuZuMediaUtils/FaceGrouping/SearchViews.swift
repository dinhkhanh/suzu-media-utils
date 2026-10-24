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
    /// Files selected in the grid (⌘-click for several), for Open.
    @State private var selected: Set<Int64> = []
    @Environment(\.openWindow) private var openWindow

    var album: SmartAlbum? { albumId.flatMap { id in model.albums.first { $0.id == id } } }
    var named: [PersonSummary] { model.people.filter { $0.name != nil } }

    var body: some View {
        VStack(spacing: 0) {
            // A search follows the session picked for the event; an album has its own dates.
            if album == nil { SessionBar(divider: true) }
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
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected.contains(h.id) ? Color.accent : .clear, lineWidth: 3))
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: h.path, isDirectory: false)) }
                            .onTapGesture { selected.click(h.id, in: hits.map(\.id)) }
                            .contextMenu {
                                // The selection when this file is in it, else just this file.
                                let open = selected.contains(h.id) ? hits.filter { selected.contains($0.id) } : [h]
                                let urls = open.map { URL(fileURLWithPath: $0.path, isDirectory: false) }
                                Button(open.count > 1 ? "Open \(open.count) Files" : "Open") {
                                    openWindow.edit(open.map(\.path), faces: Dictionary(open.compactMap { h in h.faceId.map { (h.path, $0) } }, uniquingKeysWith: { a, _ in a }))
                                }
                                Button("Open With Default App") { urls.forEach { NSWorkspace.shared.open($0) } }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                                Button("Copy File Path") { Clipboard.copyPaths(urls) }
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
        // An album searches its own project; otherwise the open one.
        q.project = album?.projectId ?? model.currentProject
        q.from = useDates ? Calendar.current.startOfDay(for: from) : nil
        q.to = useDates ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: to) : nil
        // A session picked for the event narrows it to that stretch of time.
        if album == nil, let r = model.sessionRange {
            q.from = Date(timeIntervalSince1970: r.lowerBound)
            q.to = Date(timeIntervalSince1970: r.upperBound)
        }
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
                ForEach(model.projectSources) { Text($0.name).tag(Int64?.some($0.id)) }
            }
            .fixedSize()
            if album == nil { SessionPicker() }
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
            Toggle("Hide blurry shots", isOn: $query.skipBlurry).toggleStyle(.checkbox).fixedSize()
                .help("Photos whose main face is out of focus or moved")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Auto rules: when new files match a smart-album-style query, copy them — edited or not — into a folder, and
/// notify. In a project shared with a team, rules run on every Mac.
struct RulesView: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var adding = false
    @State private var editing: DeliveryRule?

    /// Rules of the open project and rules for every project.
    var rules: [DeliveryRule] { model.rules.filter { model.currentProject == nil || $0.projectId == nil || $0.projectId == model.currentProject } }

    var body: some View {
        List {
            if let team = model.currentTeam {
                Label("Shared with team \(team.name): every Mac runs these rules on the files it processes.", systemImage: "person.3")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if rules.isEmpty {
                ContentUnavailableView("No rules yet", systemImage: "wand.and.stars",
                                       description: Text("As new photos arrive and are recognised, a rule copies the ones that match — best solo shots, everything of one person, group shots — into a folder (NAS, Google Drive, Dropbox…), edited the way you want, and tells you."))
            }
            ForEach(rules) { rule in
                HStack {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.setRule(rule, enabled: $0) })).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.displayName { id in model.knownPeople.first { $0.id == id }?.displayName }).font(.headline)
                        Text(describe(rule)).font(.caption).foregroundStyle(.secondary)
                        if let f = rule.folder, !FileManager.default.fileExists(atPath: f) {
                            Label("Folder not reachable on this Mac — files wait until it is", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button { editing = rule } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit Rule")
                    Button(role: .destructive) { model.deleteRule(rule) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .contextMenu {
                    Button("Edit Rule…") { editing = rule }
                    if let f = rule.folder { Button("Show Folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: f) } }
                    Divider()
                    Button("Delete Rule", role: .destructive) { model.deleteRule(rule) }
                }
            }
        }
        .navigationTitle("Auto Rules")
        .navigationSubtitle("Runs when new files are processed; never slows recognition")
        .toolbar { ToolbarItem { Button { adding = true } label: { Label("New Rule…", systemImage: "plus") } } }
        .sheet(isPresented: $adding) { RuleSheet() }
        .sheet(item: $editing) { RuleSheet(rule: $0) }
    }

    func describe(_ r: DeliveryRule) -> String {
        var parts: [String] = [r.projectId.flatMap { id in model.projects.first { $0.id == id }?.name } ?? "All projects"]
        if let f = r.folder {
            let short = (f as NSString).abbreviatingWithTildeInPath
            parts.append(r.layout == .person ? "Copy to \(short)/<Name>/" : "Copy to \(short)/")
        } else { parts.append("Notify only") }
        if let e = r.editRecipe {
            var edits: [String] = []
            if e.straighten == true { edits.append("level") }
            if e.autoTone { edits.append("auto tone") }
            if let c = e.cropDescription { edits.append(c) }
            if e.watermark != nil { edits.append("watermark") }
            if let l = e.maxLongSide { edits.append("\(l) px") }
            if !edits.isEmpty { parts.append(edits.joined(separator: ", ")) }
        }
        if r.folder != nil && r.writeNames { parts.append("names in metadata") }
        let q = r.mediaQuery
        if q.collapseBursts { parts.append("best of each burst") }
        if q.skipBlurry { parts.append("no blurry shots") }
        parts.append("notification")
        return parts.joined(separator: " · ")
    }
}

/// New or existing rule: what to match (like a smart album), where copies go, how they are edited.
struct RuleSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    /// Editing this rule (nil = a new one).
    var rule: DeliveryRule?
    var presetPerson: Int64?
    var notifyOnly = false
    @State private var name = ""
    @State private var query = MediaQuery()
    @State private var copy = true
    @State private var folder: URL?
    @State private var layout = DeliveryRule.Layout.person
    @State private var edit = false
    @State private var recipe = EditRecipe()
    @State private var writeNames = true
    @State private var includeExisting = false
    @State private var allProjects = false
    @State private var samples: [ToolItem] = []

    var named: [PersonSummary] { model.knownPeople }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rule == nil ? "New Auto Rule" : "Edit Auto Rule").font(.title2.bold())
            TextField("Name (optional)", text: $name, prompt: Text("e.g. Best solo shots to NAS")).textFieldStyle(.roundedBorder)
            Text("When new files match").font(.headline)
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Menu(query.people.isEmpty ? "Anyone" : "Add Person") {
                    ForEach(named.filter { !query.people.contains($0.id) }) { p in Button(p.displayName) { query.people.append(p.id) } }
                }
                .fixedSize()
                ForEach(query.people, id: \.self) { id in
                    Button { query.people.removeAll { $0 == id } } label: {
                        Label(named.first { $0.id == id }?.displayName ?? "?", systemImage: "xmark.circle.fill")
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
                Toggle("Best shots only", isOn: $query.bestOnly).toggleStyle(.checkbox).fixedSize()
                Toggle("Skip similar shots", isOn: $query.collapseBursts).toggleStyle(.checkbox).fixedSize()
                    .help("Of shots taken within a couple of seconds that look the same, only the best is handled; the rule waits until new photos' bursts are known")
                Toggle("Skip blurry shots", isOn: $query.skipBlurry).toggleStyle(.checkbox).fixedSize()
                    .help("Photos whose main face is out of focus or moved are not handled")
            }
            Picker("In", selection: $allProjects) {
                Text(model.currentProject == nil ? "Any project" : "This project (\(model.projectName))").tag(false)
                Text("Any project, now and later").tag(true)
            }
            .disabled(model.currentProject == nil || model.currentTeam != nil)
            Text("Then").font(.headline)
            Toggle("Copy them into a folder", isOn: $copy)
            if copy {
                HStack {
                    Text(folder?.path ?? "No folder chosen").foregroundStyle(folder == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { Panels.chooseFolder { folder = $0 } }
                }
                .padding(.leading, 20)
                Picker("", selection: $layout) {
                    Text("A folder per person (<folder>/<Name>/)").tag(DeliveryRule.Layout.person)
                    Text("Straight into the folder").tag(DeliveryRule.Layout.flat)
                }
                .pickerStyle(.radioGroup).padding(.leading, 20)
                Text("Tip: a folder on the NAS, or inside Google Drive or Dropbox, to share automatically.").font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                Toggle("Write names into the files", isOn: $writeNames).padding(.leading, 20)
                Toggle("Edit photos (level, auto tone, crop, watermark, resize)", isOn: $edit).padding(.leading, 20)
                if edit { EditOptionsView(recipe: $recipe, samples: samples, remember: "deliveryRule") }
            }
            if rule == nil { Toggle("Also handle files already in the library", isOn: $includeExisting) }
            Text(model.currentTeam == nil ? "You'll get a notification on this Mac each time new files arrive."
                 : "Shared with team \(model.currentTeam!.name): every Mac runs it on the files it processes, each with its own notification.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(rule == nil ? "Add Rule" : "Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(copy && folder == nil)
            }
        }
        .padding(20)
        .frame(width: copy && edit ? 960 : 620)
        .onAppear(perform: load)
        .task(id: query.people.first) { samples = await model.samples(personId: query.people.first) }
    }

    func load() {
        if let rule {
            name = rule.name ?? ""
            query = rule.mediaQuery
            copy = rule.folder != nil
            folder = rule.folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            layout = rule.layout
            edit = rule.editRecipe != nil
            recipe = rule.editRecipe ?? EditRecipe()
            writeNames = rule.writeNames
            allProjects = rule.projectId == nil
        } else {
            if let presetPerson { query.people = [presetPerson]; query.match = .any }
            copy = !notifyOnly
        }
    }

    func save() {
        let projectId = allProjects ? nil : model.currentProject
        if var r = rule {
            r.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
            r.projectId = projectId
            r.setQuery(query)
            r.folder = copy ? folder?.path : nil
            r.layout = layout
            r.setRecipe(copy && edit ? recipe : nil)
            r.writeNames = writeNames
            model.updateRule(r)
        } else {
            model.addRule(DeliveryRule(name: name, query: query, folder: copy ? folder?.path : nil, layout: layout,
                                       recipe: copy && edit ? recipe : nil, writeNames: writeNames, projectId: projectId),
                          includeExisting: includeExisting)
        }
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
            + (report.failed.isEmpty ? "" : "\n\(report.failed.count) could not be copied yet (will retry)")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
