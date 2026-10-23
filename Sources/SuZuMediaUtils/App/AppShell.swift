import SwiftUI

/// Where the user is in the app. Add a case per tool; the tool decides what its own route values mean.
enum AppRoute: Hashable {
    /// The project's photos and videos by folder (the start screen).
    case files
    case faces(FaceRoute)
    case tool(ToolRoute)
}

/// Main window: one sidebar listing every tool's sections, and the selected tool's views on the right.
///
/// To add a tool: add an `AppRoute` case, a sidebar section view whose rows are tagged with that case, and a branch
/// in `detail`. Keep tool logic in its own library target (like FaceLibrary) so it stays testable without UI.
struct AppShell: View {
    @State private var route: AppRoute? = AppShell.startRoute
    @State private var path = NavigationPath()
    @EnvironmentObject var faces: FaceGroupingModel
    @Environment(\.openWindow) private var openWindow

    /// SUZU_START_ROUTE=people | unassigned | search | rules | album.<id> | tool.<name> (testing): open the app on that screen.
    static var startRoute: AppRoute {
        let r = ProcessInfo.processInfo.environment["SUZU_START_ROUTE"] ?? ""
        if r.hasPrefix("album."), let id = Int64(r.dropFirst(6)) { return .faces(.album(id)) }
        if r.hasPrefix("tool."), let t = ToolRoute(rawValue: String(r.dropFirst(5))) { return .tool(t) }
        switch r {
        case "search": return .faces(.search)
        case "rules": return .faces(.rules)
        case "unassigned": return .faces(.unassigned)
        case "people": return .faces(.people)
        default: return .files
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $route) {
                FilesSidebar()
                FaceGroupingSidebar()
                ToolsSidebar()
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .top) { SidebarHeader() }
            .safeAreaInset(edge: .bottom) { FaceGroupingStatus() }
            .toolbar { FaceGroupingSidebarToolbar() }
        } detail: {
            NavigationStack(path: $path) {
                switch route ?? .files {
                case .files: FilesBrowser()
                case .faces(let r): FaceGroupingDetail(route: r, path: $path)
                case .tool(let t): ToolDetail(route: t)
                }
            }
        }
        .onChange(of: route) { path = NavigationPath() }
        // Another project: a person, album or folder page from the old one would show the wrong files.
        .onChange(of: faces.currentProject) {
            path = NavigationPath()
            if case .faces(let r) = route, r != .people, r != .unassigned, r != .search, r != .rules { route = .faces(.people) }
        }
        // SUZU_START_EDIT=/a.jpg:/b.jpg (testing): open those photos in the Edit & Export window at once.
        .task {
            if let p = ProcessInfo.processInfo.environment["SUZU_START_EDIT"], !p.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                openWindow.edit(p.split(separator: ":").map(String.init))
            }
        }
        .sheet(isPresented: $faces.askNewProject) { NewProjectSheet() }
        .sheet(isPresented: $faces.askShareTeam) { ShareTeamSheet() }
        .sheet(isPresented: $faces.askJoinTeam) { JoinTeamSheet() }
    }
}
