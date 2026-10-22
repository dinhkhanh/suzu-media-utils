import AppKit
import UniformTypeIdentifiers

/// Open panels that never block the app: `begin` instead of `runModal`, starting in a local folder so a slow
/// network share isn't listed before the panel can even appear.
@MainActor
enum Panels {
    private static var open: NSOpenPanel?

    static var exportsFolder: URL {
        let u = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SuZu Exports")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func choose(folders: Bool, files: Bool, multiple: Bool = false, types: [UTType]? = nil, prompt: String = "Choose",
                       message: String? = nil, start: URL? = nil, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = folders
        panel.prompt = prompt
        if let message { panel.message = message }
        if let types { panel.allowedContentTypes = types }
        panel.directoryURL = start ?? (folders && !files ? exportsFolder : FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0])
        open = panel
        panel.begin { response in
            open = nil
            if response == .OK { completion(panel.urls) }
        }
    }

    static func chooseFolder(prompt: String = "Choose", start: URL? = nil, completion: @escaping (URL) -> Void) {
        choose(folders: true, files: false, prompt: prompt, start: start) { if let u = $0.first { completion(u) } }
    }
}
