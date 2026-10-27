import SwiftUI

/// Small pieces every screen shares: filter chips, the floating bar over a selection, section labels.

/// A capsule toggle: a session, a person, a filter. The accent colour when on.
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

/// A switch at the right edge of its row, the label at the left, the way Settings lays them out.
struct LabeledSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var help: String? = nil

    init(_ title: String, isOn: Binding<Bool>, help: String? = nil) {
        self.title = title
        _isOn = isOn
        self.help = help
    }

    var body: some View {
        HStack {
            Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .help(help ?? "")
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

/// One line of text. When it doesn't fit, `scrolling` (the mouse over its row) slides it to the end at reading
/// pace, rests there, and eases back to the start while the mouse stays; the clipped edge fades out. Text that fits
/// is centred and never moves.
struct MarqueeText: View {
    let text: String
    var font: Font = .headline
    /// Whether the mouse is over the row (hit testing stays with the row, not with this overlay).
    var scrolling: Bool
    /// Points per second: about the pace a name is read at.
    var speed: CGFloat = 40
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var run = 0

    var overflow: CGFloat { max(0, textWidth - boxWidth) }

    var body: some View {
        Text(text).font(font).lineLimit(1).fixedSize()
            .background(GeometryReader { g in Color.clear.onAppear { textWidth = g.size.width }.onChange(of: g.size.width) { textWidth = $1 } })
            .offset(x: offset)
            .frame(maxWidth: .infinity, alignment: overflow > 0 ? .leading : .center)
            .clipped()
            .mask(fade)
            .background(GeometryReader { g in Color.clear.onAppear { boxWidth = g.size.width }.onChange(of: g.size.width) { boxWidth = $1 } })
            .onChange(of: scrolling) { _, over in
                run += 1
                if over { start(run) } else { withAnimation(.easeOut(duration: 0.35)) { offset = 0 } }
            }
            .onChange(of: text) { run += 1; offset = 0 }
    }

    /// Clear at an edge that hides text: the trailing one until the end is reached, the leading one once moved.
    var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: offset < 0 ? 12 : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: overflow > 0 && offset > -overflow + 1 ? 12 : 0)
        }
    }

    /// One pass: a short pause, slide to the end, rest, ease back, pause, and again while the mouse stays. `token`
    /// tells a pass that the mouse left (or came back) meanwhile to stop.
    func start(_ token: Int) {
        let distance = overflow
        guard distance > 0 else { return }
        let slide = Double(distance / speed)
        withAnimation(.linear(duration: slide).delay(0.5)) { offset = -distance }
        DispatchQueue.main.asyncAfter(deadline: .now() + slide + 0.5 + 1.5) {
            guard run == token, scrolling else { return }
            withAnimation(.easeInOut(duration: 0.7)) { offset = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if run == token, scrolling { start(token) } }
        }
    }
}
