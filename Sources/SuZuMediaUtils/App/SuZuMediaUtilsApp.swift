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
                Button("Add Photo & Video Folder…") { faces.addFolder(kind: .media) }
                    .keyboardShortcut("o")
                Button("Add Known-People Folder…") { faces.addFolder(kind: .reference) }
            }
        }
        Settings {
            TabView {
                FaceGroupingSettings()
                    .tabItem { Label("Face Grouping", systemImage: "person.2.crop.square.stack") }
                EditingSettings()
                    .tabItem { Label("Editing", systemImage: "wand.and.stars") }
            }
            .environmentObject(faces)
        }
    }
}
