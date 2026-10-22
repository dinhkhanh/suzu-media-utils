import MediaKit
import SwiftUI

/// Proxies (small 720p copies for review/editing) and contact sheets (one-page overviews) for many videos.
struct VideoToolsView: View {
    @State private var files: [URL] = []
    @State private var output: URL?
    @State private var proxies = true
    @State private var sheets = true
    @State private var grid = 4
    @State private var running = false
    @State private var done = 0
    @State private var failures: [String] = []
    @State private var finished = false

    var steps: Int { files.count * ((proxies ? 1 : 0) + (sheets ? 1 : 0)) }

    var body: some View {
        Form {
            Section("Videos") { FileInputList(files: $files, kinds: MediaTypes.videos, label: "videos") }
            Section("Make") {
                Toggle("Proxies — 720p H.264 copies for quick review and editing", isOn: $proxies)
                Toggle("Contact sheets — a grid of frames with timestamps per video", isOn: $sheets)
                if sheets { Picker("Grid", selection: $grid) { Text("3×3").tag(3); Text("4×4").tag(4); Text("5×5").tag(5) }.fixedSize() }
                FolderField(title: "Save to", url: $output)
            }
            Section {
                HStack {
                    if running || finished {
                        ProgressView(value: Double(done), total: Double(max(1, steps))).frame(maxWidth: 260)
                        Text(finished ? "Done\(failures.isEmpty ? "" : ", \(failures.count) failed")" : "\(done) of \(steps)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if finished, let output { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                    Button("Start") { run() }.keyboardShortcut(.defaultAction)
                        .disabled(running || files.isEmpty || output == nil || (!proxies && !sheets))
                }
                ForEach(failures.prefix(5), id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Video Tools")
    }

    func run() {
        guard let output else { return }
        running = true; finished = false; done = 0; failures = []
        let files = files, proxies = proxies, sheets = sheets, grid = grid
        Task.detached(priority: .utility) {
            for f in files {
                let stem = f.deletingPathExtension().lastPathComponent
                if proxies {
                    do { try await VideoTools.proxy(f, to: output.appendingPathComponent(stem + "_proxy.mp4")) }
                    catch { await MainActor.run { failures.append("\(f.lastPathComponent): \(error.localizedDescription)") } }
                    await MainActor.run { done += 1 }
                }
                if sheets {
                    do { try VideoTools.contactSheet(f, columns: grid, rows: grid, to: output.appendingPathComponent(stem + "_sheet.jpg")) }
                    catch { await MainActor.run { failures.append("\(f.lastPathComponent): \(error.localizedDescription)") } }
                    await MainActor.run { done += 1 }
                }
            }
            await MainActor.run { running = false; finished = true }
        }
    }
}
