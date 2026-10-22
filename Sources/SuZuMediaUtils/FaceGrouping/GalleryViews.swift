import FaceLibrary
import MediaKit
import SwiftUI

/// Settings → Sharing: serve the library as a web gallery on the local network.
struct SharingSettings: View {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some View {
        Form {
            Section {
                Toggle("Share a web gallery on the local network", isOn: Binding(get: { model.sharingURL != nil }, set: { model.setSharing($0) }))
                if let url = model.sharingURL {
                    LabeledContent("Address") {
                        HStack {
                            Text(url).textSelection(.enabled).font(.callout.monospaced())
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                            Button("Open") { NSWorkspace.shared.open(URL(string: url)!) }
                        }
                    }
                    Button("New Secret Link") { model.regenerateSharingToken() }
                        .help("Old links stop working")
                }
            } footer: {
                Text("Anyone on your network with the link can browse people, play videos, download originals and rename people — use it from a MacBook, iPad or phone while this Mac does the work. Without the link the gallery can't be found.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}

/// Export a self-contained web gallery folder.
struct GalleryExportSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = "SuZu Media"
    @State private var options = GalleryExporter.Options()
    @State private var watermark = false
    @State private var folder: URL?
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var result: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Web Gallery").font(.title2.bold())
            Text("A folder with an index.html: open it in a browser, or put it on Google Drive, Dropbox or the NAS to share. Every named person gets a page.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let result {
                HStack {
                    Button("Open Gallery") { NSWorkspace.shared.open(result) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Picker("Photos per person", selection: $options.topN) {
                    Text("Best 30").tag(Int?.some(30)); Text("Best 60").tag(Int?.some(60)); Text("Best 150").tag(Int?.some(150)); Text("All").tag(Int?.none)
                }
                .fixedSize()
                Toggle("Skip similar shots (best of each burst)", isOn: $options.bestOfBurst)
                Toggle("Include videos (copied as they are)", isOn: $options.includeVideos)
                Toggle("Watermark photos with the logo", isOn: $watermark).disabled(EditSettings.watermark == nil)
                Toggle("Auto tone", isOn: $options.recipe.autoTone)
                HStack {
                    Text("Save to: \(destination.path)").font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { choose() }
                }
                if running { ProgressView(value: Double(progress.0), total: Double(max(1, progress.1))) }
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button("Export") { run() }.keyboardShortcut(.defaultAction).disabled(running)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    var destination: URL {
        folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuZu Exports").appendingPathComponent("\(Exporter.folderName(title)) Gallery")
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { folder = panel.url }
    }

    func run() {
        guard let store = model.store else { return }
        var opts = options
        opts.recipe.watermark = watermark ? EditSettings.watermark : nil
        opts.recipe.autoToneStrength = EditSettings.autoToneStrength
        running = true
        let dest = destination, title = title
        Task.detached {
            do {
                let index = try GalleryExporter(store: store).export(title: title, personIds: nil, options: opts, to: dest) { d, t in
                    Task { @MainActor in progress = (d, t) }
                }
                await MainActor.run { result = index; running = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; running = false }
            }
        }
    }
}
