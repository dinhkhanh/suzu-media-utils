import SwiftUI

/// SuZu Media Utils: a home for SuZu Media's photo and video tools. Each tool owns a model, its sidebar sections and
/// its detail views (see AppShell). Face Grouping is the first tool.
struct SuZuMediaUtilsApp: App {
    @StateObject private var faces = FaceGroupingModel()
    @StateObject private var updater = Updater()
    // Settings › General. Applied at the root of every scene so windows, sheets and popovers agree.
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("accent") private var accent = AccentChoice.coral

    var body: some Scene {
        WindowGroup("SuZu Media Utils") {
            AppShell()
                .environmentObject(faces)
                .frame(minWidth: 900, minHeight: 600)
                .styled(appearance, accent)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
            }
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
                Divider()
                Button("Share Project with Team…") { faces.askShareTeam = true }
                    .disabled(faces.currentProject == nil)
                Button("Join a Team…") { faces.askJoinTeam = true }
            }
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        // Photos opened from the library: Batch Export with just them.
        WindowGroup("Edit & Export", id: "edit", for: EditRequest.self) { $request in
            EditWindow(request: request).environmentObject(faces).styled(appearance, accent)
        }
        // Files culled from the Files browser, full screen.
        WindowGroup("Cull", id: "cull", for: CullRequest.self) { $request in
            CullWindow(request: request).environmentObject(faces).styled(appearance, accent)
        }
        .defaultSize(width: 1400, height: 900)
        .restorationBehavior(.disabled)
        Settings {
            TabView {
                GeneralSettings()
                    .tabItem { Label("General", systemImage: "gearshape") }
                FaceGroupingSettings()
                    .tabItem { Label("Face Grouping", systemImage: "person.2.crop.square.stack") }
                WatermarkSettings()
                    .tabItem { Label("Watermarks", systemImage: "seal") }
                SharingSettings()
                    .tabItem { Label("Sharing", systemImage: "network") }
                UpdateSettings()
                    .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            }
            .environmentObject(faces)
            .environmentObject(updater)
            .styled(appearance, accent)
        }
    }
}

extension View {
    /// The user's appearance and accent (Settings › General) on a scene's root view.
    func styled(_ appearance: Appearance, _ accent: AccentChoice) -> some View {
        preferredColorScheme(appearance.colorScheme)
            .tint(accent.color)
            // Custom drawings read `Color.accent` themselves; redraw them when the choice changes.
            .id(accent)
    }
}
