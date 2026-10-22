import FaceCore
import FaceLibrary
import MediaKit
import SwiftUI

/// Auto tone, face-aware social crop, watermark and resize for files or people's photos: a large preview of the
/// result on the left, source, edits and output in an inspector on the right.
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EditPreview(recipe: $recipe, samples: items)
                    .frame(minWidth: 260, maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        InspectorSection(title: "Photos") {
                            ToolInputView(items: $items, kinds: MediaTypes.photos, mediaKind: .photo, label: "photos")
                        }
                        EditControls(recipe: $recipe)
                        Text(fromPeople ? "Crops keep each person's face in frame; names are written into the files."
                                        : "Crops find the faces in each photo (or the most eye-catching area) and keep them in frame.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        InspectorSection(title: "Output") {
                            FolderField(title: "Save to", url: $output)
                            if fromPeople { Toggle("A folder per person", isOn: $folderPerPerson) }
                            TextField("Add to file names", text: $suffix, prompt: Text("e.g. _ig")).textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(16)
                }
                .frame(width: 320)
            }
            Divider()
            HStack(spacing: 12) {
                if running || finished {
                    ProgressView(value: Double(done), total: Double(max(1, total))).frame(maxWidth: 220)
                    Text(finished ? "Done: \(done - failures.count) saved\(failures.isEmpty ? "" : ", \(failures.count) failed")" : "\(done) of \(total)")
                        .foregroundStyle(.secondary)
                    if let f = failures.first { Text(f).font(.caption).foregroundStyle(.red).lineLimit(1).help(failures.prefix(10).joined(separator: "\n")) }
                } else {
                    Text(output == nil ? "Choose where to save" : "\(items.count) photos → \(output!.lastPathComponent)").foregroundStyle(.secondary)
                }
                Spacer()
                if running { Button("Stop") { cancel = true } }
                if finished, let output { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                Button("Export \(items.count) Photos") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || items.isEmpty || output == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
        .navigationTitle("Batch Export")
        .navigationSubtitle("Auto tone · social crops · watermark · resize")
        .rememberEdits("batchExport", recipe: $recipe)
        .task {
            // SUZU_TOOL_SAMPLES=1 (testing): start with the project's best photos as input.
            if ProcessInfo.processInfo.environment["SUZU_TOOL_SAMPLES"] != nil, items.isEmpty, let faces = ToolWork.faces {
                try? await Task.sleep(for: .seconds(2))
                items = await faces.samples(limit: 40)
            }
        }
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
