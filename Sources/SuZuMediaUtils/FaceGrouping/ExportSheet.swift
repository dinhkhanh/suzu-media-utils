import FaceLibrary
import MediaKit
import SwiftUI

enum ExportScope: Identifiable {
    case person(Int64)
    case all
    /// Search results or a smart album, exported into one folder.
    case media([Int64], title: String)
    /// The open project's sessions, each into a folder of its own.
    case sessions
    var id: String {
        switch self {
        case .person(let p): "p\(p)"
        case .all: "all"
        case .media(let ids, let t): "m\(t)\(ids.count)"
        case .sessions: "sessions"
        }
    }
}

/// Copy or move people's files into "<base>/<Name>/". Base is each file's own source folder unless the user picks one.
struct ExportSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    let scope: ExportScope
    let mode: ExportMode
    @State var name: String
    @State private var chosen: Set<Int64> = []
    @State private var chosenSessions: Set<Int> = []
    @State private var base: URL?
    @State private var policy = CollisionPolicy.skip
    @State private var editPhotos = false
    @State private var recipe = EditRecipe()
    @State private var writeNames = false
    @State private var topN: Int?
    @State private var bestOfBurst = false
    @State private var skipBlurry = false
    @State private var plan: Exporter.Plan?
    @State private var planning = false
    /// Ignore the session picked in the People view and export the whole event.
    @State private var wholeEvent = false
    /// Photos and videos: 0 together, 1 in two folders inside the person's folder, 2 in two folders picked here.
    @AppStorage("export.kindLayout") private var kindLayout = 0
    @AppStorage("export.photosFolder") private var photosChild = "Photos"
    @AppStorage("export.videosFolder") private var videosChild = "Videos"
    @State private var photosBase: URL?
    @State private var videosBase: URL?

    init(scope: ExportScope, mode: ExportMode, initialName: String = "") {
        self.scope = scope
        self.mode = mode
        _name = State(initialValue: initialName)
    }

    var isAll: Bool { if case .all = scope { true } else { false } }
    var isMedia: Bool { if case .media = scope { true } else { false } }
    var isSessions: Bool { if case .sessions = scope { true } else { false } }
    var verb: String { mode == .copy ? "Copy" : "Move" }
    var folder: String { Exporter.folderName(name) }
    var named: [PersonSummary] { model.people.filter { $0.name != nil && $0.faces > 0 } }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text(isAll ? "\(verb) everyone's files to their folders" : isSessions ? "\(verb) each session to its own folder"
                 : "\(verb) to “\(folder.isEmpty ? "…" : folder)” folder")
                .font(.title2.bold())
            if let s = model.currentSession, !isMedia, !isSessions {
                HStack {
                    Image(systemName: "timer")
                    Text(wholeEvent ? "The whole event" : "Only the “\(model.sessionTitle(s))” session (\(model.sessionTime(s)))")
                    Toggle("Whole event", isOn: $wholeEvent).toggleStyle(.checkbox).padding(.leading, 8)
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accent.opacity(0.1)))
            }
            form
        }
        .padding(20)
        }
        .frame(maxHeight: 860)
        .frame(width: editPhotos ? 960 : 620)
        .onAppear {
            chosen = Set(named.map(\.id))
            // The session picked in the bar, else all of them.
            chosenSessions = Set(model.currentSession.map { [$0.index] } ?? model.sessions.map(\.index))
        }
        .task(id: "\(name)|\(base?.path ?? "")|\(chosen.sorted())|\(chosenSessions.sorted())|\(editPhotos)|\(recipe.hashValue)|\(writeNames)|\(topN ?? 0)|\(bestOfBurst)|\(skipBlurry)|\(wholeEvent)|\(kindLayout)|\(photosChild)|\(videosChild)|\(photosBase?.path ?? "")|\(videosBase?.path ?? "")") { await replan() }
    }

    @ViewBuilder
    var form: some View {
        if isAll {
            peopleList
        } else if isSessions {
            sessionList
        } else {
            TextField(isMedia ? "Folder name" : "Person's name (folder name)", text: $name).textFieldStyle(.roundedBorder)
        }
        if kindLayout != 2 {
            VStack(alignment: .leading, spacing: 6) {
                Text(isAll ? "Put each person's folder:" : isSessions ? "Put each session's folder:" : "Put the “\(folder)” folder:").font(.headline)
                Picker("", selection: Binding(get: { base == nil ? 0 : 1 }, set: { if $0 == 0 { base = nil } else { choose() } })) {
                    Text(isSessions ? "Inside Pictures/SuZu Exports/\(folder.isEmpty ? "…" : folder)" : isMedia ? "Inside Pictures/SuZu Exports" : "Inside each file's source folder").tag(0)
                    Text(base.map { "Inside \($0.path)" } ?? "Inside another folder…").tag(1)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        kindsSection
        if let plan {
            // One example of each kind, so the two places can be checked before copying.
            ForEach([plan.items.first { !MediaTypes.videos.contains($0.from.pathExtension.lowercased()) },
                     plan.items.first { MediaTypes.videos.contains($0.from.pathExtension.lowercased()) }].compactMap { $0 }, id: \.to) { example in
                Text("e.g. \(example.to.path)").font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("If a file with the same name is already there:").font(.headline)
            Picker("", selection: $policy) {
                Text("Skip it (never overwrite)").tag(CollisionPolicy.skip)
                Text("Keep both (add “ (2)” to the new one)").tag(CollisionPolicy.keepBoth)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        extras
        if planning && plan == nil { HStack { ProgressView().controlSize(.small); Text("Counting files…").foregroundStyle(.secondary) } }
        if let plan { summary(plan) }
        HStack {
            Text("Runs in the background: its progress and Stop are at the bottom of the sidebar.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(isAll ? "\(verb) All" : verb) { run() }
                .keyboardShortcut(.defaultAction)
                .disabled((!isAll && !isSessions && folder.isEmpty) || (plan?.items.isEmpty ?? true))
        }
    }

    var options: Exporter.Options {
        var o = Exporter.Options()
        o.recipe = editPhotos ? recipe : nil
        o.writeNames = writeNames
        o.topN = topN
        o.bestOfBurst = bestOfBurst
        o.skipBlurry = skipBlurry
        o.project = model.currentProject
        o.taken = wholeEvent || isSessions ? nil : model.sessionRange
        switch kindLayout {
        case 1: o.kinds = .subfolders(photos: photosChild, videos: videosChild)
        case 2: o.kinds = .folders(photos: photosBase, videos: videosBase)
        default: o.kinds = .together
        }
        return o
    }

    /// Photos and videos together, in two folders inside the person's folder, or in two folders of their own; a
    /// kind without a folder is left out (photos only, videos only).
    @ViewBuilder
    var kindsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Photos and videos:").font(.headline)
            Picker("", selection: $kindLayout) {
                Text("Together in \(isAll ? "each person's" : isSessions ? "each session's" : "the “\(folder)”") folder").tag(0)
                Text("In two folders inside it").tag(1)
                Text("In two folders I choose").tag(2)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if kindLayout == 1 {
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Text("Photos in")
                        TextField("Leave empty: no photos", text: $photosChild).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    GridRow {
                        Text("Videos in")
                        TextField("Leave empty: no videos", text: $videosChild).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                }
                .padding(.leading, 20)
                Text("e.g. “\(isAll ? "Name" : isSessions ? sessionFolder(model.sessions.first) : folder.isEmpty ? "Name" : folder)/\(photosChild.isEmpty ? "…" : photosChild)/”. Leave a name empty to copy only the other kind.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            } else if kindLayout == 2 {
                Grid(alignment: .leading, verticalSpacing: 6) {
                    kindFolderRow("Photos", $photosBase, key: "peopleExportPhotos")
                    kindFolderRow("Videos", $videosBase, key: "peopleExportVideos")
                }
                .padding(.leading, 20)
                Text("\(isAll ? "Each person gets a folder" : isSessions ? "Each session gets a folder" : "The “\(folder.isEmpty ? "…" : folder)” folder goes") inside each. Choose only one to copy only photos or only videos.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
        }
    }

    func kindFolderRow(_ title: String, _ url: Binding<URL?>, key: String) -> some View {
        GridRow {
            Text(title)
            Text(url.wrappedValue?.path ?? "Not \(mode == .copy ? "copied" : "moved")")
                .foregroundStyle(url.wrappedValue == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .leading)
            Button("Choose…") { Panels.chooseFolder(key: key) { url.wrappedValue = $0 } }.controlSize(.small)
            if url.wrappedValue != nil {
                Button { url.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Leave \(title.lowercased()) out")
            }
        }
    }

    @ViewBuilder
    var extras: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which photos:").font(.headline)
            HStack {
                Picker("", selection: $topN) {
                    Text("All of them").tag(Int?.none)
                    ForEach([10, 20, 50, 100], id: \.self) { Text("Best \($0) per \(isSessions ? "session" : "person")").tag(Int?.some($0)) }
                }
                .labelsHidden().fixedSize()
                Toggle("Skip similar shots (best of each burst)", isOn: $bestOfBurst).toggleStyle(.checkbox)
            }
            Toggle("Skip blurry shots (main face out of focus)", isOn: $skipBlurry).toggleStyle(.checkbox)
                .help("Photos whose biggest face is soft, as the Files browser marks them, are left out")
            Toggle("Write people's names into the files (Lightroom, Photos, Bridge)", isOn: $writeNames)
                .toggleStyle(.checkbox)
                .disabled(editPhotos)
                .help(editPhotos ? "Edited photos always get the names" : "Only the copies are tagged; originals are never changed")
            Toggle("Edit photos: auto tone, social crop, watermark, resize", isOn: $editPhotos.animation())
                .toggleStyle(.checkbox)
            if editPhotos {
                EditOptionsView(recipe: $recipe, samples: previewSamples, remember: "export")
                if mode == .move {
                    Text("Edited versions are saved as new JPEGs; originals stay where they are.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// The plan's photos (who's in them and where) to preview the edit on.
    var previewSamples: [ToolItem] {
        let items: [Exporter.Item] = plan?.items ?? []
        return items.filter { !MediaTypes.videos.contains($0.from.pathExtension.lowercased()) }.prefix(200)
            .map { ToolItem(url: $0.from, personName: $0.personName, people: $0.people, focus: $0.focus) }
    }

    var peopleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("People (\(chosen.count) of \(named.count))").font(.headline)
                Spacer()
                Button("All") { chosen = Set(named.map(\.id)) }.controlSize(.small)
                Button("None") { chosen = [] }.controlSize(.small)
            }
            if named.isEmpty {
                Text("Name some people first — only named people have a folder name.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(named) { p in
                        Toggle(isOn: Binding(get: { chosen.contains(p.id) },
                                             set: { if $0 { chosen.insert(p.id) } else { chosen.remove(p.id) } })) {
                            HStack {
                                FaceImage(faceId: p.coverFaceId, side: 24).clipShape(Circle())
                                Text(p.displayName)
                                Spacer()
                                Text(PersonCell(person: p, selected: false).counts).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    /// "03 Awards", "04 18.05–19.40": numbered so the folders sort in the order of the event.
    func sessionFolder(_ s: EventSession?) -> String {
        guard let s else { return "01 Opening" }
        return String(format: "%02d ", s.index + 1) + model.sessionTitle(s).replacingOccurrences(of: ":", with: ".")
    }

    var sessionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sessions (\(chosenSessions.count) of \(model.sessions.count))").font(.headline)
                Spacer()
                Button("All") { chosenSessions = Set(model.sessions.map(\.index)) }.controlSize(.small)
                Button("None") { chosenSessions = [] }.controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sessions) { s in
                        Toggle(isOn: Binding(get: { chosenSessions.contains(s.index) },
                                             set: { if $0 { chosenSessions.insert(s.index) } else { chosenSessions.remove(s.index) } })) {
                            HStack {
                                Text(sessionFolder(s))
                                Spacer()
                                Text(s.videos > 0 ? "\(s.photos) photos · \(s.videos) videos" : "\(s.photos) photos")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            Text("Folders are named after the sessions; right-click a session in the bar to name it first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func summary(_ plan: Exporter.Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isAll && mode == .move {
                Text("\(plan.moves) files will be moved and \(plan.copies) copied.")
                if plan.copies > 0 {
                    Text("Group photos move to the folder of the person shown largest and are copied into the others' folders.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(plan.photos) photos and \(plan.videos) videos will be \(mode == .copy ? "copied" : "moved").")
            }
            if let left = leftOut { Text("\(left) are left out: \(kindLayout == 1 ? "no folder name" : "no folder chosen") for them.").foregroundStyle(.secondary) }
            if plan.alreadyThere > 0 { Text("\(plan.alreadyThere) are already in place.").foregroundStyle(.secondary) }
            if !isAll && mode == .move && plan.sharedCount > 0 {
                Text("\(plan.sharedCount) of them also show other named people. Moving takes them out of their current folder, so they won't be in those people's folders. Use Copy, or Move All from the People view, for group photos.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The kinds with no folder ("Photos", "Videos", or both), nil when both have one.
    var leftOut: String? {
        let (noPhotos, noVideos): (Bool, Bool)
        switch kindLayout {
        case 1: (noPhotos, noVideos) = (photosChild.trimmingCharacters(in: .whitespaces).isEmpty, videosChild.trimmingCharacters(in: .whitespaces).isEmpty)
        case 2: (noPhotos, noVideos) = (photosBase == nil, videosBase == nil)
        default: return nil
        }
        return noPhotos && noVideos ? "Photos and videos" : noPhotos ? "Photos" : noVideos ? "Videos" : nil
    }

    func choose() {
        Panels.chooseFolder(key: "peopleExport") { base = $0 }
    }

    /// Plans in the background after options settle: planning thousands of files must never freeze the dialog.
    func replan() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let service = model.service else { return }
        let exporter = service.exporter, options = options, base = base, mode = mode, name = name, folder = folder
        let scope = scope
        let people = named.filter { chosen.contains($0.id) }.map { (id: $0.id, name: $0.name!) }
        let sessions = model.sessions.filter { chosenSessions.contains($0.index) }.map { (range: $0.range, folder: sessionFolder($0)) }
        let exports = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SuZu Exports")
        planning = true
        let result = await Task.detached(priority: .userInitiated) { () -> Exporter.Plan? in
            switch scope {
            case .all:
                return try? exporter.planAll(people: people, base: base, mode: mode, options: options)
            case .person(let id):
                return folder.isEmpty ? nil : try? exporter.plan(personId: id, name: name, base: base, mode: mode, options: options)
            case .media(let ids, _):
                return folder.isEmpty ? nil : try? exporter.planMedia(ids, folder: name, base: base ?? exports, options: options)
            case .sessions:
                // Without a folder chosen, the sessions go in one named after the event.
                return try? exporter.planSessions(sessions, base: base ?? exports.appendingPathComponent(folder.isEmpty ? "Sessions" : folder, isDirectory: true),
                                                  options: options)
            }
        }.value
        guard !Task.isCancelled else { return }
        plan = result
        planning = false
    }

    func run() {
        guard let service = model.service, let plan else { return }
        if case .person(let id) = scope {
            // Naming the person is part of exporting them.
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if model.people.first(where: { $0.id == id })?.name != trimmed { model.rename(id, to: trimmed) }
        }
        // Show in Finder: the person's folder (not the Photos folder inside it); for everyone, the one holding theirs.
        var shown = plan.items.first?.to.deletingLastPathComponent()
        if kindLayout == 1 { shown = shown?.deletingLastPathComponent() }
        if isAll || isSessions { shown = shown?.deletingLastPathComponent() }
        model.exports.start(plan, exporter: service.exporter, policy: policy, workers: min(6, ToolWork.parallelism),
                            target: isAll ? "everyone's folders" : isSessions ? "each session's folder" : "“\(folder)”", mode: mode, folder: shown)
        dismiss()
    }
}
