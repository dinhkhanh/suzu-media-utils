import FaceCore
import FaceLibrary
import MediaKit
import SwiftUI

/// Auto tone, face-aware social crop, logo and resize for files or people's photos.
struct BatchExportTool: View {
    @State private var items: [ToolItem] = []
    @State private var recipe = EditRecipe()
    @State private var output: URL?
    @State private var suffix = ""
    @State private var folderPerPerson = true
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var failures: [String] = []
    @State private var finished = false
    @State private var cancel = false

    var fromPeople: Bool { items.contains { $0.personName != nil } }

    var body: some View {
        Form {
            Section("Photos") {
                ToolInputView(items: $items, kinds: MediaTypes.photos, mediaKind: .photo, label: "photos")
            }
            Section("Edits") {
                EditOptionsView(recipe: $recipe, previewSource: items.first?.url, previewFocus: items.first?.focus)
                Text(fromPeople ? "Crops keep each person's face in frame; names are written into the files."
                                : "Crops find the faces in each photo (or the most eye-catching area) and keep them in frame.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                FolderField(title: "Save to", url: $output)
                if fromPeople { Toggle("A folder per person", isOn: $folderPerPerson) }
                TextField("Add to file names (optional)", text: $suffix, prompt: Text("e.g. _ig"))
            }
            Section {
                HStack {
                    if running || finished {
                        ProgressView(value: Double(done), total: Double(max(1, total))).frame(maxWidth: 260)
                        Text(finished ? "Done: \(done - failures.count) saved\(failures.isEmpty ? "" : ", \(failures.count) failed")" : "\(done) of \(total)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if running { Button("Stop") { cancel = true } }
                    if finished, let output { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                    Button("Export \(items.count) Photos") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || items.isEmpty || output == nil)
                }
                ForEach(failures.prefix(5), id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Batch Export")
        .navigationSubtitle("Auto tone · social crops · watermark · resize")
        .onAppear { recipe.autoToneStrength = EditSettings.autoToneStrength }
    }

    func run() {
        guard let output else { return }
        running = true; finished = false; done = 0; failures = []; cancel = false
        let items = items, recipe = recipe, suffix = suffix, perPerson = folderPerPerson && fromPeople
        total = items.count
        let workers = ToolWork.parallelism
        ToolWork.begin()
        Task.detached(priority: .utility) {
            await withTaskGroup(of: String?.self) { group in
                var next = 0
                func add() async {
                    guard next < items.count, !(await MainActor.run { cancel }) else { return }
                    let item = items[next]; next += 1
                    group.addTask(priority: .utility) {
                        var dir = output
                        if perPerson, let name = item.personName { dir = dir.appendingPathComponent(Exporter.folderName(name)) }
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let dest = dir.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension("jpg")
                        do { try EditPipeline.render(item.url, recipe: recipe, focus: item.focus, people: item.people, to: dest); return nil }
                        catch { return "\(item.url.lastPathComponent): \(error.localizedDescription)" }
                    }
                }
                for _ in 0..<workers { await add() }
                for await r in group {
                    await MainActor.run { done += 1; if let r { failures.append(r) } }
                    await add()
                }
            }
            await MainActor.run { running = false; finished = true; ToolWork.end() }
        }
    }
}
