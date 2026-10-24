import AppKit
import SwiftUI

/// Light, dark, or whatever macOS is set to (System › Appearance, Auto included). Applied once at the root of every
/// window (see SuZuMediaUtilsApp), so sheets and the Edit & Export window follow.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    /// nil hands control back to macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The colour of selection, toggles and primary buttons: SuZu's coral (from the app icon) or the Mac's own accent.
enum AccentChoice: String, CaseIterable, Identifiable {
    case coral, system
    var id: Self { self }
    var title: String { self == .coral ? "Coral" : "Mac accent colour" }
    /// nil = the system accent.
    var color: Color? { self == .coral ? .coral : nil }
    static var current: AccentChoice { AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .coral }
}

/// The screen the app opens on.
enum StartScreen: String, CaseIterable, Identifiable {
    case overview, files, people, last
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .files: "Files"
        case .people: "People"
        case .last: "Where I left off"
        }
    }
}

extension Color {
    /// Coral, a touch darker in light mode so white text on it stays readable (≥ 4.5:1).
    static let coral = Color(nsColor: NSColor(name: "coral") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.949, green: 0.361, blue: 0.310, alpha: 1)
            : NSColor(srgbRed: 0.851, green: 0.271, blue: 0.184, alpha: 1)
    })
    /// The app's accent as the user set it (Settings › General); `.accentColor` stays the system's.
    static var accent: Color { AccentChoice.current.color ?? .accentColor }
    /// Cards and panels on the window background.
    static let panel = Color(nsColor: NSColor(name: "panel") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.106, green: 0.106, blue: 0.125, alpha: 1) : .white
    })
    /// "Needs you": amber, darker in light mode for contrast.
    static let amber = Color(nsColor: NSColor(name: "amber") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.969, green: 0.631, blue: 0.325, alpha: 1)
            : NSColor(srgbRed: 0.706, green: 0.325, blue: 0.035, alpha: 1)
    })
    /// Done, synced, delivered.
    static let good = Color(nsColor: NSColor(name: "good") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1)
            : NSColor(srgbRed: 0.118, green: 0.557, blue: 0.243, alpha: 1)
    })
}

/// Settings › General: appearance, accent and the start screen.
struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("accent") private var accent = AccentChoice.coral
    @AppStorage("startScreen") private var start = StartScreen.overview
    @EnvironmentObject private var faces: FaceGroupingModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(Appearance.allCases) { a in
                        AppearanceOption(appearance: a, selected: appearance == a) { appearance = a }
                    }
                }
                .frame(maxWidth: .infinity)
                Text("System follows macOS › Appearance, including Auto (light by day, dark at night). Every window follows this setting; photo previews keep a dark ground either way.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Appearance")
            }
            Section {
                Picker("Accent colour", selection: $accent) {
                    ForEach(AccentChoice.allCases) { c in
                        HStack(spacing: 8) {
                            Circle().fill(c.color ?? Color(nsColor: .controlAccentColor)).frame(width: 12, height: 12)
                            Text(c.title)
                        }
                        .tag(c)
                    }
                }
                Picker("Open the app on", selection: $start) {
                    ForEach(StartScreen.allCases) { Text($0.title).tag($0) }
                }
                Picker("Start a new session after", selection: $faces.sessionGapMinutes) {
                    ForEach([10, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes without a shot").tag($0) }
                }
                Text("Sessions split an event wherever nobody shot for a while: the opening, each match, the awards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 540)
    }
}

/// One of the three appearance choices, as a little window: sidebar, a card, a coral line.
struct AppearanceOption: View {
    let appearance: Appearance
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 8) {
                preview
                    .frame(width: 150, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 1))
                Text(appearance.title).font(.callout.weight(.medium))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accent.opacity(0.1) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accent : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The selected card is its own highlight; the first-responder ring on top of it looks like a glitch.
        .focusEffectDisabled()
        .accessibilityLabel(appearance.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder var preview: some View {
        switch appearance {
        case .light: window(dark: false)
        case .dark: window(dark: true)
        case .system:
            ZStack {
                window(dark: false)
                window(dark: true).mask(alignment: .trailing) { Rectangle().frame(width: 75) }
            }
        }
    }

    func window(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(dark ? Color(white: 0.106) : Color(white: 0.925)).frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(dark ? Color(white: 0.25) : Color(white: 0.78)).frame(width: 60, height: 5)
                RoundedRectangle(cornerRadius: 3).fill(dark ? Color(white: 0.13) : .white).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)))
                Capsule().fill(dark ? Color(white: 0.2) : Color(white: 0.85)).frame(width: 80, height: 5)
                Capsule().fill(Color.coral).frame(width: 40, height: 5)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dark ? Color(white: 0.078) : Color(white: 0.96))
        }
    }
}
