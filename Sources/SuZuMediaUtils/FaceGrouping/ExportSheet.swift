import FaceLibrary
import MediaKit
import SwiftUI

enum ExportScope: Identifiable {
    case person(Int64)
    case all
    /// Search results or a smart album, exported into one folder.
    case media([Int64], title: String)
    var id: String {
        switch self {
        case .person(let p): "p\(p)"
        case .all: "all"
        case .media(let ids, let t): "m\(t)\(ids.count)"
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
    @State private var running = false
    @State private var progress = 0
    @State private var result: Exporter.Result?
    /// Ignore the session picked in the People view and export the whole event.
    @State private var wholeEvent = false

    init(scope: ExportScope, mode: ExportMode, initialName: String = "") {
        self.scope = scope
        self.mode = mode
        _name = State(initialValue: initialName)
    }

    var isAll: Bool { if case .all = scope { true } else { false } }
    var isMedia: Bool { if case .media = scope { true } else { false } }
    var verb: String { mode == .copy ? "Copy" : "Move" }
    var folder: String { Exporter.folderName(name) }
    var named: [PersonSummary] { model.people.filter { $0.name != nil && $0.faces > 0 } }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text(isAll ? "\(verb) everyone's files to their folders" : "\(verb) to “\(folder.isEmpty ? "…" : folder)” folder")
                .font(.title2.bold())
            if result == nil, let s = model.currentSession, !isMedia {
                HStack {
                    Image(systemName: "timer")
                    Text(wholeEvent ? "The whole event" : "Only the “\(model.sessionTitle(s))” session (\(model.sessionTime(s)))")
                    Toggle("Whole event", isOn: $wholeEvent).toggleStyle(.checkbox).padding(.leading, 8)
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
            }
            if let result { resultView(result) } else { form }
        }
        .padding(20)
        }
        .frame(maxHeight: 860)
        .frame(width: editPhotos ? 960 : 620)
        .onAppear { chosen = Set(named.map(\.id)) }
        .task(id: "\(name)|\(base?.path ?? "")|\(chosen.sorted())|\(editPhotos)|\(recipe.hashValue)|\(writeNames)|\(topN ?? 0)|\(bestOfBurst)|\(skipBlurry)|\(wholeEvent)") { await replan() }
    }

    @ViewBuilder
    var form: some View {
        if isAll {
            peopleList
        } else {
            TextField(isMedia ? "Folder name" : "Person's name (folder name)", text: $name).textFieldStyle(.roundedBorder)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(isAll ? "Put each person's folder:" : "Put the “\(folder)” folder:").font(.headline)
            Picker("", selection: Binding(get: { base == nil ? 0 : 1 }, set: { if $0 == 0 { base = nil } else { choose() } })) {
                Text(isMedia ? "Inside Pictures/SuZu Exports" : "Inside each file's source folder").tag(0)
                Text(base.map { "Inside \($0.path)" } ?? "Inside another folder…").tag(1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let example = plan?.items.first {
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
        if running {
            ProgressView(value: Double(progress), total: Double(max(1, plan?.items.count ?? 1)))
            Text("\(progress) of \(plan?.items.count ?? 0)").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
            Button(isAll ? "\(verb) All" : verb) { run() }
                .keyboardShortcut(.defaultAction)
                .disabled(running || (!isAll && folder.isEmpty) || (plan?.items.isEmpty ?? true))
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
        o.taken = wholeEvent ? nil : model.sessionRange
        return o
    }

    @ViewBuilder
    var extras: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which photos:").font(.headline)
            HStack {
                Picker("", selection: $topN) {
                    Text("All of them").tag(Int?.none)
                    ForEach([10, 20, 50, 100], id: \.self) { Text("Best \($0) per person").tag(Int?.some($0)) }
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
            if plan.alreadyThere > 0 { Text("\(plan.alreadyThere) are already in place.").foregroundStyle(.secondary) }
            if !isAll && mode == .move && plan.sharedCount > 0 {
                Text("\(plan.sharedCount) of them also show other named people. Moving takes them out of their current folder, so they won't be in those people's folders. Use Copy, or Move All from the People view, for group photos.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func resultView(_ r: Exporter.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(r.done) files \(mode == .copy ? "copied" : "moved or copied").")
            if r.skippedExisting > 0 { Text("\(r.skippedExisting) skipped because a file with that name was already there.").foregroundStyle(.secondary) }
            if !r.failed.isEmpty {
                Text("\(r.failed.count) failed:").foregroundStyle(.red)
                ForEach(Array(r.failed.prefix(5).enumerated()), id: \.offset) { _, f in
                    Text("\(f.0): \(f.1)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if let dir = plan?.items.first?.to.deletingLastPathComponent() {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([isAll ? dir.deletingLastPathComponent() : dir])
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    func choose() {
        Panels.chooseFolder { base = $0 }
    }

    /// Plans in the background after options settle: planning thousands of files must never freeze the dialog.
    func replan() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let service = model.service else { return }
        let exporter = service.exporter, options = options, base = base, mode = mode, name = name, folder = folder
        let scope = scope
        let people = named.filter { chosen.contains($0.id) }.map { (id: $0.id, name: $0.name!) }
        planning = true
        let result = await Task.detached(priority: .userInitiated) { () -> Exporter.Plan? in
            switch scope {
            case .all:
                return try? exporter.planAll(people: people, base: base, mode: mode, options: options)
            case .person(let id):
                return folder.isEmpty ? nil : try? exporter.plan(personId: id, name: name, base: base, mode: mode, options: options)
            case .media(let ids, _):
                let root = base ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SuZu Exports")
                return folder.isEmpty ? nil : try? exporter.planMedia(ids, folder: name, base: root, options: options)
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
        running = true
        let exporter = service.exporter
        let policy = policy
        ToolWork.begin()
        Task.detached(priority: .utility) {
            let r = exporter.run(plan, policy: policy) { n in if n % 5 == 0 || n == plan.items.count { Task { @MainActor in progress = n } } }
            await MainActor.run {
                result = r
                running = false
                ToolWork.end()
            }
        }
    }
}
