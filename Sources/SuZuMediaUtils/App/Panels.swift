import AppKit
import UniformTypeIdentifiers

/// Open panels that never block the app: `begin` instead of `runModal`. Each kind of browse button opens where it
/// was last used (the folder chosen, or the one holding what was chosen); the first time, in a local folder, so a
/// slow network share isn't listed before the panel can even appear.
@MainActor
enum Panels {
    private static var open: NSOpenPanel?
    private static let lastKey = "panels.lastFolders"

    static var exportsFolder: URL {
        let u = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SuZu Exports")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// `key`: which button this is, for where it opens next time; by default, buttons choosing the same kind of
    /// thing with the same prompt share it. `start`: where it opens until it has been used.
    static func choose(folders: Bool, files: Bool, multiple: Bool = false, types: [UTType]? = nil, prompt: String = "Choose",
                       message: String? = nil, start: URL? = nil, key: String? = nil, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = folders
        panel.prompt = prompt
        if let message { panel.message = message }
        if let types { panel.allowedContentTypes = types }
        let key = key ?? "\(folders ? "folders" : "")\(files ? "files" : "")|\(prompt)|\(types?.map(\.identifier).joined(separator: ",") ?? "")"
        panel.directoryURL = last(key) ?? start ?? (folders && !files ? exportsFolder : FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0])
        open = panel
        panel.begin { response in
            open = nil
            guard response == .OK else { return }
            remember(panel.urls, folders: folders && !files && !multiple, key: key)
            completion(panel.urls)
        }
    }

    static func chooseFolder(prompt: String = "Choose", start: URL? = nil, key: String? = nil, completion: @escaping (URL) -> Void) {
        choose(folders: true, files: false, prompt: prompt, start: start, key: key) { if let u = $0.first { completion(u) } }
    }

    /// Where the button opened last, unless it is on a volume that is no longer mounted. Nothing is read from the
    /// folder itself, so a slow share doesn't hold up the panel.
    static func last(_ key: String) -> URL? {
        guard let path = (UserDefaults.standard.dictionary(forKey: lastKey) as? [String: String])?[key] else { return nil }
        let url = URL(fileURLWithPath: path)
        let parts = url.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            let volume = "/Volumes/" + parts[2]
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?.contains { $0.path == volume } ?? false
            return mounted ? url : nil
        }
        return FileManager.default.fileExists(atPath: path) ? url : nil
    }

    /// A single folder chosen opens in itself next time (to choose it again, or one inside); otherwise where the
    /// chosen items are, to pick their neighbours.
    static func remember(_ urls: [URL], folders: Bool, key: String) {
        guard let first = urls.first else { return }
        let folder = folders ? first : first.deletingLastPathComponent()
        var all = UserDefaults.standard.dictionary(forKey: lastKey) as? [String: String] ?? [:]
        all[key] = folder.path
        UserDefaults.standard.set(all, forKey: lastKey)
    }
}
