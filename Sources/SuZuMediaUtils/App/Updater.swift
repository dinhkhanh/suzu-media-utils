import Combine
import Sparkle
import SwiftUI

/// Automatic updates (Sparkle): once a day the app reads the appcast named in Info.plist (`SUFeedURL`), and offers
/// a signed update (`SUPublicEDKey`) when there is one; "Check for Updates…" in the app menu does it now.
/// Only runs from the built app bundle (scripts/build-app.sh); a bare `swift run` has no Info.plist to read.
@MainActor
final class Updater: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    private var cancellables: Set<AnyCancellable> = []

    static var available: Bool { Bundle.main.infoDictionary?["SUFeedURL"] != nil }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.available, updaterDelegate: nil, userDriverDelegate: nil)
        guard Self.available else { return }
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &cancellables)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main).sink { [weak self] in self?.lastCheck = $0 }.store(in: &cancellables)
    }

    func check() { controller.checkForUpdates(nil) }

    var automatic: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}

struct UpdateSettings: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Updater.version)
                if Updater.available {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                    LabeledContent("Last checked", value: updater.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    Button("Check Now") { updater.check() }.disabled(!updater.canCheck)
                } else {
                    Text("Updates are checked in the built app (scripts/build-app.sh).").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Updates are downloaded from the address built into the app, checked against its signature, and installed when you say so.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}
