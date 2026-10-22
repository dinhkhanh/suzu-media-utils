import AppKit
import CoreImage
import FaceCore
import ImageIO
import MediaKit
import SwiftUI

/// Decoded preview photos (about 1600 px), so switching edits or flipping between a few photos is instant.
final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    static let context = CIContext(options: [.cacheIntermediates: false])

    struct Entry {
        var image: CGImage
        /// Full-size pixel dimensions, upright (for the output size shown under the preview).
        var pixelSize: CGSize
        /// Faces found in the photo, for crops of photos that aren't in the library.
        var detected: FocusHint?
        var detectedDone = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func entry(_ url: URL) -> Entry? {
        if let e = lock.withLock({ entries[url.path] }) { return e }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 1600,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var w = Double(p?[kCGImagePropertyPixelWidth] as? Int ?? cg.width), h = Double(p?[kCGImagePropertyPixelHeight] as? Int ?? cg.height)
        if let o = p?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let e = Entry(image: cg, pixelSize: CGSize(width: w, height: h))
        store(url.path, e)
        return e
    }

    func focus(_ url: URL, given: FocusHint?) -> FocusHint? {
        if let given { return given }
        guard var e = entry(url) else { return nil }
        if !e.detectedDone {
            e.detected = EditPipeline.detectFaces(CIImage(cgImage: e.image))
            e.detectedDone = true
            store(url.path, e)
        }
        return e.detected
    }

    private func store(_ key: String, _ e: Entry) {
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            entries[key] = e
            while order.count > 12 { entries[order.removeFirst()] = nil }
        }
    }

    struct Rendered { var image: NSImage; var outputSize: CGSize; var warning: String? }

    /// The photo through the recipe (or untouched), plus the size the exported file will have.
    func render(_ item: ToolItem, recipe: EditRecipe, original: Bool) -> Rendered? {
        guard let e = entry(item.url) else { return nil }
        var r = recipe
        r.maxLongSide = nil
        var warning: String?
        let input = CIImage(cgImage: e.image)
        var out = input
        if !original {
            let focus = r.aspect == nil ? nil : self.focus(item.url, given: item.focus)
            do { out = try EditPipeline.apply(r, to: input, focus: focus) } catch {
                warning = "The watermark logo can't be read: choose it again"
                r.watermark = nil
                out = (try? EditPipeline.apply(r, to: input, focus: focus)) ?? input
            }
        }
        guard let cg = Self.context.createCGImage(out, from: out.extent) else { return nil }
        return Rendered(image: NSImage(cgImage: cg, size: .zero), outputSize: Self.outputSize(e.pixelSize, recipe: recipe), warning: warning)
    }

    static func outputSize(_ size: CGSize, recipe: EditRecipe) -> CGSize {
        var w = size.width, h = size.height
        if let a = recipe.aspect { let cw = min(w, h * a.ratio), ch = min(h, w / a.ratio); w = cw; h = ch }
        if let long = recipe.maxLongSide, Double(long) < max(w, h) {
            let s = Double(long) / max(w, h); w *= s; h *= s
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

/// The big preview of an edit: the selected photo as it will be exported, a film strip to pick another photo, a
/// before/after switch, and click-to-place for the watermark.
struct EditPreview: View {
    @Binding var recipe: EditRecipe
    let samples: [ToolItem]
    var filmstrip = true
    /// When set, photos can be ticked off: the action then applies only to the ticked ones (this set holds the
    /// unticked ones, so photos added later start ticked).
    var excluded: Binding<Set<ToolItem>>? = nil
    @State private var index = 0
    @State private var gridMode = false
    /// Last photo ticked or unticked, for Shift-click ranges.
    @State private var anchor: Int?
    @State private var rendered: PreviewCache.Rendered?
    @State private var showOriginal = false
    @State private var rendering = false
    @State private var hovering = false

    var current: ToolItem? { samples.isEmpty ? nil : samples[min(index, samples.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            if showGrid { grid } else { previewArea }
            if excluded != nil && samples.count > 1 { selectionBar }
            if filmstrip && samples.count > 1 && !showGrid { strip }
        }
        .onChange(of: samples.count) { if index >= samples.count { index = 0 } }
        .onChange(of: samples.count > 1) { if samples.count > 1, ProcessInfo.processInfo.environment["SUZU_TOOL_SAMPLES"] == "grid" { gridMode = true } }
        .task(id: "\(recipe.hashValue)|\(current?.url.path ?? "")|\(showOriginal)") { await render() }
    }

    var previewArea: some View {
        ZStack {
            Color(nsColor: NSColor(white: 0.13, alpha: 1))
            if let rendered {
                Image(nsImage: rendered.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .overlay { placementLayer }
                    .padding(18)
            } else if samples.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
                    Text("Add photos or people to preview the edit").font(.callout)
                }
                .foregroundStyle(.white.opacity(0.45))
            }
            if rendering { ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12) }
        }
        .overlay(alignment: .topTrailing) {
            Picker("", selection: $showOriginal) {
                Text("Edited").tag(false)
                Text("Original").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(10)
            .help("Compare with the original photo")
        }
        .overlay(alignment: .bottom) { infoBar }
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// Thirds overlay while hovering with a watermark on; a click puts the watermark in that ninth.
    @ViewBuilder
    var placementLayer: some View {
        if recipe.watermark != nil && !showOriginal {
            GeometryReader { g in
                ZStack {
                    if hovering {
                        Path { p in
                            for i in 1...2 {
                                let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                            }
                        }
                        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { loc in
                            let col = min(2, max(0, Int(loc.x / (g.size.width / 3)))), row = min(2, max(0, Int(loc.y / (g.size.height / 3))))
                            recipe.watermark?.position = WatermarkSpec.Position.allCases[row * 3 + col]
                        }
                }
            }
            .onHover { hovering = $0 }
            .help("Click where the watermark should go")
        }
    }

    var infoBar: some View {
        HStack(spacing: 10) {
            if samples.count > 1 {
                Button { index = (index - 1 + samples.count) % samples.count } label: { Image(systemName: "chevron.left") }
                Text("\(min(index, samples.count - 1) + 1) of \(samples.count)").monospacedDigit()
                Button { index = (index + 1) % samples.count } label: { Image(systemName: "chevron.right") }
            }
            if let current { Text(current.url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
            if let s = rendered?.outputSize, !showOriginal { Text("→ \(Int(s.width)) × \(Int(s.height)) px \(recipe.outputFormat.label)").monospacedDigit() }
            if let w = rendered?.warning { Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
        .opacity(samples.isEmpty ? 0 : 1)
    }

    var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    // Long lists only show their start; the arrows still step through all of them.
                    ForEach(Array(samples.prefix(300).enumerated()), id: \.offset) { i, item in
                        StripThumb(url: item.url, selected: i == index, checked: isChecked(item), onCheck: { tick(i) })
                            .id(i)
                            .onTapGesture {
                                // Click previews; ⌘-click ticks or unticks; ⇧-click ticks a range.
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.shift) || mods.contains(.command) { tick(i) } else { index = i }
                            }
                            .help(item.url.lastPathComponent)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(height: 112)
            .background(Color(nsColor: NSColor(white: 0.09, alpha: 1)))
            .environment(\.colorScheme, .dark)
            .onChange(of: index) { withAnimation { proxy.scrollTo(index, anchor: .center) } }
        }
    }

    var showGrid: Bool { gridMode && excluded != nil && samples.count > 1 }

    func isChecked(_ item: ToolItem) -> Bool? { excluded.map { !$0.wrappedValue.contains(item) } }

    /// Ticks or unticks a photo; with Shift, every photo from the last one clicked gets the same state.
    func tick(_ i: Int) {
        guard let excluded, i < samples.count else { return }
        let on = excluded.wrappedValue.contains(samples[i])
        let range = NSEvent.modifierFlags.contains(.shift) && anchor != nil ? min(anchor!, i)...max(anchor!, i) : i...i
        var set = excluded.wrappedValue
        for k in range where k < samples.count { if on { set.remove(samples[k]) } else { set.insert(samples[k]) } }
        excluded.wrappedValue = set
        anchor = i
    }

    var selectionBar: some View {
        let total = samples.count, off = excluded?.wrappedValue.count ?? 0
        return HStack(spacing: 10) {
            Picker("", selection: $gridMode) {
                Image(systemName: "photo").tag(false).help("Large preview")
                Image(systemName: "square.grid.3x3").tag(true).help("All photos as a grid, to tick many at once")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text(off == 0 ? "All \(total) photos" : "\(total - off) of \(total) photos").monospacedDigit()
            if let item = current, !showGrid {
                Toggle("Include this one", isOn: Binding(get: { isChecked(item) ?? true }, set: { _ in tick(min(index, total - 1)) }))
                    .toggleStyle(.checkbox)
            }
            Spacer()
            Button("Select All") { excluded?.wrappedValue = [] }.disabled(off == 0)
            Button("Select None") { excluded?.wrappedValue = Set(samples) }.disabled(off == total)
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: NSColor(white: 0.09, alpha: 1)))
        .environment(\.colorScheme, .dark)
    }

    /// Every photo, bigger: click to tick or untick (⇧-click for a range), double-click to preview it large.
    var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { i, item in
                        StripThumb(url: item.url, selected: i == index, checked: isChecked(item), side: 150, onCheck: { tick(i) })
                            .id(i)
                            .onTapGesture(count: 2) { index = i; gridMode = false }
                            .onTapGesture { tick(i) }
                            .help("\(item.url.lastPathComponent)\(item.personName.map { " · \($0)" } ?? "")")
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: NSColor(white: 0.13, alpha: 1)))
            .onAppear { proxy.scrollTo(index, anchor: .center) }
        }
        .environment(\.colorScheme, .dark)
    }

    func render() async {
        guard let item = current else { rendered = nil; return }
        // Let sliders settle; a newer change cancels this one.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        rendering = true
        let recipe = recipe, original = showOriginal
        let result = await Task.detached(priority: .userInitiated) { PreviewCache.shared.render(item, recipe: recipe, original: original) }.value
        guard !Task.isCancelled else { return }
        rendering = false
        if let result { rendered = result }
    }
}

struct StripThumb: View {
    let url: URL
    let selected: Bool
    /// nil = no tick box; false = left out (dimmed).
    var checked: Bool? = nil
    var side: CGFloat = 96
    var onCheck: () -> Void = {}
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.08))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(checked == false ? 0.35 : 1)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
        .overlay(alignment: .topTrailing) {
            if let checked {
                Button(action: onCheck) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: side > 120 ? 20 : 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, checked ? Color.accentColor : Color.black.opacity(0.35))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help(checked ? "Included — click to leave out" : "Left out — click to include")
            }
        }
        .task(id: url) { image = await Thumbnails.shared.media(url, time: nil, side: side) }
    }
}
