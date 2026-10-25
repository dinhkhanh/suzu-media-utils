import FaceLibrary
import SwiftUI

/// The event's sessions (opening, matches, awards…) as a row of buttons: pick one to see only who was there, and
/// what they're in. Sessions split wherever nobody shot for a while; right-click to name one.
struct SessionBar: View {
    @EnvironmentObject var model: FaceGroupingModel
    /// A rule under the bar (screens whose content starts right below it).
    var divider = false
    @State private var renaming: EventSession?
    @State private var newName = ""

    var body: some View {
        // Shown whenever the open project has capture times, even as one session, so every screen looks the same
        // and a session can be named before the next one starts.
        if model.currentProject != nil && !model.sessions.isEmpty {
            VStack(spacing: 0) {
                bar
                if divider { Divider() }
            }
            // The bar is part of the screen's header: the toolbar draws no line of its own above it, so the header
            // has one separator (under the bar) instead of two stacked ones.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }

    var bar: some View {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        let n = model.sessions.count
                        chip(title: "Whole event", detail: "\(n) session\(n == 1 ? "" : "s")", selected: model.currentSession == nil) {
                            model.sessionAnchor = nil
                        }
                        ForEach(model.sessions) { s in
                            chip(title: model.sessionTitle(s), detail: detail(s), selected: model.currentSession?.index == s.index) {
                                model.sessionAnchor = model.currentSession?.index == s.index ? nil : s.start
                            }
                            .contextMenu {
                                Button("Rename Session…") { newName = s.name ?? ""; renaming = s }
                                if s.name != nil { Button("Remove Name") { model.renameSession(s, to: "") } }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                Menu {
                    Picker("Start a new session after", selection: $model.sessionGapMinutes) {
                        ForEach([10, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes without a shot").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "timer")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Sessions split wherever nobody shot for \(model.sessionGapMinutes) minutes")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName, prompt: Text("e.g. Opening, Final, Awards"))
                Button("Rename") { if let s = renaming { model.renameSession(s, to: newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                if let s = renaming { Text(model.sessionTime(s)) }
            }
    }

    func detail(_ s: EventSession) -> String {
        var parts: [String] = []
        if s.name != nil { parts.append(model.sessionTime(s)) }
        parts.append("\(s.photos) photo\(s.photos == 1 ? "" : "s")")
        if s.videos > 0 { parts.append("\(s.videos) video\(s.videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    func chip(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : .primary)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accent : Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A new page hands keyboard focus to its first control, which would be this chip: no ring on it.
        .focusEffectDisabled()
    }
}

/// A session picker for forms and filter rows (person pages, search, batch tools, export dialogs).
struct SessionPicker: View {
    @EnvironmentObject var model: FaceGroupingModel
    var allTitle = "Whole event"

    var body: some View {
        if model.currentProject != nil && !model.sessions.isEmpty {
            Picker("", selection: Binding(get: { model.currentSession?.start }, set: { model.sessionAnchor = $0 })) {
                Text(allTitle).tag(Double?.none)
                ForEach(model.sessions) { s in
                    Text("\(model.sessionTitle(s)) (\(s.photos + s.videos))").tag(Double?.some(s.start))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Only files from one session of the event (split wherever nobody shot for \(model.sessionGapMinutes) minutes)")
        }
    }
}
