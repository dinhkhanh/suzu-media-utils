import FaceLibrary
import MediaKit
import SwiftUI

/// Export a person's moments from videos: clips, a highlight reel, or best still frames.
struct VideoExportSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    let personId: Int64
    let name: String
    enum Choice: String, CaseIterable, Identifiable {
        case clips = "A clip for each appearance", reel = "One highlight reel", stills = "Best still frames"
        var id: String { rawValue }
    }
    @State private var choice = Choice.reel
    @State private var maxSeconds: Double? = 60
    @State private var recipe = EditRecipe()
    @State private var folder: URL?
    @State private var appearances: [VideoExport.Appearance] = []
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var result: [URL]?
    @State private var error: String?
    @State private var samples: [ToolItem] = []

    var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuZu Exports").appendingPathComponent(Exporter.folderName(name) + " – Video")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export \(name)'s video moments").font(.title2.bold())
            Text("\(appearances.count) appearances in \(Set(appearances.map(\.mediaId)).count) videos, \(VideoTools.timecode(appearances.map(\.segment.duration).reduce(0, +))) on screen in total.")
                .foregroundStyle(.secondary)
            if let result {
                Text("Created \(result.count) file\(result.count == 1 ? "" : "s").")
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Picker("", selection: $choice) { ForEach(Choice.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.radioGroup).labelsHidden()
                switch choice {
                case .clips:
                    Text("Cut straight from the originals without re-encoding (fast, full quality).").font(.caption).foregroundStyle(.secondary)
                case .reel:
                    Picker("Length", selection: $maxSeconds) {
                        Text("Up to 30 s").tag(Double?.some(30))
                        Text("Up to 1 min").tag(Double?.some(60))
                        Text("Up to 2 min").tag(Double?.some(120))
                        Text("Everything").tag(Double?.none)
                    }
                    .fixedSize()
                    Text("Takes the best moments (sharpest, facing the camera) and joins them in time order as HEVC.")
                        .font(.caption).foregroundStyle(.secondary)
                case .stills:
                    EditOptionsView(recipe: $recipe, samples: samples, remember: "videoStills")
                }
                HStack {
                    Text("Save to: \((folder ?? defaultFolder).path)").font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { choose() }
                }
                if running {
                    ProgressView(value: Double(progress.0), total: Double(max(1, progress.1)))
                }
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button("Export") { run() }.keyboardShortcut(.defaultAction).disabled(running || appearances.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: choice == .stills ? 960 : 560)
        .task {
            guard let store = model.store else { return }
            let project = model.currentProject, personId = personId
            samples = await model.samples(personId: personId)
            appearances = await Task.detached { (try? VideoExport(store: store).appearances(personId: personId, project: project)) ?? [] }.value
        }
    }

    func choose() {
        Panels.chooseFolder { folder = $0 }
    }

    func run() {
        guard let store = model.store else { return }
        running = true
        let kind: VideoExport.Kind = switch choice {
        case .clips: .clips
        case .reel: .reel(maxSeconds: maxSeconds)
        case .stills: .stills(recipe)
        }
        let dest = folder ?? defaultFolder, project = model.currentProject
        Task {
            do {
                result = try await VideoExport(store: store).export(personId: personId, name: name, kind: kind, project: project, to: dest) { d, t in
                    Task { @MainActor in progress = (d, t) }
                }
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}
