import FaceCore
import SwiftUI
import UniformTypeIdentifiers

/// The tools beyond Face Grouping. Each is a self-contained view over MediaKit.
enum ToolRoute: String, Hashable, CaseIterable {
    case batchExport, rename, verify, video

    var title: String {
        switch self {
        case .batchExport: "Batch Export"
        case .rename: "Batch Rename"
        case .verify: "Copy Verifier"
        case .video: "Video Tools"
        }
    }
    var icon: String {
        switch self {
        case .batchExport: "wand.and.stars"
        case .rename: "character.cursor.ibeam"
        case .verify: "checkmark.shield"
        case .video: "film"
        }
    }
}

struct ToolsSidebar: View {
    var body: some View {
        Section("Tools") {
            ForEach(ToolRoute.allCases, id: \.self) { t in
                Label(t.title, systemImage: t.icon).tag(AppRoute.tool(t))
            }
        }
    }
}

struct ToolDetail: View {
    let route: ToolRoute
    var body: some View {
        switch route {
        case .batchExport: BatchExportTool()
        case .rename: BatchRenameTool()
        case .verify: CopyVerifierTool()
        case .video: VideoToolsView()
        }
    }
}

/// Tools run below face processing so they never slow recognition: limited parallelism at utility priority.
enum ToolWork {
    static var parallelism: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 3) }
}

/// A list of input files with Add Files…, Add Folder… (recursive) and drag & drop.
struct FileInputList: View {
    @Binding var files: [URL]
    let kinds: Set<String>
    var label = "files"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Add Files or Folders…") { pick() }
                if !files.isEmpty { Button("Clear") { files = [] } }
                Text(files.isEmpty ? "or drop \(label) here" : "\(files.count) \(label)").foregroundStyle(.secondary)
                Spacer()
            }
            if !files.isEmpty {
                List(files, id: \.self) { u in
                    Text(u.lastPathComponent).font(.callout).lineLimit(1).help(u.path)
                }
                .frame(minHeight: 90, maxHeight: 160)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5])))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { add([url]) } }
                }
            }
            return true
        }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        var out = files
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if kinds.contains(f.pathExtension.lowercased()) { out.append(f) }
                }
            } else if kinds.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        var seen: Set<String> = []
        files = out.filter { seen.insert($0.path).inserted }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

struct FolderField: View {
    let title: String
    @Binding var url: URL?
    var body: some View {
        HStack {
            Text(title)
            Text(url?.path ?? "Not chosen").foregroundStyle(url == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK { url = panel.url }
            }
        }
    }
}

enum MediaTypes {
    static let photos = ImageLoader.extensions
    static let videos = VideoSampler.extensions
}
