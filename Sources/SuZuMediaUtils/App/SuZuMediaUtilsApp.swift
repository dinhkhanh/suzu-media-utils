import SwiftUI

/// SuZu Media Utils: a home for SuZu Media's photo and video tools. Each tool owns a model, its sidebar sections and
/// its detail views (see AppShell). Face Grouping is the first tool.
struct SuZuMediaUtilsApp: App {
    @StateObject private var faces = FaceGroupingModel()

    var body: some Scene {
        WindowGroup("SuZu Media Utils") {
            AppShell()
                .environmentObject(faces)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { faces.askNewProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Menu("Open Project") {
                    ForEach(faces.projects) { p in Button(p.name) { faces.currentProject = p.id } }
                    Divider()
                    Button("All Projects") { faces.currentProject = nil }
                }
                Divider()
                Button("Add Photo & Video Folder…") { faces.addFolder(kind: .media) }
                    .keyboardShortcut("o")
                Button("Add Known-People Folder…") { faces.addFolder(kind: .reference) }
            }
        }
        // Photos opened from the library: Batch Export with just them.
        WindowGroup("Edit & Export", id: "edit", for: EditRequest.self) { $request in
            EditWindow(request: request).environmentObject(faces)
        }
        // Files culled from the Files browser, full screen.
        WindowGroup("Cull", id: "cull", for: CullRequest.self) { $request in
            CullWindow(request: request).environmentObject(faces)
        }
        .defaultSize(width: 1400, height: 900)
        .restorationBehavior(.disabled)
        Settings {
            TabView {
                FaceGroupingSettings()
                    .tabItem { Label("Face Grouping", systemImage: "person.2.crop.square.stack") }
                WatermarkSettings()
                    .tabItem { Label("Watermarks", systemImage: "seal") }
                SharingSettings()
                    .tabItem { Label("Sharing", systemImage: "network") }
            }
            .environmentObject(faces)
        }
    }
}
