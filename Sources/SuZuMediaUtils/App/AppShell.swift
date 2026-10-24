import SwiftUI

/// Where the user is in the app. Add a case per tool; the tool decides what its own route values mean.
enum AppRoute: Hashable {
    /// The event at a glance: what is processing, what needs you, sessions, activity (the start screen).
    case overview
    /// The project's photos and videos by folder.
    case files
    case faces(FaceRoute)
    case tool(ToolRoute)

    /// "overview" | "files" | "people" | "unassigned" | "search" | "rules" | "album.<id>" | "source.<id>" | "tool.<name>".
    init?(key r: String) {
        if r.hasPrefix("album."), let id = Int64(r.dropFirst(6)) { self = .faces(.album(id)); return }
        if r.hasPrefix("source."), let id = Int64(r.dropFirst(7)) { self = .faces(.source(id)); return }
        if r.hasPrefix("tool."), let t = ToolRoute(rawValue: String(r.dropFirst(5))) { self = .tool(t); return }
        switch r {
        case "overview": self = .overview
        case "files": self = .files
        case "search": self = .faces(.search)
        case "rules": self = .faces(.rules)
        case "unassigned": self = .faces(.unassigned)
        case "toname": self = .faces(.toName)
        case "people": self = .faces(.people)
        default: return nil
        }
    }

    var key: String {
        switch self {
        case .overview: "overview"
        case .files: "files"
        case .faces(.people): "people"
        case .faces(.toName): "toname"
        case .faces(.unassigned): "unassigned"
        case .faces(.search): "search"
        case .faces(.rules): "rules"
        case .faces(.album(let id)): "album.\(id)"
        case .faces(.source(let id)): "source.\(id)"
        case .tool(let t): "tool.\(t.rawValue)"
        }
    }
}

/// Main window: one sidebar, grouped the way an event night goes (Overview and Files, then People, then Tools),
/// and the selected screen on the right.
///
/// To add a tool: add an `AppRoute` case, a sidebar section view whose rows are tagged with that case, and a branch
/// in `detail`. Keep tool logic in its own library target (like FaceLibrary) so it stays testable without UI.
struct AppShell: View {
    @State private var route: AppRoute? = AppShell.startRoute
    @State private var path = NavigationPath()
    @EnvironmentObject var faces: FaceGroupingModel
    @Environment(\.openWindow) private var openWindow

    /// SUZU_START_ROUTE=<AppRoute key> (testing) wins; else Settings › General › "Open the app on".
    static var startRoute: AppRoute {
        if let r = ProcessInfo.processInfo.environment["SUZU_START_ROUTE"].flatMap(AppRoute.init(key:)) { return r }
        let start = StartScreen(rawValue: UserDefaults.standard.string(forKey: "startScreen") ?? "") ?? .overview
        switch start {
        case .overview: return .overview
        case .files: return .files
        case .people: return .faces(.people)
        case .last: return UserDefaults.standard.string(forKey: "lastRoute").flatMap(AppRoute.init(key:)) ?? .overview
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $route) {
                HomeSidebar()
                FaceGroupingSidebar()
                ToolsSidebar()
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .safeAreaInset(edge: .top) { SidebarHeader() }
            .safeAreaInset(edge: .bottom) { FaceGroupingStatus() }
            .toolbar { FaceGroupingSidebarToolbar() }
        } detail: {
            NavigationStack(path: $path) {
                switch route ?? .overview {
                case .overview: OverviewView(route: $route)
                case .files: FilesBrowser()
                case .faces(let r): FaceGroupingDetail(route: r, path: $path)
                case .tool(let t): ToolDetail(route: t)
                }
            }
        }
        .onChange(of: route) {
            path = NavigationPath()
            if let route { UserDefaults.standard.set(route.key, forKey: "lastRoute") }
        }
        // Another project: a person, album or folder page from the old one would show the wrong files.
        .onChange(of: faces.currentProject) {
            path = NavigationPath()
            if case .faces(let r) = route, r != .people, r != .toName, r != .unassigned, r != .search, r != .rules { route = .faces(.people) }
        }
        // SUZU_START_EDIT=/a.jpg:/b.jpg (testing): open those photos in the Edit & Export window at once.
        // SUZU_START_PERSON=<id> (testing): open that person's page.
        .task {
            let env = ProcessInfo.processInfo.environment
            if let p = env["SUZU_START_EDIT"], !p.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                openWindow.edit(p.split(separator: ":").map(String.init))
            }
            if let id = env["SUZU_START_PERSON"].flatMap(Int64.init) {
                try? await Task.sleep(for: .seconds(2))
                route = .faces(.people)
                // The route change clears the path (onChange below); push after it has.
                try? await Task.sleep(for: .milliseconds(300))
                path.append(PersonRoute(id: id))
            }
        }
        .sheet(isPresented: $faces.askNewProject) { NewProjectSheet() }
        .sheet(isPresented: $faces.askShareTeam) { ShareTeamSheet() }
        .sheet(isPresented: $faces.askJoinTeam) { JoinTeamSheet() }
    }
}

/// The first rows of the sidebar: the event at a glance, and its files.
struct HomeSidebar: View {
    @EnvironmentObject var model: FaceGroupingModel

    var body: some View {
        Section {
            Label("Overview", systemImage: "square.grid.2x2").tag(AppRoute.overview)
            Label("Files", systemImage: "folder")
                .badge(model.stats.files)
                .tag(AppRoute.files)
        }
    }
}
