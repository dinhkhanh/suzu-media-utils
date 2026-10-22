import FaceCore
import MediaKit
import SwiftUI

/// Auto tone, face-aware social crop, logo and resize for any photos (no library needed).
struct BatchExportTool: View {
    @State private var files: [URL] = []
    @State private var recipe = EditRecipe()
    @State private var output: URL?
    @State private var suffix = ""
    @State private var running = false
    @State private var done = 0
    @State private var failures: [String] = []
    @State private var finished = false

    var body: some View {
        Form {
            Section("Photos") { FileInputList(files: $files, kinds: MediaTypes.photos, label: "photos") }
            Section("Edits") {
                EditOptionsView(recipe: $recipe, previewSource: files.first, previewFocus: nil)
                Text("Crops find the faces in each photo (or the most eye-catching area) and keep them in frame.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                FolderField(title: "Save to", url: $output)
                TextField("Add to file names (optional)", text: $suffix, prompt: Text("e.g. _ig"))
            }
            Section {
                HStack {
                    if running || finished {
                        ProgressView(value: Double(done), total: Double(max(1, files.count))).frame(maxWidth: 260)
                        Text(finished ? "Done: \(done - failures.count) saved\(failures.isEmpty ? "" : ", \(failures.count) failed")" : "\(done) of \(files.count)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if finished, let output { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                    Button("Export \(files.count) Photos") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || files.isEmpty || output == nil)
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
        running = true; finished = false; done = 0; failures = []
        let files = files, recipe = recipe, suffix = suffix
        Task.detached(priority: .utility) {
            await withTaskGroup(of: String?.self) { group in
                var next = 0
                func add() {
                    guard next < files.count else { return }
                    let f = files[next]; next += 1
                    group.addTask(priority: .utility) {
                        let dest = output.appendingPathComponent(f.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension("jpg")
                        do { try EditPipeline.render(f, recipe: recipe, focus: nil, to: dest); return nil }
                        catch { return "\(f.lastPathComponent): \(error.localizedDescription)" }
                    }
                }
                for _ in 0..<ToolWork.parallelism { add() }
                for await r in group {
                    await MainActor.run { done += 1; if let r { failures.append(r) } }
                    add()
                }
            }
            await MainActor.run { running = false; finished = true }
        }
    }
}
