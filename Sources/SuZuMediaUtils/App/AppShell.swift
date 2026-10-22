import SwiftUI

/// Where the user is in the app. Add a case per tool; the tool decides what its own route values mean.
enum AppRoute: Hashable {
    case faces(FaceRoute)
}

/// Main window: one sidebar listing every tool's sections, and the selected tool's views on the right.
///
/// To add a tool: add an `AppRoute` case, a sidebar section view whose rows are tagged with that case, and a branch
/// in `detail`. Keep tool logic in its own library target (like FaceLibrary) so it stays testable without UI.
struct AppShell: View {
    @State private var route: AppRoute? = .faces(.people)
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: $route) {
                FaceGroupingSidebar()
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) { FaceGroupingStatus() }
            .toolbar { FaceGroupingSidebarToolbar() }
        } detail: {
            NavigationStack(path: $path) {
                switch route ?? .faces(.people) {
                case .faces(let r): FaceGroupingDetail(route: r, path: $path)
                }
            }
        }
        .onChange(of: route) { path = NavigationPath() }
    }
}
