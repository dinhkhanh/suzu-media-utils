import SwiftUI

/// Small pieces every screen shares: filter chips, the floating bar over a selection, section labels.

/// A capsule toggle: a session, a person, a filter. Coral when on.
struct Chip<Leading: View>: View {
    let title: String
    var count: String? = nil
    var on = false
    var help: String? = nil
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                leading
                Text(title).lineLimit(1)
                if let count { Text(count).foregroundStyle(on ? .white.opacity(0.8) : .secondary).monospacedDigit() }
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(Capsule().fill(on ? Color.accent : Color.secondary.opacity(0.13)))
            .foregroundStyle(on ? .white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}

extension Chip where Leading == EmptyView {
    init(_ title: String, count: String? = nil, on: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, count: count, on: on, help: help, action: action) { EmptyView() }
    }
}

/// A chip with a person's face in it.
struct FaceChip: View {
    let faceId: Int64?
    let title: String
    var count: String? = nil
    var on = false
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Chip(title: title, count: count, on: on, help: help, action: action) {
            FaceImage(faceId: faceId, side: 18).clipShape(Circle()).padding(.leading, -5)
        }
    }
}

/// The bar that floats over a grid while something is selected: what is selected, and what can be done with it.
struct SelectionBar<Content: View>: View {
    let title: String
    let clear: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.semibold).padding(.trailing, 6).lineLimit(1)
            content
            Button(action: clear) { Image(systemName: "xmark") }
                .help("Deselect")
                .keyboardShortcut(.escape, modifiers: [])
        }
        .controlSize(.small)
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(.bottom, 16)
    }
}

/// A line of filter chips under the toolbar, scrolling sideways when there are many.
struct ChipRow<Content: View>: View {
    var divider = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) { content }.padding(.horizontal, 16).padding(.vertical, 7)
            }
            .scrollIndicators(.never)
            if divider { Divider() }
        }
    }
}

/// "FILES", "LOOK": the label above a group of controls.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
    }
}
